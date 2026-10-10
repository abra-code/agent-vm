// Tests/AgentVMKitTests/ConsoleLogTests.swift
//
// The file a Linux guest's console output goes to: bounded in size (two files) and in rate (a
// budget per minute), and never something the writer waits on. The writer here is the test,
// in the place of a machine's serial port.

import Foundation
import Testing
@testable import AgentVMKit

@Suite struct ConsoleLogTests {
    /// Writes all of `bytes` to the log's pipe; false when a write failed.
    @discardableResult
    static func write(_ bytes: [UInt8], to log: ConsoleLog) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let count = bytes[offset...].withUnsafeBytes { Darwin.write(log.writeHandle.fileDescriptor, $0.baseAddress, $0.count) }
            if count <= 0 {
                return false
            }
            offset += count
        }
        return true
    }

    static func size(_ url: URL) -> Int {
        return ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? -1
    }

    static func lines(_ count: Int) -> [UInt8] {
        return Array((0..<count).map { "line \($0)\n" }.joined().utf8)
    }

    @Test func whatIsWrittenIsKept() throws {
        let scratch = try Scratch()
        let url = scratch.root.appendingPathComponent("console.log")
        let log = try ConsoleLog(url: url)
        Self.write(Array("Booting\r\nLinux version 6.12\r\n".utf8), to: log)
        log.close()
        #expect(try String(contentsOf: url, encoding: .utf8) == "Booting\r\nLinux version 6.12\r\n")
        // Only this user reads it.
        let mode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0
        #expect(mode == 0o600)
        // Closing twice is nothing.
        log.close()
    }

    @Test func aKernelPanicIsSeen() throws {
        let scratch = try Scratch()
        let log = try ConsoleLog(url: scratch.root.appendingPathComponent("console.log"))
        Self.write(Array("[    1.0] Internal error: Oops: 0000000096000004 [#1] SMP\r\n[    1.1] Kernel panic - not ".utf8), to: log)
        usleep(300_000)
        #expect(!log.sawKernelPanic)
        // The rest of the line, in a read of its own.
        Self.write(Array("syncing: Fatal exception\r\n".utf8), to: log)
        log.close()
        #expect(log.sawKernelPanic)
    }

    @Test func aKernelPanicIsSeenInAFloodThatIsDropped() throws {
        let scratch = try Scratch()
        let log = try ConsoleLog(url: scratch.root.appendingPathComponent("console.log"), bytesPerMinute: 64)
        Self.write(Self.lines(100) + Array("Kernel panic - not syncing: Attempted to kill init!\n".utf8), to: log)
        log.close()
        #expect(log.sawKernelPanic)
    }

    @Test func anOrdinaryBootIsNoPanic() throws {
        let scratch = try Scratch()
        let log = try ConsoleLog(url: scratch.root.appendingPathComponent("console.log"))
        Self.write(Array("Kernel command line: panic=0\r\nKernel panic - not\r\nsyncing\r\n".utf8), to: log)
        log.close()
        #expect(!log.sawKernelPanic)
    }

    @Test func fileSystemErrorsAreSeen() throws {
        let scratch = try Scratch()
        let url = scratch.root.appendingPathComponent("console.log")
        let log = try ConsoleLog(url: url)
        Self.write(Array("box login: [  968.951994] EXT4-fs err".utf8), to: log)
        usleep(300_000)
        #expect(!log.sawDiskErrors)
        Self.write(Array("or (device vda1): ext4_lookup:1821: inode #24287: comm tar: iget: checksum invalid\r\n[  968.96] EXT4-fs (vda1): Remounting filesystem read-only\r\n".utf8), to: log)
        log.close()
        #expect(log.sawDiskErrors && !log.sawKernelPanic)
        // What the commands read afterwards, from the file.
        #expect(GuestTrouble.found(inConsole: ConsoleLog.end(of: url)) == .damagedDisk)
        #expect(GuestTrouble.found(inConsole: "EXT4-fs (vda1): recovery complete\nEXT4-fs (vda1): re-mounted r/w.") == nil)
        #expect(GuestTrouble.found(inConsole: "EXT4-fs error\nKernel panic - not syncing: Attempted to kill init!") == .kernelPanic)
        #expect(GuestTrouble.found(inConsole: "") == nil)
    }

    @Test func rotatesAtTheLimit() throws {
        let scratch = try Scratch()
        let url = scratch.root.appendingPathComponent("console.log")
        let log = try ConsoleLog(url: url, limit: 4096)
        let bytes = Self.lines(700)
        #expect(bytes.count > 4096 && bytes.count < 8192)
        Self.write(bytes, to: log)
        log.close()
        #expect(Self.size(ConsoleLog.previous(url)) == 4096)
        #expect(Self.size(url) == bytes.count - 4096)
        let all = try Data(contentsOf: ConsoleLog.previous(url)) + Data(contentsOf: url)
        #expect(Array(all) == bytes)
    }

    @Test func neverHoldsMoreThanTwoFiles() throws {
        let scratch = try Scratch()
        let folder = scratch.root.appendingPathComponent("box", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("console.log")
        let log = try ConsoleLog(url: url, limit: 4096)
        let bytes = Self.lines(5000)
        Self.write(bytes, to: log)
        log.close()
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["console.log", "console.log.1"])
        #expect(Self.size(url) <= 4096 && Self.size(ConsoleLog.previous(url)) == 4096)
        // What is there is the end of what was written.
        let kept = try Data(contentsOf: ConsoleLog.previous(url)) + Data(contentsOf: url)
        #expect(Array(kept) == Array(bytes.suffix(kept.count)))
    }

    @Test func theLastBootsLogIsKeptAsThePreviousOne() throws {
        let scratch = try Scratch()
        let url = scratch.root.appendingPathComponent("console.log")
        let first = try ConsoleLog(url: url)
        Self.write(Array("first boot\n".utf8), to: first)
        first.close()
        let second = try ConsoleLog(url: url)
        Self.write(Array("second boot\n".utf8), to: second)
        second.close()
        #expect(try String(contentsOf: url, encoding: .utf8) == "second boot\n")
        #expect(try String(contentsOf: ConsoleLog.previous(url), encoding: .utf8) == "first boot\n")
    }

    @Test func keepsReadingWhenTheFolderIsGone() throws {
        let scratch = try Scratch()
        let folder = scratch.root.appendingPathComponent("box", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let log = try ConsoleLog(url: folder.appendingPathComponent("console.log"), limit: 4096)
        try FileManager.default.removeItem(at: folder)
        // Far more than a pipe holds: a reader that stopped would block these writes for good.
        let block = [UInt8](repeating: UInt8(ascii: "x"), count: 64 << 10)
        for _ in 0..<32 {
            #expect(Self.write(block, to: log))
        }
        log.close()
        #expect(!FileSystem.exists(folder.path))
    }

    @Test func aFloodIsDroppedPastTheMinutesBudget() throws {
        let scratch = try Scratch()
        let url = scratch.root.appendingPathComponent("console.log")
        let budget = 16 << 10
        let log = try ConsoleLog(url: url, limit: 1 << 20, bytesPerMinute: budget)
        let block = [UInt8](repeating: UInt8(ascii: "y"), count: 64 << 10)
        for _ in 0..<16 {
            #expect(Self.write(block, to: log))
        }
        log.close()
        let text = try String(contentsOf: url, encoding: .utf8)
        let dropped = (1 << 20) - budget
        let note = "\n[agent-vm: \(dropped) bytes of console output were dropped: the guest printed more than \(budget) bytes within 60 s]\n"
        #expect(text.hasSuffix(note))
        #expect(text.count == budget + note.count)
        #expect(text.components(separatedBy: "[agent-vm:").count == 2)
    }

    @Test func theBudgetComesBackWhenTheMinuteIsOver() throws {
        let scratch = try Scratch()
        let url = scratch.root.appendingPathComponent("console.log")
        let log = try ConsoleLog(url: url, bytesPerMinute: 8, window: 0.3)
        Self.write(Array("0123456789abcdef".utf8), to: log)
        Thread.sleep(forTimeInterval: 1)
        Self.write(Array("again\n".utf8), to: log)
        log.close()
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix("01234567\n[agent-vm: 8 bytes of console output were dropped"))
        #expect(text.hasSuffix("]\nagain\n"))
    }

    @Test func closingDoesNotWaitForAWriterThatNeverStops() throws {
        let scratch = try Scratch()
        let url = scratch.root.appendingPathComponent("console.log")
        let log = try ConsoleLog(url: url, limit: 1 << 20, bytesPerMinute: 1 << 30)
        // A machine that did not stop: it prints for as long as its console takes it.
        let stop = DispatchSemaphore(value: 0)
        // Its own copy of the pipe's write end, as a machine has: a number that stays its own.
        let descriptor = dup(log.writeHandle.fileDescriptor)
        let writer = Thread {
            let block = [UInt8](repeating: UInt8(ascii: "z"), count: 16 << 10)
            while block.withUnsafeBytes({ Darwin.write(descriptor, $0.baseAddress, $0.count) }) > 0 {}
            Darwin.close(descriptor)
            stop.signal()
        }
        writer.start()
        Thread.sleep(forTimeInterval: 0.3)
        let began = Date()
        log.close()
        #expect(Date().timeIntervalSince(began) < 5)
        // The writer's next write fails (nobody reads the pipe any more) without a signal,
        // and it ends.
        #expect(stop.wait(timeout: .now() + 5) == .success)
    }

    @Test func theTailIsPrintable() throws {
        let scratch = try Scratch()
        let url = scratch.root.appendingPathComponent("console.log")
        let log = try ConsoleLog(url: url)
        let lines = (1...30).map { "boot step \($0)" }.joined(separator: "\r\n")
        Self.write(Array((lines + "\r\n\u{1B}[31mKernel panic\u{1B}[0m\u{07}\r\n\r\n").utf8), to: log)
        log.close()
        let tail = ConsoleLog.tail(of: url, lines: 3)
        #expect(tail == "boot step 29\nboot step 30\n?[31mKernel panic?[0m?")
        #expect(!tail.unicodeScalars.contains { $0.value < 0x20 && $0 != "\n" })
        #expect(ConsoleLog.tail(of: url, lines: 0).isEmpty)
        #expect(ConsoleLog.tail(of: scratch.root.appendingPathComponent("none.log"), lines: 20).isEmpty)
    }

    @Test func theTailReachesIntoThePreviousFile() throws {
        let scratch = try Scratch()
        let url = scratch.root.appendingPathComponent("console.log")
        let log = try ConsoleLog(url: url, limit: 64)
        // 64 bytes fill the first file exactly; the rest starts the second.
        let first = (0..<8).map { "line 0\($0)\n" }.joined()
        #expect(first.utf8.count == 64)
        Self.write(Array((first + "line 08\n").utf8), to: log)
        log.close()
        #expect(ConsoleLog.tail(of: url, lines: 3) == "line 06\nline 07\nline 08")
    }

    @Test func aLinkInThePlaceOfTheLogIsNotFollowed() throws {
        let scratch = try Scratch()
        let target = scratch.root.appendingPathComponent("elsewhere")
        try Data("mine".utf8).write(to: target)
        let folder = scratch.root.appendingPathComponent("box", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("console.log")
        // The link is moved aside as "the last boot's log", and a file of the log's own starts.
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        let log = try ConsoleLog(url: url)
        Self.write(Array("guest text\n".utf8), to: log)
        log.close()
        #expect(try String(contentsOf: target, encoding: .utf8) == "mine")
        #expect(ConsoleLog.tail(of: url, lines: 5) == "guest text")
        // And read back, the link is not followed either.
        #expect(ConsoleLog.tail(of: ConsoleLog.previous(url), lines: 5).isEmpty)
    }
}
