// Tests/AgentVMKitTests/HostileGuestTests.swift
//
// The host's side of the guest protocol against a guest that is not agent-vm-guest: a thread
// plays the guest on the other end of a socket pair and answers with whatever a test gives it.
// What the guest sends decides nothing about how long the host waits, how much it keeps, or
// whether it stays up.

import Darwin
import Foundation
import Testing
@testable import AgentVMKit

/// A socket pair whose far end reads one request and then runs `script`.
private final class FakeGuest {
    let host: Int32
    private let guest: Int32
    private let done = DispatchSemaphore(value: 0)

    init(_ script: @escaping @Sendable (FrameChannel) -> Void) throws {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw AgentVMError.system(operation: "socketpair", code: errno)
        }
        host = pair[0]
        guest = pair[1]
        let guest = guest
        let done = done
        Thread.detachNewThread {
            let channel = FrameChannel(descriptor: guest)
            _ = try? channel.receive()
            script(channel)
            done.signal()
        }
    }

    /// Ends the guest's thread before its descriptor goes (a write of its into a reused
    /// descriptor number would land in another test). Closing the host's end is what frees a
    /// guest blocked in a write: a shutdown of the reading side alone does not wake it.
    deinit {
        close(host)
        done.wait()
        close(guest)
    }

    static let accepted = Array(#"{"v":1,"ok":true,"pid":4242}"#.utf8)
}

