// Sources/agent-vm/ExecRunner.swift
//
// Runs one program in a running box, for `agent-vm exec` and `agent-vm box shell`: streams
// stdio (or, with a terminal, puts the local terminal in raw mode and relays it, window size
// included), forwards signals, records the run in the box's exec log, and exits with the
// program's status. A program that waits on a permission prompt nobody sees is reported at
// once (stderr, and a notice line in the exec log) and, with `--prompts stop`, stopped.

import AgentVMKit
import Darwin
import Foundation

/// What exec does when a program waits on a permission prompt nobody sees.
enum PromptPolicy: String, CaseIterable {
    /// Let it wait: someone answers the prompt in `box view --interactive`.
    case wait
    /// Stop the waiting program (only that one), so whoever runs exec is not left hanging.
    case stop

    /// Without --prompts: stop when stdin is not a terminal (no person is there to go and
    /// answer), wait when it is.
    static var `default`: PromptPolicy {
        return isatty(STDIN_FILENO) == 1 ? .wait : .stop
    }
}

struct ExecRunner {
    var store: BoxStore
    var box: String
    var user: String?
    var cwd: String?
    var project: String?
    var readOnly: Bool
    /// From --env-file and --env; the proxy settings and TERM are added here.
    var added: [String: String]
    var argv: [String]
    var terminal: Bool
    var prompts: PromptPolicy = .wait

    /// agent-vm's own failures (box not running, connection lost), as docker exec uses it:
    /// distinct from any status the program itself returns.
    static let ownFailureStatus: Int32 = 125

    func run() -> Never {
        do {
            try runInBox()
        } catch {
            // The terminal first, so the message is not printed in raw mode.
            ExecExit.shared.restoreTerminal()
            FileHandle.standardError.write(Data("agent-vm: \(error)\n".utf8))
            ExecExit.shared.exit(Self.ownFailureStatus)
        }
    }

    private func runInBox() throws -> Never {
        signal(SIGPIPE, SIG_IGN)
        let box = try store.box(named: self.box)
        guard box.isRunning else {
            throw AgentVMError.boxNotRunning(box.name)
        }
        // A proxied box reaches out only through its proxy: tell the tools that ignore the
        // system proxy (curl, git, SwiftPM, Node). --env-file and --env override.
        var environment = box.record.effectiveNetwork.usesProxy ? GuestNetworkSetup.proxyEnvironment : [:]
        environment.merge(added) { _, new in new }
        if terminal && environment["TERM"] == nil {
            environment["TERM"] = ExecEnvironment.terminalType(host: ProcessInfo.processInfo.environment["TERM"])
        }

        // The project appears in the box at the same absolute path, and the program starts
        // there. Sharing and opening the connection are one request: the supervisor keeps the
        // share unchanged until this process ends.
        var directory = cwd
        var projectPath: String?
        if let project {
            projectPath = try ProjectShare.validated(project, storeRoot: store.root)
            directory = directory ?? projectPath
        }

        // The control connection stays open for the whole run: the supervisor keeps the vsock
        // connection alive until it closes (and closes it if this process dies).
        let (control, guest, status) = try ControlClient.openGuest(path: box.controlSocketPath, project: projectPath, readOnly: readOnly)
        var size: TerminalSize?
        if terminal {
            guard status.guestFeatures?.contains(GuestFeature.terminal) == true else {
                close(guest)
                close(control)
                // No list at all: a supervisor from an agent-vm before features, still running.
                guard status.guestFeatures != nil else {
                    throw AgentVMError.guestRefused("box \(box.name) was started by an older agent-vm; restart it (`agent-vm box stop \(box.name)`, then `box start`) to use a terminal")
                }
                throw AgentVMError.guestRefused("box \(box.name) was made from an image whose agent-vm-guest has no terminal support; update the image with `agent-vm image update-guest \(box.record.image)` and create the box again")
            }
            size = Self.localTerminalSize()
        }

        let log = ExecLog(url: box.execLogURL)
        let id = ExecLog.newID()
        log.append(ExecLog.Entry(id: id, event: .start, time: Date(), argv: argv, user: user ?? box.record.userName, cwd: directory,
                                 project: projectPath, readOnly: projectPath == nil ? nil : readOnly, terminal: terminal ? true : nil,
                                 hostPid: getpid()))
        ExecExit.shared.record(log: log, id: id)

        let session: ExecSession
        do {
            session = try ExecSession(descriptor: guest, request: GuestRequest(
                op: .exec, argv: argv, env: environment.isEmpty ? nil : environment, cwd: directory, user: user, terminal: size,
                notices: status.guestFeatures?.contains(GuestFeature.promptNotices) == true ? true : nil))
        } catch let refusal as ExecRefusal {
            // Like env(1) and shells: 127 when the program is not found, 126 when it cannot run.
            FileHandle.standardError.write(Data("agent-vm: \(refusal.message)\n".utf8))
            ExecExit.shared.exit(refusal.status)
        }
        ExecExit.shared.started(guestPid: session.pid)

        var sources: [DispatchSourceSignal] = []
        for signalNumber in [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGUSR1, SIGUSR2] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler {
                // On a terminal, SIGHUP and SIGTERM end the session, as for ssh: closing the
                // connection hangs up the program's terminal (a shell at its prompt ignores
                // SIGTERM itself). Everything else is forwarded.
                if terminal && (signalNumber == SIGHUP || signalNumber == SIGTERM) {
                    ExecExit.shared.exit(128 + signalNumber)
                }
                try? session.sendSignal(signalNumber)
            }
            source.resume()
            sources.append(source)
        }
        if terminal {
            signal(SIGWINCH, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
            source.setEventHandler {
                try? session.sendResize(Self.localTerminalSize())
            }
            source.resume()
            sources.append(source)
            // Keys go to the box as typed (Control-C included); the guest's terminal echoes
            // and edits lines. Restored on every exit.
            ExecExit.shared.enterRawMode()
        }
        session.forwardStdin(from: STDIN_FILENO)

        let report: ExitReport
        do {
            let terminal = self.terminal
            let prompts = self.prompts
            report = try session.run(stdout: { Self.writeAll(STDOUT_FILENO, $0) }, stderr: { Self.writeAll(STDERR_FILENO, $0) }, notice: { notice in
                Self.report(notice, box: box, terminal: terminal, prompts: prompts)
            })
        } catch {
            throw AgentVMError.guestUnreachable("the connection to box \(box.name) ended: \(error)")
        }
        withExtendedLifetime(sources) {}
        // Exit at once: the stdin thread may still be blocked reading a terminal. Closing the
        // control connection (with the process) returns the guest connection.
        _ = control
        ExecExit.shared.exit(report.shellStatus)
    }

