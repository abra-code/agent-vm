// Sources/AgentVMKit/Images/GuestDisk.swift
//
// Growing a macOS guest's disk. On Apple silicon the guest's disk holds three partitions in a
// GUID partition table (GPT): iBoot's system container, the main APFS container, and last the
// recovery container. Space added at the end of the disk file lands after the recovery
// container, where the main container cannot grow into it. So the recovery container is moved
// to the new end (its bytes copied, its table entry changed), and the guest then grows the
// main container into the gap with `diskutil apfs resizeContainer <store> 0`. Tart's Packer
// plugin does the same ("relocate"); deleting the recovery container instead would stop
// macOS updates in the guest. The file is changed directly, on the Mac, while no guest runs.

import Darwin
import Foundation

public enum GuestDisk {
    static let sectorSize = 512
    /// Partition type GUIDs, as they appear in the table (the first three fields little-endian).
    static let apfsType = gptBytes("7C3457EF-0000-11AA-AA11-00306543ECAC")
    static let recoveryType = gptBytes("52637672-7900-11AA-AA11-00306543ECAC")

    /// What `grow` did: where the recovery container was and is, in sectors.
    public struct Moved: Equatable, Sendable {
        public var sectors: UInt64
        public var from: UInt64
        public var to: UInt64
    }

    /// The command, run as root in the guest, that grows the boot volume's APFS container into
    /// the free space after it.
    public static let resizeCommand = #"store=$(/usr/sbin/diskutil info / | /usr/bin/awk -F': *' '/APFS Physical Store/ {print $2; exit}') && [ -n "$store" ] && /usr/sbin/diskutil apfs resizeContainer "$store" 0"#

    /// Makes the disk file at `url` `bytes` long and moves its recovery container to the new
    /// end. Refused, before anything is written, unless the disk has the layout macOS installs
    /// (a valid table, the recovery container last, right after an APFS container) and `bytes`
    /// is larger than the file.
    public static func grow(_ url: URL, to bytes: UInt64) throws -> Moved {
        func fail(_ reason: String) -> AgentVMError {
            return AgentVMError.virtualMachine(operation: "grow the disk \(url.path)", message: reason)
        }
        let descriptor = open(url.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw AgentVMError.system(operation: "open \(url.path)", code: errno)
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw AgentVMError.system(operation: "read \(url.path)", code: errno)
        }
        let oldBytes = UInt64(info.st_size)
        guard bytes > oldBytes else {
            throw fail("it is \(oldBytes >> 30) GB already; a disk can only grow")
        }
        guard bytes % 4096 == 0, oldBytes % UInt64(sectorSize) == 0, bytes <= RecordNumbers.maximumBytes else {
            throw fail("sizes must be whole 4 KB blocks, of 1 PB at most")
        }
        guard oldBytes >= 1 << 20 else {
            throw fail("it is too small to hold a macOS installation")
        }
        let file = DiskFile(descriptor: descriptor, path: url.path)

        // The table as it is.
        var primary = try Header(file.read(at: UInt64(sectorSize), count: sectorSize), fail)
        let oldSectors = oldBytes / UInt64(sectorSize)
        guard primary.currentLBA == 1, primary.backupLBA == oldSectors - 1, primary.entriesLBA == 2 else {
            throw fail("its partition table is not where a macOS installation puts it")
        }
        guard primary.entrySize == 128, (1...1024).contains(primary.entryCount) else {
            throw fail("its partition table has \(primary.entryCount) entries of \(primary.entrySize) bytes")
        }
        let entriesLength = Int(primary.entryCount * primary.entrySize)
        var entries = try file.read(at: primary.entriesLBA * UInt64(sectorSize), count: entriesLength)
        guard CRC32.checksum(entries) == primary.entriesCRC else {
            throw fail("its partition entries do not match their checksum")
        }
        let entrySectors = UInt64((entriesLength + sectorSize - 1) / sectorSize)
        // The backup header too: its table is where the old backup is zeroed below.
        let oldBackup = try Header(file.read(at: (oldSectors - 1) * UInt64(sectorSize), count: sectorSize), fail)
        guard oldBackup.currentLBA == oldSectors - 1, oldBackup.backupLBA == 1, oldBackup.entriesLBA == oldSectors - 1 - entrySectors,
              oldBackup.entriesCRC == primary.entriesCRC else {
            throw fail("its backup partition table does not match the primary one")
        }
        let used = (0..<Int(primary.entryCount)).compactMap { index -> Entry? in
            let entry = Entry(entries, index: index)
            return entry.type.allSatisfy { $0 == 0 } ? nil : entry
        }.sorted { $0.firstLBA < $1.firstLBA }
        guard used.count >= 2, let recovery = used.last, recovery.type == recoveryType, used[used.count - 2].type == apfsType,
              used[used.count - 2].lastLBA < recovery.firstLBA, recovery.firstLBA <= recovery.lastLBA,
              recovery.lastLBA <= primary.lastUsableLBA else {
            throw fail("its last partition is not a recovery container after an APFS container")
        }
        // The table is the guest's to write, and its checksums prove nothing about it: what it
        // calls usable must end before the backup table, inside the file.
        guard primary.lastUsableLBA < oldSectors - 1 - entrySectors else {
            throw fail("its partition table names space past the end of the disk")
        }

        // The new geometry: the backup table at the new end, the recovery container right
        // before it, on a 4 KB boundary.
        let newSectors = bytes / UInt64(sectorSize)
        let newBackupLBA = newSectors - 1
        let newBackupEntriesLBA = newBackupLBA - entrySectors
        let newLastUsable = newBackupEntriesLBA - 1
        let length = recovery.lastLBA - recovery.firstLBA + 1
        let newFirst = (newLastUsable + 1 - length) / 8 * 8
        guard newFirst > recovery.firstLBA else {
            throw fail("\(bytes >> 30) GB leaves no room to move the recovery container")
        }

        guard ftruncate(descriptor, off_t(bytes)) == 0 else {
            throw AgentVMError.system(operation: "size \(url.path)", code: errno)
        }
        try file.move(from: recovery.firstLBA, to: newFirst, sectors: length, freshFrom: oldSectors)

        // The old backup table is now free space (or overwritten by the moved container).
        let newRange = newFirst...(newFirst + length - 1)
        for sector in (oldSectors - 1 - entrySectors)...(oldSectors - 1) where !newRange.contains(sector) {
            try file.write(Array(repeating: 0, count: sectorSize), at: sector * UInt64(sectorSize))
        }

        Entry.setRange(&entries, index: recovery.index, first: newFirst, last: newFirst + length - 1)
        primary.backupLBA = newBackupLBA
        primary.lastUsableLBA = newLastUsable
        primary.entriesCRC = CRC32.checksum(entries)
        var backup = primary
        backup.currentLBA = newBackupLBA
        backup.backupLBA = 1
        backup.entriesLBA = newBackupEntriesLBA
        try file.write(entries, at: newBackupEntriesLBA * UInt64(sectorSize))
        try file.write(backup.sector(), at: newBackupLBA * UInt64(sectorSize))
        try file.write(entries, at: primary.entriesLBA * UInt64(sectorSize))
        try file.write(primary.sector(), at: UInt64(sectorSize))
        try updateProtectiveMBR(file, sectors: newSectors)
        guard fcntl(descriptor, F_FULLFSYNC) == 0 else {
            throw AgentVMError.system(operation: "flush \(url.path)", code: errno)
        }
        return Moved(sectors: length, from: recovery.firstLBA, to: newFirst)
    }