@Suite struct HostileGuestTests {
    @Test(arguments: [
        #"{"signal":2147483647}"#, #"{"signal":-1}"#, #"{"signal":0}"#, #"{"signal":32}"#,
        #"{"status":-1}"#, #"{"status":256}"#, #"{"status":0,"signal":9}"#, "{}", "not JSON", "",
    ])
    func anExitReportNoProcessCanEndWithIsRefused(payload: String) throws {
        let guest = try FakeGuest { channel in
            try? channel.send(Frame(.response, FakeGuest.accepted))
            try? channel.send(Frame(.exit, Array(payload.utf8)))
        }
        #expect(throws: GuestProtocolError.malformed("unreadable exit report")) {
            try GuestClient.capture(guest.host, GuestRequest(op: .exec, argv: ["/usr/bin/true"]))
        }
    }

    @Test func aShellStatusIsNeverATrap() {
        #expect(ExitReport(signal: Int32.max).shellStatus == 128)
        #expect(ExitReport(signal: -1).shellStatus == 128)
        #expect(ExitReport().shellStatus == 128)
        #expect(ExitReport(signal: SIGKILL).shellStatus == 137)
        #expect(ExitReport(status: 0).isValid && ExitReport(status: 255).isValid && ExitReport(signal: 1).isValid)
        #expect(!ExitReport().isValid && !ExitReport(status: 1, signal: 1).isValid)
    }

    @Test func capturedOutputHasALimit() throws {
        let guest = try FakeGuest { channel in
            try? channel.send(Frame(.response, FakeGuest.accepted))
            // Far more than the limit, for as long as the host keeps reading.
            let chunk = [UInt8](repeating: 0x41, count: 65536)
            for _ in 0..<2000 {
                guard (try? channel.send(Frame(.stdout, chunk))) != nil else {
                    return
                }
            }
        }
        #expect(throws: GuestProtocolError.malformed("the program printed more than 200000 bytes")) {
            try GuestClient.capture(guest.host, GuestRequest(op: .exec, argv: ["/usr/bin/yes"]), limit: 200_000)
        }
    }

    @Test func outputWithinTheLimitArrivesWhole() throws {
        let guest = try FakeGuest { channel in
            try? channel.send(Frame(.response, FakeGuest.accepted))
            try? channel.send(Frame(.stdout, Array("out".utf8)))
            try? channel.send(Frame(.stderr, Array("err".utf8)))
            try? channel.send(Frame(.exit, Array(#"{"status":3}"#.utf8)))
        }
        let result = try GuestClient.capture(guest.host, GuestRequest(op: .exec, argv: ["x"]), limit: 3)
        #expect(result.report == ExitReport(status: 3))
        #expect(result.stdout == "out" && result.stderr == "err")
    }

    /// Each byte arrives well inside the read timeout, so only a limit on the whole answer ends
    /// the wait.
    @Test(.timeLimit(.minutes(1)))
    func anAnswerSentAByteAtATimeEndsAtTheDeadline() throws {
        for request in ["hello", "shutdown", "time-sync", "capture"] {
            let guest = try FakeGuest { channel in
                // A response frame announcing 100,000 bytes, then a byte every 50 ms.
                var sent = FrameChannel.writeIgnoringErrors(channel.descriptor, [FrameType.response.rawValue, 0, 1, 0x86, 0xa0])
                while sent {
                    usleep(50_000)
                    sent = FrameChannel.writeIgnoringErrors(channel.descriptor, [0x20])
                }
            }
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            _ = setsockopt(guest.host, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let began = ContinuousClock.now
            #expect(throws: AgentVMError.self) {
                switch request {
                case "hello": _ = try GuestClient.hello(guest.host, within: .milliseconds(700))
                case "shutdown": try GuestClient.shutdown(guest.host, within: .milliseconds(700))
                case "time-sync": _ = try GuestClient.syncTime(guest.host, within: .milliseconds(700))
                default: _ = try GuestClient.capture(guest.host, GuestRequest(op: .exec, argv: ["x"]), within: .milliseconds(700))
                }
            }
            #expect(ContinuousClock.now - began < .seconds(10), "\(request)")
        }
    }

    @Test(arguments: [
        #"{"v":1,"ok":true,"version":"0.5.9\u001b]52;c;eA==\u0007"}"#,
        #"{"v":1,"ok":true,"version":"0.5.9\nforged line"}"#,
        #"{"v":1,"ok":true,"version":"0.5.9","osBuild":"26A434\r"}"#,
        #"{"v":1,"ok":true,"version":"0.5.9","features":["terminal","\u009b2J"]}"#,
        #"{"v":1,"ok":true,"version":""}"#,
    ])
    func aHelloThatNamesNoVersionIsRefused(answer: String) throws {
        let guest = try FakeGuest { channel in
            try? channel.send(Frame(.response, Array(answer.utf8)))
        }
        #expect(throws: GuestProtocolError.self) { try GuestClient.hello(guest.host) }
    }

    @Test func aHelloTooLongToKeepIsRefused() throws {
        let long = String(repeating: "9", count: 70_000)
        let many = (0..<10_000).map { "\"f\($0)\"" }.joined(separator: ",")
        for answer in [#"{"v":1,"ok":true,"version":"\#(long)"}"#, #"{"v":1,"ok":true,"version":"1","features":[\#(many)]}"#] {
            let guest = try FakeGuest { channel in
                try? channel.send(Frame(.response, Array(answer.utf8)))
            }
            #expect(throws: GuestProtocolError.self) { try GuestClient.hello(guest.host) }
        }
    }

    @Test func aRealHelloIsTaken() throws {
        let guest = try FakeGuest { channel in
            try? channel.send(Frame(.response, Array(#"{"v":1,"ok":true,"version":"0.5.10","osBuild":"26A434","features":["terminal-pixels","user-session","time-sync"]}"#.utf8)))
        }
        let hello = try GuestClient.hello(guest.host)
        #expect(hello.version == "0.5.10" && hello.osBuild == "26A434" && hello.features?.count == 3)
    }

    @Test func aRefusalIsOneLineAndAShellStatus() throws {
        let guest = try FakeGuest { channel in
            try? channel.send(Frame(.response, Array(#"{"v":1,"ok":false,"status":2147483647,"error":"no\r\u001b[2Kagent-vm: forged\nline"}"#.utf8)))
        }
        do {
            _ = try ExecSession(descriptor: guest.host, request: GuestRequest(op: .exec, argv: ["x"]))
            Issue.record("the refusal was not thrown")
        } catch let refusal as ExecRefusal {
            #expect(refusal.message == "no??[2Kagent-vm: forged?line")
            #expect(refusal.status == 126)
        }
    }

    /// Notices cost the caller a printed line, a log line and perhaps a stopped program each.
    @Test func noticesAreCheckedCountedAndNotRepeated() throws {
        let guest = try FakeGuest { channel in
            try? channel.send(Frame(.response, FakeGuest.accepted))
            func notice(_ json: String) {
                try? channel.send(Frame(.notice, Array(json.utf8)))
            }
            // Not a service name; too large to be a notice; a repeat; then far too many.
            notice(#"{"kind":"permission-prompt","service":"\u001b]52;c;eA==\u0007","program":"/bin/ls","pid":7}"#)
            notice(#"{"kind":"permission-prompt","service":"kTCCServiceSystemPolicyDownloadsFolder","program":"\#(String(repeating: "p", count: 5000))","pid":7}"#)
            notice(#"{"kind":"permission-prompt","service":"kTCCServiceSystemPolicyDownloadsFolder","program":"/bin/ls\r\u001b[2K","pid":7}"#)
            notice(#"{"kind":"permission-prompt","service":"kTCCServiceSystemPolicyDownloadsFolder","program":"/bin/ls\r\u001b[2K","pid":7}"#)
            for pid in 100..<1100 {
                notice(#"{"kind":"keychain-prompt","service":"keychain","program":"/usr/bin/security","pid":\#(pid)}"#)
            }
            try? channel.send(Frame(.exit, Array(#"{"status":0}"#.utf8)))
        }
        let session = try ExecSession(descriptor: guest.host, request: GuestRequest(op: .exec, argv: ["x"]))
        var notices: [GuestNotice] = []
        let report = try session.run(stdout: { _ in }, stderr: { _ in }, notice: { notices.append($0) })
        #expect(report == ExitReport(status: 0))
        #expect(notices.count == ExecSession.maxNotices)
        #expect(notices.first == GuestNotice(kind: .permissionPrompt, service: "kTCCServiceSystemPolicyDownloadsFolder", program: "/bin/ls??[2K", pid: 7))
        #expect(notices.dropFirst().allSatisfy { $0.kind == .keychainPrompt })
    }

    @Test func aDeadlineNotReachedChangesNothing() throws {
        let guest = try FakeGuest { channel in
            try? channel.send(Frame(.response, Array(#"{"v":1,"ok":true,"version":"9.9.9"}"#.utf8)))
        }
        let hello = try GuestClient.hello(guest.host, within: .seconds(30))
        #expect(hello.version == "9.9.9")
        // The connection is still whole afterwards: the timer was called off.
        var one: UInt8 = 1
        #expect(write(guest.host, &one, 1) == 1)
    }
}

extension FrameChannel {
    /// For a fake guest that writes raw bytes; false once the host is gone.
    static func writeIgnoringErrors(_ descriptor: Int32, _ bytes: [UInt8]) -> Bool {
        return (try? writeAll(descriptor, bytes)) != nil
    }
}
