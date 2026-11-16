// Tests/AgentVMKitTests/BoxMemoryTests.swift
//
// A box's memory figures: what is read from the guest's output (and what is not believed),
// the line a person sees, the figures through the control socket, and the search for the
// box's Virtualization process.

import Darwin
import Foundation
import Testing
@testable import AgentVMKit

@Suite struct BoxMemoryTests {
    /// /proc/meminfo of a Debian 13 box of 8 GB, shortened.
    static let meminfo = """
        MemTotal:        8131488 kB
        MemFree:         1203528 kB
        MemAvailable:    3801312 kB
        Buffers:          112640 kB
        Cached:          2465788 kB
        SwapCached:            0 kB
        HugePages_Total:       0
        Hugepagesize:       2048 kB

        """

    /// hw.memsize, then vm_stat, of a Mac of 32 GB (measured on macOS 27.2).
    static let vmStat = """
        34359738368
        Mach Virtual Memory Statistics: (page size of 16384 bytes)
        Pages free:                                    36358.
        Pages active:                                 873683.
        Pages inactive:                               898380.
        Pages speculative:                             13455.
        Pages throttled:                                   0.
        Pages wired down:                             189153.
        Pages purgeable:                               22790.
        "Translation faults":                     4384792872.
        File-backed pages:                            741918.
        Anonymous pages:                             1043600.
        Pages stored in compressor:                    89043.
        Pages occupied by compressor:                  32232.

        """

    @Test func linuxFiguresComeFromMeminfoInKibibytes() throws {
        let figures = try #require(BoxMemory.guestFigures(Self.meminfo, guest: .linux))
        #expect(figures.total == 8_131_488 * 1024)
        #expect(figures.available == 3_801_312 * 1024)
        #expect(figures.cache == 2_465_788 * 1024)
    }

    @Test func macFiguresAreWhatActivityMonitorCallsUsed() throws {
        let figures = try #require(BoxMemory.guestFigures(Self.vmStat, guest: .macOS))
        #expect(figures.total == 34_359_738_368)
        // (anonymous - purgeable) + wired + occupied by the compressor.
        let used: UInt64 = (1_043_600 - 22_790 + 189_153 + 32_232) * 16384
        #expect(figures.available == 34_359_738_368 - used)
        #expect(figures.cache == 741_918 * 16384)
    }

    @Test func outputThatIsNotTheCommandsGivesNoFigures() {
        #expect(BoxMemory.guestFigures("", guest: .linux) == nil)
        #expect(BoxMemory.guestFigures("MemTotal: 100 kB\n", guest: .linux) == nil)
        #expect(BoxMemory.guestFigures("MemTotal: 0 kB\nMemAvailable: 0 kB\nCached: 0 kB\n", guest: .linux) == nil)
        #expect(BoxMemory.guestFigures(Self.meminfo, guest: .macOS) == nil)
        #expect(BoxMemory.guestFigures(Self.vmStat, guest: .linux) == nil)
        // No page size: the counts mean nothing.
        let noPageSize = Self.vmStat.replacingOccurrences(of: "(page size of 16384 bytes)", with: "")
        #expect(BoxMemory.guestFigures(noPageSize, guest: .macOS) == nil)
    }

    @Test func aGuestsNumbersAreBoundedAndNeverExceedItsTotal() throws {
        // More than a pebibyte is not believed; the line is skipped, and with it the figures.
        let huge = Self.meminfo.replacingOccurrences(of: "8131488 kB", with: "99999999999999999 kB")
        #expect(BoxMemory.guestFigures(huge, guest: .linux) == nil)
        // Available and cache above the total are cut down to it.
        let inflated = Self.meminfo.replacingOccurrences(of: "3801312 kB", with: "9999999 kB").replacingOccurrences(of: "2465788 kB", with: "9999999 kB")
        let figures = try #require(BoxMemory.guestFigures(inflated, guest: .linux))
        #expect(figures.available == figures.total && figures.cache == figures.total)
        // Page counts whose bytes would overflow are taken as the whole memory.
        let overflowing = Self.vmStat.replacingOccurrences(of: "1043600.", with: "1125899906842624.")
        let mac = try #require(BoxMemory.guestFigures(overflowing, guest: .macOS))
        #expect(mac.available == 0)
    }

    @Test func theLineSaysWhatIsKnown() {
        let gib: UInt64 = 1 << 30
        var memory = BoxMemory(configuredBytes: 8 * gib)
        #expect(memory.line == "memory 8 GB")
        memory.hostFootprintBytes = 3 * gib + gib / 2
        #expect(memory.line == "memory 8 GB: the Mac holds 3.5 GB for it")
        memory.guestTotalBytes = 8 * gib
        memory.guestAvailableBytes = 4 * gib
        memory.guestCacheBytes = 2 * gib + gib / 4
        #expect(memory.line == "memory 8 GB: programs use 4.0 GB, file cache 2.2 GB; the Mac holds 3.5 GB for it")
        #expect(memory.guestUsedBytes == 4 * gib)
    }

