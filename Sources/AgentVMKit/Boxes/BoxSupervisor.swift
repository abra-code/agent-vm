// Sources/AgentVMKit/Boxes/BoxSupervisor.swift
//
// `agent-vm box serve <name>`: the one process that owns a running box. It holds the box lock,
// runs the VM (Virtualization lets only the owning process open vsock connections), and
// answers the control socket: status, open (a vsock descriptor to the guest daemon for
// `agent-vm exec`), stop. A stop - requested, or SIGTERM/SIGINT/SIGHUP - shuts the guest down
// through its daemon, since requestStop() does not stop a macOS guest with a logged-in user.
//
// `BoxLauncher` starts the supervisor as a detached process (its own session, output to
// supervisor.log) and waits until the guest daemon answers.

import Darwin
import Foundation
import Virtualization

@MainActor
public final class BoxSupervisor {
    public let box: Box
    private let log: @MainActor (String) -> Void
    private let state = SupervisorState()
    private var machine: MacMachine?
    private var signalSources: [DispatchSourceSignal] = []
    /// The dead-end network card's host end (allowlist and off modes).
    private var link: DeadEndLink?

    /// How long the guest may take to boot until its daemon answers, and to shut down.
    static let bootTimeout: Duration = .seconds(180)
    static let shutdownTimeout: Duration = .seconds(90)

    public init(box: Box, log: @escaping @MainActor (String) -> Void) {
        self.box = box
        self.log = log
    }

    /// Runs the box until it stops; returns when the VM is down and the socket is gone.
    public func run() async throws {
        guard let lock = try FolderLock.tryAcquire(box.lockPath) else {
            throw AgentVMError.boxRunning(box.name)
        }
        defer { lock.release() }

        let network = box.record.effectiveNetwork
        let proxy = ProxyServer(policy: try CompiledPolicy(network), log: NetworkLog(url: box.networkLogURL))
        let attachment: MacMachineSpec.Network
        if network.usesProxy {
            let link = try DeadEndLink()
            self.link = link
            attachment = .fileHandle(link.guestHandle)
        } else {
            attachment = .nat
        }
        let spec = MacMachineSpec(cpuCount: box.record.cpuCount, memoryBytes: box.record.memoryBytes, macAddress: box.record.macAddress)
        let configuration = try spec.configuration(for: box.machineFiles, auxiliaryStorage: VZMacAuxiliaryStorage(url: box.auxiliaryStorageURL),
                                                   network: attachment, shareTag: ProjectShare.tag)
        let machine = MacMachine(configuration: configuration)
        self.machine = machine

        let name = box.name
        let handler = SupervisorControl(state: state, machine: machine, box: box, proxy: proxy) { [weak self] path, readOnly, claim in
            guard let self else {
                throw AgentVMError.boxNotRunning(name)
            }
            try await self.shareProject(path, readOnly: readOnly, claim: claim)
        }
        let server = try ControlServer(path: box.controlSocketPath, handler: handler)
        defer { server.close() }
        installSignalHandlers()

        log("Starting box \(box.name) (\(box.record.cpuCount) CPUs, \(box.record.memoryBytes >> 30) GB, image \(box.record.image), network \(network.mode.rawValue))")
        try await machine.start(provisioning: nil)
        if network.usesProxy {
            // Each proxied connection holds two descriptors; the soft limit a shell hands down
            // is often 256, which the proxy's connection cap alone would exhaust.
            Self.raiseDescriptorLimit(to: UInt64(ProxyServer.defaultMaxConnections * 2 + 512))
            // The guest daemon relays 127.0.0.1:3128 here; each connection gets a thread,
            // up to the proxy's cap.
            try machine.listen(port: GuestRelay.hostPort) { connection in
                proxy.accept(client: connection.descriptor) {
                    connection.close()
                }
            }
        }

        let clock = ContinuousClock()
        let began = clock.now
        guard let hello = await waitForDaemon(machine) else {
            if state.stopRequested {
                // No daemon to shut down through yet.
                state.set(.stopping, guestVersion: nil)
                log("Stop requested before the guest daemon answered; pulling the plug")
                try? await machine.forceStop()
                return
            }
            if !machine.isRunning {
                log("The guest stopped while booting\(machine.failure.map { ": \($0)" } ?? "")")
                throw AgentVMError.guestUnreachable("the guest stopped while booting\(machine.failure.map { ": \($0)" } ?? "")")
            }
            log("The guest daemon did not answer within \(Self.bootTimeout); stopping")
            try? await machine.forceStop()
            throw AgentVMError.guestUnreachable("the guest daemon did not answer within \(Self.bootTimeout)")
        }
        do {
            try await configureNetwork(machine, mode: network.mode)
        } catch {
            log("Cannot set up the guest's network (\(error)); stopping")
            await shutDown(machine)
            throw error
        }
        state.set(.ready, guestVersion: hello.version)
        log("Ready in \(Int(ImageBuilder.seconds(clock.now - began))) s: agent-vm-guest \(hello.version ?? "?")")

        // Until the guest stops by itself or a stop is requested.
        while machine.isRunning && !state.stopRequested {
            try? await Task.sleep(for: .milliseconds(250))
        }
        if machine.isRunning {
            await shutDown(machine)
        } else {
            log("The guest stopped\(machine.failure.map { ": \($0)" } ?? "")")
        }
    }