    /// Says on stderr what the program waits on, and records it in the exec log at once. With
    /// `.stop`, stops the waiting program (only it: the exec'd program sees it fail, as if
    /// access had been refused). On a terminal in raw mode, lines need a carriage return.
    static func report(_ notice: GuestNotice, box: Box, terminal: Bool, prompts: PromptPolicy) {
        guard notice.kind == .permissionPrompt else {
            return
        }
        // Process ids 0 and 1 (and negative ones, process groups) are never the program's.
        let stopping = prompts == .stop && (notice.pid ?? 0) > 1
        ExecExit.shared.prompted(notice, stopped: stopping)
        let program = notice.program.map { ($0 as NSString).lastPathComponent } ?? "the program"
        let end = terminal ? "\r\n" : "\n"
        let setup = "give the image Full Disk Access with `agent-vm image setup \(box.record.image)` (boxes made afterwards inherit it)"
        if stopping, let pid = notice.pid {
            let message = "agent-vm: \(program) was waiting for permission to use \(notice.serviceDescription), which macOS asks on the box's screen where nobody sees it, so agent-vm stopped it. "
                + "To answer such prompts instead, run exec with `--prompts wait` and use `agent-vm box view \(box.name) --interactive`; or \(setup).\(end)"
            writeAll(STDERR_FILENO, Array(message.utf8))
            // After the message, so a failure to stop it is always printed after it.
            stop(pid, in: box, end: end)
        } else {
            let message = "agent-vm: \(program) is waiting for permission to use \(notice.serviceDescription): macOS asks on the box's screen, where nobody sees it. "
                + "Answer it with `agent-vm box view \(box.name) --interactive`, or \(setup).\(end)"
            writeAll(STDERR_FILENO, Array(message.utf8))
        }
    }