    /// The protective MBR's one partition covers the whole disk (at most 2^32 - 1 sectors).
    private static func updateProtectiveMBR(_ file: DiskFile, sectors: UInt64) throws {
        var mbr = try file.read(at: 0, count: sectorSize)
        guard mbr[510] == 0x55, mbr[511] == 0xAA, mbr[450] == 0xEE else {
            return
        }
        LittleEndian.put(UInt32(min(sectors - 1, 0xFFFF_FFFF)), into: &mbr, at: 458)
        try file.write(mbr, at: 0)
    }

    /// A GUID string as the 16 bytes a partition table stores.
    static func gptBytes(_ text: String) -> [UInt8] {
        let uuid = UUID(uuidString: text)!.uuid
        let bytes = [uuid.0, uuid.1, uuid.2, uuid.3, uuid.4, uuid.5, uuid.6, uuid.7,
                     uuid.8, uuid.9, uuid.10, uuid.11, uuid.12, uuid.13, uuid.14, uuid.15]
        return [bytes[3], bytes[2], bytes[1], bytes[0], bytes[5], bytes[4], bytes[7], bytes[6]] + bytes[8...]
    }

    // MARK: - The table

    /// A GPT header (the 92 bytes of revision 1.0).
    struct Header {
        var bytes: [UInt8]
        var currentLBA: UInt64
        var backupLBA: UInt64
        var lastUsableLBA: UInt64
        var entriesLBA: UInt64
        var entryCount: UInt64
        var entrySize: UInt64
        var entriesCRC: UInt32

