// Tests/AgentVMKitTests/TerminalExecTests.swift
//
// exec on a terminal, against the real GuestServer over a socket pair (see GuestPair): the
// program's controlling terminal, its size and resizing, keys such as Control-C and Control-D
// going through the terminal, and background processes that keep the terminal open.

import Darwin
import Foundation
import Testing
@testable import AgentVMKit

@Suite struct TerminalExecTests {
    let size = TerminalSize(rows: 24, columns: 80)

    /// Runs `session` to its end, collecting stdout; stderr must stay empty on a terminal.
    func finish(_ session: ExecSession) throws -> (report: ExitReport, output: String) {
        var output = Data()
        var errors = Data()
        let report = try session.run(stdout: { output.append(contentsOf: $0) }, stderr: { errors.append(contentsOf: $0) })
        #expect(errors.isEmpty)
        return (report, String(decoding: output, as: UTF8.self))
    }

    /// As `finish`, calling `act` once the program has printed "ready": a key or signal sent
    /// then cannot come before the program runs, as one sent after a fixed wait could on a busy
    /// Mac (the test then hung or failed).
    func finish(_ session: ExecSession, whenReady act: () throws -> Void) throws -> (report: ExitReport, output: String) {
        var output = Data()
        var acted = false
        let report = try session.run(stdout: { bytes in
            output.append(contentsOf: bytes)
            if !acted, String(decoding: output, as: UTF8.self).contains("ready") {
                acted = true
                try act()
            }
        }, stderr: { _ in })
        return (report, String(decoding: output, as: UTF8.self))
    }

    @Test func helloAnnouncesTheTerminal() throws {
        let pair = try GuestPair(helperPath: try GuestPair.builtHelper())
        #expect(try GuestClient.hello(pair.client).features?.contains(GuestFeature.terminal) == true)
    }

    @Test func theTerminalIsTheControllingTerminal() throws {
        let pair = try GuestPair(helperPath: try GuestPair.builtHelper())
        let script = "tty; stty size; test -t 0 && test -t 1 && test -t 2 && echo all-three; ps -o stat= -p $$; echo to-stderr >&2; exit 4"
        let session = try ExecSession(descriptor: pair.client, request: GuestRequest(op: .exec, argv: ["/bin/sh", "-c", script], terminal: size))
        let (report, output) = try finish(session)
        #expect(report == ExitReport(status: 4))
        #expect(output.contains("/dev/ttys"))
        #expect(output.contains("24 80"))
        #expect(output.contains("all-three"))
        // A session leader ("s") in the terminal's foreground group ("+"). Other flags may come
        // between: "SNs+" when the tests run at a lower priority (zsh lowers background jobs).
        #expect(output.range(of: #"(?m)^[A-Z]\S*s\S*\+"#, options: .regularExpression) != nil, "\(output)")
        // Both streams arrive through the terminal, with its line endings.
        #expect(output.contains("to-stderr\r\n"))
    }

    @Test func aResizeReachesTheProgram() throws {
        let pair = try GuestPair(helperPath: try GuestPair.builtHelper())
        let script = "trap 'stty size; exit 0' WINCH; echo ready; while :; do /bin/sleep 0.1; done"
        let session = try ExecSession(descriptor: pair.client, request: GuestRequest(op: .exec, argv: ["/bin/sh", "-c", script], terminal: size))
        // Resized once the trap is set: a resize before it was lost, and the loop never ended.
        let (report, output) = try finish(session) { try session.sendResize(TerminalSize(rows: 40, columns: 120)) }
        #expect(report == ExitReport(status: 0))
        #expect(output.contains("40 120"))
    }

    @Test func controlCInterruptsTheForegroundProgram() throws {
        let pair = try GuestPair(helperPath: try GuestPair.builtHelper())
        // Control-C once the program runs ("ready", then sleep in its place): a key typed before
        // it started was lost, and it slept 30 s.
        let session = try ExecSession(descriptor: pair.client, request: GuestRequest(op: .exec, argv: ["/bin/sh", "-c", "echo ready; exec /bin/sleep 30"], terminal: size))
        let (report, _) = try finish(session) { try session.sendStdin([0x03]) }
        #expect(report == ExitReport(signal: SIGINT))
    }

    @Test func inputIsEchoedAndControlDEndsIt() throws {
        let pair = try GuestPair(helperPath: try GuestPair.builtHelper())
        // Typed once the program runs ("ready", then cat in its place): keys typed before it
        // started were lost, and cat, never seeing Control-D, hung the run.
        let session = try ExecSession(descriptor: pair.client, request: GuestRequest(op: .exec, argv: ["/bin/sh", "-c", "echo ready; exec /bin/cat"], terminal: size))
        let (report, output) = try finish(session) {
            try session.sendStdin(Array("hello\r".utf8))
            try session.sendStdin([0x04])
        }
        #expect(report == ExitReport(status: 0))
        // Once echoed by the terminal, once written by cat.
        #expect(output.components(separatedBy: "hello").count == 3)
    }

    @Test func signalsFromTheHostReachTheProgram() throws {
        let pair = try GuestPair(helperPath: try GuestPair.builtHelper())
        // Signaled once the program runs, not after a fixed wait (failed once on a busy Mac).
        let session = try ExecSession(descriptor: pair.client, request: GuestRequest(op: .exec, argv: ["/bin/sh", "-c", "echo ready; exec /bin/sleep 30"], terminal: size))
        let (report, output) = try finish(session) { try session.sendSignal(SIGTERM) }
        #expect(report == ExitReport(signal: SIGTERM), "\(report), output \(output)")
    }

