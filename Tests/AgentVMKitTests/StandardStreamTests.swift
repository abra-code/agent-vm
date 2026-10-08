// Tests/AgentVMKitTests/StandardStreamTests.swift
//
// Writing to standard output and standard error must never end the program: a descriptor that
// is closed, or a pipe nobody reads, lets the message go unsaid.

import Darwin
import Foundation
import Testing
@testable import AgentVMGuestKit

@Suite struct StandardStreamTests {
    @Test func whatIsWrittenArrives() throws {
        var ends: [Int32] = [0, 0]
        #expect(pipe(&ends) == 0)
        StandardStream.write("one\n", to: ends[1])
        StandardStream.write(Data("two\n".utf8), to: ends[1])
        close(ends[1])
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = read(ends[0], &buffer, buffer.count)
        close(ends[0])
        #expect(String(decoding: buffer.prefix(max(count, 0)), as: UTF8.self) == "one\ntwo\n")
    }

    /// A stream somebody made non-blocking (a terminal or a pipe shared with another program)
    /// is full at times: the rest is written once there is room, not dropped.
    @Test func aFullNonBlockingPipeIsWaitedFor() throws {
        var ends: [Int32] = [0, 0]
        #expect(pipe(&ends) == 0)
        #expect(fcntl(ends[1], F_SETFL, fcntl(ends[1], F_GETFL) | O_NONBLOCK) == 0)
        let total = 1_000_000
        let readEnd = ends[0]
        let result = ReadCount()
        let finished = DispatchSemaphore(value: 0)
        let reader = Thread {
            // Late, so the writer finds the pipe full first.
            usleep(100_000)
            var got = 0
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = read(readEnd, &buffer, buffer.count)
                if count <= 0 {
                    break
                }
                got += count
            }
            result.set(got)
            finished.signal()
        }
        reader.start()
        StandardStream.write(String(repeating: "x", count: total), to: ends[1])
        close(ends[1])
        finished.wait()
        close(ends[0])
        #expect(result.get() == total)
    }

    @Test func aClosedDescriptorOrAPipeNobodyReadsIsLetPass() throws {
        // No descriptor: EBADF. (Not the number of one just closed: tests run side by side in
        // one process, and another may have been given that number meanwhile.)
        StandardStream.write("lost\n", to: -1)
        var ends: [Int32] = [0, 0]
        // Nobody reads: EPIPE, with the signal that comes with it not delivered here.
        #expect(pipe(&ends) == 0)
        close(ends[0])
        #expect(fcntl(ends[1], F_SETNOSIGPIPE, 1) == 0)
        StandardStream.write(String(repeating: "x", count: 100_000), to: ends[1])
        close(ends[1])
    }
}

/// What the reading thread counted, handed to the test.
private final class ReadCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func set(_ value: Int) {
        lock.lock()
        count = value
        lock.unlock()
    }

    func get() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