        init(_ sector: [UInt8], _ fail: (String) -> AgentVMError) throws {
            guard Array(sector[0..<8]) == Array("EFI PART".utf8) else {
                throw fail("it has no GUID partition table")
            }
            let size = Int(LittleEndian.uint32(sector, at: 12))
            guard (92...sector.count).contains(size) else {
                throw fail("its partition table header is \(size) bytes")
            }
            var zeroed = Array(sector[0..<size])
            LittleEndian.put(UInt32(0), into: &zeroed, at: 16)
            guard CRC32.checksum(zeroed) == LittleEndian.uint32(sector, at: 16) else {
                throw fail("its partition table header does not match its checksum")
            }
            bytes = Array(sector[0..<size])
            currentLBA = LittleEndian.uint64(sector, at: 24)
            backupLBA = LittleEndian.uint64(sector, at: 32)
            lastUsableLBA = LittleEndian.uint64(sector, at: 48)
            entriesLBA = LittleEndian.uint64(sector, at: 72)
            entryCount = UInt64(LittleEndian.uint32(sector, at: 80))
            entrySize = UInt64(LittleEndian.uint32(sector, at: 84))
            entriesCRC = LittleEndian.uint32(sector, at: 88)
        }

        /// The header with its fields written back and its checksum updated, as a whole sector.
        func sector() -> [UInt8] {
            var header = bytes
            LittleEndian.put(currentLBA, into: &header, at: 24)
            LittleEndian.put(backupLBA, into: &header, at: 32)
            LittleEndian.put(lastUsableLBA, into: &header, at: 48)
            LittleEndian.put(entriesLBA, into: &header, at: 72)
            LittleEndian.put(entriesCRC, into: &header, at: 88)
            LittleEndian.put(UInt32(0), into: &header, at: 16)
            LittleEndian.put(CRC32.checksum(header), into: &header, at: 16)
            return header + Array(repeating: 0, count: GuestDisk.sectorSize - header.count)
        }
    }

    /// One partition entry: its type and first and last sectors.
    struct Entry {
        var index: Int
        var type: [UInt8]
        var firstLBA: UInt64
        var lastLBA: UInt64

        init(_ entries: [UInt8], index: Int) {
            let base = index * 128
            self.index = index
            type = Array(entries[base..<(base + 16)])
            firstLBA = LittleEndian.uint64(entries, at: base + 32)
            lastLBA = LittleEndian.uint64(entries, at: base + 40)
        }

        static func setRange(_ entries: inout [UInt8], index: Int, first: UInt64, last: UInt64) {
            LittleEndian.put(first, into: &entries, at: index * 128 + 32)
            LittleEndian.put(last, into: &entries, at: index * 128 + 40)
        }
    }

    // MARK: - The file

    struct DiskFile {
        let descriptor: Int32
        let path: String

        func read(at offset: UInt64, count: Int) throws -> [UInt8] {
            var buffer = [UInt8](repeating: 0, count: count)
            var done = 0
            while done < count {
                let got = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress! + done, count - done, off_t(offset) + off_t(done)) }
                guard got > 0 else {
                    throw AgentVMError.system(operation: "read \(path)", code: got == 0 ? EIO : errno)
                }
                done += got
            }
            return buffer
        }

        func write(_ bytes: [UInt8], at offset: UInt64) throws {
            var done = 0
            while done < bytes.count {
                let wrote = bytes.withUnsafeBytes { pwrite(descriptor, $0.baseAddress! + done, bytes.count - done, off_t(offset) + off_t(done)) }
                guard wrote > 0 else {
                    throw AgentVMError.system(operation: "write \(path)", code: errno)
                }
                done += wrote
            }
        }

        /// Copies `sectors` sectors from `from` to the later `to`, last chunk first, so an
        /// overlap is safe. Chunks of zeros are skipped where the destination is at or past
        /// `freshFrom` (the old end of the file: never written, so it reads as zeros already),
        /// which keeps the sparse file sparse.
        func move(from: UInt64, to: UInt64, sectors: UInt64, freshFrom: UInt64) throws {
            let chunk: UInt64 = 16384  // 8 MB
            var remaining = sectors
            while remaining > 0 {
                let count = min(chunk, remaining)
                remaining -= count
                let bytes = try read(at: (from + remaining) * UInt64(GuestDisk.sectorSize), count: Int(count) * GuestDisk.sectorSize)
                if to + remaining >= freshFrom && bytes.allSatisfy({ $0 == 0 }) {
                    continue
                }
                try write(bytes, at: (to + remaining) * UInt64(GuestDisk.sectorSize))
            }
        }
    }
}

enum LittleEndian {
    static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
    }

    static func uint64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        return (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[offset + $1]) << (8 * $1) }
    }

    static func put<T: FixedWidthInteger>(_ value: T, into bytes: inout [UInt8], at offset: Int) {
        for index in 0..<(T.bitWidth / 8) {
            bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index))
        }
    }
}

/// CRC-32 as the GPT uses it (IEEE 802.3, the one zlib computes).
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { value in
        (0..<8).reduce(UInt32(value)) { crc, _ in crc & 1 != 0 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
    }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        return ~bytes.reduce(UInt32(0xFFFF_FFFF)) { crc, byte in table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
    }
}