    @Test func aRunningBoxsFiguresComeThroughItsSupervisor() throws {
        let folder = try ShortFolder()
        let fixture = try BoxScratch()
        let created = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images)
        let box = Box(record: created.record, directory: URL(fileURLWithPath: folder.path, isDirectory: true))
        let lock = try #require(try FolderLock.tryAcquire(box.lockPath))
        defer { lock.release() }
        let figures = BoxMemory(configuredBytes: 8 << 30, guestTotalBytes: 8 << 30, guestAvailableBytes: 5 << 30, guestCacheBytes: 1 << 30,
                                hostFootprintBytes: 2 << 30, sampledAt: Date(timeIntervalSince1970: 1_800_000_000))
        let server = try ControlServer(path: box.controlSocketPath, handler: StatusHandler(
            ControlResponse(ok: true, state: .ready, pid: 4242, supervisorVersion: AgentVM.version), memory: figures))
        defer { server.close() }
        // Only when asked: a plain status runs nothing in the guest.
        #expect(BoxStatus.of(box).memory == nil)
        let status = BoxStatus.of(box, memory: true)
        #expect(status.memory == figures)
        let json = String(decoding: try JSONEncoder().encode(status), as: UTF8.self)
        #expect(json.contains("\"hostFootprintBytes\""))
    }

    @Test func aSupervisorThatGivesNoFiguresLeavesTheSizeAndWhy() throws {
        let folder = try ShortFolder()
        let fixture = try BoxScratch()
        let created = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images)
        let box = Box(record: created.record, directory: URL(fileURLWithPath: folder.path, isDirectory: true))
        let lock = try #require(try FolderLock.tryAcquire(box.lockPath))
        defer { lock.release() }
        let server = try ControlServer(path: box.controlSocketPath, handler: StatusHandler(
            ControlResponse(ok: true, state: .ready, pid: 4242, supervisorVersion: "0.8.12")))
        defer { server.close() }
        let memory = try #require(BoxStatus.of(box, memory: true).memory)
        #expect(memory.configuredBytes == box.record.memoryBytes)
        #expect(memory.guestTotalBytes == nil && memory.hostFootprintBytes == nil)
        let note = try #require(memory.notes?.first)
        #expect(note.contains("no memory in tests"))
    }

    @Test func anOlderSupervisorIsNamed() throws {
        let folder = try ShortFolder()
        let fixture = try BoxScratch()
        let created = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images)
        let box = Box(record: created.record, directory: URL(fileURLWithPath: folder.path, isDirectory: true))
        let lock = try #require(try FolderLock.tryAcquire(box.lockPath))
        defer { lock.release() }
        let server = try ControlServer(path: box.controlSocketPath, handler: StatusHandler(
            ControlResponse(ok: true, state: .ready, pid: 4242, supervisorVersion: "0.8.11")))
        defer { server.close() }
        let note = try #require(BoxStatus.of(box, memory: true).memory?.notes?.first)
        #expect(note.contains("agent-vm 0.8.11, which does not report memory"))
        #expect(BoxStatus.isOlder("0.8.9", than: "0.8.12") && BoxStatus.isOlder("0.8", than: "0.8.12"))
        #expect(!BoxStatus.isOlder("0.8.12", than: "0.8.12") && !BoxStatus.isOlder("0.9.0", than: "0.8.12") && !BoxStatus.isOlder("1.0", than: "0.8.12"))
    }

    @Test func aFileNoMachineHoldsHasNoProcess() throws {
        let scratch = try Scratch()
        let disk = scratch.root.appendingPathComponent("Disk.img")
        try Data("disk".utf8).write(to: disk)
        guard case .failure = MachineProcess.find(holding: disk) else {
            Issue.record("a file no Virtualization process holds was matched")
            return
        }
        guard case .failure = MachineProcess.find(holding: scratch.root.appendingPathComponent("missing.img")) else {
            Issue.record("a missing file was matched")
            return
        }
        #expect(!MachineProcess.stillHolds(getpid(), disk: disk))
    }

    @Test func aGuestThatDoesNotAnswerHoldsAQuestionUpToTheLimitOnly() async {
        let quick = Task { 7 }
        #expect(await FirstAnswer.value(of: quick, within: .seconds(5)) == 7)
        let slow = Task { () -> Int in
            try? await Task.sleep(for: .seconds(3))
            return 8
        }
        let started = ContinuousClock.now
        #expect(await FirstAnswer.value(of: slow, within: .milliseconds(200)) == nil)
        #expect(ContinuousClock.now - started < .seconds(2))
    }
}
