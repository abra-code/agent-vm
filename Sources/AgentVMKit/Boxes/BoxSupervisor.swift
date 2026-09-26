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

    /// Whether this process runs AppKit and can show the box's screen (`box view`).
    private let windows: Bool
    private var viewer: BoxViewer?
    /// The process whose exit stops the box (`box start --owner-pid`), and its watch.
    private let ownerPid: Int32?
    private var ownerWatch: OwnerWatch?

    /// `windows`: the caller runs NSApplication on the main thread (see BoxViewer).
    public init(box: Box, windows: Bool = false, ownerPid: Int32? = nil, log: @escaping @MainActor (String) -> Void) {
        self.box = box
        self.windows = windows
        self.ownerPid = ownerPid
        self.log = log
    }

    /// Whether a supervisor started here could show windows (a login session, not SSH).
    public nonisolated static var canShowWindows: Bool {
        return BoxViewer.canShowWindows
    }

    /// Stops the box cleanly, as `box stop` and SIGTERM do.
    public func requestStop() {
        state.requestStop()
    }

    private func view(interactive: Bool) throws {
        guard windows else {
            throw AgentVMError.supervisorRefused("box \(box.name) runs outside a login session (started over SSH or by a service), so it cannot show a window; stop it and start it again from a session on this Mac's screen")
        }
        guard let machine, state.snapshot.state != .stopping, !state.stopRequested else {
            throw AgentVMError.boxNotRunning(box.name)
        }
        let password = try? String(contentsOf: box.passwordURL, encoding: .utf8)
        let firstShow = self.viewer == nil
        let viewer = self.viewer ?? BoxViewer(name: box.name, machine: machine, password: password)
        self.viewer = viewer
        viewer.show(interactive: interactive)
        log("Showing the screen\(interactive ? " (interactive)" : " (view only)")")
        // The screen saver and screen lock are per machine, so a box starts with them on
        // (GuestDesktop): off while someone may be looking, without holding up the window.
        if firstShow, let password {
            let user = box.record.userName
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                do {
                    let note = try await GuestDesktop.keepUnlocked(user: user, password: password, desktopWait: 5, run: Self.guestRunner(machine))
                    self.log(note.map { "Screen lock: \($0)" } ?? "Screen lock, screen saver and display sleep off")
                } catch {
                    self.log("Screen lock: \(error)")
                }
            }
        }
    }

    /// Types the box password (or `text`) into the open window's focused field in the guest.
    private func type(text: String?) async throws {
        guard let viewer else {
            throw AgentVMError.supervisorRefused("box \(box.name) shows no window; open one with `agent-vm box view \(box.name) --interactive`")
        }
        // As the Type Password button: a view-only window takes no input, typed or not.
        guard viewer.isInteractive else {
            throw AgentVMError.supervisorRefused("the window of box \(box.name) is view only; open it with `agent-vm box view \(box.name) --interactive` to type")
        }
        if let text {
            try await viewer.type(text)
            log("Typed \(text.count) characters into the screen")
        } else {
            let password = try String(contentsOf: box.passwordURL, encoding: .utf8)
            try await viewer.type(password)
            log("Typed the password into the screen")
        }
    }

    /// Runs the box until it stops; returns when the VM is down and the socket is gone.
    public func run() async throws {
        guard let lock = try FolderLock.tryAcquire(box.lockPath, patience: FolderLock.testPatience) else {
            throw AgentVMError.boxRunning(box.name)
        }
        defer { lock.release() }
        // A delete that ran while this supervisor was starting removed the folder's files, and
        // taking the lock made a new lock file in what is left: take that away again, so the
        // delete (or the next one) can finish, and do not start a box that is gone.
        guard FileSystem.exists(box.directory.appendingPathComponent(BoxStore.recordName).path) else {
            unlink(box.lockPath)
            rmdir(box.directory.path)
            throw AgentVMError.boxNotFound(box.name)
        }
        // Checked under the lock: a disposable box that stopped is only ever deleted.
        guard !box.isTombstoned else {
            throw AgentVMError.boxDisposed(box.name)
        }
        // However it stops (asked, its owner gone, a failed boot), a disposable box leaves a
        // tombstone for `box gc`, written before the lock is released. The folder stays: the
        // lock, the socket and this log live in it.
        defer {
            if box.record.disposable == true {
                let text = "stopped \(ISO8601DateFormatter().string(from: Date()))\n"
                if (try? Data(text.utf8).write(to: box.tombstoneURL)) == nil {
                    log("Could not leave the tombstone of this disposable box at \(box.tombstoneURL.path)")
                }
            }
        }

        let network = box.record.effectiveNetwork
        let packs = try NetworkPacks.needed(for: network, store: box.directory.deletingLastPathComponent().deletingLastPathComponent())
        let proxy = ProxyServer(policy: try CompiledPolicy(network, packs: packs), log: NetworkLog(url: box.networkLogURL))
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
        } view: { [weak self] interactive in
            guard let self else {
                throw AgentVMError.boxNotRunning(name)
            }
            try self.view(interactive: interactive)
        } type: { [weak self] text in
            guard let self else {
                throw AgentVMError.boxNotRunning(name)
            }
            try await self.type(text: text)
        } syncClock: { [weak self] in
            guard let self else {
                throw AgentVMError.boxNotRunning(name)
            }
            return try await self.syncClock(reason: "asked")
        }
        let server = try ControlServer(path: box.controlSocketPath, handler: handler)
        defer { server.close() }
        installSignalHandlers()
        if let ownerPid {
            state.setOwner(ownerPid)
            log("Owner: process \(ownerPid); the box stops when it exits")
            // Called on the main queue, so on the main actor.
            ownerWatch = OwnerWatch(pid: ownerPid, queue: .main) { [state, log] in
                state.requestStop()
                MainActor.assumeIsolated {
                    log("The owner process \(ownerPid) exited; stopping")
                }
            }
        }
        defer { ownerWatch?.cancel() }

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
        state.set(.ready, guestVersion: hello.version, guestFeatures: hello.features ?? [])
        log("Ready in \(Int(ImageBuilder.seconds(clock.now - began))) s: agent-vm-guest \(hello.version ?? "?")")
        prepareDesktop(machine, features: hello.features ?? [])
        let clockSync = (hello.features ?? []).contains(GuestFeature.timeSync)
        if clockSync {
            _ = try? await syncClock(reason: "boot")
        } else {
            log("Clock: this agent-vm-guest cannot set the guest's clock (update the image with `agent-vm image update-guest \(box.record.image)`)")
        }

        // Until the guest stops by itself or a stop is requested. The guest's clock is set every
        // few minutes, and at once after the Mac slept: a suspending clock stops during sleep,
        // a continuous one does not, so their difference grows by the time slept.
        var lastSync = ContinuousClock.now
        var continuousMark = ContinuousClock.now
        var suspendingMark = SuspendingClock.now
        while machine.isRunning && !state.stopRequested {
            try? await Task.sleep(for: .milliseconds(250))
            guard clockSync else {
                continue
            }
            let continuousNow = ContinuousClock.now
            let suspendingNow = SuspendingClock.now
            let slept = (continuousNow - continuousMark) - (suspendingNow - suspendingMark)
            continuousMark = continuousNow
            suspendingMark = suspendingNow
            if (slept > Self.sleepThreshold || continuousNow - lastSync >= Self.clockSyncInterval) && !clockSyncing {
                lastSync = continuousNow
                // In a task of its own, one at a time: a guest slow to answer must not keep this
                // loop from seeing a stop (or the owner's exit) for its 10 s read timeout.
                clockSyncing = true
                let reason = slept > Self.sleepThreshold ? "wake" : "interval"
                Task { @MainActor [weak self] in
                    _ = try? await self?.syncClock(reason: reason)
                    self?.clockSyncing = false
                }
            }
        }
        if machine.isRunning {
            await shutDown(machine)
        } else {
            log("The guest stopped\(machine.failure.map { ": \($0)" } ?? "")")
        }
    }

    /// The box's name as its wallpaper, and on its first start hidden widgets (GuestDesktop), in
    /// the background: the box is ready without it, and the desktop comes up a little later.
    private func prepareDesktop(_ machine: MacMachine, features: [String]) {
        let record = box.record
        Task { @MainActor [weak self] in
            do {
                let lines = try await GuestDesktop.prepare(user: record.userName, png: try GuestWallpaper.png(for: record),
                                                           features: features, widgetsOnce: true, run: Self.guestRunner(machine))
                for line in lines {
                    self?.log("Desktop: \(line)")
                }
            } catch {
                self?.log("Desktop: \(error)")
            }
        }
    }

    /// Guest requests on `machine`, with stdin, each on a fresh vsock connection (GuestDesktop).
    private static func guestRunner(_ machine: MacMachine) -> GuestDesktop.Run {
        return { request, input in
            let connection = try await machine.connect(toPort: GuestProtocol.port)
            defer { connection.close() }
            let descriptor = connection.descriptor
            setReadTimeout(descriptor, seconds: 60)
            return try await Task.detached { try GuestClient.capture(descriptor, request, input: input) }.value
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

    /// A periodic clock sync is under way.
    private var clockSyncing = false

    /// How often the guest's clock is set while the box runs, and how long a sleep of the Mac
    /// must have been to set it at once.
    static let clockSyncInterval: Duration = .seconds(300)
    static let sleepThreshold: Duration = .seconds(5)

    /// Sets the guest's clock to this Mac's; returns how far it was behind (negative: ahead).
    /// Logged at boot and when asked, otherwise only when it was a second or more off.
    func syncClock(reason: String) async throws -> Double {
        // Not once a stop is asked for: the loop's last tick would otherwise delay the shutdown.
        guard let machine, state.snapshot.state == .ready, !state.stopRequested else {
            throw AgentVMError.supervisorRefused("box \(box.name) is not ready")
        }
        guard state.snapshot.guestFeatures.contains(GuestFeature.timeSync) else {
            throw AgentVMError.supervisorRefused("the agent-vm-guest of box \(box.name) cannot set its clock; update its image with `agent-vm image update-guest \(box.record.image)` and create the box again")
        }
        do {
            let connection = try await machine.connect(toPort: GuestProtocol.port)
            defer { connection.close() }
            let descriptor = connection.descriptor
            Self.setReadTimeout(descriptor, seconds: 10)
            let offset = try await Task.detached { try GuestClient.syncTime(descriptor) }.value
            if reason != "interval" || abs(offset) >= 1 {
                let direction = offset >= 0 ? "behind" : "ahead"
                log(String(format: "Clock: set the guest's time (%@; it was %.1f s %@)", reason, abs(offset), direction))
            }
            return offset
        } catch {
            log("Clock: could not set the guest's time (\(reason)): \(error)")
            throw error
        }
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
    private var features: [String] = []
    private var stopping = false
    private var shared: (path: String, readOnly: Bool)?
    private var claims = 0
    private var execs = 0
    private var owner: Int32?

    /// The process whose exit stops the box, if any.
    var ownerPid: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return owner
    }

    func setOwner(_ pid: Int32) {
        lock.lock()
        owner = pid
        lock.unlock()
    }

    /// When the supervisor started, in whole seconds (as the store's records keep dates).
    let startedAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))

    /// Guest connections lent to clients (exec, box shell) and not yet given back.
    var activeExecs: Int {
        lock.lock()
        defer { lock.unlock() }
        return execs
    }

    func execOpened() {
        lock.lock()
        execs += 1
        lock.unlock()
    }

    func execClosed() {
        lock.lock()
        execs = max(0, execs - 1)
        lock.unlock()
    }

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

    func set(_ state: ControlResponse.State, guestVersion: String?, guestFeatures: [String]? = nil) {
        lock.lock()
        defer { lock.unlock() }
        current = state
        if let guestVersion {
            guest = guestVersion
        }
        if let guestFeatures {
            features = guestFeatures
        }
    }

    var snapshot: (state: ControlResponse.State, guestVersion: String?, guestFeatures: [String]) {
        lock.lock()
        defer { lock.unlock() }
        return (current, guest, features)
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
    private let view: @Sendable @MainActor (Bool) throws -> Void
    private let type: @Sendable @MainActor (String?) async throws -> Void
    private let syncClock: @Sendable @MainActor () async throws -> Double

    init(state: SupervisorState, machine: MacMachine, box: Box, proxy: ProxyServer,
         share: @escaping @Sendable @MainActor (String, Bool, Bool) async throws -> Void,
         view: @escaping @Sendable @MainActor (Bool) throws -> Void,
         type: @escaping @Sendable @MainActor (String?) async throws -> Void,
         syncClock: @escaping @Sendable @MainActor () async throws -> Double) {
        self.syncClock = syncClock
        self.view = view
        self.type = type
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

    /// Types into the box's window on the main actor; blocks this control thread for at most 60 s.
    func controlType(text: String?) throws {
        let result = ShareResult()
        let done = DispatchSemaphore(value: 0)
        let type = self.type
        Task { @MainActor in
            do {
                try await type(text)
                result.set(nil)
            } catch {
                result.set(error)
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + 60) == .success else {
            throw AgentVMError.supervisorRefused("typing into box \(box.name) timed out")
        }
        if let error = result.error {
            throw error
        }
    }

    /// Sets the guest's clock on the main actor; blocks this control thread for at most 30 s.
    func controlSyncClock() throws -> Double {
        let result = ClockResult()
        let done = DispatchSemaphore(value: 0)
        let syncClock = self.syncClock
        Task { @MainActor in
            do {
                result.set(.success(try await syncClock()))
            } catch {
                result.set(.failure(error))
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + 30) == .success, let outcome = result.value else {
            throw AgentVMError.supervisorRefused("setting the clock of box \(box.name) timed out")
        }
        return try outcome.get()
    }

    /// Shows the box's screen on the main actor; blocks this control thread for at most 30 s.
    func controlView(interactive: Bool) throws {
        let result = ShareResult()
        let done = DispatchSemaphore(value: 0)
        let view = self.view
        Task { @MainActor in
            do {
                try view(interactive)
                result.set(nil)
            } catch {
                result.set(error)
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + 30) == .success else {
            throw AgentVMError.supervisorRefused("showing the screen of box \(box.name) timed out")
        }
        if let error = result.error {
            throw error
        }
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

    /// The store the box is in (Boxes/<name> under it).
    private var storeRoot: URL {
        return box.directory.deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Rereads the network rules from box.json; a mode change needs a restart.
    func controlReload() throws {
        let fresh = try BoxStore(root: storeRoot).box(named: box.name)
        let network = fresh.record.effectiveNetwork
        guard network.mode == box.record.effectiveNetwork.mode else {
            throw AgentVMError.boxRunning(box.name)
        }
        // The packs are read again too, so an edited pack applies with the rules.
        proxy.update(try CompiledPolicy(network, packs: try NetworkPacks.needed(for: network, store: storeRoot)))
    }

    func controlStatus() -> ControlResponse {
        let snapshot = state.snapshot
        let project = state.project
        return ControlResponse(ok: true, state: snapshot.state, guestVersion: snapshot.guestVersion, pid: getpid(),
                               project: project?.path, projectReadOnly: project?.readOnly, guestFeatures: snapshot.guestFeatures,
                               supervisorVersion: AgentVM.version, supervisorPath: Self.executablePath, startedAt: state.startedAt,
                               activeExecs: state.activeExecs, ownerPid: state.ownerPid)
    }

    /// This process's executable, as it was started (a rebuild renames a new file into place,
    /// so the file at this path may since be a newer agent-vm).
    static let executablePath = Bundle.main.executableURL?.resolvingSymlinksInPath().path

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
            state.execOpened()
            let claimed = project != nil
            return LentConnection(descriptor: lent.descriptor, release: {
                lent.release()
                state.execClosed()
                if claimed {
                    state.releaseProject()
                }
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

private final class ClockResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Double, Error>?

    func set(_ value: Result<Double, Error>) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    var value: Result<Double, Error>? {
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
    /// `ownerPid`: the process whose exit stops the box; ignored when the box already runs
    /// (its status names the owner it has).
    public static func start(_ box: Box, executable: String, ownerPid: Int32? = nil, timeout: Duration = .seconds(200),
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
        // The full path as argv[0], so a process list tells which binary runs the box.
        let arguments = [executable, "box", "serve", box.name] + (ownerPid.map { ["--owner-pid", String($0)] } ?? [])
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
