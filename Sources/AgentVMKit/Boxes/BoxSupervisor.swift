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

        let spec = MacMachineSpec(cpuCount: box.record.cpuCount, memoryBytes: box.record.memoryBytes, macAddress: box.record.macAddress)
        let configuration = try spec.configuration(for: box.machineFiles, auxiliaryStorage: VZMacAuxiliaryStorage(url: box.auxiliaryStorageURL))
        let machine = MacMachine(configuration: configuration)
        self.machine = machine

        let handler = SupervisorControl(state: state, machine: machine)
        let server = try ControlServer(path: box.controlSocketPath, handler: handler)
        defer { server.close() }
        installSignalHandlers()

        log("Starting box \(box.name) (\(box.record.cpuCount) CPUs, \(box.record.memoryBytes >> 30) GB, image \(box.record.image))")
        try await machine.start(provisioning: nil)

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

    init(state: SupervisorState, machine: MacMachine) {
        self.state = state
        self.machine = machine
    }

    func controlStatus() -> ControlResponse {
        let snapshot = state.snapshot
        return ControlResponse(ok: true, state: snapshot.state, guestVersion: snapshot.guestVersion, pid: getpid())
    }

    /// Opens a vsock connection on the main actor and lends its descriptor. Blocks this
    /// control thread (never the main actor) for at most 30 seconds.
    func controlOpenGuest() throws -> LentConnection {
        guard state.snapshot.state == .ready, !state.stopRequested else {
            throw AgentVMError.guestRefused("the box is \(state.snapshot.state.rawValue), not ready")
        }
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
