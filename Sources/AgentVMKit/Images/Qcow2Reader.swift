// Sources/AgentVMKit/Images/Qcow2Reader.swift
//
// Reads a qcow2 disk image (version 2 or 3) and writes the disk in it as a raw file with holes.
// Ubuntu publishes its cloud image in this format only, with zlib-compressed clusters, and
// macOS has no tool that reads it.
//
// The format, as far as this reads it: a header; a first table (L1) of offsets of second tables
// (L2), each one cluster long; an L2 entry names where one cluster of the disk is in the file,
// plain or compressed (raw deflate), or says that it is not there (zeros).
//
// The file is checked against its checksum before this reads it (LinuxBaseCache), or it is a
// file the person named. It is still read as a file from the network:
//
// - Every offset the file names is checked against the file's length before it is read, and
//   the disk's size against a limit before anything is written.
// - Memory is taken by the cluster size (at most 2 MiB) and by the first table (at most 32 MB),
//   never by a number that was not checked.
// - A compressed cluster must inflate to exactly one cluster.
// - What this does not read is refused by name: a backing file, encryption, an external data
//   file, another compression, extended tables, and any feature bit it does not know.
//
// Snapshots inside the file are not looked at: the disk is the file's current state.

import Darwin
import Foundation
import zlib

enum Qcow2Reader {
    static let magic: [UInt8] = [0x51, 0x46, 0x49, 0xFB]
    /// The largest disk a file may declare.
    static let maximumSize: Int64 = 64 << 30
    /// The largest first table that is read (a 64 GB disk of 512-byte clusters needs 16 MB).
    static let maximumTableBytes: Int64 = 32 << 20
    /// The bytes of the header that are looked at.
    static let headerBytes = 112

    /// Why a file cannot be read, as the end of a sentence: "it needs a backing file".
    struct Problem: Error, Equatable, CustomStringConvertible {
        var description: String

        init(_ description: String) {
            self.description = description
        }
    }

    struct Header: Equatable {
        var version: Int
        var clusterBits: Int
        /// The disk's size in bytes.
        var size: Int64
        /// The entries of the first table that the disk's size needs.
        var tableEntries: Int
        var tableOffset: Int64

        var clusterSize: Int {
            return 1 << clusterBits
        }

        /// Entries in one second table.
        var entriesPerTable: Int {
            return clusterSize / 8
        }
    }

    /// Whether a file's first bytes are a qcow2 file's.
    static func isQcow2(_ head: [UInt8]) -> Bool {
        return head.count >= 4 && Array(head[0..<4]) == magic
    }

