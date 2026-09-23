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
// drops privileges in a fresh single-threaded process before exec.

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

    public init(defaultUser: String?, helperPath: String?) {
        self.defaultUser = defaultUser
        self.helperPath = helperPath
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
            try? channel.send(.response, json: GuestResponse.failure("unreadable request: \(error)"))
            return
        }
        switch request.op {
        case .hello:
            try? channel.send(.response, json: GuestResponse(ok: true, v: AgentVM.guestProtocolVersion, version: AgentVM.version, osBuild: Self.osBuild()))
        case .shutdown:
            try? channel.send(.response, json: GuestResponse(ok: true, v: AgentVM.guestProtocolVersion))
            channel.shutdownBoth()
            Self.log("shutdown requested by the host")
            var pid: pid_t = 0
            let argv = ["/sbin/shutdown", "-h", "now"]
            let status = Self.withCStrings(argv) { posix_spawn(&pid, "/sbin/shutdown", nil, nil, $0, environ) }
            if status != 0 {
                Self.log("cannot run /sbin/shutdown: \(String(cString: strerror(status)))")
            }
        case .exec:
            runExec(request, channel: channel)
        }
    }

    private func runExec(_ request: GuestRequest, channel: FrameChannel) {
        let started: Started
        do {
            started = try start(request)
        } catch {
            try? channel.send(.response, json: GuestResponse.failure("\(error)"))
            return
        }
        let pid = started.pid
        do {
            try channel.send(.response, json: GuestResponse(ok: true, v: AgentVM.guestProtocolVersion, pid: pid))
        } catch {
            _ = kill(-pid, SIGKILL)
        }

        let output = DispatchGroup()
        for (descriptor, type) in [(started.stdout, FrameType.stdout), (started.stderr, FrameType.stderr)] {
            output.enter()
            Thread.detachNewThread {
                Self.pump(descriptor, type, into: channel)
                close(descriptor)
                output.leave()
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
            Self.readHost(channel: channel, pid: pid, stdin: stdin, exited: exited)
            readerDone.signal()
        }

        reaped.wait()
        // Background children may hold the pipes open; do not wait for them forever. Pumps
        // still running after this find the channel closed.
        _ = output.wait(timeout: .now() + 2)
        if let report = exited.report {
            try? channel.send(.exit, json: report)
        }
        stdin.close()
        channel.shutdownBoth()
        // The reader must be out of `receive` before the descriptor is closed and reused.
        readerDone.wait()
    }

    /// Host-to-guest frames during exec. When the host goes away (or breaks the protocol),
    /// the process group is hung up, then killed.
    private static func readHost(channel: FrameChannel, pid: pid_t, stdin: OnceCloser, exited: ExitState) {
        func hangUp() {
            stdin.close()
            _ = kill(-pid, SIGHUP)
            DispatchQueue.global().asyncAfter(deadline: .now() + hangupGrace) {
                _ = kill(-pid, SIGKILL)
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
                    _ = kill(-pid, signal)
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

    static func report(_ status: Int32) -> ExitReport {
        // WIFEXITED / WEXITSTATUS / WTERMSIG are macros Swift does not import.
        let low = status & 0x7f
        if low == 0 {
            return ExitReport(status: (status >> 8) & 0xff)
        }
        return ExitReport(signal: low)
    }

    // MARK: - Starting a process

    struct Started {
        var pid: pid_t
        var stdin: Int32
        var stdout: Int32
        var stderr: Int32
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
            throw Refusal("\(program): command not found")
        }

        let spawnPath: String
        let spawnArguments: [String]
        if account.uid == geteuid() {
            spawnPath = executable
            spawnArguments = argv
        } else {
            guard geteuid() == 0, let helperPath else {
                throw Refusal("cannot run as \(account.name): the guest daemon is not root")
            }
            spawnPath = helperPath
            spawnArguments = Self.execAsArguments(user: account.name, directory: directory, executable: executable, argv: argv)
        }
        return try Self.spawn(spawnPath, arguments: spawnArguments, environment: environment,
                              directory: account.uid == geteuid() ? directory : nil)
    }

    /// posix_spawn with pipes for stdio, a new session, default signal handling, and no other
    /// inherited descriptors.
    static func spawn(_ path: String, arguments: [String], environment: [String: String], directory: String?) throws -> Started {
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
        close(input[0])
        close(output[1])
        close(error[1])
        guard status == 0 else {
            close(input[1])
            close(output[0])
            close(error[0])
            throw Refusal("cannot start \(path): \(String(cString: strerror(status)))")
        }
        return Started(pid: pid, stdin: input[1], stdout: output[0], stderr: error[0])
    }

    // MARK: - exec-as (runs in a fresh process)

    /// `agent-vm-guest exec-as <user> <directory> <executable> -- <argv0> [arguments...]`: become the
    /// account (supplementary groups, group, user - in that order, then verify root cannot be
    /// regained), change to the directory, and exec. The environment was set by the daemon.
    /// Exits 126 when any step fails, as a shell does for "cannot execute".
    public static func execAs(_ arguments: [String]) -> Never {
        guard let (name, directory, executable, command) = parseExecAs(arguments) else {
            fail("usage: agent-vm-guest exec-as <user> <directory> <executable> -- <argv0> [arguments...]")
        }
        guard let account = account(named: name) else {
            fail("no such account: \(name)")
        }
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
        guard chdir(directory) == 0 else {
            fail("cannot enter \(directory): \(String(cString: strerror(errno)))")
        }
        _ = withCStrings(command) { argv in
            execv(executable, argv)
        }
        fail("cannot run \(executable): \(String(cString: strerror(errno)))")
    }

    /// `<user> <directory> <executable> -- <argv0> [arguments...]` (what follows `exec-as`).
    /// The executable is separate from argv[0], so the program sees the name it was asked by.
    static func parseExecAs(_ arguments: [String]) -> (user: String, directory: String, executable: String, argv: [String])? {
        guard arguments.count >= 5, arguments[3] == "--", !arguments[0].isEmpty, !arguments[2].isEmpty else {
            return nil
        }
        return (arguments[0], arguments[1], arguments[2], Array(arguments[4...]))
    }

    /// The helper's arguments for running `executable` with `argv` as `user` in `directory`.
    static func execAsArguments(user: String, directory: String, executable: String, argv: [String]) -> [String] {
        return ["agent-vm-guest", "exec-as", user, directory, executable, "--"] + argv
    }

    /// A request the daemon turns down; `message` goes to the host as is.
    struct Refusal: Error, CustomStringConvertible {
        var message: String

        init(_ message: String) {
            self.message = message
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
        FileHandle.standardError.write(Data("agent-vm-guest: \(message)\n".utf8))
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