    /// With job control the foreground job has its own process group: a signal from the host
    /// must reach it, as Control-C would, not the shell.
    @Test func hostSignalsReachTheForegroundJob() throws {
        let pair = try GuestPair(helperPath: try GuestPair.builtHelper())
        // The job says "ready" itself, then becomes sleep: sent earlier, the signal reached the
        // shell while it was still the foreground job, and it ended.
        let script = "set -m; /bin/sh -c 'echo ready; exec /bin/sleep 30'; echo shell-carries-on"
        let session = try ExecSession(descriptor: pair.client, request: GuestRequest(op: .exec, argv: ["/bin/sh", "-c", script], terminal: size))
        let (report, output) = try finish(session) { try session.sendSignal(SIGINT) }
        #expect(output.contains("shell-carries-on"))
        #expect(report == ExitReport(status: 0))
    }

    /// When the host goes away, a foreground job that ignores SIGHUP (in its own group, under job
    /// control) is killed with the program's group, not left running.
    @Test func aHostGoneEndsTheForegroundJobToo() throws {
        let pair = try GuestPair(helperPath: try GuestPair.builtHelper())
        let script = "set -m; /bin/sh -c 'trap \"\" HUP; echo inner $$; exec /bin/sleep 30'; echo after"
        let session = try ExecSession(descriptor: pair.client, request: GuestRequest(op: .exec, argv: ["/bin/sh", "-c", script], terminal: size))
        var output = ""
        // Generous: under a full parallel run, starting the helper and two shells took over 5 s.
        let deadline = ContinuousClock.now + .seconds(15)
        let channel = FrameChannel(descriptor: pair.client)
        // By scalars: "\r\n" is one Character, which contains("\n") would not find.
        while !output.unicodeScalars.contains("\n"), ContinuousClock.now < deadline, let frame = try channel.receive() {
            output += String(decoding: frame.payload, as: UTF8.self)
        }
        _ = session
        let words = output.split(whereSeparator: \.isWhitespace)
        let inner = try #require(words.firstIndex(of: "inner").flatMap { words.index(after: $0) < words.endIndex ? Int32(words[$0 + 1]) : nil }, "output: \(output.debugDescription)")
        #expect(kill(inner, 0) == 0)
        shutdown(pair.client, SHUT_RDWR)
        var gone = false
        for _ in 0..<60 {
            if kill(inner, 0) != 0 && errno == ESRCH {
                gone = true
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        #expect(gone)
    }

    @Test func aBackgroundProcessHoldingTheTerminalDoesNotHangTheExec() throws {
        let pair = try GuestPair(helperPath: try GuestPair.builtHelper())
        let session = try ExecSession(descriptor: pair.client, request: GuestRequest(op: .exec, argv: ["/bin/sh", "-c", "/bin/sleep 30 & echo started"], terminal: size))
        let clock = ContinuousClock()
        let began = clock.now
        let (report, output) = try finish(session)
        #expect(report == ExitReport(status: 0))
        #expect(output.contains("started"))
        #expect(clock.now - began < .seconds(6))
    }

    @Test func resizeFramesWithoutATerminalAreIgnored() throws {
        let pair = try GuestPair(helperPath: try GuestPair.builtHelper())
        let session = try ExecSession(descriptor: pair.client, request: GuestRequest(op: .exec, argv: ["/bin/sh", "-c", "/bin/sleep 0.5; echo fine"]))
        try session.sendResize(size)
        try session.sendStdinEnd()
        var output = Data()
        let report = try session.run(stdout: { output.append(contentsOf: $0) }, stderr: { _ in })
        #expect(report == ExitReport(status: 0))
        #expect(String(decoding: output, as: UTF8.self) == "fine\n")
    }

    @Test func aTerminalNeedsTheHelper() throws {
        let pair = try GuestPair()
        #expect(throws: ExecRefusal.self) {
            try ExecSession(descriptor: pair.client, request: GuestRequest(op: .exec, argv: ["/bin/echo"], terminal: size))
        }
    }

    @Test func terminalSizesRoundTrip() {
        let size = TerminalSize(rows: 300, columns: 65535)
        #expect(TerminalSize(bytes: size.bytes) == size)
        #expect(size.bytes.count == 4)
        #expect(TerminalSize(bytes: [1, 2, 3]) == nil)
        // With pixels: 8 bytes, which a guest with terminal-pixels reads; older ones take 4 only.
        let pixels = TerminalSize(rows: 50, columns: 160, xpixels: 1920, ypixels: 1200)
        #expect(pixels.bytes.count == 8)
        #expect(TerminalSize(bytes: pixels.bytes) == pixels)
        #expect(pixels.winsize.ws_xpixel == 1920 && pixels.winsize.ws_ypixel == 1200 && pixels.winsize.ws_col == 160)
        #expect(size.winsize.ws_xpixel == 0)
        // A half-known size is sent as cells only.
        #expect(TerminalSize(rows: 1, columns: 1, xpixels: 10).bytes.count == 4)
        // In the exec request the pixels are optional keys, absent when unknown.
        let json = String(decoding: try! JSONEncoder().encode(size), as: UTF8.self)
        #expect(!json.contains("pixels"))
    }
}
