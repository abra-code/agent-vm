// Sources/agent-vm/ExecCommand.swift
//
// `agent-vm exec --box <name> -- <program> [arguments...]`: runs a program in a running box
// with stdin, stdout and stderr streamed, signals forwarded, and its exit status as ours
// (128 + signal number when a signal ended it). Wraps any stdio program, including ACP agents
// and MCP servers launched by another application.

import AgentVMKit
import ArgumentParser
import Darwin
import Foundation

struct ExecCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "exec",
        abstract: "Run a program in a running box.",
        discussion: """
            stdin, stdout and stderr are streamed; SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGUSR1 \
            and SIGUSR2 are forwarded to the program's process group; the exit status is the \
            program's (128 + the signal number when a signal ended it; 127 when the program is \
            not found, 126 when it cannot be started, 125 when agent-vm itself fails, for \
            example because the box is not running). If agent-vm exec is \
            killed, the program gets SIGHUP, then SIGKILL 3 seconds later. The program runs \
            as the box user in their home folder unless --user or --cwd say otherwise. With \
            --project, the folder appears in the box at the same path and the program starts \
            there; the box keeps it until another project replaces it or the box stops.
            """
    )

    @Option(name: .long, help: "The running box.")
    var box: String

    @Option(name: .long, help: "Account to run as in the guest (default: the box user).")
    var user: String?

    @Option(name: .long, help: "Working folder in the guest (default: the project, else the account's home).")
    var cwd: String?

    @Option(name: .long, help: "Share this project folder into the box at the same path (one project per box at a time).")
    var project: String?

    @Flag(name: .customLong("read-only"), help: "Share the project read only.")
    var readOnly = false

    @Option(name: .long, parsing: .singleValue, help: "Environment variable NAME=VALUE for the program (repeatable).")
    var env: [String] = []

    @Argument(parsing: .captureForPassthrough, help: "The program and its arguments, after --.")
    var command: [String] = []

    @OptionGroup var options: StoreOptions

    func validate() throws {
        guard !command.isEmpty else {
            throw ValidationError("give the program to run after --, for example: agent-vm exec --box dev -- uname -a")
        }
        for entry in env {
            guard let equals = entry.firstIndex(of: "="), equals != entry.startIndex else {
                throw ValidationError("--env needs NAME=VALUE, got \(entry)")
            }
        }
        if readOnly && project == nil {
            throw ValidationError("--read-only applies to --project")
        }
    }

    /// agent-vm's own failures (box not running, connection lost), as docker exec uses it:
    /// distinct from any status the program itself returns.
    static let ownFailureStatus: Int32 = 125

    func run() throws {
        do {
            try runInBox()
        } catch {
            FileHandle.standardError.write(Data("agent-vm: \(error)\n".utf8))
            Darwin.exit(Self.ownFailureStatus)
        }
    }

    private func runInBox() throws {
        signal(SIGPIPE, SIG_IGN)
        let box = try options.boxStore.box(named: self.box)
        guard box.isRunning else {
            throw AgentVMError.boxNotRunning(box.name)
        }
        // A proxied box reaches out only through its proxy: tell the tools that ignore the
        // system proxy (curl, git, SwiftPM, Node). --env overrides.
        var environment: [String: String] = box.record.effectiveNetwork.usesProxy ? GuestNetworkSetup.proxyEnvironment : [:]
        for entry in env {
            let equals = entry.firstIndex(of: "=")!
            environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        let argv = command.first == "--" ? Array(command.dropFirst()) : command
        guard !argv.isEmpty else {
            throw ValidationError("give the program to run after --")
        }

        // The project appears in the box at the same absolute path, and the program starts
        // there. Sharing and opening the connection are one request: the supervisor keeps the
        // share unchanged until this process ends.
        var directory = cwd
        var projectPath: String?
        if let project {
            projectPath = try ProjectShare.validated(project, storeRoot: options.boxStore.root)
            directory = directory ?? projectPath
        }

        // The control connection stays open for the whole run: the supervisor keeps the vsock
        // connection alive until it closes (and closes it if this process dies).
        let (control, guest) = try ControlClient.openGuest(path: box.controlSocketPath, project: projectPath, readOnly: readOnly)
        let session: ExecSession
        do {
            session = try ExecSession(descriptor: guest, request: GuestRequest(
                op: .exec, argv: argv, env: environment.isEmpty ? nil : environment, cwd: directory, user: user))
        } catch let refusal as ExecRefusal {
            // Like env(1) and shells: 127 when the program is not found, 126 when it cannot run.
            FileHandle.standardError.write(Data("agent-vm: \(refusal.message)\n".utf8))
            Darwin.exit(refusal.status)
        }

        var sources: [DispatchSourceSignal] = []
        for signalNumber in [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGUSR1, SIGUSR2] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler {
                try? session.sendSignal(signalNumber)
            }
            source.resume()
            sources.append(source)
        }
        session.forwardStdin(from: STDIN_FILENO)

        let report: ExitReport
        do {
            report = try session.run(stdout: { Self.writeAll(STDOUT_FILENO, $0) }, stderr: { Self.writeAll(STDERR_FILENO, $0) })
        } catch {
            throw AgentVMError.guestUnreachable("the connection to box \(box.name) ended: \(error)")
        }
        withExtendedLifetime(sources) {}
        // Exit at once: the stdin thread may still be blocked reading a terminal. Closing the
        // control connection (with the process) returns the guest connection.
        _ = control
        Darwin.exit(report.shellStatus)
    }

    /// Writes everything. A closed output (EPIPE, as in `exec ... | head -1`) ends us the way
    /// SIGPIPE would end the program run locally; closing the connection on exit hangs the
    /// program up. Other errors drop the rest.
    static func writeAll(_ descriptor: Int32, _ bytes: [UInt8]) {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress! + offset, bytes.count - offset) }
            if written < 0 {
                let code = errno
                if code == EINTR {
                    continue
                }
                if code == EPIPE {
                    Darwin.exit(128 + SIGPIPE)
                }
                return
            }
            offset += written
        }
    }
}
