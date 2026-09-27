// Sources/AgentVMKit/Guest/GuestServer.swift
//
// The guest side of the protocol, run by agent-vm-guest as a root LaunchDaemon inside the box.
// One thread per connection; connections are accepted only from the host (vsock CID 2), since
// any process in the guest can open vsock sockets too.
//
// exec runs the program in its own session (so signals reach its whole process group), with
// default signal handling and no inherited descriptors except stdin, stdout and stderr. When
// the host goes away mid-run, the group gets SIGHUP, then SIGKILL 3 seconds later - like
// closing a terminal. Running as another account goes through `agent-vm-guest exec-as`, which
// drops privileges in a fresh single-threaded process before exec; for an account other than
// root, `launchctl asuser` comes first, so the program runs in that account's login session.

import Darwin
import Foundation

public final class GuestServer: @unchecked Sendable {
    /// Account used when a request names none (the box user).
    public let defaultUser: String?
    /// An executable implementing `exec-as` (agent-vm-guest itself); needed to run as another account.
    public let helperPath: String?

    /// Signals the host may deliver to the process group.
    public static let allowedSignals: Set<Int32> = [SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGKILL, SIGUSR1, SIGUSR2, SIGWINCH, SIGCONT, SIGSTOP, SIGTSTP]
    static let defaultPath = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    static let hangupGrace: Double = 3

    /// Sets the system clock (settimeofday; the daemon runs as root); replaced in tests.
    let setClock: @Sendable (Double) -> Int32

    public init(defaultUser: String?, helperPath: String?, setClock: (@Sendable (Double) -> Int32)? = nil) {
        self.defaultUser = defaultUser
        self.helperPath = helperPath
        self.setClock = setClock ?? Self.setSystemClock
    }

    /// settimeofday to `epoch`; 0, or the errno.
    static func setSystemClock(_ epoch: Double) -> Int32 {
        let seconds = epoch.rounded(.down)
        var time = timeval(tv_sec: Int(seconds), tv_usec: Int32(((epoch - seconds) * 1_000_000).rounded(.down)))
        return settimeofday(&time, nil) == 0 ? 0 : errno
    }

    // MARK: - Listening

