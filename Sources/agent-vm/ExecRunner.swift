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
        if terminal {
            // The terminal's identity, so programs in the box draw as they would here. TERM
            // comes once the box is known to take a terminal (it may install a definition).
            let host = ProcessInfo.processInfo.environment
            for name in ExecEnvironment.terminalIdentity where environment[name] == nil {
                environment[name] = host[name]
            }
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
        // Whether the guest takes the size in pixels too (resize frames of 8 bytes).
        let pixels = status.guestFeatures?.contains(GuestFeature.terminalPixels) == true
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
            size = Self.localTerminalSize(pixels: pixels)
            if environment["TERM"] == nil {
                environment["TERM"] = Self.terminalType(host: ProcessInfo.processInfo.environment["TERM"], box: box, user: user)
            }
        }

        let log = ExecLog(url: box.execLogURL)
        let id = ExecLog.newID()
        log.append(ExecLog.Entry(id: id, event: .start, time: Date(), argv: argv, user: user ?? box.record.userName, cwd: directory,
                                 project: projectPath, readOnly: projectPath == nil ? nil : readOnly, terminal: terminal ? true : nil,
                                 hostPid: getpid()))
        ExecExit.shared.record(log: log, id: id, box: box.name)

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
                try? session.sendResize(Self.localTerminalSize(pixels: pixels))
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
        guard notice.kind == .permissionPrompt || notice.kind == .keychainPrompt else {
            return
        }
        // Process ids 0 and 1 (and negative ones, process groups) are never the program's.
        let stopping = prompts == .stop && (notice.pid ?? 0) > 1
        ExecExit.shared.prompted(notice, stopped: stopping)
        let program = notice.program.map { ($0 as NSString).lastPathComponent } ?? "the program"
        let end = terminal ? "\r\n" : "\n"
        // A Keychain dialog is answered in the box (Always Allow keeps the answer); a privacy
        // prompt is better avoided with Full Disk Access.
        let setup = notice.kind == .keychainPrompt
            ? "log in with the program itself (`agent-vm box shell \(box.name)`), so the Keychain item is its own and it is not asked"
            : "give the image Full Disk Access with `agent-vm image setup \(box.record.image)` (boxes made afterwards inherit it)"
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

    /// The terminal type for the box: this Mac's when macOS itself knows it (the guest has the
    /// same terminfo), or when this Mac's entry (`infocmp -x`, which finds a terminal's own,
    /// such as Ghostty's or kitty's) could be installed in the account's ~/.terminfo in the box;
    /// else xterm-256color.
    static func terminalType(host: String?, box: Box, user: String?) -> String {
        let known = ExecEnvironment.terminalType(host: host)
        guard let host, known != host, let script = ExecEnvironment.terminfoInstallScript(name: host),
              let entry = localTerminfo(host) else {
            return known
        }
        do {
            let (control, guest, _) = try ControlClient.openGuest(path: box.controlSocketPath)
            defer {
                close(guest)
                close(control)
            }
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            _ = setsockopt(guest, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let installed = try GuestClient.capture(guest, GuestRequest(op: .exec, argv: ["/bin/sh", "-c", script], user: user), input: entry)
            return installed.report == ExitReport(status: 0) ? host : known
        } catch {
            return known
        }
    }

    /// This Mac's terminfo entry for `name`, as source; nil when there is none.
    static func localTerminfo(_ name: String) -> Data? {
        let infocmp = Process()
        infocmp.executableURL = URL(fileURLWithPath: "/usr/bin/infocmp")
        infocmp.arguments = ["-x", name]
        let output = Pipe()
        infocmp.standardOutput = output
        infocmp.standardError = FileHandle.nullDevice
        do {
            try infocmp.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        infocmp.waitUntilExit()
        return infocmp.terminationStatus == 0 && !data.isEmpty ? data : nil
    }

    /// The local terminal's size (stdin's, else stdout's), 24 x 80 when neither is a terminal.
    /// With `pixels`, its size in pixels too, when the terminal gives one.
    static func localTerminalSize(pixels: Bool = false) -> TerminalSize {
        var cells = winsize()
        for descriptor in [STDIN_FILENO, STDOUT_FILENO] where ioctl(descriptor, TIOCGWINSZ, &cells) == 0 && cells.ws_row > 0 && cells.ws_col > 0 {
            let known = pixels && cells.ws_xpixel > 0 && cells.ws_ypixel > 0
            return TerminalSize(rows: cells.ws_row, columns: cells.ws_col, xpixels: known ? cells.ws_xpixel : nil, ypixels: known ? cells.ws_ypixel : nil)
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
    private var box: String?
    private let began = ContinuousClock.now

    func record(log: ExecLog, id: String, box: String) {
        lock.lock()
        defer { lock.unlock() }
        self.log = log
        self.id = id
        self.box = box
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
            // A full-screen program may have drawn over the notices: say it again, now that the
            // terminal is ours.
            if !prompts.isEmpty {
                // One plain write, errors ignored: writeAll would come back here on EPIPE and
                // wait forever on the lock this thread holds.
                let text = "agent-vm: while it ran, a program waited on \(prompts.joined(separator: ", ")) (see `agent-vm box execlog \(box ?? "<box>")`)\n"
                _ = Array(text.utf8).withUnsafeBytes { write(STDERR_FILENO, $0.baseAddress!, $0.count) }
            }
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
