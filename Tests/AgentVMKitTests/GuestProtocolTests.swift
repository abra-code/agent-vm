// Tests/AgentVMKitTests/GuestProtocolTests.swift
//
// The guest protocol end to end on this Mac: the real GuestServer serves one side of a socket
// pair and GuestClient/ExecSession drive the other, so everything except the vsock accept loop
// (host-only CID check) and switching accounts (needs root) is exercised here.

import Darwin
import Foundation
import Testing
@testable import AgentVMKit

/// A connected pair: the server side is served on a thread; `client` is closed at the end.
final class GuestPair {
    let client: Int32
    let serverDone = DispatchSemaphore(value: 0)

    /// `helperPath`: an exec-as helper (see `builtHelper`); without one, the server runs programs
    /// only directly, as this test process's account and without a terminal.
    init(helperPath: String? = nil, setClock: (@Sendable (Double) -> Int32)? = nil) throws {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw AgentVMError.system(operation: "socketpair", code: errno)
        }
        client = pair[0]
        let server = pair[1]
        let done = serverDone
        Thread.detachNewThread {
            GuestServer(defaultUser: nil, helperPath: helperPath, setClock: setClock).serve(descriptor: server)
            done.signal()
        }
    }

    deinit {
        close(client)
    }

    /// The agent-vm-guest this build produced (swift test builds every target), next to the
    /// test bundle: the real exec-as helper.
    static func builtHelper() throws -> String {
        let bundle = Bundle(for: BundleMarker.self).bundleURL
        let helper = bundle.deletingLastPathComponent().appendingPathComponent("agent-vm-guest").path
        guard FileManager.default.isExecutableFile(atPath: helper) else {
            throw AgentVMError.system(operation: "find \(helper) (run swift build first)", code: ENOENT)
        }
        return helper
    }
}

private final class BundleMarker {}

@Suite struct FrameTests {
    @Test func framesRoundTrip() throws {
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[0]); close(pair[1]) }
        let a = FrameChannel(descriptor: pair[0])
        let b = FrameChannel(descriptor: pair[1])
        try a.send(Frame(.stdout, [1, 2, 3]))
        try a.send(Frame(.stdinEnd))
        try a.send(Frame(.signal, SIGTERM.bigEndianBytes))
        #expect(try b.receive() == Frame(.stdout, [1, 2, 3]))
        #expect(try b.receive() == Frame(.stdinEnd))
        let signal = try b.receive()
        #expect(Int32(bigEndianBytes: signal?.payload ?? []) == SIGTERM)
        shutdown(pair[0], SHUT_WR)
        #expect(try b.receive() == nil)
    }

    @Test func badFramesAreRejected() throws {
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[0]); close(pair[1]) }
        let reader = FrameChannel(descriptor: pair[1])
        // Unknown type.
        _ = write(pair[0], [0x7f, 0, 0, 0, 0] as [UInt8], 5)
        #expect(throws: GuestProtocolError.malformed("unknown frame type 127")) { _ = try reader.receive() }
        // Oversized length.
        _ = write(pair[0], [0x20, 0x7f, 0xff, 0xff, 0xff] as [UInt8], 5)
        #expect(throws: (any Error).self) { _ = try reader.receive() }
        // Sending more than the limit is refused locally.
        #expect(throws: (any Error).self) {
            try FrameChannel(descriptor: pair[0]).send(Frame(.stdout, [UInt8](repeating: 0, count: GuestProtocol.maxPayload + 1)))
        }
    }

    @Test func aFrameCutShortIsADisconnect() throws {
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[1]) }
        let reader = FrameChannel(descriptor: pair[1])
        _ = write(pair[0], [0x20, 0, 0, 0, 10, 1, 2] as [UInt8], 7)
        close(pair[0])
        #expect(throws: GuestProtocolError.disconnected) { _ = try reader.receive() }
    }

    @Test func aClosedChannelRefusesToSend() throws {
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[0]) }
        let channel = FrameChannel(descriptor: pair[1])
        channel.close()
        #expect(throws: GuestProtocolError.disconnected) { try channel.send(Frame(.stdout, [1])) }
    }

    @Test func shellStatus() {
        #expect(ExitReport(status: 3).shellStatus == 3)
        #expect(ExitReport(signal: SIGTERM).shellStatus == 128 + SIGTERM)
    }
}

@Suite struct GuestServerTests {
    @Test func helloReportsVersions() throws {
        let pair = try GuestPair()
        let response = try GuestClient.hello(pair.client)
        #expect(response.v == AgentVM.guestProtocolVersion)
        #expect(response.version == AgentVM.version)
        #expect(response.osBuild?.isEmpty == false)
    }