    /// A vsock socket listening on `port` for any CID.
    public static func listen(port: UInt32) throws -> Int32 {
        let descriptor = socket(AF_VSOCK, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw AgentVMError.system(operation: "vsock socket", code: errno)
        }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var address = sockaddr_vm()
        address.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
        address.svm_family = sa_family_t(AF_VSOCK)
        address.svm_port = port
        address.svm_cid = UInt32(bitPattern: -1) // VMADDR_CID_ANY
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_vm>.size))
            }
        }
        guard bound == 0, Darwin.listen(descriptor, 16) == 0 else {
            let code = errno
            close(descriptor)
            throw AgentVMError.system(operation: "listen on vsock port \(port)", code: code)
        }
        return descriptor
    }

    /// Accepts host connections forever, one thread each.
    public func run(listener: Int32) -> Never {
        // Only the real daemon (root) watches: a notice needs the privacy log, which only root reads.
        if geteuid() == 0 {
            PromptWatcher.shared.start()
        }
        while true {
            var address = sockaddr_vm()
            var length = socklen_t(MemoryLayout<sockaddr_vm>.size)
            let connection = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listener, $0, &length) }
            }
            if connection < 0 {
                if errno != EINTR {
                    Self.log("accept failed: \(String(cString: strerror(errno)))")
                    usleep(100_000)
                }
                continue
            }
            _ = fcntl(connection, F_SETFD, FD_CLOEXEC)
            // VMADDR_CID_HOST: only the host may drive the daemon.
            guard address.svm_cid == 2 else {
                Self.log("refused a connection from CID \(address.svm_cid)")
                close(connection)
                continue
            }
            Thread.detachNewThread { [self] in
                serve(descriptor: connection)
            }
        }
    }

    // MARK: - One connection

    /// Handles one connection to the end and closes it.
    public func serve(descriptor: Int32) {
        let channel = FrameChannel(descriptor: descriptor)
        defer { channel.close() }
        let request: GuestRequest
        do {
            guard let frame = try channel.receive(), frame.type == .request else {
                throw GuestProtocolError.malformed("expected a request frame")
            }
            // The version first, so a newer host with operations unknown here gets a clear answer.
            struct Versioned: Decodable { var v: Int }
            let version = try JSONDecoder().decode(Versioned.self, from: Data(frame.payload)).v
            guard version == AgentVM.guestProtocolVersion else {
                try? channel.send(.response, json: GuestResponse.failure("protocol version \(version) is not supported; this guest speaks \(AgentVM.guestProtocolVersion)"))
                return
            }
            request = try JSONDecoder().decode(GuestRequest.self, from: Data(frame.payload))
        } catch {
            // Rare: the host always sends a request first.
            Self.log("a connection brought no readable request: \(error)")
            try? channel.send(.response, json: GuestResponse.failure("unreadable request: \(error)"))
            return
        }
        switch request.op {
        case .hello:
            try? channel.send(.response, json: GuestResponse(ok: true, v: AgentVM.guestProtocolVersion, version: AgentVM.version, osBuild: Self.osBuild(),
                                                               features: GuestFeature.all))
        case .shutdown:
            try? channel.send(.response, json: GuestResponse(ok: true, v: AgentVM.guestProtocolVersion))
            channel.shutdownBoth()
            Self.log("shutdown requested by the host")
            var pid: pid_t = 0
            let argv = ["/sbin/shutdown", "-h", "now"]
            // Signals back to their defaults: an ignored one (logStopSignals) stays ignored across exec.
            var attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            var defaults = sigset_t()
            sigfillset(&defaults)
            posix_spawnattr_setsigdefault(&attributes, &defaults)
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF))
            let status = Self.withCStrings(argv) { posix_spawn(&pid, "/sbin/shutdown", nil, &attributes, $0, environ) }
            if status != 0 {
                Self.log("cannot run /sbin/shutdown: \(String(cString: strerror(status)))")
            }
        case .exec:
            runExec(request, channel: channel)
        case .timeSync:
            // Plausible times only: from 2020 to 2200. A wrong clock breaks certificates and
            // tokens, so a value that cannot be the Mac's time is refused, never applied.
            guard let epoch = request.epoch, epoch.isFinite, epoch > 1_577_836_800, epoch < 7_258_118_400 else {
                try? channel.send(.response, json: GuestResponse.failure("time-sync needs the time as seconds since 1970"))
                return
            }
            let before = Date().timeIntervalSince1970
            let code = setClock(epoch)
            guard code == 0 else {
                try? channel.send(.response, json: GuestResponse.failure("cannot set the clock: \(String(cString: strerror(code)))"))
                return
            }
            let offset = epoch - before
            if abs(offset) >= 1 {
                Self.log(String(format: "clock set by the host (it was %.1f s %@)", abs(offset), offset > 0 ? "behind" : "ahead"))
            }
            try? channel.send(.response, json: GuestResponse(ok: true, v: AgentVM.guestProtocolVersion, offset: offset))
        }
    }

    private func runExec(_ request: GuestRequest, channel: FrameChannel) {
        let started: Started
        do {
            started = try start(request)
        } catch {
            var response = GuestResponse.failure("\(error)")
            response.status = (error as? Refusal)?.status ?? 126
            try? channel.send(.response, json: response)
            return
        }
        let pid = started.pid
        do {
            try channel.send(.response, json: GuestResponse(ok: true, v: AgentVM.guestProtocolVersion, pid: pid))
        } catch {
            _ = kill(-pid, SIGKILL)
        }
        // Programs of this exec that wait on a privacy prompt are said so (PromptWatcher).
        let notices = request.notices == true ? PromptWatcher.shared.register(pid: pid, channel: channel) : nil
        defer {
            notices.map(PromptWatcher.shared.unregister)
        }

        let output = DispatchGroup()
        let stopTerminal = StopFlag()
        if let terminal = started.terminal {
            output.enter()
            Thread.detachNewThread {
                // The master is closed at the end of runExec, not here: the host reader uses it
                // (resize, foreground job) until then, and a closed number may be reused by
                // another exec's terminal.
                Self.pumpTerminal(terminal, into: channel, stop: stopTerminal)
                output.leave()
            }
        } else {
            for (descriptor, type) in [(started.stdout, FrameType.stdout), (started.stderr, FrameType.stderr)] {
                output.enter()
                Thread.detachNewThread {
                    Self.pump(descriptor, type, into: channel)
                    close(descriptor)
                    output.leave()
                }
            }
        }

        let exited = ExitState()
        let reaped = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            exited.finish(Self.report(status))
            reaped.signal()
        }

        let stdin = OnceCloser(started.stdin)
        let readerDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            Self.readHost(channel: channel, pid: pid, terminal: started.terminal, stdin: stdin, exited: exited)
            readerDone.signal()
        }

        reaped.wait()
        // Background children may hold the pipes open; do not wait for them forever. Pumps
        // still running after this find the channel closed.
        if output.wait(timeout: .now() + 2) == .timedOut, started.terminal != nil {
            // The terminal pump polls; stopped, it returns at once.
            stopTerminal.set()
            _ = output.wait(timeout: .now() + 1)
        }
        // No notice may follow the exit frame.
        notices.map(PromptWatcher.shared.unregister)
        if let report = exited.report {
            try? channel.send(.exit, json: report)
        }
        stdin.close()
        channel.shutdownBoth()
        // The reader must be out of `receive` before the descriptor is closed and reused.
        readerDone.wait()
        if let terminal = started.terminal {
            // Neither the reader nor the pump (stopped, with the channel shut) uses the master
            // any more. Closing it hangs up whatever still has the terminal open.
            stopTerminal.set()
            output.wait()
            close(terminal)
        }
    }

    /// Host-to-guest frames during exec. When the host goes away (or breaks the protocol),
    /// the process group is hung up, then killed. With a terminal, signals go to its foreground
    /// job (what a key such as Control-C would reach), and resize frames set its size.
    private static func readHost(channel: FrameChannel, pid: pid_t, terminal: Int32?, stdin: OnceCloser, exited: ExitState) {
        func hangUp() {
            stdin.close()
            // With job control the foreground job has a group of its own; it is hung up too
            // (the master is still open here: runExec closes it after this thread ends).
            let foreground = terminal.map { tcgetpgrp($0) } ?? -1
            let groups = foreground > 0 && foreground != pid ? [pid, foreground] : [pid]
            for group in groups {
                _ = kill(-group, SIGHUP)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + hangupGrace) {
                for group in groups {
                    _ = kill(-group, SIGKILL)
                }
            }
        }
        while true {
            let frame: Frame?
            do {
                frame = try channel.receive()
            } catch {
                frame = nil
            }
            guard let frame else {
                hangUp()
                return
            }
            switch frame.type {
            case .stdin:
                // A program that does not read its stdin must not keep the reader from
                // noticing that the host went away.
                guard stdin.write(frame.payload, watching: channel.descriptor) else {
                    hangUp()
                    return
                }
            case .stdinEnd:
                stdin.close()
            case .signal:
                if let signal = Int32(bigEndianBytes: frame.payload), allowedSignals.contains(signal), !exited.isFinished {
                    let foreground = terminal.map { tcgetpgrp($0) } ?? -1
                    _ = kill(foreground > 0 ? -foreground : -pid, signal)
                }
            case .resize:
                // Ignored without a terminal. Setting the size sends SIGWINCH to the foreground job.
                if let terminal, var size = TerminalSize(bytes: frame.payload).map(\.winsize) {
                    _ = ioctl(terminal, TIOCSWINSZ, &size)
                }
            default:
                // Anything else from the host is a protocol error: treat it as a hangup.
                channel.shutdownBoth()
            }
        }
    }

    private static func pump(_ descriptor: Int32, _ type: FrameType, into channel: FrameChannel) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR {
                continue
            }
            if count <= 0 {
                return
            }
            do {
                try channel.send(Frame(type, Array(buffer[0..<count])))
            } catch {
                // The host is gone; keep draining so the process does not block on a full pipe.
                continue
            }
        }
    }

    /// A terminal's output (the non-blocking master side) until every descriptor for the
    /// terminal's device is closed, or `stop` is set: a background process may keep the terminal
    /// open long after the program exited.
    private static func pumpTerminal(_ master: Int32, into channel: FrameChannel, stop: StopFlag) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while !stop.isSet {
            let count = read(master, &buffer, buffer.count)
            if count > 0 {
                // When the host is gone, keep draining so the program does not block writing.
                try? channel.send(Frame(.stdout, Array(buffer[0..<count])))
                continue
            }
            if count < 0 && errno == EINTR {
                continue
            }
            guard count < 0 && errno == EAGAIN else {
                // End of file or EIO: the terminal's device is closed on the program's side.
                return
            }
            var watched = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            _ = poll(&watched, 1, 200)
        }
    }

    static func report(_ status: Int32) -> ExitReport {
        return ExitReport(waitStatus: status)
    }

    // MARK: - Starting a process

    struct Started {
        var pid: pid_t
        var stdin: Int32
        /// With a terminal: its master side (also `terminal`); stderr is then -1.
        var stdout: Int32
        var stderr: Int32
        var terminal: Int32?
    }

    struct Account: Equatable {
        var name: String
        var uid: uid_t
        var gid: gid_t
        var home: String
        var shell: String
    }

    static func account(named name: String) -> Account? {
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16384)
        guard getpwnam_r(name, &entry, &buffer, buffer.count, &result) == 0, result != nil else {
            return nil
        }
        return Account(name: String(cString: entry.pw_name), uid: entry.pw_uid, gid: entry.pw_gid,
                       home: String(cString: entry.pw_dir), shell: String(cString: entry.pw_shell))
    }

    static func currentAccountName() -> String? {
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16384)
        guard getpwuid_r(geteuid(), &entry, &buffer, buffer.count, &result) == 0, result != nil else {
            return nil
        }
        return String(cString: entry.pw_name)
    }

    /// The environment a program starts with: a login-like base for the account, then the
    /// request's variables on top.
    static func environment(for account: Account, overrides: [String: String]?) -> [String: String] {
        var environment = [
            "HOME": account.home,
            "USER": account.name,
            "LOGNAME": account.name,
            "SHELL": account.shell,
            "PATH": defaultPath,
            "LANG": "en_US.UTF-8",
        ]
        for (key, value) in overrides ?? [:] {
            environment[key] = value
        }
        return environment
    }

    /// `name` if it contains a slash (a relative one taken from `directory`, where the program
    /// starts), else the first executable file of that name on `path`.
    static func resolveExecutable(_ name: String, path: String, directory: String) -> String? {
        if name.contains("/") {
            let full = name.hasPrefix("/") ? name : "\(directory)/\(name)"
            return access(full, X_OK) == 0 ? full : nil
        }
        for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = "\(directory)/\(name)"
            var info = stat()
            if stat(candidate, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, access(candidate, X_OK) == 0 {
                return candidate
            }
        }
        return nil
    }

    private func start(_ request: GuestRequest) throws -> Started {
        guard let argv = request.argv, let program = argv.first, !program.isEmpty else {
            throw Refusal("no program given")
        }
        guard let userName = request.user ?? defaultUser ?? Self.currentAccountName(),
              let account = Self.account(named: userName) else {
            throw Refusal("no such account: \(request.user ?? defaultUser ?? "?")")
        }
        let environment = Self.environment(for: account, overrides: request.env)
        let directory = request.cwd ?? account.home
        var info = stat()
        guard stat(directory, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw Refusal("working directory \(directory) does not exist")
        }
        guard let executable = Self.resolveExecutable(program, path: environment["PATH"] ?? Self.defaultPath, directory: directory) else {
            throw Refusal("\(program): command not found", status: 127)
        }

        // Another account, or a terminal (which only the new process itself can make its
        // controlling terminal), goes through the helper.
        let direct = account.uid == geteuid() && request.terminal == nil
        let spawnPath: String
        let spawnArguments: [String]
        if direct {
            spawnPath = executable
            spawnArguments = argv
        } else {
            guard account.uid == geteuid() || geteuid() == 0 else {
                throw Refusal("cannot run as \(account.name): the guest daemon is not root")
            }
            guard let helperPath else {
                throw Refusal("cannot run \(request.terminal == nil ? "as \(account.name)" : "on a terminal"): the guest daemon has no exec-as helper")
            }
            let execAs = Self.execAsArguments(user: account.name, directory: directory, executable: executable, argv: argv,
                                              terminal: request.terminal != nil)
            if geteuid() == 0 && account.uid != 0 {
                // In the account's login session: its desktop (Aqua) once it is logged in, else
                // its background one. Started by a root daemon, a program is outside it, so the
                // login Keychain refuses it. launchctl execs in place (same pid, so the session,
                // the terminal and the exit status stay), and the daemon stays the responsible
                // process, so Full Disk Access given to agent-vm-guest still applies (measured).
                spawnPath = Self.launchctlPath
                spawnArguments = ["launchctl", "asuser", String(account.uid), helperPath] + execAs.dropFirst()
            } else {
                spawnPath = helperPath
                spawnArguments = execAs
            }
        }
        return try Self.spawn(spawnPath, arguments: spawnArguments, environment: environment,
                              directory: direct ? directory : nil,
                              terminal: request.terminal, terminalOwner: account.uid)
    }

    /// posix_spawn with pipes for stdio (or, with `terminal`, a new pseudo-terminal that becomes
    /// the program's controlling terminal), a new session, default signal handling, and no other
    /// inherited descriptors.
    static func spawn(_ path: String, arguments: [String], environment: [String: String], directory: String?,
                      terminal: TerminalSize? = nil, terminalOwner: uid_t? = nil) throws -> Started {
        if let terminal {
            return try spawnOnTerminal(path, arguments: arguments, environment: environment, directory: directory,
                                       size: terminal, owner: terminalOwner)
        }
        var input: [Int32] = [-1, -1]
        var output: [Int32] = [-1, -1]
        var error: [Int32] = [-1, -1]
        guard pipe(&input) == 0, pipe(&output) == 0, pipe(&error) == 0 else {
            let code = errno
            for descriptor in input + output + error where descriptor >= 0 {
                close(descriptor)
            }
            throw Refusal("cannot create pipes: \(String(cString: strerror(code)))")
        }
        for descriptor in [input[1], output[0], error[0]] {
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, input[0], 0)
        posix_spawn_file_actions_adddup2(&actions, output[1], 1)
        posix_spawn_file_actions_adddup2(&actions, error[1], 2)
        let pid: pid_t
        do {
            pid = try spawnProcess(path, arguments: arguments, environment: environment, directory: directory, actions: &actions)
        } catch let failure {
            for descriptor in input + output + error {
                close(descriptor)
            }
            throw failure
        }
        close(input[0])
        close(output[1])
        close(error[1])
        return Started(pid: pid, stdin: input[1], stdout: output[0], stderr: error[0], terminal: nil)
    }

    /// The terminal variant. The program opens the terminal's device itself as the leader of its
    /// new session, which makes it the controlling terminal (a dup2 would not). The daemon keeps
    /// only the master side, non-blocking: input is written to it, output read from it.
    private static func spawnOnTerminal(_ path: String, arguments: [String], environment: [String: String], directory: String?,
                                        size: TerminalSize, owner: uid_t?) throws -> Started {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else {
            throw Refusal("cannot open a terminal: \(String(cString: strerror(errno)))")
        }
        guard grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master).map({ String(cString: $0) }) else {
            let code = errno
            close(master)
            throw Refusal("cannot set up a terminal: \(String(cString: strerror(code)))")
        }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        // Held open until the program has it: the size set here would otherwise be reset when
        // the device is first opened. The account owns its terminal, as after a login.
        let held = open(name, O_RDWR | O_NOCTTY | O_CLOEXEC)
        guard held >= 0 else {
            let code = errno
            close(master)
            throw Refusal("cannot open \(name): \(String(cString: strerror(code)))")
        }
        defer { close(held) }
        var cells = size.winsize
        _ = ioctl(held, TIOCSWINSZ, &cells)
        if let owner, owner != geteuid() {
            _ = fchown(held, owner, gid_t(bitPattern: -1))
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, name, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        let pid: pid_t
        do {
            pid = try spawnProcess(path, arguments: arguments, environment: environment, directory: directory, actions: &actions)
        } catch {
            close(master)
            throw error
        }
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        // A second descriptor for input, so closing input (stdin end) leaves output flowing.
        let input = dup(master)
        _ = fcntl(input, F_SETFD, FD_CLOEXEC)
        return Started(pid: pid, stdin: input, stdout: master, stderr: -1, terminal: master)
    }

    private static func spawnProcess(_ path: String, arguments: [String], environment: [String: String], directory: String?,
                                     actions: inout posix_spawn_file_actions_t?) throws -> pid_t {
        if let directory {
            posix_spawn_file_actions_addchdir(&actions, directory)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        sigfillset(&defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &mask)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var pid: pid_t = 0
        let environmentList = environment.map { "\($0.key)=\($0.value)" }
        let status = withCStrings(arguments) { argv in
            withCStrings(environmentList) { envp in
                posix_spawn(&pid, path, &actions, &attributes, argv, envp)
            }
        }
        guard status == 0 else {
            throw Refusal("cannot start \(path): \(String(cString: strerror(status)))")
        }
        return pid
    }

    // MARK: - exec-as (runs in a fresh process)

    /// `agent-vm-guest exec-as [--terminal] <user> <directory> <executable> -- <argv0> [arguments...]`:
    /// with --terminal, make stdin (a terminal, this process leading a new session) the controlling
    /// terminal; become the account unless already running as it (supplementary groups, group,
    /// user - in that order, then verify root cannot be regained); change to the directory, and
    /// exec. The environment was set by the daemon. Exits 126 when any step fails, as a shell does
    /// for "cannot execute".
    public static func execAs(_ arguments: [String]) -> Never {
        guard let (name, directory, executable, command, terminal) = parseExecAs(arguments) else {
            fail("usage: agent-vm-guest exec-as [--terminal] <user> <directory> <executable> -- <argv0> [arguments...]")
        }
        guard let account = account(named: name) else {
            fail("no such account: \(name)")
        }
        // On macOS, opening a terminal never makes it the controlling one; only this does.
        if terminal && ioctl(0, TIOCSCTTY, 0) != 0 {
            fail("cannot take the terminal: \(String(cString: strerror(errno)))")
        }
        if getuid() == account.uid && geteuid() == account.uid {
            // Already the account (the daemon itself runs as it): nothing to change.
        } else {
            becomeAccount(account)
        }
        guard chdir(directory) == 0 else {
            fail("cannot enter \(directory): \(String(cString: strerror(errno)))")
        }
        _ = withCStrings(command) { argv in
            execv(executable, argv)
        }
        fail("cannot run \(executable): \(String(cString: strerror(errno)))")
    }

    private static func becomeAccount(_ account: Account) {
        let name = account.name
        guard initgroups(name, Int32(bitPattern: account.gid)) == 0 else {
            fail("initgroups(\(name)): \(String(cString: strerror(errno)))")
        }
        guard setgid(account.gid) == 0, setuid(account.uid) == 0 else {
            fail("cannot become \(name): \(String(cString: strerror(errno)))")
        }
        if account.uid != 0 {
            guard setuid(0) != 0, getuid() == account.uid, geteuid() == account.uid else {
                fail("privileges were not dropped")
            }
        }
    }

    /// `[--terminal] <user> <directory> <executable> -- <argv0> [arguments...]` (what follows `exec-as`).
    /// The executable is separate from argv[0], so the program sees the name it was asked by.
    static func parseExecAs(_ arguments: [String]) -> (user: String, directory: String, executable: String, argv: [String], terminal: Bool)? {
        let terminal = arguments.first == "--terminal"
        let arguments = terminal ? Array(arguments.dropFirst()) : arguments
        guard arguments.count >= 5, arguments[3] == "--", !arguments[0].isEmpty, !arguments[2].isEmpty else {
            return nil
        }
        return (arguments[0], arguments[1], arguments[2], Array(arguments[4...]), terminal)
    }

    static let launchctlPath = "/bin/launchctl"

    /// The helper's arguments for running `executable` with `argv` as `user` in `directory`.
    static func execAsArguments(user: String, directory: String, executable: String, argv: [String], terminal: Bool = false) -> [String] {
        return ["agent-vm-guest", "exec-as"] + (terminal ? ["--terminal"] : []) + [user, directory, executable, "--"] + argv
    }

    /// A request the daemon turns down; `message` goes to the host as is, with the shell's
    /// status for it (127 not found, 126 cannot run).
    struct Refusal: Error, CustomStringConvertible {
        var message: String
        var status: Int32

        init(_ message: String, status: Int32 = 126) {
            self.message = message
            self.status = status
        }

        var description: String {
            return message
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("agent-vm-guest: \(message)\n".utf8))
        exit(126)
    }

    // MARK: - Helpers

    static func withCStrings<T>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> T) -> T {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer {
            for pointer in pointers {
                free(pointer)
            }
        }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }

    static func osBuild() -> String? {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func log(_ message: String) {
        logLine("agent-vm-guest: \(message)")
    }

    /// Logs the signal that stops the daemon, then ends by it as before: launchd sends SIGTERM
    /// at shutdown, and a SIGKILL leaves no line, which tells the two apart. The handlers run on
    /// a global queue (the main thread stays in accept()), so they are set up here, outside the
    /// main actor's top-level code: a handler inheriting its isolation traps there (measured).
    public static func logStopSignals() {
        for stopSignal in [SIGTERM, SIGHUP, SIGINT] {
            signal(stopSignal, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: stopSignal, queue: .global())
            source.setEventHandler {
                // The signal raised below can reach this handler once more before the end.
                stopLock.lock()
                let first = !stopLogged
                stopLogged = true
                stopLock.unlock()
                if first {
                    logLine("agent-vm-guest: stopping on \(String(cString: strsignal(stopSignal)))")
                }
                signal(stopSignal, SIG_DFL)
                raise(stopSignal)
            }
            source.resume()
            stopSources.append(source)
        }
    }

    /// Kept for the life of the process; set once, at startup, before any handler can run.
    nonisolated(unsafe) private static var stopSources: [DispatchSourceSignal] = []
    private static let stopLock = NSLock()
    nonisolated(unsafe) private static var stopLogged = false

    /// One line in the daemon's log (its stderr, a file launchd opens), written through to disk
    /// at once: a guest that loses power (a forced stop) keeps what came before.
    public static func logLine(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
        fsync(STDERR_FILENO)
    }
}

