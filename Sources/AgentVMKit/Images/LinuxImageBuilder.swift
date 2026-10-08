// Sources/AgentVMKit/Images/LinuxImageBuilder.swift
//
// Builds a Linux image from a distribution's cloud image, with no clicks, no SSH and no
// password:
//
// 1. The cloud image is fetched (or reused) and checked against the distribution's checksum
//    list (LinuxBaseCache), then unpacked into the image's disk (DiskUnpack).
// 2. The first boot has a small second disk (SeedDisk) from which the system's own first-boot
//    program installs the guest daemon. That is all it does.
// 3. Everything else is run by the Mac through the daemon, each step in the build log
//    (LinuxSetup): the box user, the packages, the recipes; then the image is sealed (the ssh
//    server removed, updates in the background off, cloud-init off), what was sealed is
//    checked, and the guest is shut down.
//
// Measured on a MacBook Air M5 with Debian 13: about a minute after the download.

import Darwin
import Foundation
import Virtualization

public struct LinuxImageBuildOptions: Sendable {
    public var name: String
    /// The system to build.
    public var base: LinuxBase
    /// A cloud image file of the person's own, in place of a download.
    public var cloudImage: String?
    public var cpuCount: Int
    public var memoryBytes: UInt64
    public var diskBytes: UInt64
    public var userName: String
    /// The Linux agent-vm-guest installed into the image.
    public var guestDaemon: URL
    /// Install the compiler and make (`build-essential`): what the Command Line Tools are on
    /// macOS.
    public var commandLineTools: Bool
    /// Recipes whose steps and checks run after the setup, in this order, before the image is
    /// sealed.
    public var recipes: [ImageRecipe]

    public init(name: String, base: LinuxBase, cloudImage: String? = nil, cpuCount: Int = LinuxImageBuildOptions.defaultCPUCount,
                memoryBytes: UInt64 = LinuxImageBuildOptions.defaultMemoryBytes, diskBytes: UInt64 = LinuxImageBuildOptions.defaultDiskBytes,
                userName: String = "agent", guestDaemon: URL, commandLineTools: Bool = true, recipes: [ImageRecipe] = []) {
        self.name = name
        self.base = base
        self.cloudImage = cloudImage
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
        self.userName = userName
        self.guestDaemon = guestDaemon
        self.commandLineTools = commandLineTools
        self.recipes = recipes
    }

    public static let defaultCPUCount = 4
    public static let defaultMemoryBytes: UInt64 = 4 << 30
    /// A sparse file: about 2 GB after the build.
    public static let defaultDiskBytes: UInt64 = 32 << 30
    /// The cloud image's own disk is 3 GB; below this the packages have no room.
    public static let minimumDiskBytes: UInt64 = 8 << 30
}

extension ImageBuilder {
    /// Free space a Linux image's build wants on the store's volume.
    static let minimumFreeBytesForLinux: Int64 = 6 << 30
    /// How long the first boot may take to bring the daemon up (4.5 s measured).
    static let linuxFirstBootAttempts = 180
    /// The name of the seed disk in an image's folder while it is built.
    static let seedDiskName = "Seed.iso"

