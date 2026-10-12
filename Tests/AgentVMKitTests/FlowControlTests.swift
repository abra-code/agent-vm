// Tests/AgentVMKitTests/FlowControlTests.swift
//
// Flow control of an exec (GuestFlow): the windows themselves, and the real GuestServer and
// ExecSession over a socket pair with a host that reads late, a program that echoes more input
// than both windows hold, and programs that leave output or children behind.

import Darwin
import Foundation
import Testing
@testable import AgentVMGuestKit
@testable import AgentVMKit

@Suite struct FlowControlTests {
    private final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var number = 0

        func add(_ more: Int) {
            lock.lock()
            number += more
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return number
        }
    }

    /// Bytes waiting to be read on `descriptor`.
    private static func unread(_ descriptor: Int32) -> Int {
        var count: Int32 = 0
        // FIONREAD, a macro Swift does not import.
        _ = ioctl(descriptor, 0x4004667f, &count)
        return Int(count)
    }

    // MARK: - The windows

    @Test func aGateLetsAWindowThrough() {
        let gate = CreditGate(window: 1000)
        #expect(gate.take(400))
        #expect(gate.take(600))
        #expect(gate.room == 0)
        gate.add(250)
        #expect(gate.room == 250)
        // Never more room than the window.
        gate.add(5000)
        #expect(gate.room == 1000)
        // More than the whole window is let through when the window is empty of other frames.
        #expect(gate.take(4000))
        #expect(gate.room == 0)
    }

    @Test func aFullGateWaitsForAnAcknowledgment() {
        let gate = CreditGate(window: 100)
        #expect(gate.take(100))
        let passed = Count()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            if gate.take(60) {
                passed.add(1)
            }
            done.signal()
        }
        #expect(done.wait(timeout: .now() + 0.4) == .timedOut)
        gate.add(30)
        #expect(done.wait(timeout: .now() + 0.4) == .timedOut)
        gate.add(30)
        #expect(done.wait(timeout: .now() + 5) == .success)
        #expect(passed.value == 1)
    }

    @Test func anOpenedGateEndsEveryWait() {
        let gate = CreditGate(window: 100)
        #expect(gate.take(100))
        let refused = Count()
        let done = DispatchGroup()
        for _ in 0..<3 {
            done.enter()
            Thread.detachNewThread {
                if !gate.take(50) {
                    refused.add(1)
                }
                done.leave()
            }
        }
        Thread.sleep(forTimeInterval: 0.1)
        gate.open()
        #expect(done.wait(timeout: .now() + 5) == .success)
        #expect(refused.value == 3)
        #expect(!gate.take(1))
    }

    @Test func whatWasTakenIsAcknowledgedByTheQuarter() {
        var tally = AckTally(window: 4000)
        #expect(tally.took(payload: 495) == nil)
        #expect(tally.took(payload: 495) == 1000)
        #expect(tally.took(payload: 10) == nil)
        #expect(tally.took(payload: 2000) == 2020)
    }

    @Test func aChunkAlwaysFitsBetweenTwoAcknowledgments() {
        for window in [4096, GuestFlow.window, 1024 * 1024] {
            #expect(GuestFlow.cost(payload: GuestFlow.chunk(for: window)) <= GuestFlow.acknowledgeEvery(for: window))
        }
        #expect(GuestFlow.accepted(nil) == nil)
        #expect(GuestFlow.accepted(0) == nil)
        #expect(GuestFlow.accepted(-5) == nil)
        #expect(GuestFlow.accepted(1 << 30) == nil)
        #expect(GuestFlow.accepted(GuestFlow.window) == GuestFlow.window)
        #expect(GuestFlow.acknowledged(GuestFlow.acknowledgment(70000)) == 70000)
        #expect(GuestFlow.acknowledged([1, 2, 3]) == nil)
    }

    // MARK: - An exec

    /// Runs `work` on a thread of its own. These tests sleep and wait in reads for seconds, and
    /// a test's own thread is one of the few that every async test of the run shares.
    private func onAThread<Result: Sendable>(_ work: @escaping @Sendable () throws -> Result) async throws -> Result {
        return try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(with: Swift.Result { try work() })
            }
        }
    }

    /// What one exec gave a host that started to read `delay` seconds late.
    private struct Run: Sendable {
        var report: ExitReport
        var bytes = 0
        var text = ""
        var flowControl = false
        /// Unread on the connection after the delay, and the most seen while reading.
        var unreadFirst = 0
        var unreadMost = 0
        var seconds = 0.0
    }

    private nonisolated func run(_ argv: [String], window: Int?, delay: Double = 0, roomy: Bool = false, keepText: Bool = false) async throws -> Run {
        return try await onAThread {
            let pair = try GuestPair(roomBytes: roomy ? 2 * 1024 * 1024 : nil)
            let began = Date()
            let session = try ExecSession(descriptor: pair.client, request: GuestRequest(op: .exec, argv: argv, window: window))
            if delay > 0 {
                Thread.sleep(forTimeInterval: delay)
            }
            var result = Run(report: ExitReport(status: -1), flowControl: session.hasFlowControl)
            result.unreadFirst = Self.unread(pair.client)
            result.report = try session.run(stdout: { bytes in
                result.bytes += bytes.count
                if keepText {
                    result.text += String(decoding: bytes, as: UTF8.self)
                }
                result.unreadMost = max(result.unreadMost, Self.unread(pair.client))
            }, stderr: { _ in })
            result.seconds = Date().timeIntervalSince(began)
            return result
        }
    }

    @Test func flowControlIsOnlyForAHostThatAsks() async throws {
        #expect(try await run(["/usr/bin/true"], window: nil).flowControl == false)
        let asked = try await run(["/usr/bin/true"], window: GuestFlow.window)
        #expect(asked.flowControl)
        #expect(asked.report == ExitReport(status: 0))
        // A window this build does not work with is as none.
        #expect(try await run(["/usr/bin/true"], window: 12).flowControl == false)
    }

    @Test func aHostThatDoesNotReadHoldsNoMoreThanTheWindow() async throws {
        let total = 3_000_000
        let argv = ["/usr/bin/head", "-c", "\(total)", "/dev/zero"]
        // Without flow control the connection fills as far as it can: what the window is for.
        let plain = try await run(argv, window: nil, delay: 1, roomy: true)
        #expect(plain.unreadFirst > 4 * GuestFlow.window)
        #expect(plain.report == ExitReport(status: 0))
        #expect(plain.bytes == total)

        let held = try await run(argv, window: GuestFlow.window, delay: 1, roomy: true)
        #expect(held.unreadFirst > GuestFlow.window / 2)
        #expect(held.unreadFirst <= GuestFlow.window)
        #expect(held.report == ExitReport(status: 0))
        #expect(held.bytes == total)
        // Also while it is read: the window, and the exit report after it.
        #expect(held.unreadMost <= GuestFlow.window + 1024)
    }

    @Test func aSmallWindowGetsSmallFrames() async throws {
        // The frames follow the window the host asked for, not this build's own: a host that
        // asks for little holds a quarter of that per frame, and never more than its window.
        let window = 4096
        let total = 300_000
        let (report, got, largest) = try await onAThread { () -> (ExitReport, Int, Int) in
            let pair = try GuestPair()
            let session = try ExecSession(descriptor: pair.client,
                                          request: GuestRequest(op: .exec, argv: ["/usr/bin/head", "-c", "\(total)", "/dev/zero"], window: window))
            var got = 0
            var largest = 0
            let report = try session.run(stdout: { bytes in
                got += bytes.count
                largest = max(largest, bytes.count)
            }, stderr: { _ in })
            return (report, got, largest)
        }
        #expect(report == ExitReport(status: 0))
        #expect(got == total)
        #expect(largest <= GuestFlow.chunk(for: window))
    }

    @Test func nothingWaitsInTheConnectionWhileAHandlerWaits() async throws {
        // What stalls a box is output left unread in the connection (GuestFlow), so a run
        // reads it into memory at once, and no more of it than the window.
        let total = 2_000_000
        let (report, got, waiting) = try await onAThread { () -> (ExitReport, Int, [Int]) in
            let pair = try GuestPair(roomBytes: 2 * 1024 * 1024)
            let session = try ExecSession(descriptor: pair.client,
                                          request: GuestRequest(op: .exec, argv: ["/usr/bin/head", "-c", "\(total)", "/dev/zero"], window: GuestFlow.window))
            var got = 0
            var waiting: [Int] = []
            let report = try session.run(stdout: { bytes in
                if got == 0 || (got < total / 2 && got + bytes.count >= total / 2) {
                    // A reader that stops for a while, at the start and in the middle.
                    Thread.sleep(forTimeInterval: 0.7)
                    waiting.append(Self.unread(pair.client))
                }
                got += bytes.count
            }, stderr: { _ in })
            return (report, got, waiting)
        }
        #expect(report == ExitReport(status: 0))
        #expect(got == total)
        #expect(waiting == [0, 0])
    }

    @Test func inputLargerThanBothWindowsIsEchoedWhole() async throws {
        let total = 4_000_000
        let (report, got, others, flowControl) = try await onAThread { () -> (ExitReport, Int, Int, Bool) in
            let pair = try GuestPair()
            let session = try ExecSession(descriptor: pair.client, request: GuestRequest(op: .exec, argv: ["/bin/cat"], window: GuestFlow.window))
            var ends: [Int32] = [-1, -1]
            guard pipe(&ends) == 0 else {
                throw AgentVMError.system(operation: "pipe", code: errno)
            }
            let (source, sink) = (ends[0], ends[1])
            defer { close(source) }
            Thread.detachNewThread {
                let block = [UInt8](repeating: 0x61, count: 50_000)
                var left = total
                while left > 0 {
                    let count = min(left, block.count)
                    var done = 0
                    while done < count {
                        let written = block.withUnsafeBytes { write(sink, $0.baseAddress! + done, count - done) }
                        if written <= 0 {
                            break
                        }
                        done += written
                    }
                    left -= count
                }
                close(sink)
            }
            session.forwardStdin(from: source)
            var got = 0
            var others = 0
            let report = try session.run(stdout: { bytes in
                got += bytes.count
                others += bytes.filter { $0 != 0x61 }.count
            }, stderr: { _ in })
            return (report, got, others, session.hasFlowControl)
        }
        #expect(flowControl)
        #expect(report == ExitReport(status: 0))
        #expect(got == total)
        #expect(others == 0)
    }

    @Test(arguments: [nil, GuestFlow.window])
    func outputLeftBehindArrivesHoweverLateTheHostReads(window: Int?) async throws {
        // The program is long gone when the host starts to read, and what it wrote did not
        // fit the connection: the daemon must still hold it, and send it before the exit report.
        let total = 300_000
        let late = try await run(["/usr/bin/head", "-c", "\(total)", "/dev/zero"], window: window, delay: 3.5)
        #expect(late.report == ExitReport(status: 0))
        #expect(late.bytes == total)
    }

    @Test(arguments: [nil, GuestFlow.window])
    func aChildThatKeepsWritingDoesNotKeepTheExec(window: Int?) async throws {
        let script = "(while :; do echo more; sleep 0.05; done) & echo first"
        let result = try await run(["/bin/sh", "-c", script], window: window, keepText: true)
        #expect(result.report == ExitReport(status: 0))
        #expect(result.text.contains("first\n"))
        #expect(result.seconds >= 1.5)
        #expect(result.seconds < 10)
    }

    @Test func aChildThatHoldsThePipeSilentlyDoesNotKeepTheExec() async throws {
        let result = try await run(["/bin/sh", "-c", "/bin/sleep 30 & echo first"], window: GuestFlow.window, keepText: true)
        #expect(result.report == ExitReport(status: 0))
        #expect(result.text == "first\n")
        #expect(result.seconds < 10)
    }

    @Test func inputPastTheWindowEndsTheConnection() async throws {
        let (window, ended, alive) = try await onAThread { () -> (Int?, Bool, Bool) in
            let pair = try GuestPair()
            let channel = FrameChannel(descriptor: pair.client)
            try channel.sendRequest(GuestRequest(op: .exec, argv: ["/bin/sleep", "30"], window: GuestFlow.window))
            let response = try channel.receive(.response, as: GuestResponse.self)
            guard response.ok, let pid = response.pid else {
                throw GuestProtocolError.malformed("no program")
            }
            // A program that reads nothing: its pipe takes some, the daemon holds a window, and a
            // host that sends on without acknowledgments is cut off: the daemon stops reading (a
            // send may still succeed for a moment; what it sends is dropped) and ends the program.
            let block = [UInt8](repeating: 0, count: 16_000)
            for _ in 0..<200 {
                do {
                    try channel.send(Frame(.stdin, block))
                } catch {
                    break
                }
            }
            let ended = pair.serverDone.wait(timeout: .now() + 15) == .success
            return (response.window, ended, kill(pid, 0) == 0)
        }
        #expect(window == GuestFlow.window)
        #expect(ended)
        #expect(!alive)
    }

    @Test(arguments: [0.3, 3.0])
    func aHostThatLeavesEndsAnExecWhoseOutputWaits(after: Double) async throws {
        // Output waits for acknowledgments that never come, of a program that is still writing
        // (the short wait) or has ended (the long one, past the two seconds the daemon gives
        // the pipes); when the host goes, the daemon is done with the exec at once.
        let (window, seconds) = try await onAThread { () -> (Int?, Double?) in
            let pair = try GuestPair()
            let channel = FrameChannel(descriptor: pair.client)
            let argv = after < 1 ? ["/usr/bin/head", "-c", "3000000", "/dev/zero"] : ["/usr/bin/head", "-c", "40000", "/dev/zero"]
            try channel.sendRequest(GuestRequest(op: .exec, argv: argv, window: 4096))
            let window = try channel.receive(.response, as: GuestResponse.self).window
            Thread.sleep(forTimeInterval: after)
            let began = Date()
            channel.shutdownBoth()
            guard pair.serverDone.wait(timeout: .now() + 15) == .success else {
                return (window, nil)
            }
            return (window, Date().timeIntervalSince(began))
        }
        #expect(window == GuestFlow.window)
        #expect(try #require(seconds) < 5)
    }

    @Test func aTerminalsOutputKeepsToTheWindowToo() async throws {
        let total = 400_000
        let (report, got, flowControl, seconds) = try await onAThread { () -> (ExitReport, Int, Bool, Double) in
            let pair = try GuestPair(helperPath: try GuestPair.builtHelper())
            let began = Date()
            // A child keeps the terminal open after the program: the exec ends all the same.
            let script = "stty raw; /usr/bin/head -c \(total) /dev/zero; /bin/sleep 30 &"
            let session = try ExecSession(descriptor: pair.client,
                                          request: GuestRequest(op: .exec, argv: ["/bin/sh", "-c", script], terminal: TerminalSize(rows: 24, columns: 80),
                                                                window: GuestFlow.window))
            var got = 0
            let report = try session.run(stdout: { bytes in
                if got == 0 {
                    Thread.sleep(forTimeInterval: 0.5)
                }
                got += bytes.count
            }, stderr: { _ in })
            return (report, got, session.hasFlowControl, Date().timeIntervalSince(began))
        }
        #expect(flowControl)
        #expect(report == ExitReport(status: 0))
        #expect(got == total)
        #expect(seconds < 10)
    }

    @Test func anAcknowledgmentNobodyAskedForEndsTheConnection() async throws {
        let (window, ended) = try await onAThread { () -> (Int?, Bool) in
            let pair = try GuestPair()
            let channel = FrameChannel(descriptor: pair.client)
            try channel.sendRequest(GuestRequest(op: .exec, argv: ["/bin/sleep", "30"]))
            let window = try channel.receive(.response, as: GuestResponse.self).window
            try channel.send(Frame(.outputAck, GuestFlow.acknowledgment(10)))
            return (window, pair.serverDone.wait(timeout: .now() + 15) == .success)
        }
        #expect(window == nil)
        #expect(ended)
    }

    @Test func theFeatureIsAnnounced() {
        #expect(GuestFeature.all(for: .macOS).contains(GuestFeature.flowControl))
        #expect(GuestFeature.all(for: .linux).contains(GuestFeature.flowControl))
    }
}