/// Set once, read from another thread.
private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// The exit report, set once by the reaping thread.
private final class ExitState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ExitReport?

    func finish(_ report: ExitReport) {
        lock.lock()
        value = report
        lock.unlock()
    }

    var report: ExitReport? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    var isFinished: Bool {
        return report != nil
    }
}

/// The write end of the program's stdin, closed exactly once from whichever thread gets there.
/// Writes do not block indefinitely: a program (or a background child holding its stdin) that
/// stops reading must not keep `close` or the host's hangup waiting.
private final class OnceCloser: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    private let closingLock = NSLock()
    private var closing = false

    init(_ descriptor: Int32) {
        self.descriptor = descriptor
        // The program may close its stdin early; writes must fail with EPIPE, not kill the daemon.
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        // Only the daemon's end: the program's read end is a separate open file.
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
    }

    private var isClosing: Bool {
        closingLock.lock()
        defer { closingLock.unlock() }
        return closing
    }

    /// Writes `bytes`, waiting while the pipe is full. Drops the input when the program stops
    /// reading or `close` is called. Returns false when `socket` (the host connection) reports
    /// that the host went away while waiting.
    func write(_ bytes: [UInt8], watching socket: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var done = 0
        while done < bytes.count, descriptor >= 0, !isClosing {
            let written = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress! + done, bytes.count - done) }
            if written >= 0 {
                done += written
                continue
            }
            if errno == EINTR {
                continue
            }
            guard errno == EAGAIN else {
                // The program stopped reading; drop its input.
                return true
            }
            var watched = [pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0),
                           pollfd(fd: socket, events: Int16(POLLHUP), revents: 0)]
            // The timeout bounds how long `close` waits; POLLHUP means the host closed.
            _ = poll(&watched, 2, 200)
            if watched[1].revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                return false
            }
        }
        return true
    }

    func close() {
        closingLock.lock()
        closing = true
        closingLock.unlock()
        lock.lock()
        defer { lock.unlock() }
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }
}