    @Test func anotherProtocolVersionIsRefused() throws {
        let pair = try GuestPair()
        let channel = FrameChannel(descriptor: pair.client)
        try channel.send(Frame(.request, Array(#"{"v":99,"op":"hello"}"#.utf8)))
        let response = try channel.receive(.response, as: GuestResponse.self)
        #expect(!response.ok)
        #expect(response.error?.contains("99") == true)
    }

    @Test func outputAndStatusAreSeparated() throws {
        let pair = try GuestPair()
        let result = try GuestClient.capture(pair.client, GuestRequest(op: .exec, argv: ["/bin/sh", "-c", "echo out; echo err >&2; exit 3"]))
        #expect(result.stdout == "out\n")
        #expect(result.stderr == "err\n")
        #expect(result.report == ExitReport(status: 3))
    }

    @Test func programsAreFoundOnThePath() throws {
        let pair = try GuestPair()
        let result = try GuestClient.capture(pair.client, GuestRequest(op: .exec, argv: ["echo", "found"]))
        #expect(result.stdout == "found\n")
    }

    @Test func environmentAndWorkingDirectory() throws {
        let pair = try GuestPair()
        let result = try GuestClient.capture(pair.client, GuestRequest(op: .exec, argv: ["/bin/sh", "-c", "echo $FOO $LANG; /bin/pwd -P"],
                                                                        env: ["FOO": "bar"], cwd: "/tmp"))
        #expect(result.stdout == "bar en_US.UTF-8\n/private/tmp\n")
    }

    @Test func stdinIsDeliveredAndEnds() throws {
        let pair = try GuestPair()
        let session = try ExecSession(descriptor: pair.client, request: GuestRequest(op: .exec, argv: ["/bin/cat"]))
        try session.sendStdin(Array("abc".utf8))
        try session.sendStdinEnd()
        var output: [UInt8] = []
        let report = try session.run(stdout: { output += $0 }, stderr: { _ in })
        #expect(String(decoding: output, as: UTF8.self) == "abc")
        #expect(report == ExitReport(status: 0))
    }

    @Test func largeOutputArrivesWhole() throws {
        let pair = try GuestPair()
        let session = try ExecSession(descriptor: pair.client, request: GuestRequest(op: .exec, argv: ["/usr/bin/head", "-c", "5000000", "/dev/zero"]))
        try session.sendStdinEnd()
        var count = 0
        _ = try session.run(stdout: { count += $0.count }, stderr: { _ in })
        #expect(count == 5_000_000)
    }

    @Test func refusedRequests() throws {
        for request in [GuestRequest(op: .exec, argv: ["no-such-program-anywhere"]),
                        GuestRequest(op: .exec, argv: ["/bin/echo"], cwd: "/no/such/folder"),
                        GuestRequest(op: .exec, argv: []),
                        GuestRequest(op: .exec, argv: ["/bin/echo"], user: "no-such-account-here")] {
            let pair = try GuestPair()
            #expect(throws: ExecRefusal.self) {
                _ = try ExecSession(descriptor: pair.client, request: request)
            }
        }
    }

    @Test func signalsReachTheProcessGroup() throws {
        let pair = try GuestPair()
        // The shell waits on a background child: only a group-wide signal ends both promptly.
        let session = try ExecSession(descriptor: pair.client, request: GuestRequest(op: .exec, argv: ["/bin/sh", "-c", "/bin/sleep 30 & wait"]))
        Thread.sleep(forTimeInterval: 0.3)
        try session.sendSignal(SIGSEGV) // not allowed: ignored
        try session.sendSignal(SIGTERM)
        let clock = ContinuousClock()
        let began = clock.now
        let report = try session.run(stdout: { _ in }, stderr: { _ in })
        #expect(report == ExitReport(signal: SIGTERM))
        #expect(clock.now - began < .seconds(5))
    }

    @Test func aDisconnectedHostEndsTheProgram() throws {
        let pair = try GuestPair()
        let session = try ExecSession(descriptor: pair.client, request: GuestRequest(op: .exec, argv: ["/bin/sleep", "30"]))
        let pid = session.pid
        #expect(kill(pid, 0) == 0)
        shutdown(pair.client, SHUT_RDWR)
        var gone = false
        for _ in 0..<50 {
            if kill(pid, 0) != 0 && errno == ESRCH {
                gone = true
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        #expect(gone)
        #expect(pair.serverDone.wait(timeout: .now() + 5) == .success)
    }

    @Test func aRelativeProgramIsFoundFromTheWorkingDirectory() throws {
        let pair = try GuestPair()
        let result = try GuestClient.capture(pair.client, GuestRequest(op: .exec, argv: ["./echo", "relative"], cwd: "/bin"))
        #expect(result.stdout == "relative\n")
    }

    @Test func stdinThatNobodyReadsDoesNotHangTheConnection() throws {
        let pair = try GuestPair()
        // The shell exits after a second; a background child keeps stdin open without reading it, so
        // writing more than a pipe holds would block forever.
        let session = try ExecSession(descriptor: pair.client, request: GuestRequest(op: .exec, argv: ["/bin/sh", "-c", "exec 3<&0; /bin/sleep 30 0<&3 >/dev/null 2>&1 & /bin/sleep 1; exit 0"]))
        try session.sendStdin([UInt8](repeating: 0x61, count: 512 * 1024))
        let report = try session.run(stdout: { _ in }, stderr: { _ in })
        #expect(report == ExitReport(status: 0))
        shutdown(pair.client, SHUT_RDWR)
        #expect(pair.serverDone.wait(timeout: .now() + 5) == .success)
    }

    @Test func aHostGoneWhileStdinIsBlockedEndsTheProgram() throws {
        let pair = try GuestPair()
        let session = try ExecSession(descriptor: pair.client, request: GuestRequest(op: .exec, argv: ["/bin/sleep", "30"]))
        let pid = session.pid
        try session.sendStdin([UInt8](repeating: 0x61, count: 512 * 1024))
        Thread.sleep(forTimeInterval: 0.3)
        shutdown(pair.client, SHUT_RDWR)
        var gone = false
        for _ in 0..<50 {
            if kill(pid, 0) != 0 && errno == ESRCH {
                gone = true
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        #expect(gone)
        #expect(pair.serverDone.wait(timeout: .now() + 5) == .success)
    }

    @Test func onlyStdioIsInherited() throws {
        let leaked = open("/dev/null", O_RDONLY)
        #expect(leaked > 2)
        defer { close(leaked) }
        let pair = try GuestPair()
        let result = try GuestClient.capture(pair.client, GuestRequest(op: .exec, argv: ["/bin/sh", "-c", "if [ -e /dev/fd/\(leaked) ]; then echo leaked; else echo clean; fi"]))
        #expect(result.stdout == "clean\n")
    }

    @Test func environmentBase() {
        let account = GuestServer.Account(name: "agent", uid: 501, gid: 20, home: "/Users/agent", shell: "/bin/zsh")
        let environment = GuestServer.environment(for: account, overrides: ["PATH": "/custom", "HTTPS_PROXY": "http://127.0.0.1:3128"])
        #expect(environment["HOME"] == "/Users/agent")
        #expect(environment["USER"] == "agent")
        #expect(environment["PATH"] == "/custom")
        #expect(environment["HTTPS_PROXY"] == "http://127.0.0.1:3128")
    }

    @Test func execAsArgumentsRoundTrip() throws {
        let arguments = GuestServer.execAsArguments(user: "agent", directory: "/Users/agent", executable: "/bin/echo", argv: ["echo", "--", "x"])
        #expect(arguments.prefix(2) == ["agent-vm-guest", "exec-as"])
        // agent-vm-guest's main hands over what follows "exec-as".
        let parsed = try #require(GuestServer.parseExecAs(Array(arguments.dropFirst(2))))
        #expect(parsed.user == "agent")
        #expect(parsed.directory == "/Users/agent")
        #expect(parsed.executable == "/bin/echo")
        #expect(parsed.argv == ["echo", "--", "x"])
        #expect(GuestServer.parseExecAs(["agent", "/tmp", "/bin/echo", "echo"]) == nil)
        #expect(GuestServer.parseExecAs(["agent", "/tmp", "/bin/echo", "--"]) == nil)
        #expect(parsed.terminal == false)
        let onTerminal = GuestServer.execAsArguments(user: "agent", directory: "/tmp", executable: "/bin/sh", argv: ["sh"], terminal: true)
        #expect(onTerminal == ["agent-vm-guest", "exec-as", "--terminal", "agent", "/tmp", "/bin/sh", "--", "sh"])
        #expect(GuestServer.parseExecAs(Array(onTerminal.dropFirst(2)))?.terminal == true)
    }

    @Test func refusalsReadOnce() throws {
        let pair = try GuestPair()
        do {
            _ = try ExecSession(descriptor: pair.client, request: GuestRequest(op: .exec, argv: ["no-such-program-anywhere"]))
            Issue.record("expected a refusal")
        } catch let refusal as ExecRefusal {
            #expect(refusal == ExecRefusal(message: "no-such-program-anywhere: command not found", status: 127))
        }
        let other = try GuestPair()
        do {
            _ = try ExecSession(descriptor: other.client, request: GuestRequest(op: .exec, argv: ["/bin/echo"], cwd: "/no/such/folder"))
            Issue.record("expected a refusal")
        } catch let refusal as ExecRefusal {
            #expect(refusal.status == 126)
        }
    }

    @Test func aNewerHostGetsAVersionAnswer() throws {
        let pair = try GuestPair()
        let channel = FrameChannel(descriptor: pair.client)
        try channel.send(Frame(.request, Array(#"{"v":2,"op":"something-new"}"#.utf8)))
        let response = try channel.receive(.response, as: GuestResponse.self)
        #expect(response.error?.contains("protocol version 2") == true)
    }

    @Test func exitStatusDecoding() {
        #expect(GuestServer.report(3 << 8) == ExitReport(status: 3))
        #expect(GuestServer.report(SIGKILL) == ExitReport(signal: SIGKILL))
    }
}
