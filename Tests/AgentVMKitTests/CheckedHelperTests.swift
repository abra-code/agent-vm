// Tests/AgentVMKitTests/CheckedHelperTests.swift
//
// The checked start of a program, which a Linux guest daemon uses for every exec: the helper
// finds the working folder and the program after it has become the account, and tells the
// daemon on a status pipe why a program could not be started. The helper's code is the same
// on both systems, so it runs here on the Mac, with the macOS helper this build produced; a
// shell script stands in for a helper that misbehaves.

import Darwin
import Foundation
import Testing
@testable import AgentVMGuestKit
@testable import AgentVMKit

@Suite struct CheckedHelperTests {
    func pair(deadline: Double = 10) throws -> GuestPair {
        return try GuestPair(helperPath: try GuestPair.builtHelper(), checkedHelper: true, statusDeadline: deadline)
    }

    /// A pair whose helper is the shell script `body`, in a scratch folder the caller deletes.
    func pair(standIn body: String, deadline: Double = 10) throws -> (pair: GuestPair, folder: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agent-vm-helper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("helper")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: script)
        #expect(chmod(script.path, 0o755) == 0)
        return (try GuestPair(helperPath: script.path, checkedHelper: true, statusDeadline: deadline), folder)
    }

    /// Runs `request` through a checked pair of its own, which lives until the program ended.
    func capture(_ request: GuestRequest, input: Data? = nil) throws -> (report: ExitReport, stdout: String, stderr: String) {
        let pair = try pair()
        return try withExtendedLifetime(pair) {
            try GuestClient.capture(pair.client, request, input: input)
        }
    }

    func refusal(_ pair: GuestPair, _ request: GuestRequest) -> ExecRefusal? {
        do {
            _ = try ExecSession(descriptor: pair.client, request: request)
            Issue.record("expected a refusal")
            return nil
        } catch let refusal as ExecRefusal {
            return refusal
        } catch {
            Issue.record("expected a refusal, got \(error)")
            return nil
        }
    }

    // MARK: - With the real helper

    @Test func aCheckedProgramRuns() throws {
        let result = try capture(GuestRequest(op: .exec, argv: ["/bin/sh", "-c", "echo out; echo err >&2; exit 3"]))
        #expect(result.stdout == "out\n")
        #expect(result.stderr == "err\n")
        #expect(result.report == ExitReport(status: 3))
    }

    @Test func aMissingProgramIsRefusedWith127() throws {
        #expect(refusal(try pair(), GuestRequest(op: .exec, argv: ["no-such-program-anywhere"]))
            == ExecRefusal(message: "no-such-program-anywhere: command not found", status: 127))
        #expect(refusal(try pair(), GuestRequest(op: .exec, argv: ["/no/such/program"]))
            == ExecRefusal(message: "/no/such/program: command not found", status: 127))
    }

    @Test func aMissingFolderIsRefusedWith126() throws {
        #expect(refusal(try pair(), GuestRequest(op: .exec, argv: ["/bin/echo"], cwd: "/no/such/folder"))
            == ExecRefusal(message: "working directory /no/such/folder does not exist", status: 126))
        // A file is not a folder to work in.
        #expect(refusal(try pair(), GuestRequest(op: .exec, argv: ["/bin/echo"], cwd: "/etc/hosts"))
            == ExecRefusal(message: "working directory /etc/hosts does not exist", status: 126))
    }

    @Test func aFileThatCannotBeRunIsRefusedWith126() throws {
        // Executable by its mode, and not a program: found, then refused by the system.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agent-vm-checked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("not-a-program")
        try Data([0, 1, 2, 3]).write(to: file)
        #expect(chmod(file.path, 0o755) == 0)
        let refused = try #require(refusal(try pair(), GuestRequest(op: .exec, argv: [file.path])))
        #expect(refused.status == 126)
        #expect(refused.message.hasPrefix("cannot run \(file.path): "))
    }

    @Test func aRelativeProgramIsFoundInTheWorkingFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agent-vm-checked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("here.sh")
        try Data("#!/bin/sh\necho from-here \"$0\"\n".utf8).write(to: script)
        #expect(chmod(script.path, 0o755) == 0)
        let result = try capture(GuestRequest(op: .exec, argv: ["./here.sh"], cwd: folder.path))
        // The program sees the name it was asked by.
        #expect(result.stdout == "from-here ./here.sh\n")
        #expect(result.report == ExitReport(status: 0))
    }

    @Test func aBareNameIsFoundAlongThePath() throws {
        let result = try capture(GuestRequest(op: .exec, argv: ["echo", "found"]))
        #expect(result.stdout == "found\n")
        // Along the request's PATH, when it gives one: nothing there is called echo.
        #expect(refusal(try pair(), GuestRequest(op: .exec, argv: ["echo"], env: ["PATH": "/var/empty"]))
            == ExecRefusal(message: "echo: command not found", status: 127))
    }

    @Test func environmentAndWorkingDirectoryArrive() throws {
        let result = try capture(GuestRequest(op: .exec, argv: ["/bin/sh", "-c", "echo $FOO; /bin/pwd -P"],
                                                                              env: ["FOO": "bar"], cwd: "/tmp"))
        #expect(result.stdout == "bar\n/private/tmp\n")
    }

    @Test func theProgramDoesNotSeeTheStatusPipe() throws {
        let leaked = open("/dev/null", O_RDONLY)
        #expect(leaked > 2)
        defer { close(leaked) }
        // What is open in the program: its three standard descriptors and nothing above them
        // (the fourth name, if any, is the listing's own).
        let script = "for n in 3 4 5 6 7 8 9 \(leaked); do if [ -e /dev/fd/$n ]; then echo open $n; fi; done; echo done"
        let result = try capture(GuestRequest(op: .exec, argv: ["/bin/sh", "-c", script]))
        #expect(result.stdout == "done\n")
    }

    @Test func stdinIsDeliveredAndEnds() throws {
        let result = try capture(GuestRequest(op: .exec, argv: ["/bin/cat"]), input: Data("abc".utf8))
        #expect(result.stdout == "abc")
        #expect(result.report == ExitReport(status: 0))
    }

    @Test func aTerminalWorksChecked() throws {
        let script = "tty; stty size; test -t 0 && test -t 1 && test -t 2 && echo all-three; ps -o stat= -p $$; [ -e /dev/fd/3 ] && echo three-is-open; exit 4"
        let pair = try pair()
        defer { withExtendedLifetime(pair) {} }
        let session = try ExecSession(descriptor: pair.client,
                                      request: GuestRequest(op: .exec, argv: ["/bin/sh", "-c", script], terminal: TerminalSize(rows: 24, columns: 80)))
        var output = Data()
        let report = try session.run(stdout: { output.append(contentsOf: $0) }, stderr: { _ in })
        let text = String(decoding: output, as: UTF8.self)
        #expect(report == ExitReport(status: 4))
        #expect(text.contains("/dev/ttys"))
        #expect(text.contains("24 80"))
        #expect(text.contains("all-three"))
        #expect(text.range(of: #"(?m)^[A-Z]\S*s\S*\+"#, options: .regularExpression) != nil, "\(text)")
        #expect(!text.contains("three-is-open"))
    }

    @Test func aMissingProgramOnATerminalIsRefused() throws {
        #expect(refusal(try pair(), GuestRequest(op: .exec, argv: ["no-such-program-anywhere"], terminal: TerminalSize(rows: 24, columns: 80)))
            == ExecRefusal(message: "no-such-program-anywhere: command not found", status: 127))
    }

    // MARK: - With a stand-in helper

    @Test func aHelperThatSaysNothingIsStoppedAtTheDeadline() throws {
        let (pair, folder) = try pair(standIn: "echo $$ > \"$(/usr/bin/dirname \"$0\")/pid\"; exec /bin/sleep 30", deadline: 0.5)
        defer { try? FileManager.default.removeItem(at: folder) }
        let started = Date()
        let refused = try #require(refusal(pair, GuestRequest(op: .exec, argv: ["/bin/echo"])))
        #expect(refused == ExecRefusal(message: "the program did not start within 0.5 s", status: 126))
        #expect(Date().timeIntervalSince(started) < 5)
        // The stand-in was ended and reaped, not left to its 30 seconds.
        let text = try String(contentsOf: folder.appendingPathComponent("pid"), encoding: .utf8)
        let pid = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) != 0)
    }

    @Test func aLongStatusLineIsCut() throws {
        // 4 KB of one letter, then the helper ends.
        let (pair, folder) = try pair(standIn: "/usr/bin/printf '126 ' >&3; /usr/bin/head -c 4096 /dev/zero | /usr/bin/tr '\\0' x >&3; exit 126")
        defer { try? FileManager.default.removeItem(at: folder) }
        let refused = try #require(refusal(pair, GuestRequest(op: .exec, argv: ["/bin/echo"])))
        #expect(refused.status == 126)
        // The host shows 500 characters of any refusal; what the daemon kept is below.
        #expect(refused.message.hasPrefix(String(repeating: "x", count: 400)))
        let kept = GuestServer.refusal(said: Array("126 ".utf8) + [UInt8](repeating: 0x78, count: 4096))
        #expect(kept.message.utf8.count == GuestServer.statusLimit - 4)
        #expect(kept.message.allSatisfy { $0 == "x" })
    }

    @Test func aHelperThatNeverStopsWritingEndsAtTheDeadline() throws {
        let (pair, folder) = try pair(standIn: "exec /bin/cat /dev/zero >&3", deadline: 0.5)
        defer { try? FileManager.default.removeItem(at: folder) }
        let refused = try #require(refusal(pair, GuestRequest(op: .exec, argv: ["/bin/echo"])))
        #expect(refused == ExecRefusal(message: "the program did not start within 0.5 s", status: 126))
    }

    @Test func anOddStatusBecomes126() {
        func refusal(_ line: String) -> ExecRefusal {
            let refusal = GuestServer.refusal(said: Array(line.utf8))
            return ExecRefusal(message: refusal.message, status: refusal.status)
        }
        #expect(refusal("127 x: command not found\n") == ExecRefusal(message: "x: command not found", status: 127))
        #expect(refusal("126 cannot run x: Exec format error\n") == ExecRefusal(message: "cannot run x: Exec format error", status: 126))
        #expect(refusal("0 hello\n") == ExecRefusal(message: "hello", status: 126))
        #expect(refusal("999 x\n") == ExecRefusal(message: "x", status: 126))
        #expect(refusal("abc\n") == ExecRefusal(message: "abc", status: 126))
        #expect(refusal("127\n") == ExecRefusal(message: "the program could not be started", status: 127))
        #expect(refusal("\n") == ExecRefusal(message: "the program could not be started", status: 126))
        // Only the first line counts.
        #expect(refusal("126 first\n127 second\n") == ExecRefusal(message: "first", status: 126))
    }

    // MARK: - The helper's arguments, and what a Linux daemon gives a program

    @Test func execAsArgumentsRoundTripChecked() throws {
        let checked = GuestServer.execAsArguments(user: "agent", directory: "/home/agent", executable: "git", argv: ["git", "status"], checked: true)
        #expect(checked == ["agent-vm-guest", "exec-as", "--checked", "agent", "/home/agent", "git", "--", "git", "status"])
        let parsed = try #require(GuestServer.parseExecAs(Array(checked.dropFirst(2))))
        #expect(parsed.checked)
        #expect(!parsed.terminal)
        #expect(parsed.executable == "git")
        #expect(parsed.argv == ["git", "status"])
        let both = GuestServer.execAsArguments(user: "agent", directory: "/tmp", executable: "sh", argv: ["sh"], terminal: true, checked: true)
        #expect(both == ["agent-vm-guest", "exec-as", "--checked", "--terminal", "agent", "/tmp", "sh", "--", "sh"])
        let parsedBoth = try #require(GuestServer.parseExecAs(Array(both.dropFirst(2))))
        #expect(parsedBoth.checked && parsedBoth.terminal)
        // The order is fixed: --checked after --terminal is not the form.
        #expect(GuestServer.parseExecAs(["--terminal", "--checked", "agent", "/tmp", "sh", "--", "sh"]) == nil)
        #expect(GuestServer.parseExecAs(Array(GuestServer.execAsArguments(user: "a", directory: "/", executable: "x", argv: ["x"]).dropFirst(2)))?.checked == false)
    }

    @Test func theLinuxPathStartsWithTheHomeBin() {
        #expect(GuestServer.defaultPath(for: .linux, home: "/home/agent")
            == "/home/agent/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin")
    }

    @Test func theMacPathIsUnchanged() {
        #expect(GuestServer.defaultPath(for: .macOS, home: "/Users/agent") == "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test func linuxSpeaksCUTF8() {
        let account = GuestServer.Account(name: "agent", uid: 1000, gid: 1000, home: "/home/agent", shell: "/bin/bash")
        let linux = GuestServer.environment(for: account, overrides: ["FOO": "bar"], kind: .linux)
        #expect(linux["LANG"] == "C.UTF-8")
        #expect(linux["PATH"]?.hasPrefix("/home/agent/.local/bin:") == true)
        #expect(linux["FOO"] == "bar")
        #expect(GuestServer.environment(for: account, overrides: nil, kind: .macOS)["LANG"] == "en_US.UTF-8")
        // A request's own value wins on both.
        #expect(GuestServer.environment(for: account, overrides: ["LANG": "de_DE.UTF-8"], kind: .linux)["LANG"] == "de_DE.UTF-8")
    }
}

