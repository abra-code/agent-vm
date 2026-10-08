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

/// A socket whose other end closed before anyone could turn SIGPIPE off for it: macOS refuses
/// the setting then (EINVAL), and a write would end the process. These tests run with SIGPIPE
/// at its default, so a write that slips through ends the whole test run.
@Suite struct DisconnectedSocketTests {
    /// A socket pair with one end closed already; the other end is returned.
    static func orphan() throws -> Int32 {
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        close(pair[0])
        return pair[1]
    }

    @Test func theSettingIsRefusedForADisconnectedSocket() throws {
        let socket = try Self.orphan()
        defer { close(socket) }
        // What the fix rests on. If macOS comes to accept the setting, the rest still holds.
        #expect(!Platform.noSIGPIPE(descriptor: socket))
        #expect(!Platform.noSIGPIPE(socket: socket))
        var live: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &live) == 0)
        defer { live.forEach { close($0) } }
        #expect(Platform.noSIGPIPE(descriptor: live[0]) && Platform.noSIGPIPE(socket: live[0]))
    }

    @Test func aChannelOnADisconnectedSocketDoesNotWrite() throws {
        let channel = FrameChannel(descriptor: try Self.orphan())
        defer { channel.close() }
        #expect(throws: GuestProtocolError.io(operation: "write", code: EPIPE)) {
            try channel.send(Frame(.stdout, [1, 2, 3]))
        }
        // A request that cannot be written is one the guest did not get.
        #expect(throws: GuestProtocolError.notDelivered(code: EPIPE)) {
            try channel.sendRequest(GuestRequest(op: .hello))
        }
        #expect(try channel.receive() == nil)
    }

    /// The guest daemon answers a connection that brought no request; the host may be gone by
    /// then. This is what ended test runs, about two in three, with signal 13.
    @Test(arguments: 0..<3) func theServerSurvivesAHostThatLeftAtOnce(_ attempt: Int) throws {
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        close(pair[0])
        GuestServer(defaultUser: nil, helperPath: nil).serve(descriptor: pair[1])
    }

    /// A socket that got the setting while it was connected keeps it, though macOS refuses to
    /// set it again once the peer is gone: such a socket is protected, and what its peer sent
    /// before leaving still crosses a splice.
    @Test func aSocketProtectedWhileConnectedStaysProtected() throws {
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        #expect(Platform.noSIGPIPE(socket: pair[1]))
        #expect(write(pair[0], "last", 4) == 4)
        close(pair[0])
        #expect(fcntl(pair[1], F_SETNOSIGPIPE, 1) == -1)
        #expect(Platform.noSIGPIPE(descriptor: pair[1]) && Platform.noSIGPIPE(socket: pair[1]))
        var live: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &live) == 0)
        defer {
            close(pair[1])
            live.forEach { close($0) }
        }
        // Something for the gone side too: the write fails with EPIPE, and no signal.
        #expect(write(live[1], "data", 4) == 4)
        let counts = Splice.run(pair[1], live[0])
        #expect(counts.aToB == 4 && counts.bToA == 0)
        var buffer = [UInt8](repeating: 0, count: 8)
        #expect(read(live[1], &buffer, 8) == 4)
        #expect(Array(buffer.prefix(4)) == Array("last".utf8))
    }

    /// The live side's peer has finished sending already (a request, then a half-close): macOS
    /// refuses SHUT_RDWR on such a socket, so each way is shut by itself.
    @Test func aSpliceWithADisconnectedSocketTellsAHalfClosedPeer() throws {
        let dead = try Self.orphan()
        var live: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &live) == 0)
        defer {
            close(dead)
            live.forEach { close($0) }
        }
        #expect(shutdown(live[1], SHUT_WR) == 0)
        Splice.run(live[0], dead)
        var watched = pollfd(fd: live[1], events: Int16(POLLIN), revents: 0)
        try #require(poll(&watched, 1, 2000) == 1)
        var byte: UInt8 = 0
        #expect(read(live[1], &byte, 1) == 0)
    }

    @Test func aSpliceWithADisconnectedSocketCopiesNothing() throws {
        let dead = try Self.orphan()
        var live: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &live) == 0)
        defer {
            close(dead)
            live.forEach { close($0) }
        }
        #expect(write(live[1], "data", 4) == 4)
        let counts = Splice.run(live[0], dead)
        #expect(counts.aToB == 0 && counts.bToA == 0)
        // The live side was told: its peer reads the end.
        var byte: UInt8 = 0
        #expect(read(live[1], &byte, 1) == 0)
    }
}