    /// Builds a Linux image; on failure the record says which step failed and the folder is
    /// kept for inspection (`agent-vm image delete` removes it). Nothing is created when the
    /// cloud image cannot be fetched or checked.
    public func buildLinux(_ options: LinuxImageBuildOptions) async throws -> GoldenImage {
        guard ImageStore.isValidName(options.name) else {
            throw AgentVMError.invalidImageName(options.name)
        }
        guard LinuxSetup.isValidUserName(options.userName) else {
            throw AgentVMError.invalidUserName(options.userName)
        }
        guard options.diskBytes >= LinuxImageBuildOptions.minimumDiskBytes else {
            throw AgentVMError.virtualMachine(operation: "create the disk", message: "\(options.diskBytes >> 30) GB is too small; a Linux image needs at least \(LinuxImageBuildOptions.minimumDiskBytes >> 30) GB")
        }
        if let problem = MachineSize.problem(cpuCount: options.cpuCount, memoryBytes: options.memoryBytes) {
            throw AgentVMError.virtualMachine(operation: "configure \(options.name)", message: problem)
        }
        for recipe in options.recipes {
            try recipe.check(serves: .linux, image: options.name)
        }
        let daemon = LocalGuestDaemon.inspectLinux(options.guestDaemon)
        guard daemon.error == nil, let daemonDigest = daemon.digest else {
            throw AgentVMError.hostNotReady("the Linux guest daemon \(options.guestDaemon.path) is missing or not a Linux program (\(daemon.error ?? "no digest")); Scripts/build.sh builds it when the swift.org toolchain and its static Linux SDK are installed")
        }
        if FileSystem.exists(store.imagesDirectory.appendingPathComponent(options.name).path) {
            let state = (try? store.image(named: options.name))?.record.state.rawValue ?? "unreadable"
            throw AgentVMError.imageExists(name: options.name, state: state)
        }
        try Self.checkHost(HostFacts.current(storeRoot: store.root), minimumFree: Self.minimumFreeBytesForLinux)

        subject = shownName ?? options.name
        let source = try await cloudImage(options)
        try checkCanceled()
        log("\(options.base.name); \(options.cpuCount) CPUs, \(options.memoryBytes >> 30) GB memory, \(options.diskBytes >> 30) GB disk")

        var record = ImageRecord(
            formatVersion: ImageRecord.formatVersion(passwordID: nil, guest: .linux), name: options.name, state: .installing, failure: nil,
            createdAt: Date(), createdBy: AgentVM.version, macOSVersion: nil, macOSBuild: nil,
            cpuCount: options.cpuCount, memoryBytes: options.memoryBytes, diskBytes: options.diskBytes,
            macAddress: VZMACAddress.randomLocallyAdministered().string, userName: options.userName,
            installSeconds: nil, provisionSeconds: nil)
        record.guest = .linux
        // What was asked for, so a list names the system while it is built (and when the build
        // fails early); what the guest says of itself takes its place once it is read.
        record.linux = LinuxSystem(distribution: options.base.distribution, version: options.base.version, name: options.base.name)
        record.base = ImageRecord.BaseSource(release: options.base.id, file: source.file.lastPathComponent, url: source.url, sha512: source.sha512, build: source.build)
        let created = try store.create(record)
        var image = created.0
        let lock = created.1
        defer { lock.release() }

        do {
            image = try await unpack(source.file, base: options.base, into: image)
            image = try await provisionLinux(image, options: options, daemonDigest: daemonDigest)
            return image
        } catch {
            let reason = Self.failureReason(error)
            _ = try? store.update(image) { record in
                record.state = .failed
                record.failure = reason
            }
            throw error
        }
    }

    /// The cloud image to build from: the person's own file, or the distribution's, checked.
    private func cloudImage(_ options: LinuxImageBuildOptions) async throws -> LinuxBaseCache.Resolved {
        let cache = try LinuxBaseCache(root: store.root)
        if let path = options.cloudImage {
            progress("base-check", "Reading \(path)")
            let local = try await cache.local(path)
            log("  SHA-512 \(local.sha512.prefix(16))... (your own file: not checked against \(options.base.name)'s list)")
            return local
        }
        let events = report
        let image = subject
        let last = LastFraction()
        let resolved = try await cache.resolve(options.base, cancellation: cancellation) { step in
            let event: ProgressEvent
            switch step {
            case let .checkingList(host):
                event = ProgressEvent(.progress, "Asking \(host) for the checksum of \(options.base.name)'s cloud image", step: "base-check", image: image)
            case let .hashing(file):
                event = ProgressEvent(.log, "  checking \(file)", image: image)
            case let .reusing(file):
                event = ProgressEvent(.log, "  the downloaded \(file) is the one the list names", image: image)
            case let .downloading(file, bytes, total):
                // One event per percent, not one per packet.
                guard let total, total > 0, last.advance(to: Int(bytes * 100 / total)) else {
                    return
                }
                event = ProgressEvent(.progress, "Downloading \(file) (\(total / 1_000_000) MB)", step: "download", fraction: Double(bytes) / Double(total), image: image)
            case let .offline(reason, file, checkedAt):
                event = ProgressEvent(.notice, "  note: the checksum list could not be fetched (\(reason)); using \(file), checked on \(checkedAt.formatted(.iso8601))", image: image)
            }
            Task { @MainActor in
                events(event)
            }
        }
        // Let the events above be shown before the next line.
        await Task.yield()
        return resolved
    }