    private func waitForDaemon(_ machine: MacMachine) async -> GuestResponse? {
        let deadline = ContinuousClock.now + Self.bootTimeout
        while ContinuousClock.now < deadline && machine.isRunning && !state.stopRequested {
            if let connection = try? await machine.connect(toPort: GuestProtocol.port) {
                let descriptor = connection.descriptor
                Self.setReadTimeout(descriptor, seconds: 10)
                let hello = try? await Task.detached { try GuestClient.hello(descriptor) }.value
                connection.close()
                if let hello, hello.v == AgentVM.guestProtocolVersion {
                    return hello
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return nil
    }

    /// Raises the soft limit on open descriptors to at least `wanted` (within the hard limit).
    static func raiseDescriptorLimit(to wanted: UInt64) {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0, limit.rlim_cur < wanted else {
            return
        }
        limit.rlim_cur = min(wanted, limit.rlim_max)
        _ = setrlimit(RLIMIT_NOFILE, &limit)
    }

    /// The share request running now, if any; the next one waits for it.
    private var shareQueue: Task<Void, Error>?

    /// Shares `path` into the box at the same path, replacing the previous project. Called
    /// from control threads through the main actor. The awaits inside let other requests run
    /// on the main actor meanwhile, so requests are chained to change the guest's mounts and
    /// the device's share one at a time.
    /// `claim`: the caller runs a program on the project (an exec); the share then stays as
    /// it is until the claim is released (`SupervisorState.releaseProject`).
    func shareProject(_ path: String, readOnly: Bool, claim: Bool) async throws {
        let previous = shareQueue
        let task = Task { @MainActor in
            _ = await previous?.result
            try await self.replaceProject(path, readOnly: readOnly)
            if claim {
                self.state.claimProject()
            }
        }
        shareQueue = task
        try await task.value
    }

    private func replaceProject(_ path: String, readOnly: Bool) async throws {
        guard let machine, state.snapshot.state == .ready else {
            throw AgentVMError.supervisorRefused("box \(box.name) is not ready")
        }
        let storeRoot = box.directory.deletingLastPathComponent().deletingLastPathComponent()
        let project = try ProjectShare.validated(path, storeRoot: storeRoot)
        let current = state.project
        if current?.path == project && current?.readOnly == readOnly {
            return
        }
        if let current, state.projectClaims > 0 {
            throw AgentVMError.supervisorRefused("box \(box.name) is running programs on \(current.path)\(current.readOnly ? " (read only)" : ""); wait until they end, or use another box")
        }
        if let current {
            let result = try await guestCapture(machine, ProjectShare.unmountRequest(current.path))
            guard result.report == ExitReport(status: 0) else {
                throw AgentVMError.supervisorRefused("\(current.path) is still in use in box \(box.name) (\(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))); end the programs using it first")
            }
            state.setProject(nil)
            try machine.share(tag: ProjectShare.tag, directory: nil, readOnly: false)
            log("Unshared \(current.path)")
            // While the previous project was mounted the guest could change folders on the
            // new one's path (a symlink swapped in); it has no access now, so resolve again.
            guard try ProjectShare.validated(path, storeRoot: storeRoot) == project else {
                throw AgentVMError.unsuitableProject(path: project, reason: "its path changed while the previous project was being unshared")
            }
        }
        try machine.share(tag: ProjectShare.tag, directory: URL(fileURLWithPath: project, isDirectory: true), readOnly: readOnly)
        var mountTried = false
        do {
            let requests = ProjectShare.mountRequests(project)
            try await guestRun(machine, requests[0])
            let found = try await guestCapture(machine, ProjectShare.parentContentsRequest(project))
            let first = found.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard found.report == ExitReport(status: 0), first.isEmpty else {
                let parent = (project as NSString).deletingLastPathComponent
                let what = first.isEmpty ? "cannot be examined (\(found.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))" : "already holds \(first)"
                throw AgentVMError.unsuitableProject(path: project, reason: "\(parent) in the box \(what), which the share would hide; share a folder whose parent is new or empty in the box")
            }
            mountTried = true
            try await guestRun(machine, requests[1])
        } catch {
            // Leave nothing mounted. If the guest cannot confirm that, keep the share recorded
            // so the next request unmounts it first (the unmount succeeds when nothing is there).
            // Before the mount the parent may be some other mount point: leave it alone.
            let unmounted = mountTried ? try? await guestCapture(machine, ProjectShare.unmountRequest(project)) : nil
            if !mountTried || unmounted?.report == ExitReport(status: 0) {
                try? machine.share(tag: ProjectShare.tag, directory: nil, readOnly: false)
            } else {
                state.setProject((project, readOnly))
            }
            throw error
        }
        state.setProject((project, readOnly))
        log("Shared \(project)\(readOnly ? " (read only)" : "")")
    }

    /// Runs one guest request; throws unless it exits with status 0.
    private func guestRun(_ machine: MacMachine, _ request: GuestRequest) async throws {
        let result = try await guestCapture(machine, request)
        guard result.report == ExitReport(status: 0) else {
            throw AgentVMError.guestCommandFailed(command: request.argv?.joined(separator: " ") ?? "?", status: result.report.shellStatus,
                                                  output: (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Runs one guest request to the end on a fresh vsock connection, off the main actor.
    private func guestCapture(_ machine: MacMachine, _ request: GuestRequest) async throws -> (report: ExitReport, stdout: String, stderr: String) {
        let connection = try await machine.connect(toPort: GuestProtocol.port)
        defer { connection.close() }
        let descriptor = connection.descriptor
        Self.setReadTimeout(descriptor, seconds: 60)
        return try await Task.detached { try GuestClient.capture(descriptor, request) }.value
    }

    /// Applies the network mode inside the guest (address, DNS, system proxy) as root.
    private func configureNetwork(_ machine: MacMachine, mode: BoxNetwork.Mode) async throws {
        let connection = try await machine.connect(toPort: GuestProtocol.port)
        defer { connection.close() }
        let descriptor = connection.descriptor
        Self.setReadTimeout(descriptor, seconds: 60)
        let request = GuestRequest(op: .exec, argv: ["/bin/sh", "-c", GuestNetworkSetup.command(for: mode)], user: "root")
        let result = try await Task.detached { try GuestClient.capture(descriptor, request) }.value
        guard result.report == ExitReport(status: 0) else {
            throw AgentVMError.guestCommandFailed(command: "network setup", status: result.report.shellStatus, output: (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        log("Network: \(mode.rawValue)\(mode == .open ? " (NAT)" : " (dead-end card, proxy on vsock port \(GuestRelay.hostPort))")")
    }

    private func shutDown(_ machine: MacMachine) async {
        state.set(.stopping, guestVersion: nil)
        log("Shutting down")
        if let connection = try? await machine.connect(toPort: GuestProtocol.port) {
            let descriptor = connection.descriptor
            Self.setReadTimeout(descriptor, seconds: 10)
            _ = try? await Task.detached { try GuestClient.shutdown(descriptor) }.value
            connection.close()
        }
        if await machine.waitUntilStopped(timeout: Self.shutdownTimeout) {
            log("Stopped")
            return
        }
        log("The guest did not shut down within \(Self.shutdownTimeout); pulling the plug")
        try? await machine.forceStop()
    }

    private func installSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [state] in
                state.requestStop()
            }
            source.resume()
            signalSources.append(source)
        }
    }

    nonisolated static func setReadTimeout(_ descriptor: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
}

/// The supervisor's state as the control threads see it.
final class SupervisorState: @unchecked Sendable {
    private let lock = NSLock()
    private var current: ControlResponse.State = .starting
    private var guest: String?
    private var stopping = false
    private var shared: (path: String, readOnly: Bool)?
    private var claims = 0

    /// Programs (execs) running on the shared project; while any do, it is not switched.
    var projectClaims: Int {
        lock.lock()
        defer { lock.unlock() }
        return claims
    }

    func claimProject() {
        lock.lock()
        claims += 1
        lock.unlock()
    }

    func releaseProject() {
        lock.lock()
        claims = max(0, claims - 1)
        lock.unlock()
    }

    var project: (path: String, readOnly: Bool)? {
        lock.lock()
        defer { lock.unlock() }
        return shared
    }

    func setProject(_ project: (path: String, readOnly: Bool)?) {
        lock.lock()
        shared = project
        lock.unlock()
    }

    func set(_ state: ControlResponse.State, guestVersion: String?) {
        lock.lock()
        defer { lock.unlock() }
        current = state
        if let guestVersion {
            guest = guestVersion
        }
    }

    var snapshot: (state: ControlResponse.State, guestVersion: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (current, guest)
    }

    func requestStop() {
        lock.lock()
        defer { lock.unlock() }
        stopping = true
    }

    var stopRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopping
    }
}

/// Answers the control socket for a running supervisor.
final class SupervisorControl: ControlHandler, @unchecked Sendable {
    private let state: SupervisorState
    /// Main-actor isolated; used only from the MainActor task below.
    private let machine: MacMachine
    private let box: Box
    private let proxy: ProxyServer
    private let share: @Sendable @MainActor (String, Bool, Bool) async throws -> Void

    init(state: SupervisorState, machine: MacMachine, box: Box, proxy: ProxyServer,
         share: @escaping @Sendable @MainActor (String, Bool, Bool) async throws -> Void) {
        self.state = state
        self.machine = machine
        self.box = box
        self.proxy = proxy
        self.share = share
    }

    /// Shares a project on the main actor; blocks this control thread (at most 5 minutes:
    /// up to four guest commands of at most 60 s each).
    func controlShare(path: String, readOnly: Bool) throws {
        try shareBlocking(path: path, readOnly: readOnly, claim: false)
    }

    private func shareBlocking(path: String, readOnly: Bool, claim: Bool) throws {
        let result = ShareResult()
        let done = DispatchSemaphore(value: 0)
        let share = self.share
        Task { @MainActor in
            do {
                try await share(path, readOnly, claim)
                result.set(nil)
            } catch {
                result.set(error)
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + 300) == .success else {
            throw AgentVMError.guestUnreachable("sharing \(path) timed out")
        }
        if let error = result.error {
            throw error
        }
    }

    /// Rereads the network rules from box.json; a mode change needs a restart.
    func controlReload() throws {
        let fresh = try BoxStore(root: box.directory.deletingLastPathComponent().deletingLastPathComponent()).box(named: box.name)
        let network = fresh.record.effectiveNetwork
        guard network.mode == box.record.effectiveNetwork.mode else {
            throw AgentVMError.boxRunning(box.name)
        }
        proxy.update(try CompiledPolicy(network))
    }

    func controlStatus() -> ControlResponse {
        let snapshot = state.snapshot
        let project = state.project
        return ControlResponse(ok: true, state: snapshot.state, guestVersion: snapshot.guestVersion, pid: getpid(),
                               project: project?.path, projectReadOnly: project?.readOnly)
    }

    /// Opens a vsock connection on the main actor and lends its descriptor. Blocks this
    /// control thread (never the main actor) for at most 30 seconds.
    /// With `project`, shares it first and claims it for the connection's lifetime.
    func controlOpenGuest(project: String?, readOnly: Bool) throws -> LentConnection {
        guard state.snapshot.state == .ready, !state.stopRequested else {
            throw AgentVMError.supervisorRefused("box \(box.name) is \(state.snapshot.state.rawValue), not ready")
        }
        if let project {
            try shareBlocking(path: project, readOnly: readOnly, claim: true)
        }
        let state = self.state
        do {
            let lent = try openConnection()
            guard project != nil else {
                return lent
            }
            return LentConnection(descriptor: lent.descriptor, release: {
                lent.release()
                state.releaseProject()
            })
        } catch {
            if project != nil {
                state.releaseProject()
            }
            throw error
        }
    }

    private func openConnection() throws -> LentConnection {
        let result = OpenResult()
        let done = DispatchSemaphore(value: 0)
        let machine = self.machine
        Task { @MainActor in
            do {
                result.set(.success(try await machine.connect(toPort: GuestProtocol.port)))
            } catch {
                result.set(.failure(error))
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + 30) == .success, let outcome = result.value else {
            throw AgentVMError.guestUnreachable("opening a connection to the guest daemon timed out")
        }
        let connection = try outcome.get()
        return LentConnection(descriptor: connection.descriptor, release: { connection.close() })
    }

    func controlStop() {
        state.requestStop()
    }
}

private final class ShareResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?

    func set(_ error: Error?) {
        lock.lock()
        stored = error
        lock.unlock()
    }

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private final class OpenResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<GuestConnection, Error>?

    func set(_ value: Result<GuestConnection, Error>) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    var value: Result<GuestConnection, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// Starts a box's supervisor as a detached process and waits until the box is ready.
public enum BoxLauncher {
    /// Spawns `executable box serve <name>` in its own session, output appended to the box's
    /// supervisor.log, and waits (up to `timeout`) until it reports ready. Returns its status.
    public static func start(_ box: Box, executable: String, timeout: Duration = .seconds(200),
                             progress: (String) -> Void) throws -> ControlResponse {
        if box.isRunning {
            // Another start is under way (or done): wait for it rather than fail.
            return try waitUntilReady(box, supervisor: nil, timeout: timeout, progress: progress)
        }
        let logDescriptor = open(box.logURL.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard logDescriptor >= 0 else {
            throw AgentVMError.system(operation: "open \(box.logURL.path)", code: errno)
        }
        defer { close(logDescriptor) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, logDescriptor, 1)
        posix_spawn_file_actions_adddup2(&actions, logDescriptor, 2)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var pid: pid_t = 0
        let arguments = ["agent-vm", "box", "serve", box.name]
        let status = GuestServer.withCStrings(arguments) { argv in
            posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
        }
        guard status == 0 else {
            throw AgentVMError.system(operation: "start the supervisor \(executable)", code: status)
        }

        return try waitUntilReady(box, supervisor: pid, timeout: timeout, progress: progress)
    }

    /// Polls the supervisor until the box is ready. With `supervisor` (our own child), its
    /// exit ends the wait; without, a released lock does.
    private static func waitUntilReady(_ box: Box, supervisor pid: pid_t?, timeout: Duration,
                                       progress: (String) -> Void) throws -> ControlResponse {
        let deadline = ContinuousClock.now + timeout
        var lastState: ControlResponse.State?
        while ContinuousClock.now < deadline {
            if let pid {
                var exitStatus: Int32 = 0
                if waitpid(pid, &exitStatus, WNOHANG) == pid {
                    let status = GuestServer.report(exitStatus).shellStatus
                    if status == 0 {
                        throw AgentVMError.guestUnreachable("box \(box.name) was stopped before it became ready")
                    }
                    throw AgentVMError.guestUnreachable("the supervisor exited (status \(status)); see \(box.logURL.path)")
                }
            } else if !box.isRunning {
                throw AgentVMError.guestUnreachable("box \(box.name) stopped before it became ready; see \(box.logURL.path)")
            }
            if let response = try? ControlClient.request(.status, path: box.controlSocketPath), response.ok {
                if response.state != lastState, let state = response.state {
                    lastState = state
                    progress(state.rawValue)
                }
                if response.state == .ready {
                    return response
                }
            }
            usleep(500_000)
        }
        throw AgentVMError.guestUnreachable("the box did not become ready within \(timeout); see \(box.logURL.path)")
    }

    /// Asks the supervisor to stop and waits until it has released the box.
    public static func stop(_ box: Box, timeout: Duration = .seconds(120)) throws {
        guard box.isRunning else {
            throw AgentVMError.boxNotRunning(box.name)
        }
        _ = try ControlClient.request(.stop, path: box.controlSocketPath)
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if !box.isRunning {
                return
            }
            usleep(250_000)
        }
        throw AgentVMError.guestUnreachable("box \(box.name) did not stop within \(timeout); see \(box.logURL.path)")
    }
}