    /// Kills the program with process id `pid` in the box, through a guest connection of its
    /// own (as root: the program may run as another account). In the background: the notice
    /// arrives on the thread that relays the exec's output, which must keep going.
    static func stop(_ pid: Int32, in box: Box, end: String) {
        DispatchQueue.global().async {
            do {
                let (control, guest, _) = try ControlClient.openGuest(path: box.controlSocketPath)
                defer {
                    close(guest)
                    close(control)
                }
                var timeout = timeval(tv_sec: 30, tv_usec: 0)
                _ = setsockopt(guest, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                let result = try GuestClient.capture(guest, GuestRequest(op: .exec, argv: ["/bin/kill", "-KILL", String(pid)], cwd: "/", user: "root"))
                if result.report != ExitReport(status: 0) {
                    let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    writeAll(STDERR_FILENO, Array("agent-vm: could not stop process \(pid) in box \(box.name): \(reason)\(end)".utf8))
                }
            } catch {
                writeAll(STDERR_FILENO, Array("agent-vm: could not stop process \(pid) in box \(box.name): \(error)\(end)".utf8))
            }
        }
    }

    /// The local terminal's size (stdin's, else stdout's), 24 x 80 when neither is a terminal.
    static func localTerminalSize() -> TerminalSize {
        var cells = winsize()
        for descriptor in [STDIN_FILENO, STDOUT_FILENO] where ioctl(descriptor, TIOCGWINSZ, &cells) == 0 && cells.ws_row > 0 && cells.ws_col > 0 {
            return TerminalSize(rows: cells.ws_row, columns: cells.ws_col)
        }
        return TerminalSize(rows: 24, columns: 80)
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
                    ExecExit.shared.exit(128 + SIGPIPE)
                }
                return
            }
            offset += written
        }
    }
}

/// Every way an exec ends goes through here: the local terminal gets its settings back and the
/// exec log its end line, once, whichever thread gets here first.
final class ExecExit: @unchecked Sendable {
    static let shared = ExecExit()

    private let lock = NSLock()
    private var savedTerminal: termios?
    private var log: ExecLog?
    private var id: String?
    private var guestPid: Int32?
    private var prompts: [String] = []
    private let began = ContinuousClock.now

    func record(log: ExecLog, id: String) {
        lock.lock()
        defer { lock.unlock() }
        self.log = log
        self.id = id
    }

    func started(guestPid: Int32) {
        lock.lock()
        defer { lock.unlock() }
        self.guestPid = guestPid
    }

    /// A program of the run waits on a permission prompt: a notice line in the exec log now,
    /// and the prompt again in the end line.
    func prompted(_ notice: GuestNotice, stopped: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let what = notice.serviceDescription
        if !prompts.contains(what) {
            prompts.append(what)
        }
        if let log, let id {
            log.append(ExecLog.Entry(id: id, event: .notice, time: Date(), guestPid: notice.pid, prompt: what, service: notice.service,
                                     program: notice.program, stopped: stopped ? true : nil))
        }
    }

    /// Raw mode on stdin, when it is a terminal: no echo, no line editing, no signals from keys,
    /// no output processing (the guest's terminal does all that).
    func enterRawMode() {
        lock.lock()
        defer { lock.unlock() }
        var settings = termios()
        guard isatty(STDIN_FILENO) == 1, tcgetattr(STDIN_FILENO, &settings) == 0 else {
            return
        }
        savedTerminal = settings
        cfmakeraw(&settings)
        _ = tcsetattr(STDIN_FILENO, TCSADRAIN, &settings)
    }

    /// Gives the local terminal its settings back (also done by `exit`).
    func restoreTerminal() {
        lock.lock()
        defer { lock.unlock() }
        if var saved = savedTerminal {
            _ = tcsetattr(STDIN_FILENO, TCSADRAIN, &saved)
            savedTerminal = nil
        }
    }

    func exit(_ status: Int32) -> Never {
        // Never unlocked: a second thread arriving here waits for the process to end.
        lock.lock()
        if var saved = savedTerminal {
            _ = tcsetattr(STDIN_FILENO, TCSADRAIN, &saved)
        }
        if let log, let id {
            let elapsed = (ContinuousClock.now - began).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            log.append(ExecLog.Entry(id: id, event: .end, time: Date(), guestPid: guestPid, status: status,
                                     seconds: (seconds * 1000).rounded() / 1000, prompts: prompts.isEmpty ? nil : prompts))
        }
        Darwin.exit(status)
    }
}