    /// The cloud image's disk as the image's, at the image's size, with a new variable store
    /// and identifier.
    private func unpack(_ source: URL, base: LinuxBase, into image: GoldenImage) async throws -> GoldenImage {
        let clock = ContinuousClock()
        let began = clock.now
        progress("unpack", "Unpacking the disk")
        let disk = image.diskURL
        let limit = Int64(image.record.diskBytes)
        let cancellation = self.cancellation
        let size = try await Task.detached {
            try DiskUnpack.unpack(source, member: base.member, to: disk, limit: limit, cancellation: cancellation)
        }.value
        // The system grows its root file system into the rest when it boots.
        guard truncate(disk.path, off_t(image.record.diskBytes)) == 0 else {
            throw AgentVMError.system(operation: "size \(disk.path)", code: errno)
        }
        try LinuxMachineSpec.createFiles(variableStore: image.efiVariableStoreURL, machineIdentifier: image.machineIdentifierURL)
        let seconds = Self.seconds(clock.now - began)
        log("  \(size >> 20) MB disk unpacked in \(Int(seconds)) s, extended to \(image.record.diskBytes >> 30) GB")
        try checkCanceled()
        return try store.update(image) { record in
            record.state = .installed
            record.installSeconds = seconds
        }
    }

    private func provisionLinux(_ image: GoldenImage, options: LinuxImageBuildOptions, daemonDigest: String) async throws -> GoldenImage {
        let clock = ContinuousClock()
        let began = clock.now
        var current = try store.update(image) { $0.state = .provisioning }
        let user = current.record.userName
        let seed = current.directory.appendingPathComponent(Self.seedDiskName)
        // Before it is made: a seed disk half written by a failure is removed too.
        defer { try? FileManager.default.removeItem(at: seed) }
        try SeedDisk.make(at: seed, daemon: options.guestDaemon, unit: GuestDaemon.systemdUnit(user: user), instance: "agent-vm-\(UUID().uuidString.lowercased())")
        let console = try ConsoleLog(url: current.consoleLogURL)
        defer { console.close() }
        let machine = try makeMachine(for: current, extras: LinuxMachineExtras(seedDisk: seed, console: console.writeHandle))

        try checkCanceled()
        progress("first-boot", "First boot: the system installs the guest daemon")
        try await machine.start()
        do {
            let hello: GuestResponse
            do {
                hello = try await waitForDaemon(machine, attempts: Self.linuxFirstBootAttempts, guest: .linux)
            } catch AgentVMError.guestUnreachable(let reason) {
                let tail = ConsoleLog.tail(of: current.consoleLogURL, lines: 20)
                throw AgentVMError.guestUnreachable("\(reason)\(tail.isEmpty ? "" : "; the console's last lines (\(current.consoleLogURL.path)):\n\(tail)")")
            }
            // A stale build of the daemon is caught here, not by a box that misbehaves later.
            guard hello.version == AgentVM.version else {
                throw AgentVMError.hostNotReady("the Linux guest daemon \(options.guestDaemon.path) is version \(Printable.line(hello.version ?? "?", limit: 32)) and agent-vm is \(AgentVM.version); build both with Scripts/build.sh")
            }
            progress("guest-daemon", "The guest daemon answers")
            log("  agent-vm-guest \(hello.version ?? "?") answers over vsock (protocol \(hello.v ?? 0), \((hello.features ?? []).joined(separator: ", ")))")
            current = try store.update(current) { record in
                record.guestVersion = hello.version
                record.guestProtocol = hello.v
                record.guestFeatures = hello.features
                record.guestDigest = daemonDigest
            }

            var steps = [LinuxSetup.waitForFirstBoot]
            steps += LinuxSetup.steps(user: user, tools: options.commandLineTools)
            let count = steps.count + LinuxSetup.seal.count
            try await runLinuxSteps([LinuxSetup.waitForFirstBoot], machine: machine, offset: 0, count: count)
            let system = try await readLinuxSystem(machine, base: options.base, diskBytes: current.record.diskBytes)
            log("  \(system.name), kernel \(system.kernel ?? "?"), \(system.architecture)")
            current = try store.update(current) { $0.linux = system }
            try await runLinuxSteps(Array(steps.dropFirst()), machine: machine, offset: 1, count: count)

            let identity = try await guestCapture(machine, GuestRequest(op: .exec, argv: ["/usr/bin/id", "-un"]))
            guard identity.report == ExitReport(status: 0), identity.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == user else {
                throw AgentVMError.guestCommandFailed(command: "id -un", status: identity.report.shellStatus,
                                                      output: "expected \(user), got \"\(Printable.line(identity.stdout.trimmingCharacters(in: .whitespacesAndNewlines), limit: 80))\" \(Printable.line(identity.stderr, limit: 200))")
            }
            log("  programs run as \(user)")
            // Before the recipes: one of them may give the account sudo on purpose.
            try await sealCheck(machine, checks: [LinuxSetup.accountCheck(user: user)], what: "account check")
            if options.commandLineTools {
                let version = try await guestCapture(machine, Self.rootRequest(LinuxSetup.toolsVersion))
                let label = try LinuxSetup.packageVersion(version.stdout, package: LinuxSetup.toolsPackage)
                current = try store.update(current) { $0.commandLineTools = "\(LinuxSetup.toolsPackage) \(label)" }
            }

            current = try await applyRecipes(options.recipes, to: current, machine: machine)

            progress("seal", "Sealing the image: no ssh server, no background updates, no first-boot setup")
            try await runLinuxSteps(LinuxSetup.seal, machine: machine, offset: steps.count, count: count)
            try await sealCheck(machine, checks: LinuxSetup.sealChecks())
            // The kernel a box of this image boots, after the updates.
            try await shutDown(machine, guest: .linux)
        } catch {
            let error = canceledError(error)
            await stopAfterFailure(machine)
            throw error
        }
        let seconds = Self.seconds(clock.now - began)
        log("Set up in \(Int(seconds)) s")
        return try store.update(current) { record in
            record.state = .ready
            record.provisionSeconds = seconds
            record.systemCheckedAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        }
    }

    /// What a derived Linux image gets once its daemon answers: the network card's address
    /// (a recipe's first step may download), the compiler and make when asked for and
    /// missing, then the recipes in order. Returns the updated image.
    func configureLinux(_ image: GoldenImage, machine: GuestMachine, commandLineTools: Bool, recipes: [ImageRecipe]) async throws -> GoldenImage {
        var current = image
        var steps = [LinuxSetup.waitForNetwork, LinuxSetup.toolFolder(user: current.record.userName)]
        var installsTools = false
        if commandLineTools {
            if let installed = current.record.commandLineTools {
                log("  the compiler and make are already installed (\(installed))")
            } else {
                steps += [LinuxSetup.packageLists, LinuxSetup.tools]
                installsTools = true
            }
        }
        try await runLinuxSteps(steps, machine: machine, offset: 0, count: steps.count)
        if installsTools {
            let version = try await guestCapture(machine, Self.rootRequest(LinuxSetup.toolsVersion))
            let label = try LinuxSetup.packageVersion(version.stdout, package: LinuxSetup.toolsPackage)
            current = try store.update(current) { $0.commandLineTools = "\(LinuxSetup.toolsPackage) \(label)" }
        }
        return try await applyRecipes(recipes, to: current, machine: machine)
    }

    /// After a disk was made longer: the root file system must have grown into it (the
    /// system does that by itself at boot), or the new image would be the old size for good.
    func checkRootGrew(_ machine: GuestMachine, diskBytes: UInt64) async throws {
        let result = try await guestCapture(machine, Self.rootRequest(LinuxSetup.rootSize))
        let size = UInt64(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        // Nine tenths: the boot partitions and the file system's own tables take the rest.
        guard result.report == ExitReport(status: 0), size >= diskBytes / 10 * 9 else {
            throw AgentVMError.guestCommandFailed(command: "check the disk's size", status: result.report.shellStatus,
                                                  output: "the root file system has \(size >> 20) MB on a \(diskBytes >> 30) GB disk: it did not grow")
        }
        log("  root file system grown to \(size >> 30) GB")
    }

    /// A script run as root, with apt told to ask nothing.
    nonisolated static func rootRequest(_ script: String) -> GuestRequest {
        return GuestRequest(op: .exec, argv: ["/bin/sh", "-c", script], env: LinuxSetup.environment, cwd: "/", user: "root")
    }

    /// Runs setup steps in order, each with its output in the build log; `offset` and `count`
    /// place them among all the steps of the build.
    func runLinuxSteps(_ steps: [LinuxSetup.Step], machine: GuestMachine, offset: Int, count: Int) async throws {
        let clock = ContinuousClock()
        for (index, step) in steps.enumerated() {
            let began = clock.now
            let position = offset + index + 1
            progress("linux-setup", "  [\(position)/\(count)] \(step.name)", fraction: Double(position - 1) / Double(count), index: position, count: count)
            let label = "setup step \(position) (\(step.name))"
            let emit = LineEmitter(report: report, image: subject)
            let ended: ExitReport
            do {
                ended = try await runStreaming(machine, label, Self.rootRequest(step.script), input: nil, readTimeout: step.timeout, emit: emit)
            } catch {
                emit.flush()
                throw Self.recipeFailure(label, error, timeoutSeconds: step.timeout, output: emit.tail)
            }
            guard ended == ExitReport(status: 0) else {
                throw AgentVMError.guestCommandFailed(command: label, status: ended.shellStatus, output: emit.tail)
            }
            log("      done in \(Int(Self.seconds(clock.now - began))) s")
        }
    }

    /// What the guest says it is, taken strictly (LinuxSetup.parseOSRelease), and refused when
    /// it is not the system that was asked for or its disk did not grow to the image's size.
    private func readLinuxSystem(_ machine: GuestMachine, base: LinuxBase, diskBytes: UInt64) async throws -> LinuxSystem {
        func answer(_ script: String) async throws -> String {
            let result = try await guestCapture(machine, Self.rootRequest(script))
            guard result.report == ExitReport(status: 0) else {
                throw AgentVMError.guestCommandFailed(command: script, status: result.report.shellStatus, output: Printable.line(result.stderr, limit: 300))
            }
            return result.stdout
        }
        let release = try LinuxSetup.parseOSRelease(try await answer(LinuxSetup.osRelease))
        guard release.distribution == base.distribution, release.version == base.version else {
            throw AgentVMError.guestCommandFailed(command: "read the system's description", status: 0,
                                                  output: "the cloud image is \(release.distribution) \(release.version), not \(base.name)")
        }
        let kernel = try LinuxSetup.token(try await answer(LinuxSetup.kernel), what: "kernel version")
        let architecture = try LinuxSetup.token(try await answer(LinuxSetup.architecture), what: "architecture")
        // Nine tenths: the boot partitions and the file system's own tables take the rest.
        let size = UInt64(try await answer(LinuxSetup.rootSize).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard size >= diskBytes / 10 * 9 else {
            throw AgentVMError.guestCommandFailed(command: "check the disk's size", status: 0,
                                                  output: "the root file system has \(size >> 20) MB on a \(diskBytes >> 30) GB disk: it did not grow")
        }
        return LinuxSystem(distribution: release.distribution, version: release.version, name: release.name, kernel: kernel, architecture: architecture)
    }

    /// Checks what sealing must have left, as the macOS build checks that SSH no longer
    /// answers; the first check that fails fails the build, with what it found.
    func sealCheck(_ machine: GuestMachine, checks: [LinuxSetup.Step], what: String = "seal check") async throws {
        for check in checks {
            let result = try await guestCapture(machine, Self.rootRequest(check.script))
            guard result.report == ExitReport(status: 0) else {
                let found = Printable.line((result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines), limit: 400)
                throw AgentVMError.guestCommandFailed(command: "\(what) \"\(check.name)\"", status: result.report.shellStatus, output: found)
            }
        }
        log("  checked: \(checks.map(\.name).joined(separator: "; "))")
    }

    /// Clears what must differ between the boots of one disk (LinuxSetup.prepareForCloning).
    func prepareForCloning(_ machine: GuestMachine) async throws {
        let result = try await guestCapture(machine, Self.rootRequest(LinuxSetup.prepareForCloning))
        guard result.report == ExitReport(status: 0) else {
            throw AgentVMError.guestCommandFailed(command: "clear the machine id", status: result.report.shellStatus,
                                                  output: Printable.line(result.stderr + result.stdout, limit: 300))
        }
    }
}

/// The last whole percent a download reported, so that each is reported once.
private final class LastFraction: @unchecked Sendable {
    private let lock = NSLock()
    private var percent = -1

    /// False when `percent` was reported already.
    func advance(to percent: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard percent > self.percent else {
            return false
        }
        self.percent = percent
        return true
    }
}
