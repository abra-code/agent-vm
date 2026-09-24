// Tests/AgentVMKitTests/GuestDiskTests.swift
//
// Growing a guest disk: small synthetic disks laid out as macOS lays out a guest's (iBoot's
// system container, the main APFS container, the recovery container last), grown with and
// without the moved container overlapping its old place. The result is read back with this
// code and with macOS's own gpt(8).

import Darwin
import Foundation
import Testing
@testable import AgentVMKit

@Suite struct GuestDiskTests {
    private static let sector = 512
    private static let iscType = GuestDisk.gptBytes("69646961-6700-11AA-AA11-00306543ECAC")

    /// A disk of `sectors` sectors with a valid table; the recovery container (`recovery`
    /// sectors, last) holds a pattern except for an all-zero 8 MB stretch in its middle.
    private func makeDisk(_ url: URL, sectors: UInt64, recovery: UInt64, lastType: [UInt8] = GuestDisk.recoveryType) throws -> UInt64 {
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        #expect(ftruncate(descriptor, off_t(sectors) * off_t(Self.sector)) == 0)
        let file = GuestDisk.DiskFile(descriptor: descriptor, path: url.path)

        let lastUsable = sectors - 34
        let recoveryFirst = (lastUsable + 1 - recovery) / 8 * 8
        var entries = [UInt8](repeating: 0, count: 128 * 128)
        func entry(_ index: Int, _ type: [UInt8], _ first: UInt64, _ last: UInt64) {
            entries.replaceSubrange((index * 128)..<(index * 128 + 16), with: type)
            entries.replaceSubrange((index * 128 + 16)..<(index * 128 + 32), with: (0..<16).map { _ in UInt8.random(in: 0...255) })
            GuestDisk.Entry.setRange(&entries, index: index, first: first, last: last)
        }
        entry(0, Self.iscType, 40, 2087)
        entry(1, GuestDisk.apfsType, 2088, recoveryFirst - 1024)
        entry(2, lastType, recoveryFirst, recoveryFirst + recovery - 1)

        var header = [UInt8](repeating: 0, count: 92)
        header.replaceSubrange(0..<8, with: Array("EFI PART".utf8))
        LittleEndian.put(UInt32(0x0001_0000), into: &header, at: 8)
        LittleEndian.put(UInt32(92), into: &header, at: 12)
        LittleEndian.put(UInt64(34), into: &header, at: 40)
        header.replaceSubrange(56..<72, with: (0..<16).map { _ in UInt8.random(in: 0...255) })
        LittleEndian.put(UInt32(128), into: &header, at: 80)
        LittleEndian.put(UInt32(128), into: &header, at: 84)
        let primary = try GuestDisk.Header(signed(header, current: 1, backup: sectors - 1, lastUsable: lastUsable, entriesLBA: 2, entries: entries),
                                           { AgentVMError.invalidRecipe(path: "", reason: $0) })
        var backup = primary
        backup.currentLBA = sectors - 1
        backup.backupLBA = 1
        backup.entriesLBA = sectors - 33
        try file.write(entries, at: 2 * UInt64(Self.sector))
        try file.write(primary.sector(), at: UInt64(Self.sector))
        try file.write(entries, at: (sectors - 33) * UInt64(Self.sector))
        try file.write(backup.sector(), at: (sectors - 1) * UInt64(Self.sector))

        var mbr = [UInt8](repeating: 0, count: Self.sector)
        mbr[450] = 0xEE
        LittleEndian.put(UInt32(1), into: &mbr, at: 454)
        LittleEndian.put(UInt32(sectors - 1), into: &mbr, at: 458)
        mbr[510] = 0x55
        mbr[511] = 0xAA
        try file.write(mbr, at: 0)

        try file.write(pattern(recovery), at: recoveryFirst * UInt64(Self.sector))
        return recoveryFirst
    }

