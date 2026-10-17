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
    /// As `run` read it under the box's lock; before that, as the caller read it.
    public private(set) var box: Box
    private let log: @MainActor (String) -> Void
    private let state = SupervisorState()
    private var machine: GuestMachine?
    private var signalSources: [DispatchSourceSignal] = []
    /// The dead-end network card's host end (allowlist and off modes).
    private var link: DeadEndLink?

    /// How long the guest may take to boot until its daemon answers, and to shut down.
    static let bootTimeout: Duration = .seconds(180)
    static let shutdownTimeout: Duration = .seconds(90)
    /// A Linux box's daemon answers within 3 s of the start (measured); a minute is for a
    /// loaded Mac. Its shutdown has a second way: the power button, which Linux obeys.
    static let linuxBootTimeout: Duration = .seconds(60)
    static let linuxShutdownTimeout: Duration = .seconds(45)
    static let linuxPowerButtonTimeout: Duration = .seconds(15)

    /// What a Linux guest prints on its console (ConsoleLog); a macOS box has none.
    private var console: ConsoleLog?

    private var guest: GuestKind {
        return box.record.effectiveGuest
    }

    private var bootLimit: Duration {
        return guest == .linux ? Self.linuxBootTimeout : Self.bootTimeout
    }

    /// Whether this process runs AppKit and can show the box's screen (`box view`).
    private let windows: Bool
    private var viewer: BoxViewer?
    /// The process whose exit stops the box (`box start --owner-pid`), and its watch.
    private let ownerPid: Int32?
    /// When the owner started, as `box start` saw it (`OwnerWatch.startTime`).
    private let ownerStartedAt: String?
    private var ownerWatch: OwnerWatch?

    /// `windows`: the caller runs NSApplication on the main thread (see BoxViewer).
    public init(box: Box, windows: Bool = false, ownerPid: Int32? = nil, ownerStartedAt: String? = nil,
                log: @escaping @MainActor (String) -> Void) {
        self.box = box
        self.windows = windows
        self.ownerPid = ownerPid
        self.ownerStartedAt = ownerStartedAt
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
        try box.record.requireScreen()
        guard windows else {
            throw AgentVMError.supervisorRefused("box \(box.name) runs outside a login session (started over SSH or by a service), so it cannot show a window; stop it and start it again from a session on this Mac's screen")
        }
        guard let machine, state.snapshot.state != .stopping, !state.stopRequested else {
            throw AgentVMError.boxNotRunning(box.name)
        }
        // The password is read when it is needed, and never on the main actor, which runs the
        // VM: from the Keychain, the read waits when macOS asks the person about it.
        let box = self.box
        let firstShow = self.viewer == nil
        // A Linux box's account has no password, so its window has no Type Password button.
        let password: (@Sendable () throws -> String)? = box.record.effectiveGuest == .linux ? nil : { @Sendable in try box.accountPassword() }
        let viewer = self.viewer ?? BoxViewer(name: box.name, machine: machine, guest: box.record.effectiveGuest, password: password, log: { [weak self] in self?.log($0) },
                                                  sent: { [weak self] item in self?.note(.init(.send, items: [item])) })
        self.viewer = viewer
        viewer.show(interactive: interactive)
        log("Showing the screen\(interactive ? " (interactive)" : " (view only)")")
        note(.init(.view, interactive: interactive))
        // The screen saver and screen lock are per machine, so a box starts with them on
        // (GuestDesktop): off while someone may be looking, without holding up the window.
        // A Linux desktop is set up by its recipe never to lock or blank.
        if firstShow, box.record.effectiveGuest == .macOS {
            let user = box.record.userName
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                do {
                    let password = try await Task.detached { try box.accountPassword() }.value
                    let note = try await GuestDesktop.keepUnlocked(user: user, password: password, desktopWait: 5, run: Self.guestRunner(machine))
                    self.log(note.map { "Screen lock: \($0)" } ?? "Screen lock, screen saver and display sleep off")
                } catch {
                    self.log("Screen lock: \(error)")
                }
            }
        }
    }

    /// Writes one line of the box's event log (BoxEventLog). A line that cannot be written is
    /// said in the supervisor's own log and holds nothing up.
    private func note(_ event: BoxEventLog.Event) {
        if let problem = BoxEventLog(url: box.eventsLogURL).append(event) {
            log("Event log: \(event.event.rawValue) not recorded (\(problem))")
        }
    }

    /// Whether the start under way has its `stop` line: each start gets one, however it ends.
    private var stopNoted = true
    /// Why the box is being stopped, when nobody asked for it: its owner process exited.
    private var stopReason: String?

    private func noteStop(_ detail: String? = nil) {
        guard !stopNoted else {
            return
        }
        stopNoted = true
        note(.init(.stop, detail: detail ?? stopReason))
    }

    /// Types the box password (or `text`) into the open window's focused field in the guest.
    private func type(text: String?) async throws {
        try box.record.requireScreen()
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
            note(.init(.type, characters: text.count))
        } else {
            try box.record.requirePassword()
            let box = self.box
            let password = try await Task.detached { try box.accountPassword() }.value
            try await viewer.type(password)
            log("Typed the password into the screen")
            note(.init(.type, password: true))
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
        // The record as it is now: `box set` or `box network` may have changed it between the
        // caller's read and this lock, and the box must run as its record says.
        box = try BoxStore.reread(box)
        // Checked under the lock: a disposable box that stopped is only ever deleted.
        guard !box.isTombstoned else {
            throw AgentVMError.boxDisposed(box.name)
        }
        // However it stops once its VM ran (asked, its owner gone, a failed boot), a disposable
        // box leaves a tombstone for `box gc`, written before the lock is released. The folder
        // stays: the lock, the socket and this log live in it. A VM that never started (no free
        // VM slot) changed nothing, so the box can be started again; box gc still collects it
        // once it is old enough.
        var ran = false
        defer {
            if box.record.disposable == true && ran {
                let text = "stopped \(ISO8601DateFormatter().string(from: Date()))\n"
                if (try? Data(text.utf8).write(to: box.tombstoneURL)) == nil {
                    log("Could not leave the tombstone of this disposable box at \(box.tombstoneURL.path)")
                }
            }
        }

        let network = box.record.effectiveNetwork
        let packs = try NetworkPacks.needed(for: network, store: box.directory.deletingLastPathComponent().deletingLastPathComponent())
        let proxy = ProxyServer(policy: try CompiledPolicy(network, packs: packs), log: NetworkLog(url: box.networkLogURL))
        let attachment: MachineNetwork
        if !network.usesProxy {
            attachment = .nat
        } else if guest == .linux {
            // No card at all: programs reach the proxy through the daemon's relay, and a
            // Linux system is content without a network device.
            attachment = .none
        } else {
            let link = try DeadEndLink()
            self.link = link
            attachment = .fileHandle(link.guestHandle)
        }
        var extras = LinuxMachineExtras()
        if guest == .linux {
            let console = try ConsoleLog(url: box.consoleLogURL)
            self.console = console
            extras.console = console.writeHandle
        }
        // After the machine stopped, on every way out of this function.
        defer {
            console?.close()
            console = nil
        }
        let machine = try MachineBuilder.machine(MachineShape(box.record), files: box.machineFiles, network: attachment, share: true, extras: extras)
        self.machine = machine

        let name = box.name
        let handler = SupervisorControl(state: state, machine: machine, box: box, proxy: proxy) { [weak self] path, readOnly, claim in
            guard let self else {
                throw AgentVMError.boxNotRunning(name)
            }
            return try await self.shareProject(path, readOnly: readOnly, claim: claim)
        } unshare: { [weak self] path, asked in
            guard let self else {
                throw AgentVMError.boxNotRunning(name)
            }
            if asked {
                try await self.unshareProject(path, asked: true)
            } else if let path {
                self.projectReleased(path)
            }
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
            ownerWatch = OwnerWatch(pid: ownerPid, startedAt: ownerStartedAt, queue: .main) { [weak self, state, log] in
                MainActor.assumeIsolated {
                    self?.stopReason = "the owner process \(ownerPid) exited"
                }
                state.requestStop()
                MainActor.assumeIsolated {
                    log("The owner process \(ownerPid) exited; stopping")
                }
            }
        }
        defer { ownerWatch?.cancel() }

        log("Starting box \(box.name) (\(box.record.cpuCount) CPUs, \(box.record.memoryBytes >> 30) GB, image \(box.record.image), network \(network.mode.rawValue))")
        note(.init(.start, detail: "image \(box.record.image), network \(network.mode.rawValue)"))
        stopNoted = false
        // A start that fails on a way with no line of its own below (the VM did not start).
        defer { noteStop("the start failed") }
        if guest == .linux {
            try await machine.start()
        } else {
            try await machine.start(provisioning: nil)
        }
        ran = true
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
                noteStop()
                try? await machine.forceStop()
                return
            }
            if console?.sawKernelPanic == true {
                log("The guest's kernel panicked while booting (the reason is at the end of \(box.consoleLogURL.path)); stopping the box")
                noteStop("the guest's kernel panicked while booting")
                try? await machine.forceStop()
                throw AgentVMError.guestUnreachable("the guest's kernel panicked while booting\(consoleTail())")
            }
            if !machine.isRunning {
                log("The guest stopped while booting\(machine.failure.map { ": \($0)" } ?? "")")
                noteStop("the guest stopped while booting\(machine.failure.map { ": \($0)" } ?? "")")
                throw AgentVMError.guestUnreachable("the guest stopped while booting\(machine.failure.map { ": \($0)" } ?? "")\(consoleTail())")
            }
            if let refusal = daemonRefusal {
                log("\(refusal); stopping")
                noteStop(refusal)
                try? await machine.forceStop()
                throw AgentVMError.guestRefused(refusal)
            }
            log("The guest daemon did not answer within \(bootLimit); stopping")
            noteStop("the guest daemon did not answer within \(bootLimit)")
            try? await machine.forceStop()
            // A small box is the likely reason; with the comfortable size, say nothing of it.
            let small = MachineSize.smallMemoryNote(memoryBytes: box.record.memoryBytes, guest: guest) == nil ? ""
                : "; a box of \(MachineSize.gigabytesText(box.record.memoryBytes)) GB may be too small: `agent-vm box set \(box.name) --memory-gb \(MachineSize.gigabytes(MachineSize.comfortableMemory(for: guest)))` gives it more"
            throw AgentVMError.guestUnreachable("the guest daemon did not answer within \(bootLimit)\(small)\(consoleTail())")
        }
        do {
            try await configureNetwork(machine, mode: network.mode)
        } catch {
            log("Cannot set up the guest's network (\(error)); stopping")
            await shutDown(machine)
            throw error
        }
        if guest == .linux {
            // The box's disk remembers the project its last run shared; nothing is shared now.
            // Before the box is ready, so that no share's own writing can come first.
            _ = try? await guestCapture(machine, ProjectShare.safeDirectoryRequest([]))
            // For images made before this was a file in the image (LinuxSetup.stopOnKernelFault).
            let told = try? await guestCapture(machine, LinuxSetup.stopOnKernelFaultRequest)
            if told?.report != ExitReport(status: 0) {
                log("Could not tell the guest's kernel to stop at its first fault; a fault may go on to damage the box's disk")
            }
        }
        state.set(.ready, guestVersion: hello.version, guestFeatures: hello.features ?? [])
        log("Ready in \(Int(ImageBuilder.seconds(clock.now - began))) s: agent-vm-guest \(hello.version ?? "?")")
        note(.init(.ready, detail: "agent-vm-guest \(hello.version ?? "?")"))
        if guest == .macOS {
            prepareDesktop(machine, features: hello.features ?? [])
        }
        let clockSync = (hello.features ?? []).contains(GuestFeature.timeSync)
        if clockSync, !state.stopRequested {
            _ = try? await syncClock(reason: "boot")
        } else {
            log("Clock: this agent-vm-guest cannot set the guest's clock (update the image with `agent-vm image update \(box.record.image) --guest`)")
        }

        // Until the guest stops by itself or a stop is requested. The guest's clock is set every
        // few minutes, and at once after the Mac slept: a suspending clock stops during sleep,
        // a continuous one does not, so their difference grows by the time slept.
        var lastSync = ContinuousClock.now
        var lastProgress = ContinuousClock.now
        var continuousMark = ContinuousClock.now
        var suspendingMark = SuspendingClock.now
        while machine.isRunning && !state.stopRequested {
            try? await Task.sleep(for: .milliseconds(250))
            if console?.sawKernelPanic == true {
                break
            }
            if !diskErrorsLogged, console?.sawDiskErrors == true {
                diskErrorsLogged = true
                log("The guest's file system reports errors (\(box.consoleLogURL.path)): the box's disk is damaged, and programs may be refused; `agent-vm box recreate \(box.name)` makes the box again")
            }
            let continuousNow = ContinuousClock.now
            if continuousNow - lastProgress >= ProxyServer.progressInterval {
                // The bytes of open connections, off this loop: the log is a file.
                lastProgress = continuousNow
                Task.detached { proxy.logProgress() }
            }
            guard clockSync else {
                continue
            }
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
        // Before the guest goes: a connection whose end is not logged in time keeps these bytes.
        proxy.logProgress()
        if console?.sawKernelPanic == true && machine.isRunning {
            // Also when a stop was asked for in the same moment. Nothing runs in the guest any more, and nothing in it would answer a shutdown.
            state.set(.stopping, guestVersion: nil)
            log("The guest's kernel panicked (the reason is at the end of \(box.consoleLogURL.path)); stopping the box")
            noteStop("the guest's kernel panicked")
            try? await machine.forceStop()
        } else if machine.isRunning {
            await shutDown(machine)
        } else {
            log("The guest stopped\(machine.failure.map { ": \($0)" } ?? "")")
            noteStop("the guest stopped\(machine.failure.map { ": \($0)" } ?? "")")
        }
    }

    /// The box's name as its wallpaper, and on its first start hidden widgets (GuestDesktop), in
    /// the background: the box is ready without it, and the desktop comes up a little later.
    private func prepareDesktop(_ machine: GuestMachine, features: [String]) {
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
    private static func guestRunner(_ machine: GuestMachine) -> GuestDesktop.Run {
        return { request, input in
            let connection = try await machine.connect(toPort: GuestProtocol.port)
            defer { connection.close() }
            let descriptor = connection.descriptor
            setReadTimeout(descriptor, seconds: 60)
            return try await Task.detached { try GuestClient.capture(descriptor, request, input: input, within: commandLimit) }.value
        }
    }

    /// Why a daemon that did answer is not this box's: it says it runs another system than
    /// the box's record does.
    private var daemonRefusal: String?

    /// How often the daemon is asked while a guest boots: a Linux box is up in under 3 s, and a
    /// poll once a second would round that up by a third.
    static let quickPoll: Duration = .milliseconds(200)
    static let quickPollTime: Duration = .seconds(10)

    /// The console's last lines, for the error of a Linux box that did not come up: a guest
    /// that does not boot has nothing else to show. The text is the guest's, made printable.
    private func consoleTail() -> String {
        guard guest == .linux else {
            return ""
        }
        let tail = ConsoleLog.tail(of: box.consoleLogURL, lines: 20)
        return tail.isEmpty ? "; its console printed nothing (\(box.consoleLogURL.path))" : "; the console's last lines (\(box.consoleLogURL.path)):\n\(tail)"
    }

    private func waitForDaemon(_ machine: GuestMachine) async -> GuestResponse? {
        let began = ContinuousClock.now
        let deadline = began + bootLimit
        let expected = guest
        while ContinuousClock.now < deadline && machine.isRunning && !state.stopRequested && console?.sawKernelPanic != true {
            if let connection = try? await machine.connect(toPort: GuestProtocol.port) {
                let descriptor = connection.descriptor
                Self.setReadTimeout(descriptor, seconds: 10)
                let hello = try? await Task.detached { try GuestClient.hello(descriptor, within: Self.answerLimit) }.value
                connection.close()
                if let hello, hello.v == AgentVM.guestProtocolVersion {
                    // A consistency check, not trust: a guest can say anything, but a disk
                    // that is not what its record says is not run as if it were. A hello
                    // without the field is a macOS daemon's from before there was one.
                    guard GuestKind(hello: hello.os) == expected else {
                        daemonRefusal = "The guest daemon says it runs on \(hello.os ?? GuestKind.macOS.rawValue), and box \(box.name) is a \(expected.rawValue) one"
                        return nil
                    }
                    return hello
                }
            }
            let quick = expected == .linux && ContinuousClock.now - began < Self.quickPollTime
            try? await Task.sleep(for: quick ? Self.quickPoll : .seconds(1))
        }
        return nil
    }

    /// A periodic clock sync is under way.
    private var clockSyncing = false

    /// The guest's file system errors were logged, once.
    private var diskErrorsLogged = false

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
            throw AgentVMError.supervisorRefused("the agent-vm-guest of box \(box.name) cannot set its clock; update its image with `agent-vm image update \(box.record.image) --guest`, then `agent-vm box recreate \(box.name)`")
        }
        do {
            let connection = try await machine.connect(toPort: GuestProtocol.port)
            defer { connection.close() }
            let descriptor = connection.descriptor
            Self.setReadTimeout(descriptor, seconds: 10)
            let offset = try await Task.detached { try GuestClient.syncTime(descriptor, within: Self.answerLimit) }.value
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

    /// The store the box is in (Boxes/<name> under it).
    private var storeRoot: URL {
        return box.directory.deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Shares `path` into the box at the same path, beside the folders it shares already: a
    /// Linux box shares up to `ProjectShare.slots(for:)` at once, a macOS box one, so there a
    /// new folder replaces the previous one. Called from control threads through the main
    /// actor. The awaits inside let other requests run on the main actor meanwhile, so requests
    /// are chained to change the guest's mounts and the devices' shares one at a time.
    /// `claim`: the caller runs a program on the project (an exec); the share then stays as
    /// it is until the claim is released (`SupervisorState.releaseProject`).
    /// Returns the folder as shared (its canonical path), which a claim is released by.
    @discardableResult
    func shareProject(_ path: String, readOnly: Bool, claim: Bool) async throws -> String {
        let project = try ProjectShare.validated(path, storeRoot: storeRoot)
        // Someone wants this project now: a pending unshare of it is off.
        unshareGenerations[project, default: 0] += 1
        let calledOff = pendingUnshares.remove(project) != nil
        let previous = shareQueue
        let task = Task { @MainActor in
            _ = await previous?.result
            try await self.addProject(project, readOnly: readOnly)
            if claim {
                self.state.claimProject(at: project)
            }
        }
        shareQueue = task
        do {
            try await task.value
        } catch {
            // A request that failed runs nothing on the project: the unshare it called off
            // is due again, or the project would stay shared with no program on it.
            if calledOff {
                projectReleased(project)
            }
            throw error
        }
        return project
    }

    /// How long after its last program ended a project stays shared: a script that runs one
    /// program after another on it does not mount and unmount each time.
    static let unshareDelay: Duration = .seconds(5)

    /// Counts, per project, the share requests and the releases, so that an unshare that
    /// waited `unshareDelay` knows whether anything happened to its project meanwhile.
    private var unshareGenerations: [String: Int] = [:]

    /// The projects whose unshare is waiting out `unshareDelay`.
    private var pendingUnshares: Set<String> = []

    /// A program on the project at `path` ended. When it was the last, the project is taken
    /// away from the box after `unshareDelay`, unless it is asked for again by then: a box
    /// that goes on running after its session must not keep the Mac's folder, with whatever
    /// the session left running in it.
    func projectReleased(_ path: String) {
        guard let project = state.project(at: path), project.programs == 0 else {
            return
        }
        unshareGenerations[path, default: 0] += 1
        let generation = unshareGenerations[path]
        pendingUnshares.insert(path)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.unshareDelay)
            guard let self, self.unshareGenerations[path] == generation else {
                return
            }
            self.pendingUnshares.remove(path)
            guard !self.state.stopRequested else {
                return
            }
            try? await self.unshareProject(path, asked: false)
        }
    }

    /// Takes shared projects away from the box, in turn with the share requests: the one at
    /// `path`, or with no path every one. `asked`: a person's request (`box unshare`), which is
    /// refused while programs run on a project it takes and fails when the guest cannot let go
    /// of one; otherwise both are only logged, and a project programs run on stays.
    func unshareProject(_ path: String?, asked: Bool) async throws {
        let previous = shareQueue
        let task = Task { @MainActor in
            _ = await previous?.result
            guard let machine = self.machine, self.state.snapshot.state == .ready else {
                if asked {
                    throw AgentVMError.supervisorRefused("box \(self.box.name) is not ready")
                }
                return
            }
            let shared = self.state.projects
            let targets = shared.filter { path == nil || $0.path == path }
            if asked, let busy = targets.first(where: { $0.programs > 0 }) {
                let others = path == nil && shared.count > 1 ? ", or name another folder to unshare" : ""
                throw AgentVMError.supervisorRefused("box \(self.box.name) is running programs on \(busy.path); wait until they end\(others)")
            }
            for current in targets where current.programs == 0 {
                do {
                    try await self.removeProject(current, machine: machine, force: true)
                } catch {
                    if !asked {
                        self.log("\(current.path) stays shared after its last program ended: \(error)")
                    }
                    throw error
                }
            }
        }
        shareQueue = task
        try await task.value
    }

    /// Unmounts the project in the guest and takes the folder out of its device's share.
    ///
    /// `force`: the folder is taken away whatever the guest answers. That is for a project no
    /// program of the person's runs on any more: what still holds it in the box is what a
    /// session left behind, and the guest's word that it cannot unmount is not what keeps the
    /// Mac's folder shared. Without it (making room for another project) a refusal is an error.
    private func removeProject(_ current: SharedProject, machine: GuestMachine, force: Bool = false) async throws {
        let guest = self.guest
        let layout: ShareLayout = guest == .linux ? .single : .namedEntry
        var held: String?
        do {
            let result = try await guestCapture(machine, ProjectShare.unmountRequest(current.path, guest: guest))
            if result.report != ExitReport(status: 0) {
                held = Printable.line(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines), limit: 200)
            }
        } catch {
            guard force else {
                throw error
            }
            held = "\(error)"
        }
        if let held {
            guard force else {
                throw AgentVMError.supervisorRefused("\(current.path) is still in use in box \(box.name) (\(held)); end the programs using it first")
            }
            _ = try? await guestCapture(machine, ProjectShare.forcedUnmountRequest(current.path, guest: guest))
            log("\(current.path) was still in use in the box (\(held)); it is taken away regardless, and the programs that worked in it there are ended")
        }
        state.removeProject(at: current.path)
        try machine.share(tag: current.tag, directory: nil, readOnly: false, layout: layout)
        if guest == .linux {
            // Only the projects still shared are safe places for git.
            _ = try? await guestCapture(machine, ProjectShare.safeDirectoryRequest(state.projects.map(\.path)))
        }
        log("Unshared \(current.path)")
        note(.init(.unshare, path: current.path))
    }

    /// Shares `project` (a canonical path) beside the projects shared already, after taking away
    /// what is in its way and unused (`ProjectShare.room`); what is in its way with programs on
    /// it refuses the request.
    private func addProject(_ project: String, readOnly: Bool) async throws {
        guard let machine, state.snapshot.state == .ready else {
            throw AgentVMError.supervisorRefused("box \(box.name) is not ready")
        }
        let guest = self.guest
        // A macOS guest gets the folder as the one entry of a root; a Linux guest the folder.
        let layout: ShareLayout = guest == .linux ? .single : .namedEntry
        let slots = ProjectShare.slots(for: guest)
        // Resolved when the request came, before the requests ahead of it ran: a project those
        // took away could have had a symlink swapped in on this one's path while it was mounted.
        guard try ProjectShare.validated(project, storeRoot: storeRoot) == project else {
            throw AgentVMError.unsuitableProject(path: project, reason: "its path changed while the request waited for its turn")
        }
        let inTheWay: [SharedProject]
        switch ProjectShare.room(for: project, readOnly: readOnly, among: state.projects, slots: slots) {
        case .shared:
            return
        case let .blocked(busy):
            throw shareRefusal(busy, asked: project, readOnly: readOnly, slots: slots)
        case let .remove(projects):
            inTheWay = projects
        }
        for other in inTheWay {
            try await removeProject(other, machine: machine)
        }
        if !inTheWay.isEmpty {
            // While the other projects were mounted the guest could change folders on this
            // one's path (a symlink swapped in); it has no access now, so resolve again.
            guard try ProjectShare.validated(project, storeRoot: storeRoot) == project else {
                throw AgentVMError.unsuitableProject(path: project, reason: "its path changed while the previous project was being unshared")
            }
        }
        let used = Set(state.projects.map(\.tag))
        guard let tag = ProjectShare.tags(for: guest).first(where: { !used.contains($0) }) else {
            throw AgentVMError.supervisorRefused("box \(box.name) has no free share device for \(project)")
        }
        try machine.share(tag: tag, directory: URL(fileURLWithPath: project, isDirectory: true), readOnly: readOnly, layout: layout)
        var mountTried = false
        do {
            let requests = ProjectShare.mountRequests(project, guest: guest, readOnly: readOnly, tag: tag)
            try await guestRun(machine, requests[0])
            let found = try await guestCapture(machine, ProjectShare.hiddenContentsRequest(project, guest: guest))
            let first = found.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard found.report == ExitReport(status: 0), first.isEmpty else {
                let hidden = ProjectShare.mountPoint(project, guest: guest)
                let what = first.isEmpty ? "cannot be examined (\(found.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))" : "already holds \(first)"
                let advice = guest == .linux ? "share a folder whose path is new or holds only folders in the box" : "share a folder whose parent is new or empty in the box"
                throw AgentVMError.unsuitableProject(path: project, reason: "\(hidden) in the box \(what), which the share would hide; \(advice)")
            }
            mountTried = true
            try await guestRun(machine, requests[1])
            if guest == .linux {
                // Not fatal: the share works without it, and git says what it misses.
                let told = try? await guestCapture(machine, ProjectShare.safeDirectoryRequest(state.projects.map(\.path) + [project]))
                if told?.report != ExitReport(status: 0) {
                    log("Could not tell git in the box that \(project) is a safe place: \(told.map { ($0.stderr + $0.stdout).trimmingCharacters(in: .whitespacesAndNewlines) } ?? "no answer")")
                }
            }
        } catch {
            // Leave nothing mounted. If the guest cannot confirm that, keep the share recorded
            // so a later request unmounts it first (the unmount succeeds when nothing is there),
            // and let the unshare that follows a release try again: with several devices, a
            // record nothing ever takes away would hold one for as long as the box runs.
            // Before the mount the path may be some other mount point: leave it alone.
            let unmounted = mountTried ? try? await guestCapture(machine, ProjectShare.unmountRequest(project, guest: guest)) : nil
            if !mountTried || unmounted?.report == ExitReport(status: 0) {
                try? machine.share(tag: tag, directory: nil, readOnly: false, layout: layout)
            } else {
                state.addProject(SharedProject(path: project, readOnly: readOnly, tag: tag))
                projectReleased(project)
            }
            throw error
        }
        state.addProject(SharedProject(path: project, readOnly: readOnly, tag: tag))
        log("Shared \(project)\(readOnly ? " (read only)" : "")\(slots > 1 ? " on device \(tag)" : "")")
        note(.init(.share, path: project, readOnly: readOnly))
    }

    /// Why `asked` cannot be shared while programs run on `busy`, and what works instead.
    /// The words "is running programs on <folder>" are what avm and the tests look for.
    private func shareRefusal(_ busy: SharedProject, asked project: String, readOnly: Bool, slots: Int) -> AgentVMError {
        let mode = busy.readOnly ? " (read only)" : ""
        let asked = busy.path == project ? "the same folder \(readOnly ? "read only" : "for writing")" : project
        let reason: String
        if slots == 1 {
            reason = "a box shares one folder at a time"
        } else if busy.path == project {
            reason = "a box shares a folder in one mode at a time"
        } else if project.hasPrefix(busy.path + "/") {
            reason = "\(project) is inside it"
        } else if busy.path.hasPrefix(project + "/") {
            reason = "it is inside \(project)"
        } else {
            return AgentVMError.supervisorRefused("box \(box.name) is running programs on each of the \(slots) folders it shares (\(busy.path) first), and a box shares at most \(slots) folders at a time, so it cannot share \(project) now; "
                + "wait until the programs on one of them end, or use another box")
        }
        return AgentVMError.supervisorRefused("box \(box.name) is running programs on \(busy.path)\(mode), and \(reason), so it cannot share \(asked) now; "
            + "start from \(busy.path)\(mode) to work beside those programs, wait until they end, or use another box")
    }

    /// Runs one guest request; throws unless it exits with status 0.
    private func guestRun(_ machine: GuestMachine, _ request: GuestRequest) async throws {
        let result = try await guestCapture(machine, request)
        guard result.report == ExitReport(status: 0) else {
            throw AgentVMError.guestCommandFailed(command: request.argv?.joined(separator: " ") ?? "?", status: result.report.shellStatus,
                                                  output: (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Runs one guest request to the end on a fresh vsock connection, off the main actor.
    private func guestCapture(_ machine: GuestMachine, _ request: GuestRequest) async throws -> (report: ExitReport, stdout: String, stderr: String) {
        let connection = try await machine.connect(toPort: GuestProtocol.port)
        defer { connection.close() }
        let descriptor = connection.descriptor
        Self.setReadTimeout(descriptor, seconds: 60)
        return try await Task.detached { try GuestClient.capture(descriptor, request, within: Self.commandLimit) }.value
    }

    /// Applies the network mode inside the guest (address, DNS, system proxy) as root.
    private func configureNetwork(_ machine: GuestMachine, mode: BoxNetwork.Mode) async throws {
        let connection = try await machine.connect(toPort: GuestProtocol.port)
        defer { connection.close() }
        let descriptor = connection.descriptor
        Self.setReadTimeout(descriptor, seconds: 60)
        let request = GuestRequest(op: .exec, argv: ["/bin/sh", "-c", GuestNetworkSetup.command(for: mode, guest: guest)], user: "root")
        let result = try await Task.detached { try GuestClient.capture(descriptor, request, within: Self.commandLimit) }.value
        guard result.report == ExitReport(status: 0) else {
            throw AgentVMError.guestCommandFailed(command: "network setup", status: result.report.shellStatus, output: (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let card = guest == .linux ? "no network card" : "dead-end card"
        log("Network: \(mode.rawValue)\(mode == .open ? " (NAT)" : " (\(card), proxy on vsock port \(GuestRelay.hostPort))")")
    }

    private func shutDown(_ machine: GuestMachine) async {
        state.set(.stopping, guestVersion: nil)
        log("Shutting down")
        noteStop()
        if let connection = try? await machine.connect(toPort: GuestProtocol.port) {
            let descriptor = connection.descriptor
            Self.setReadTimeout(descriptor, seconds: 10)
            // Asked, not waited for: what follows must not depend on the guest's answer.
            _ = try? await Task.detached { try GuestClient.shutdown(descriptor, within: Self.answerLimit) }.value
            connection.close()
        }
        guard guest == .linux else {
            if await machine.waitUntilStopped(timeout: Self.shutdownTimeout) {
                log("Stopped")
                return
            }
            log("The guest did not shut down within \(Self.shutdownTimeout); pulling the plug")
            try? await machine.forceStop()
            return
        }
        if await machine.waitUntilStopped(timeout: Self.linuxShutdownTimeout) {
            log("Stopped")
            return
        }
        // The power button, which the system obeys even when the daemon is gone.
        log("The guest did not shut down within \(Self.linuxShutdownTimeout); pressing its power button")
        try? machine.requestStop()
        if await machine.waitUntilStopped(timeout: Self.linuxPowerButtonTimeout) {
            log("Stopped")
            return
        }
        log("The guest did not shut down within \(Self.linuxPowerButtonTimeout) more; pulling the plug")
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

    /// How long the guest has for a whole answer to hello, the clock and shutdown, and for a
    /// whole command the supervisor runs for itself (network setup, mounting the project, the
    /// desktop's settings). A read timeout alone bounds one read: a guest sending a byte now
    /// and then would hold the supervisor, and with it `box stop`, for as long as it liked.
    nonisolated static let answerLimit: Duration = .seconds(15)
    nonisolated static let commandLimit: Duration = .seconds(90)

    nonisolated static func setReadTimeout(_ descriptor: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
}

/// A folder shared into a running box: on which device, and how many programs (execs) run on it.
struct SharedProject: Equatable, Sendable {
    var path: String
    var readOnly: Bool
    var tag: String
    var programs = 0

    var folder: SharedFolder {
        return SharedFolder(path: path, readOnly: readOnly, programs: programs)
    }
}

/// The supervisor's state as the control threads see it.
final class SupervisorState: @unchecked Sendable {
    private let lock = NSLock()
    private var current: ControlResponse.State = .starting
    private var guest: String?
    private var features: [String] = []
    private var stopping = false
    private var shared: [SharedProject] = []
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

    /// The folders shared into the box, in the order they were shared.
    var projects: [SharedProject] {
        lock.lock()
        defer { lock.unlock() }
        return shared
    }

    /// The folder shared at `path`, if any.
    func project(at path: String) -> SharedProject? {
        lock.lock()
        defer { lock.unlock() }
        return shared.first { $0.path == path }
    }

    /// Records `project` as shared, replacing what was recorded for its path.
    func addProject(_ project: SharedProject) {
        lock.lock()
        shared.removeAll { $0.path == project.path }
        shared.append(project)
        lock.unlock()
    }

    func removeProject(at path: String) {
        lock.lock()
        shared.removeAll { $0.path == path }
        lock.unlock()
    }

    /// A program (exec) runs on the project at `path`; while any do, it stays as it is.
    func claimProject(at path: String) {
        lock.lock()
        if let index = shared.firstIndex(where: { $0.path == path }) {
            shared[index].programs += 1
        }
        lock.unlock()
    }

    func releaseProject(at path: String) {
        lock.lock()
        if let index = shared.firstIndex(where: { $0.path == path }) {
            shared[index].programs = max(0, shared[index].programs - 1)
        }
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
    /// How long a control thread waits for a share, in seconds: up to four guest commands of at
    /// most 60 s each, after the requests ahead of it (`ControlClient.shareTimeout` is a little
    /// longer).
    static let shareLimit = 300
    /// The same for an unshare, which takes up to three guest commands for each folder; the
    /// unshare of all 8 folders of a slow guest goes on past it.
    static let unshareLimit = 300

    private let state: SupervisorState
    /// Main-actor isolated; used only from the MainActor task below.
    private let machine: GuestMachine
    private let box: Box
    private let proxy: ProxyServer
    /// Returns the folder as shared (its canonical path).
    private let share: @Sendable @MainActor (String, Bool, Bool) async throws -> String
    /// The folder (nil: every one), and true: a person asked (`box unshare`); false: the last
    /// program on the folder ended.
    private let unshare: @Sendable @MainActor (String?, Bool) async throws -> Void
    private let view: @Sendable @MainActor (Bool) throws -> Void
    private let type: @Sendable @MainActor (String?) async throws -> Void
    private let syncClock: @Sendable @MainActor () async throws -> Double

    init(state: SupervisorState, machine: GuestMachine, box: Box, proxy: ProxyServer,
         share: @escaping @Sendable @MainActor (String, Bool, Bool) async throws -> String,
         unshare: @escaping @Sendable @MainActor (String?, Bool) async throws -> Void,
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
        self.unshare = unshare
    }

    /// Takes the project at `path` (nil: every one) away on the main actor; blocks this control
    /// thread for at most `unshareLimit`.
    func controlUnshare(path: String?) throws {
        let result = ShareResult()
        let done = DispatchSemaphore(value: 0)
        let unshare = self.unshare
        Task { @MainActor in
            do {
                try await unshare(path, true)
                result.set(nil)
            } catch {
                result.set(error)
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + .seconds(Self.unshareLimit)) == .success else {
            let what = path ?? "the folders of box \(box.name)"
            throw AgentVMError.supervisorRefused("unsharing \(what) did not finish within \(Self.unshareLimit) s and goes on in the box; agent-vm box status \(box.name) shows what is still shared")
        }
        if let error = result.error {
            throw error
        }
    }

    /// Shares a project on the main actor; blocks this control thread for at most `shareLimit`.
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

    /// Returns the folder as shared (its canonical path).
    @discardableResult
    private func shareBlocking(path: String, readOnly: Bool, claim: Bool) throws -> String {
        let result = ShareResult()
        let done = DispatchSemaphore(value: 0)
        let share = self.share
        let state = self.state
        let unshare = self.unshare
        Task { @MainActor in
            do {
                let shared = try await share(path, readOnly, claim)
                if !result.finish(path: shared), claim {
                    // The caller was told the share timed out and runs nothing on it: the claim
                    // is released as a connection's end releases it, or it would hold the
                    // folder (and its device) for as long as the box runs.
                    state.releaseProject(at: shared)
                    try? await unshare(shared, false)
                }
            } catch {
                result.set(error)
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + .seconds(Self.shareLimit)) == .success || !result.abandon() else {
            throw AgentVMError.supervisorRefused("sharing \(path) did not finish within \(Self.shareLimit) s and goes on in the box\(claim ? "; nothing is run on it, and it is unshared again 5 s after it is shared" : "")")
        }
        if let error = result.error {
            throw error
        }
        return result.path ?? path
    }

    /// The store the box is in (Boxes/<name> under it).
    private var storeRoot: URL {
        return box.directory.deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Rereads the network rules from box.json, and closes the open connections they no longer
    /// allow; a mode change needs a restart.
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
        let projects = state.projects
        // `project` and `projectReadOnly` name the first, for readers that know of one.
        return ControlResponse(ok: true, state: snapshot.state, guestVersion: snapshot.guestVersion, pid: getpid(),
                               project: projects.first?.path, projectReadOnly: projects.first?.readOnly, projects: projects.map(\.folder),
                               guestFeatures: snapshot.guestFeatures,
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
        let claimed = try project.map { try shareBlocking(path: $0, readOnly: readOnly, claim: true) }
        let state = self.state
        let unshare = self.unshare
        do {
            let lent = try openConnection()
            state.execOpened()
            return LentConnection(descriptor: lent.descriptor, release: {
                lent.release()
                state.execClosed()
                if let claimed {
                    state.releaseProject(at: claimed)
                    Task { @MainActor in try? await unshare(claimed, false) }
                }
            })
        } catch {
            if let claimed {
                state.releaseProject(at: claimed)
                Task { @MainActor in try? await unshare(claimed, false) }
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
    private var sharedPath: String?
    private var finished = false
    private var abandoned = false

    /// The share succeeded. False when its waiter gave up first (`abandon`): the share is then
    /// nobody's.
    func finish(path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        sharedPath = path
        finished = true
        return !abandoned
    }

    /// The waiter gives up. False when the outcome came first, and it stands.
    func abandon() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        abandoned = !finished
        return abandoned
    }

    var path: String? {
        lock.lock()
        defer { lock.unlock() }
        return sharedPath
    }

    func set(_ error: Error?) {
        lock.lock()
        stored = error
        finished = true
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
    /// The least time a supervisor gets to bring its box up, even when waiting for a stopping
    /// box used most of the call's limit (a boot takes 10 to 30 seconds).
    static let minimumBootWait: Duration = .seconds(60)

    /// Spawns `executable box serve <name>` in its own session, output appended to the box's
    /// supervisor.log, and waits (up to `timeout`, or `minimumBootWait` after a long wait for a stopping box) until it reports ready. Returns its status.
    /// `ownerPid`: the process whose exit stops the box; ignored when the box already runs
    /// (its status names the owner it has). A box that is stopping is waited for and started
    /// again, with `ownerPid`. `tick` is called at every poll (twice a second) while it waits,
    /// for a caller that shows the time passing.
    public static func start(_ box: Box, executable: String, ownerPid: Int32? = nil, timeout: Duration = .seconds(200),
                             tick: (() -> Void)? = nil, progress: (String) -> Void) throws -> ControlResponse {
        // One limit for the whole call, a wait for a stopping box included.
        let deadline = ContinuousClock.now + timeout
        // The owner's start time as it is now, right after the caller checked the number and
        // before any wait for a stopping box: by the time the supervisor watches the number,
        // it may be another process's.
        let ownerStartedAt = ownerPid.flatMap { OwnerWatch.startTime(of: $0) }
        if box.isRunning {
            // Another start is under way (or done): wait for it rather than fail. A box that is
            // stopping (or whose other start failed) is started here once it has stopped, so
            // one call covers every state.
            if let response = try waitForOtherSupervisor(box, timeout: timeout, tick: tick, progress: progress) {
                return response
            }
            // Checked once the old supervisor is gone: it leaves a disposable box's tombstone
            // before it releases the lock.
            guard !box.isTombstoned else {
                throw AgentVMError.boxDisposed(box.name)
            }
            // Deleted once it stopped: a disposable one by another client's `box gc`, which
            // also takes the tombstone.
            guard FileSystem.exists(box.directory.appendingPathComponent(BoxStore.recordName).path) else {
                throw box.record.disposable == true ? AgentVMError.boxDisposed(box.name) : AgentVMError.boxNotFound(box.name)
            }
        }
        // A name too long for the control socket (a box made before 0.7.53, or a store that
        // moved): its supervisor could not listen, and the start would say only that it exited.
        try BoxStore.checkNameLength(box.name, boxes: box.directory.deletingLastPathComponent().path, existing: true)
        // A box made before the smallest size was checked (0.7.51) would only time out, after
        // 180 s of a guest that never answers.
        let guest = box.record.effectiveGuest
        if let refusal = MachineSize.memoryRefusal(memoryBytes: box.record.memoryBytes, guest: guest) {
            throw AgentVMError.virtualMachine(operation: "start \(box.name)",
                                              message: "\(refusal); `agent-vm box set \(box.name) --memory-gb \(MachineSize.gigabytes(MachineSize.comfortableMemory(for: guest)))` gives it more")
        }
        let logDescriptor = open(box.logURL.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard logDescriptor >= 0 else {
            throw AgentVMError.system(operation: "open \(box.logURL.path)", code: errno)
        }
        defer { close(logDescriptor) }
        let logStart = UInt64(max(lseek(logDescriptor, 0, SEEK_END), 0))

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
        // A box with no screen to show (a Linux box without a desktop) has a supervisor that is no
        // application.
        let arguments = [executable, "box", "serve", box.name] + (box.record.hasScreen ? [] : ["--headless"])
            + (ownerPid.map { ["--owner-pid", String($0)] } ?? [])
            + (ownerStartedAt.map { ["--owner-started-at", $0] } ?? [])
        // Not the caller's whole environment: the supervisor outlives it by days.
        let status = GuestServer.withCStrings(arguments) { argv in
            GuestServer.withCStrings(DetachedEnvironment.list()) { envp in
                posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
            }
        }
        guard status == 0 else {
            throw AgentVMError.system(operation: "start the supervisor \(executable)", code: status)
        }

        // A box that took long to stop still gets time to boot.
        return try waitUntilReady(box, supervisor: pid, logStart: logStart, timeout: max(deadline - ContinuousClock.now, minimumBootWait), tick: tick,
                                  progress: progress)
    }

    /// How long the box took to become ready the last time it started, from its supervisor
    /// log's last "Ready in N s" line; nil when there is none (a new box) or the log cannot be
    /// read. Only the log's end is read.
    public static func lastBootSeconds(of box: Box) -> Int? {
        return logTail(of: box).flatMap { lastBootSeconds(inLog: $0) }
    }

    /// The last 64 KiB of the box's supervisor log, or what was written after byte `offset`
    /// when that is less; nil when the log cannot be read.
    static func logTail(of box: Box, from offset: UInt64 = 0) -> String? {
        // As the supervisor writes it: never through a link, and never waiting on something
        // that is not a plain file.
        let descriptor = open(box.logURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            return nil
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            return nil
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: max(offset, size > 65536 ? size - 65536 : 0))
        guard let data = try? handle.readToEnd() else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The seconds of the last "Ready in N s" line in `text`.
    public static func lastBootSeconds(inLog text: String) -> Int? {
        for line in text.split(separator: "\n").reversed() {
            guard let range = line.range(of: "Ready in ") else {
                continue
            }
            let digits = line[range.upperBound...].prefix { $0.isNumber }
            if let seconds = Int(digits), line[range.upperBound...].dropFirst(digits.count).hasPrefix(" s") {
                return seconds
            }
        }
        return nil
    }

    /// Why a supervisor that exited failed: its last "Error: " line in `text` (what it wrote
    /// to its log), without that prefix or a repeated "the guest is unreachable: ", as one
    /// printable line. nil when there is none.
    public static func lastError(inLog text: String) -> String? {
        guard let line = text.split(separator: "\n").last(where: { $0.hasPrefix("Error: ") }) else {
            return nil
        }
        var reason = line.dropFirst("Error: ".count)
        let unreachable = "the guest is unreachable: "
        if reason.hasPrefix(unreachable) {
            reason = reason.dropFirst(unreachable.count)
        }
        let trimmed = reason.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : Printable.line(trimmed, limit: 1000)
    }

    /// Polls our own supervisor until the box is ready; its exit ends the wait. `logStart`:
    /// the log's size before the supervisor started, so its exit is explained by what it
    /// wrote, not by an earlier start's error.
    private static func waitUntilReady(_ box: Box, supervisor pid: pid_t, logStart: UInt64, timeout: Duration, tick: (() -> Void)?,
                                       progress: (String) -> Void) throws -> ControlResponse {
        let deadline = ContinuousClock.now + timeout
        var lastState: ControlResponse.State?
        while ContinuousClock.now < deadline {
            var exitStatus: Int32 = 0
            if waitpid(pid, &exitStatus, WNOHANG) == pid {
                let status = GuestServer.report(exitStatus).shellStatus
                if status == 0 {
                    throw AgentVMError.guestUnreachable("box \(box.name) was stopped before it became ready")
                }
                if status == AgentVMError.noFreeVMSlotStatus {
                    throw AgentVMError.noFreeVMSlot(operation: "start box \(box.name)")
                }
                // Another start took the box between our check and our supervisor (which then
                // found the lock held): that start is the one to wait for.
                if box.isRunning, let response = try waitForOtherSupervisor(box, timeout: max(deadline - ContinuousClock.now, minimumBootWait),
                                                                          tick: tick, progress: progress) {
                    return response
                }
                if let reason = logTail(of: box, from: logStart).flatMap({ lastError(inLog: $0) }) {
                    throw AgentVMError.guestUnreachable("the supervisor exited (status \(status)): \(reason); see \(box.logURL.path)")
                }
                throw AgentVMError.guestUnreachable("the supervisor exited (status \(status)); see \(box.logURL.path)")
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
            tick?()
            usleep(500_000)
        }
        throw AgentVMError.guestUnreachable("the box did not become ready within \(timeout); see \(box.logURL.path)")
    }

    /// Polls a supervisor another process started: the box's status once it is ready, nil once
    /// the box has stopped (it was stopping, or that start failed). Its states are reported as
    /// they change, so a wait for a stop shows as `stopping`.
    private static func waitForOtherSupervisor(_ box: Box, timeout: Duration, tick: (() -> Void)?,
                                               progress: (String) -> Void) throws -> ControlResponse? {
        let deadline = ContinuousClock.now + timeout
        var lastState: ControlResponse.State?
        while ContinuousClock.now < deadline {
            guard box.isRunning else {
                return nil
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
            tick?()
            usleep(500_000)
        }
        throw AgentVMError.guestUnreachable("box \(box.name) did not become ready or stop within \(timeout); see \(box.logURL.path)")
    }

    /// Asks the supervisor to stop and waits until it has released the box.
    public static func stop(_ box: Box, timeout: Duration = .seconds(120)) throws {
        guard box.isRunning else {
            throw AgentVMError.boxNotRunning(box.name)
        }
        // The supervisor asked to stop: once it has exited the stop is done, even when a
        // `box start` waiting on it has already started the box again (the box never looks free).
        let supervisor = (try? ControlClient.request(.status, path: box.controlSocketPath))?.pid
        _ = try ControlClient.request(.stop, path: box.controlSocketPath)
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if !box.isRunning {
                return
            }
            if let supervisor, kill(supervisor, 0) != 0 && errno == ESRCH {
                return
            }
            usleep(250_000)
        }
        throw AgentVMError.guestUnreachable("box \(box.name) did not stop within \(timeout); see \(box.logURL.path)")
    }
}
