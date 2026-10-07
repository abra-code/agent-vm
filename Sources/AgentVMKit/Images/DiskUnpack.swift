// Sources/AgentVMKit/Images/DiskUnpack.swift
//
// A distribution's cloud image made into an image's disk. Debian ships a tar archive (xz) with
// one member, the raw disk: 3 GB, mostly zeros. tar writes that member to a pipe and nothing
// to a folder; what comes out of the pipe is written to the disk file with holes in the place
// of blocks of zeros (tar itself would write every zero), so the file takes what the system
// takes, under 2 GB. A raw disk given as it is, is cloned.
//
// The archive is checked against its checksum before this reads it (LinuxBaseCache), or it is
// a file the person named. It is still read as a file from the network: the output is limited
// to the size the image's disk may have.

import Darwin
import Foundation

enum DiskUnpack {
    static let blockSize = 1 << 20

    /// What a cloud image file is, by its first bytes, not by its name.
    enum Kind: Equatable {
        /// An xz-compressed tar archive.
        case tarXZ
        /// A raw disk with a partition table.
        case raw
    }

    static func kind(of file: URL) throws -> Kind {
        let descriptor = open(file.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw AgentVMError.system(operation: "open \(file.path)", code: errno)
        }
        defer { close(descriptor) }
        var head = [UInt8](repeating: 0, count: 1024)
        let count = pread(descriptor, &head, head.count, 0)
        if count >= 6, Array(head[0..<6]) == [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00] {
            return .tarXZ
        }
        // A GUID partition table's header is the second 512-byte block.
        if count >= 520, Array(head[512..<520]) == Array("EFI PART".utf8) {
            return .raw
        }
        throw AgentVMError.virtualMachine(operation: "read \(file.path)", message: "it is neither an xz-compressed tar archive nor a raw disk with a partition table")
    }

    /// Writes the disk in `source` to `disk` (which must not exist) and returns its size. For
    /// an archive, `member` is the disk's name in it. More than `limit` bytes is refused. A
    /// cancel, or any failure, removes what was written.
    static func unpack(_ source: URL, member: String, to disk: URL, limit: Int64, cancellation: BuildCancellation? = nil) throws -> Int64 {
        do {
            switch try kind(of: source) {
            case .raw:
                do {
                    try BoxStore.cloneFile(source, to: disk)
                } catch AgentVMError.differentVolume {
                    // A file of the person's own may be on any disk: copied, then.
                    do {
                        try FileManager.default.copyItem(at: source, to: disk)
                    } catch {
                        throw AgentVMError.system(operation: "copy \(source.path) to \(disk.path)", code: FileSystem.posixCode(error))
                    }
                }
                // A clone has its source's permissions: a file given read-only would make a
                // disk that cannot be written, one readable by all a disk that is.
                guard chmod(disk.path, 0o600) == 0 else {
                    throw AgentVMError.system(operation: "set the permissions of \(disk.path)", code: errno)
                }
                let size = ((try? FileManager.default.attributesOfItem(atPath: disk.path))?[.size] as? Int64) ?? 0
                guard size > 0, size <= limit else {
                    throw tooLarge(source, limit: limit)
                }
                return size
            case .tarXZ:
                return try extract(source, member: member, to: disk, limit: limit, cancellation: cancellation)
            }
        } catch {
            try? FileManager.default.removeItem(at: disk)
            if let signal = cancellation?.signal {
                throw AgentVMError.canceled(signal: signal)
            }
            throw error
        }
    }

    private static func tooLarge(_ source: URL, limit: Int64) -> AgentVMError {
        return .virtualMachine(operation: "unpack \(source.path)", message: "its disk is larger than the image's (\(limit >> 30) GB); give a larger --disk-gb")
    }

    private static func extract(_ archive: URL, member: String, to disk: URL, limit: Int64, cancellation: BuildCancellation?) throws -> Int64 {
        let output = open(disk.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard output >= 0 else {
            throw AgentVMError.system(operation: "create \(disk.path)", code: errno)
        }
        defer { close(output) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        // -O: the member goes to standard output, and nothing is written anywhere else.
        process.arguments = ["-xOf", archive.path, member]
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = FileHandle.nullDevice
        let data = Pipe()
        let errors = Pipe()
        process.standardOutput = data
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw AgentVMError.hostNotReady("cannot run /usr/bin/tar: \(error.localizedDescription)")
        }
        // tar's own words, read as they come so that it never waits on a full pipe.
        let said = Collected()
        let errorsRead = DispatchSemaphore(value: 0)
        let errorHandle = errors.fileHandleForReading
        Thread.detachNewThread {
            said.set(errorHandle.readDataToEndOfFile())
            errorsRead.signal()
        }
        let key = cancellation?.whenCanceled { process.terminate() }
        defer {
            if let key {
                cancellation?.remove(key)
            }
        }

        var total: Int64 = 0
        var failure: Error?
        let input = data.fileHandleForReading.fileDescriptor
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: blockSize, alignment: 16)
        defer { buffer.deallocate() }
        reading: while true {
            // A whole block at a time, so a block of zeros is seen as one.
            var filled = 0
            while filled < blockSize {
                let count = read(input, buffer + filled, blockSize - filled)
                if count < 0 && errno == EINTR {
                    continue
                }
                if count < 0 {
                    failure = AgentVMError.system(operation: "read from tar", code: errno)
                    break reading
                }
                if count == 0 {
                    break
                }
                filled += count
            }
            if filled == 0 {
                break
            }
            guard total + Int64(filled) <= limit else {
                failure = tooLarge(archive, limit: limit)
                break
            }
            let bytes = UnsafeRawBufferPointer(start: buffer, count: filled)
            if !bytes.contains(where: { $0 != 0 }) {
                // A hole: the file's length is set at the end.
            } else if let problem = write(bytes, to: output, at: total, path: disk.path) {
                failure = problem
                break
            }
            total += Int64(filled)
            if filled < blockSize {
                break
            }
        }
        if failure != nil {
            process.terminate()
        }
        process.waitUntilExit()
        errorsRead.wait()
        if let failure {
            throw failure
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let words = Printable.line(String(decoding: said.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), limit: 300)
            throw AgentVMError.virtualMachine(operation: "unpack \(archive.path)", message: words.isEmpty ? "tar ended with status \(process.terminationStatus)" : words)
        }
        guard total > 0 else {
            throw AgentVMError.virtualMachine(operation: "unpack \(archive.path)", message: "the archive's \(member) is empty")
        }
        guard ftruncate(output, total) == 0 else {
            throw AgentVMError.system(operation: "set the size of \(disk.path)", code: errno)
        }
        return total
    }

    private static func write(_ bytes: UnsafeRawBufferPointer, to descriptor: Int32, at offset: Int64, path: String) -> Error? {
        var done = 0
        while done < bytes.count {
            let count = pwrite(descriptor, bytes.baseAddress! + done, bytes.count - done, offset + Int64(done))
            if count < 0 && errno == EINTR {
                continue
            }
            if count <= 0 {
                return AgentVMError.system(operation: "write \(path)", code: errno)
            }
            done += count
        }
        return nil
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = Data()

        func set(_ data: Data) {
            lock.lock()
            stored = data.prefix(4096)
            lock.unlock()
        }

        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }
}