@Suite struct GuestFeatureTests {
    @Test func linuxAnnouncesThree() {
        #expect(GuestFeature.all(for: .linux) == [GuestFeature.terminal, GuestFeature.timeSync, GuestFeature.terminalPixels])
    }

    @Test func macOSAnnouncesSix() {
        #expect(GuestFeature.all(for: .macOS) == [GuestFeature.terminal, GuestFeature.promptNotices, GuestFeature.wallpaper, GuestFeature.timeSync,
                                                  GuestFeature.userSession, GuestFeature.terminalPixels])
    }

    @Test func allIsTheCurrentSystems() {
        #expect(GuestKind.current == .macOS)
        #expect(GuestFeature.all == GuestFeature.all(for: .macOS))
        #expect(GuestDaemonInfo.current.features == GuestFeature.all(for: .macOS))
    }

    @Test func aHelloWithoutASystemIsAMac() {
        #expect(GuestKind(hello: nil) == .macOS)
        #expect(GuestKind(hello: "macos") == .macOS)
        #expect(GuestKind(hello: "linux") == .linux)
        #expect(GuestKind(hello: "plan9") == nil)
    }

    @Test func theVersionOfALinuxSystemIsRead() {
        #expect(Platform.versionID(inOSRelease: "PRETTY_NAME=\"Debian GNU/Linux 13 (trixie)\"\nNAME=\"Debian GNU/Linux\"\nVERSION_ID=\"13\"\nID=debian\n") == "13")
        #expect(Platform.versionID(inOSRelease: "ID=ubuntu\nVERSION_ID=\"26.04\"\n") == "26.04")
        #expect(Platform.versionID(inOSRelease: "ID=arch\n") == nil)
        #expect(Platform.versionID(inOSRelease: "VERSION_ID=\"\"\n") == nil)
        // A value the host would refuse the hello over is left out.
        #expect(Platform.versionID(inOSRelease: "VERSION_ID=\"13 (trixie)\"\n") == nil)
        #expect(Platform.versionID(inOSRelease: "VERSION_ID=\(String(repeating: "1", count: 33))\n") == nil)
    }
}