    /// The recovery container's contents: sector numbers, but zeros from 8 MB to 16 MB.
    private func pattern(_ sectors: UInt64) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: Int(sectors) * Self.sector)
        for index in 0..<Int(sectors) where !(16384..<32768).contains(index) {
            LittleEndian.put(UInt64(index) &+ 0x5A5A_0000_0000, into: &bytes, at: index * Self.sector)
            bytes[index * Self.sector + 8] = 0xA5
        }
        return bytes
    }

    /// A header with its checksums set, as a whole sector.
    private func signed(_ header: [UInt8], current: UInt64, backup: UInt64, lastUsable: UInt64, entriesLBA: UInt64, entries: [UInt8]) -> [UInt8] {
        var bytes = header
        LittleEndian.put(current, into: &bytes, at: 24)
        LittleEndian.put(backup, into: &bytes, at: 32)
        LittleEndian.put(lastUsable, into: &bytes, at: 48)
        LittleEndian.put(entriesLBA, into: &bytes, at: 72)
        LittleEndian.put(CRC32.checksum(entries), into: &bytes, at: 88)
        LittleEndian.put(CRC32.checksum(bytes), into: &bytes, at: 16)
        return bytes + [UInt8](repeating: 0, count: Self.sector - bytes.count)
    }

    /// Reads the grown disk back: both tables valid and at the new end, the recovery entry
    /// moved, its contents intact, the MBR covering the disk.
    private func check(_ url: URL, sectors: UInt64, recovery: UInt64, moved: GuestDisk.Moved) throws {
        let fail = { (reason: String) in AgentVMError.invalidRecipe(path: url.path, reason: reason) }
        let descriptor = open(url.path, O_RDONLY)
        defer { close(descriptor) }
        let file = GuestDisk.DiskFile(descriptor: descriptor, path: url.path)
        let primary = try GuestDisk.Header(file.read(at: UInt64(Self.sector), count: Self.sector), fail)
        let backup = try GuestDisk.Header(file.read(at: (sectors - 1) * UInt64(Self.sector), count: Self.sector), fail)
        #expect(primary.backupLBA == sectors - 1)
        #expect(primary.lastUsableLBA == sectors - 34)
        #expect(backup.currentLBA == sectors - 1 && backup.backupLBA == 1 && backup.entriesLBA == sectors - 33)
        let entries = try file.read(at: 2 * UInt64(Self.sector), count: 128 * 128)
        #expect(try file.read(at: (sectors - 33) * UInt64(Self.sector), count: 128 * 128) == entries)
        #expect(CRC32.checksum(entries) == primary.entriesCRC)
        let last = GuestDisk.Entry(entries, index: 2)
        #expect(last.firstLBA == moved.to && last.lastLBA == moved.to + recovery - 1)
        #expect(last.lastLBA <= primary.lastUsableLBA)
        #expect(moved.to % 8 == 0)
        #expect(try file.read(at: moved.to * UInt64(Self.sector), count: Int(recovery) * Self.sector) == pattern(recovery))
        #expect(LittleEndian.uint32(try file.read(at: 0, count: Self.sector), at: 458) == UInt32(sectors - 1))
    }

    @Test func movesTheRecoveryContainerToTheNewEnd() throws {
        let scratch = try Scratch()
        let disk = scratch.root.appendingPathComponent("Disk.img")
        let first = try makeDisk(disk, sectors: 262_144, recovery: 49_152)
        let moved = try GuestDisk.grow(disk, to: 384 << 20)
        #expect(moved.from == first && moved.sectors == 49_152)
        try check(disk, sectors: 786_432, recovery: 49_152, moved: moved)
    }

    /// Growing by less than the container's size: the new place overlaps the old one.
    @Test func anOverlappingMoveKeepsTheContents() throws {
        let scratch = try Scratch()
        let disk = scratch.root.appendingPathComponent("Disk.img")
        _ = try makeDisk(disk, sectors: 262_144, recovery: 49_152)
        let moved = try GuestDisk.grow(disk, to: 136 << 20)
        #expect(moved.to < moved.from + moved.sectors)
        try check(disk, sectors: 278_528, recovery: 49_152, moved: moved)
    }

    /// macOS's own gpt(8) reads the grown table: the recovery container at its new place and
    /// the backup table at the end.
    @Test func gptReadsTheGrownTable() throws {
        let scratch = try Scratch()
        let disk = scratch.root.appendingPathComponent("Disk.img")
        _ = try makeDisk(disk, sectors: 262_144, recovery: 49_152)
        let moved = try GuestDisk.grow(disk, to: 384 << 20)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/gpt")
        process.arguments = ["-r", "show", disk.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(text)")
        let fields = text.split(whereSeparator: \.isNewline).map { $0.split(separator: " ").map(String.init) }
        #expect(fields.contains { $0.count >= 4 && $0[0] == "\(moved.to)" && $0[1] == "49152" && $0[2] == "3" })
        #expect(fields.contains { $0 == ["786431", "1", "Sec", "GPT", "header"] })
        #expect(!text.contains("bogus") && !text.lowercased().contains("invalid"), "\(text)")
    }

    @Test func refusesWhatItCannotGrow() throws {
        let scratch = try Scratch()
        let disk = scratch.root.appendingPathComponent("Disk.img")
        _ = try makeDisk(disk, sectors: 262_144, recovery: 49_152)
        #expect(throws: AgentVMError.self) { try GuestDisk.grow(disk, to: 128 << 20) }
        #expect(throws: AgentVMError.self) { try GuestDisk.grow(disk, to: 64 << 20) }

        let other = scratch.root.appendingPathComponent("Other.img")
        _ = try makeDisk(other, sectors: 262_144, recovery: 49_152, lastType: GuestDisk.apfsType)
        #expect(throws: AgentVMError.self) { try GuestDisk.grow(other, to: 384 << 20) }
        var info = stat()
        #expect(stat(other.path, &info) == 0 && info.st_size == 128 << 20)

        // A backup header that does not match its checksum.
        let badBackup = scratch.root.appendingPathComponent("BadBackup.img")
        _ = try makeDisk(badBackup, sectors: 262_144, recovery: 49_152)
        let handle = try FileHandle(forUpdating: badBackup)
        try handle.seek(toOffset: UInt64(262_143 * Self.sector + 48))
        try handle.write(contentsOf: Data([0x01]))
        try handle.close()
        do {
            _ = try GuestDisk.grow(badBackup, to: 384 << 20)
            Issue.record("a disk with a bad backup header was grown")
        } catch {
            #expect("\(error)".contains("partition table header does not match its checksum"), "\(error)")
        }
        #expect(stat(badBackup.path, &info) == 0 && info.st_size == 128 << 20)

        let blank = scratch.root.appendingPathComponent("Blank.img")
        #expect(FileManager.default.createFile(atPath: blank.path, contents: Data(count: 1 << 20)))
        #expect(throws: AgentVMError.self) { try GuestDisk.grow(blank, to: 2 << 20) }
    }

    @Test func crc32MatchesZlib() {
        #expect(CRC32.checksum(Array("123456789".utf8)) == 0xCBF4_3926)
    }
}