    private static func big32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        return bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func big64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        return bytes[offset..<(offset + 8)].reduce(0) { $0 << 8 | UInt64($1) }
    }

    /// The header in `bytes` (the file's first `headerBytes`, or fewer for a shorter file) of a
    /// file `fileSize` long, checked; or what in it is not read.
    static func header(_ bytes: [UInt8], fileSize: Int64) throws -> Header {
        guard bytes.count >= 72 else {
            throw Problem("its header is cut short")
        }
        guard isQcow2(bytes) else {
            throw Problem("it is not a qcow2 file")
        }
        let version = big32(bytes, 4)
        guard version == 2 || version == 3 else {
            throw Problem("it is qcow2 version \(version), and versions 2 and 3 are read")
        }
        if version == 3 {
            guard bytes.count >= 104 else {
                throw Problem("its header is cut short")
            }
            let features = big64(bytes, 72)
            let named: [(UInt64, String)] = [
                (1 << 0, "it was not closed properly (it is marked as in use)"),
                (1 << 1, "it is marked as damaged"),
                (1 << 2, "it needs an external data file"),
                (1 << 3, "its compression is not zlib"),
                (1 << 4, "it has extended cluster tables"),
            ]
            for (bit, reason) in named where features & bit != 0 {
                throw Problem(reason)
            }
            guard features == 0 else {
                throw Problem("it needs a feature this agent-vm does not know (feature bits 0x\(String(features, radix: 16)))")
            }
            let length = big32(bytes, 100)
            guard length >= 104 else {
                throw Problem("its header is cut short")
            }
            if length > 104 {
                guard bytes.count > 104 else {
                    throw Problem("its header is cut short")
                }
                guard bytes[104] == 0 else {
                    throw Problem("its compression is not zlib")
                }
            }
        }
        guard big64(bytes, 8) == 0 else {
            throw Problem("it needs a backing file")
        }
        guard big32(bytes, 32) == 0 else {
            throw Problem("it is encrypted")
        }
        let clusterBits = big32(bytes, 20)
        guard clusterBits >= 9, clusterBits <= 21 else {
            throw Problem("its cluster size is outside 512 bytes to 2 MiB")
        }
        let declared = big64(bytes, 24)
        guard declared > 0, declared % 512 == 0 else {
            throw Problem("it declares no disk")
        }
        guard declared <= UInt64(maximumSize) else {
            throw Problem("it declares a disk of \(declared >> 30) GB, and more than \(maximumSize >> 30) GB is not read")
        }
        let size = Int64(declared)
        let clusterSize = Int64(1) << Int64(clusterBits)
        // What one entry of the first table covers: a second table's entries, a cluster each.
        let covered = clusterSize * (clusterSize / 8)
        let needed = (size + covered - 1) / covered
        let entries = Int64(big32(bytes, 36))
        guard entries >= needed else {
            throw Problem("its cluster table is too short for its disk")
        }
        guard entries * 8 <= maximumTableBytes else {
            throw Problem("its cluster table is larger than \(maximumTableBytes >> 20) MB")
        }
        let offset = big64(bytes, 40)
        guard offset >= UInt64(headerBytes), offset % UInt64(clusterSize) == 0, offset <= UInt64(fileSize), UInt64(fileSize) - offset >= UInt64(needed * 8) else {
            throw Problem("its cluster table lies beyond the file's end")
        }
        return Header(version: Int(version), clusterBits: Int(clusterBits), size: size, tableEntries: Int(needed), tableOffset: Int64(offset))
    }

    /// The checked header of the file at `source`.
    static func header(of source: URL) throws -> Header {
        let descriptor = open(source.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw AgentVMError.system(operation: "open \(source.path)", code: errno)
        }
        defer { close(descriptor) }
        return try header(of: descriptor, path: source.path).header
    }

    private static func header(of descriptor: Int32, path: String) throws -> (header: Header, fileSize: Int64) {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw AgentVMError.system(operation: "read \(path)", code: errno)
        }
        var head = [UInt8](repeating: 0, count: headerBytes)
        let count = pread(descriptor, &head, head.count, 0)
        guard count >= 0 else {
            throw AgentVMError.system(operation: "read \(path)", code: errno)
        }
        return (try header(Array(head[0..<count]), fileSize: Int64(info.st_size)), Int64(info.st_size))
    }

    /// Writes the disk in `source` to `disk`, which must not exist, with holes where the disk
    /// has zeros, and returns the disk's size. The caller removes `disk` after a failure.
    static func convert(_ source: URL, to disk: URL, cancellation: BuildCancellation? = nil) throws -> Int64 {
        let input = open(source.path, O_RDONLY | O_CLOEXEC)
        guard input >= 0 else {
            throw AgentVMError.system(operation: "open \(source.path)", code: errno)
        }
        defer { close(input) }
        let (header, fileSize) = try header(of: input, path: source.path)
        let output = open(disk.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard output >= 0 else {
            throw AgentVMError.system(operation: "create \(disk.path)", code: errno)
        }
        defer { close(output) }

        let clusterSize = header.clusterSize
        let cluster = Int64(clusterSize)
        // Bits 9 to 55 of an entry are an offset in the file; the rest are flags.
        let offsetMask: UInt64 = 0x00FF_FFFF_FFFF_FE00
        // A compressed entry: the low bits are where the data starts, the bits above them how
        // many more 512-byte sectors it reaches into.
        let startBits = UInt64(62 - (header.clusterBits - 8))
        let startMask = (UInt64(1) << startBits) - 1
        let sectorMask = (UInt64(1) << UInt64(header.clusterBits - 8)) - 1

        func read(_ buffer: UnsafeMutableRawPointer, _ count: Int, at offset: Int64) throws {
            var done = 0
            while done < count {
                let got = pread(input, buffer + done, count - done, offset + Int64(done))
                if got < 0 && errno == EINTR {
                    continue
                }
                guard got >= 0 else {
                    throw AgentVMError.system(operation: "read \(source.path)", code: errno)
                }
                guard got > 0 else {
                    throw Problem("the file ends inside a cluster")
                }
                done += got
            }
        }

        let table = UnsafeMutableRawPointer.allocate(byteCount: header.tableEntries * 8, alignment: 8)
        defer { table.deallocate() }
        try read(table, header.tableEntries * 8, at: header.tableOffset)
        let second = UnsafeMutableRawPointer.allocate(byteCount: clusterSize, alignment: 8)
        defer { second.deallocate() }
        // One more byte than a cluster: a compressed cluster that holds more is seen as such.
        let data = UnsafeMutableRawPointer.allocate(byteCount: clusterSize + 1, alignment: 16)
        defer { data.deallocate() }
        // The most a compressed entry can name: its sector count has `clusterBits - 8` bits.
        let packedCapacity = (Int(sectorMask) + 1) * 512
        let packed = UnsafeMutableRawPointer.allocate(byteCount: packedCapacity, alignment: 16)
        defer { packed.deallocate() }

        var stream = z_stream()
        // Negative window bits: raw deflate, with no zlib header.
        guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw AgentVMError.hostNotReady("cannot start zlib on this Mac")
        }
        defer { inflateEnd(&stream) }

        for first in 0..<header.tableEntries {
            if let signal = cancellation?.signal {
                throw AgentVMError.canceled(signal: signal)
            }
            let tableOffset = UInt64(bigEndian: table.load(fromByteOffset: first * 8, as: UInt64.self)) & offsetMask
            if tableOffset == 0 {
                continue
            }
            // The file is at least one cluster long: the header's check of the first table's
            // place (a cluster boundary past the header, within the file) saw to that.
            guard tableOffset % UInt64(cluster) == 0, tableOffset <= UInt64(fileSize - cluster) else {
                throw Problem("a cluster table lies beyond the file's end")
            }
            try read(second, clusterSize, at: Int64(tableOffset))
            for index in 0..<header.entriesPerTable {
                // Again here: with large clusters one second table covers a whole disk.
                if index % 256 == 255, let signal = cancellation?.signal {
                    throw AgentVMError.canceled(signal: signal)
                }
                let position = (Int64(first) * Int64(header.entriesPerTable) + Int64(index)) * cluster
                if position >= header.size {
                    break
                }
                let entry = UInt64(bigEndian: second.load(fromByteOffset: index * 8, as: UInt64.self))
                if entry & (1 << 62) != 0 {
                    let start = entry & startMask
                    let sectors = Int((entry >> startBits) & sectorMask) + 1
                    guard start < UInt64(fileSize) else {
                        throw Problem("a cluster lies beyond the file's end")
                    }
                    // The count is in whole sectors: the last cluster of a file may name more
                    // than the file has.
                    let length = min(sectors * 512 - Int(start & 511), Int(fileSize - Int64(start)))
                    try read(packed, length, at: Int64(start))
                    guard inflateReset(&stream) == Z_OK else {
                        throw AgentVMError.hostNotReady("cannot start zlib on this Mac")
                    }
                    stream.next_in = packed.assumingMemoryBound(to: UInt8.self)
                    stream.avail_in = UInt32(length)
                    stream.next_out = data.assumingMemoryBound(to: UInt8.self)
                    stream.avail_out = UInt32(clusterSize + 1)
                    let status = inflate(&stream, Z_FINISH)
                    // Z_BUF_ERROR: the data ended, or the room did, without the stream's end
                    // mark; what counts is that exactly one cluster came out.
                    guard status == Z_STREAM_END || status == Z_BUF_ERROR || status == Z_OK, Int(stream.total_out) == clusterSize else {
                        throw Problem("a compressed cluster does not hold exactly one cluster")
                    }
                } else {
                    let start = entry & offsetMask
                    // Bit 0: the cluster reads as zeros, whatever is stored for it.
                    if start == 0 || entry & 1 != 0 {
                        continue
                    }
                    guard start % UInt64(cluster) == 0, start <= UInt64(fileSize - cluster) else {
                        throw Problem("a cluster lies beyond the file's end")
                    }
                    try read(data, clusterSize, at: Int64(start))
                }
                let count = Int(min(cluster, header.size - position))
                let bytes = UnsafeRawBufferPointer(start: data, count: count)
                if !bytes.contains(where: { $0 != 0 }) {
                    continue
                }
                var done = 0
                while done < count {
                    let wrote = pwrite(output, data + done, count - done, position + Int64(done))
                    if wrote < 0 && errno == EINTR {
                        continue
                    }
                    guard wrote > 0 else {
                        throw AgentVMError.system(operation: "write \(disk.path)", code: wrote < 0 ? errno : EIO)
                    }
                    done += wrote
                }
            }
        }
        guard ftruncate(output, header.size) == 0 else {
            throw AgentVMError.system(operation: "set the size of \(disk.path)", code: errno)
        }
        return header.size
    }
}
