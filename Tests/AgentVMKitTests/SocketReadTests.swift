// Tests/AgentVMKitTests/SocketReadTests.swift
//
// Readers of AF_UNIX sockets must see a shutdown made the moment they start waiting. On macOS
// 27 a reader asleep in read() missed a few in 100 of these and slept on (SocketRead).

import Darwin
import Foundation
import Synchronization
import Testing
@testable import AgentVMKit

/// One reader on a thread of its own, and a trigger `delay` after it started. The tests sweep
/// the delay across the moment the reader goes to sleep: with read(2), misses peaked 1.5 to 4
/// microseconds after a frame reader started (up to 1 in 5 rounds there), and 40 to 50 after a
/// Splice copy started (it clears a 64 KB buffer first).
private final class Race: @unchecked Sendable {
    private let started = Atomic<Bool>(false)
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var outcome = ""

    /// What `read` returned, or nil when it had not returned 2 s after `trigger`. A reader that
    /// missed a shutdown of its own socket is not freed by a receive timeout (measured), only by
    /// a signal or the other end closing, so after a miss the caller leaves the descriptors open
    /// for it rather than close one under it.
    static func run(delay nanoseconds: UInt64, read: @escaping @Sendable () -> String, trigger: () -> Void) -> String? {
        let race = Race()
        Thread.detachNewThread {
            race.started.store(true, ordering: .releasing)
            let outcome = read()
            race.lock.lock()
            race.outcome = outcome
            race.lock.unlock()
            race.done.signal()
        }
        while !race.started.load(ordering: .acquiring) {}
        let began = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        while clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - began < nanoseconds {}
        trigger()
        guard race.done.wait(timeout: .now() + 2) == .success else {
            return nil
        }
        race.lock.lock()
        defer { race.lock.unlock() }
        return race.outcome
    }
}

@Suite struct SocketReadTests {
    static let triggers: [(name: String, shut: @Sendable (_ peer: Int32, _ own: Int32) -> Void)] = [
        ("the peer's SHUT_WR", { peer, _ in _ = shutdown(peer, SHUT_WR) }),
        ("the peer's SHUT_RDWR", { peer, _ in _ = shutdown(peer, SHUT_RDWR) }),
        ("its own SHUT_RDWR", { _, own in _ = shutdown(own, SHUT_RDWR) }),
        ("its own SHUT_RD", { _, own in _ = shutdown(own, SHUT_RD) }),
    ]

    static func socketPair() throws -> (peer: Int32, own: Int32) {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw AgentVMError.system(operation: "socketpair", code: errno)
        }
        return (pair[0], pair[1])
    }

    @Test func aFrameReaderSeesAShutdownRacingIt() throws {
        for round in 0..<1600 {
            let trigger = Self.triggers[round % Self.triggers.count]
            let (peer, own) = try Self.socketPair()
            let channel = FrameChannel(descriptor: own)
            // 0 to 10 microseconds in steps of 25 ns, for each trigger.
            let delay = UInt64(round / Self.triggers.count % 400) * 25
            let outcome = Race.run(delay: delay, read: {
                do {
                    return try channel.receive().map { "a \($0.type) frame" } ?? "end of file"
                } catch {
                    return "\(error)"
                }
            }, trigger: { trigger.shut(peer, own) })
            try #require(outcome != nil, "round \(round): a receive missed \(trigger.name) \(delay) ns after it started")
            close(peer)
            close(own)
            #expect(outcome == "end of file", "round \(round), \(trigger.name)")
        }
    }

    /// A tunnel's copy ends when the guest's side shuts down, however close the timing.
    @Test func aSpliceCopySeesAShutdownRacingIt() throws {
        for round in 0..<5000 {
            let (peer, own) = try Self.socketPair()
            var sink: [Int32] = [-1, -1]
            try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &sink) == 0)
            let into = sink[0]
            // 0 to 100 microseconds in steps of 20 ns.
            let delay = UInt64(round) * 20
            let outcome = Race.run(delay: delay, read: { "\(Splice.copy(own, into)) bytes" }, trigger: { _ = shutdown(peer, SHUT_WR) })
            try #require(outcome != nil, "round \(round): a copy missed the peer's SHUT_WR \(delay) ns after it started")
            for descriptor in [peer, own, sink[0], sink[1]] {
                close(descriptor)
            }
            #expect(outcome == "0 bytes")
        }
    }

    /// A receive timeout the caller set still ends a wait with nothing to read.
    @Test func theReceiveTimeoutStillApplies() throws {
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer {
            close(pair[0])
            close(pair[1])
        }
        var limit = timeval(tv_sec: 0, tv_usec: 300_000)
        _ = setsockopt(pair[1], SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        let channel = FrameChannel(descriptor: pair[1])
        let clock = ContinuousClock()
        let began = clock.now
        #expect(throws: GuestProtocolError.io(operation: "read", code: EAGAIN)) { _ = try channel.receive() }
        let took = clock.now - began
        #expect(took >= .milliseconds(300) && took < .seconds(2), "took \(took)")
    }

    /// Waiting data is read at once, then end of file.
    @Test func dataThenEndOfFile() throws {
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[1]) }
        _ = write(pair[0], "abc", 3)
        close(pair[0])
        var buffer = [UInt8](repeating: 0, count: 8)
        #expect(buffer.withUnsafeMutableBytes { SocketRead.read(pair[1], $0.baseAddress!, $0.count) } == 3)
        #expect(Array(buffer[0..<3]) == Array("abc".utf8))
        #expect(buffer.withUnsafeMutableBytes { SocketRead.read(pair[1], $0.baseAddress!, $0.count) } == 0)
    }

    @Test func slicesRoundUpToWholeMilliseconds() {
        #expect(SocketRead.milliseconds(.zero) == 1)
        #expect(SocketRead.milliseconds(.microseconds(1)) == 1)
        #expect(SocketRead.milliseconds(.milliseconds(250)) == 250)
        #expect(SocketRead.milliseconds(.microseconds(250_001)) == 251)
        #expect(SocketRead.milliseconds(.seconds(3)) == 3000)
    }
}
