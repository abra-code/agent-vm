// Sources/AgentVMKit/Images/ImageBuilder.swift
//
// Builds a golden image with no clicks: install macOS from a restore image, then boot once
// with Virtualization's guest provisioning (macOS 27), which creates an administrator account,
// logs it in automatically and turns on Remote Login. The build checks the account over SSH
// and shuts the guest down from inside, since `requestStop()` does not stop a macOS guest with
// a logged-in user. Every step is written to the image record, so an interrupted or failed
// build is visible in `agent-vm image list`.

import CryptoKit
import Darwin
import Foundation
import Security
import Virtualization

public struct ImageBuildOptions: Sendable {
    public var name: String
    public var restoreImage: URL
    public var cpuCount: Int
    public var memoryBytes: UInt64
    public var diskBytes: UInt64
    public var userName: String
    /// Absolute path of the agent-vm executable, which answers ssh's password prompt.
    public var askpassProgram: String
    /// The agent-vm-guest executable installed into the image.
    public var guestDaemon: URL
    /// Install Xcode's Command Line Tools (clang, swift, git, python3) into the image.
    public var commandLineTools: Bool
    /// Steps and checks run after the tools, before the image is sealed.
    public var recipe: ImageRecipe?

    public init(name: String, restoreImage: URL, cpuCount: Int, memoryBytes: UInt64, diskBytes: UInt64,
                userName: String, askpassProgram: String, guestDaemon: URL, commandLineTools: Bool = true,
                recipe: ImageRecipe? = nil) {
        self.name = name
        self.restoreImage = restoreImage
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
        self.userName = userName
        self.askpassProgram = askpassProgram
        self.guestDaemon = guestDaemon
        self.commandLineTools = commandLineTools
        self.recipe = recipe
    }

    public static let defaultCPUCount = 4
    public static let defaultMemoryBytes: UInt64 = 8 << 30
    public static let defaultDiskBytes: UInt64 = 64 << 30
    /// An installed macOS 27 takes about 28 GB; below this the first boot runs out of room.
    public static let minimumDiskBytes: UInt64 = 40 << 30

    /// A short name for the macOS account: lower-case letters, digits and "_", starting
    /// with a letter; not a name macOS reserves.
    public static func isValidUserName(_ name: String) -> Bool {
        let reserved: Set<String> = ["root", "daemon", "nobody", "admin", "guest", "staff", "wheel", "everyone"]
        return name.range(of: #"^[a-z][a-z0-9_]{0,30}$"#, options: .regularExpression) != nil && !reserved.contains(name)
    }
}

/// An image built from another image (`image create --from`).
public struct ImageDeriveOptions: Sendable {
    public var name: String
    public var base: String
    public var recipe: ImageRecipe?
    /// Install the Command Line Tools if the base lacks them.
    public var commandLineTools: Bool
    /// nil: the base image's.
    public var cpuCount: Int?
    public var memoryBytes: UInt64?

    /// The agent-vm-guest to put in the new image when the base has another one (nil: keep the
    /// base's).
    public var guestDaemon: URL?

    public init(name: String, base: String, recipe: ImageRecipe?, commandLineTools: Bool, cpuCount: Int? = nil, memoryBytes: UInt64? = nil,
                guestDaemon: URL? = nil) {
        self.guestDaemon = guestDaemon
        self.name = name
        self.base = base
        self.recipe = recipe
        self.commandLineTools = commandLineTools
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
    }
}

@MainActor
public final class ImageBuilder {
    public let store: ImageStore
    let log: @MainActor (String) -> Void

    /// How long the first boot may take to bring up SSH, and the shutdown to finish.
    static let provisionTimeout: Duration = .seconds(600)
    static let shutdownTimeout: Duration = .seconds(120)

    public init(store: ImageStore, log: @escaping @MainActor (String) -> Void) {
        self.store = store
        self.log = log
    }

    /// Builds the image; on failure the record says which step failed and the folder is kept
    /// for inspection (`agent-vm image delete` removes it).
    public func build(_ options: ImageBuildOptions) async throws -> GoldenImage {
        guard ImageStore.isValidName(options.name) else {
            throw AgentVMError.invalidImageName(options.name)
        }
        guard ImageBuildOptions.isValidUserName(options.userName) else {
            throw AgentVMError.invalidUserName(options.userName)
        }
        guard options.diskBytes >= ImageBuildOptions.minimumDiskBytes else {
            throw AgentVMError.virtualMachine(operation: "create the disk", message: "\(options.diskBytes >> 30) GB is too small; macOS needs at least \(ImageBuildOptions.minimumDiskBytes >> 30) GB")
        }
        guard FileSystem.exists(options.restoreImage.path) else {
            throw AgentVMError.virtualMachine(operation: "read restore image", message: "\(options.restoreImage.path) does not exist")
        }
        guard access(options.guestDaemon.path, X_OK) == 0 else {
            throw AgentVMError.hostNotReady("the guest daemon \(options.guestDaemon.path) is missing; Scripts/build.sh builds it next to agent-vm")
        }
        // Fail on an existing name before reading the multi-GB restore image.
        if FileSystem.exists(store.imagesDirectory.appendingPathComponent(options.name).path) {
            let state = (try? store.image(named: options.name))?.record.state.rawValue ?? "unreadable"
            throw AgentVMError.imageExists(name: options.name, state: state)
        }
        try Self.checkHost(HostFacts.current(storeRoot: store.root))

        log("Reading \(options.restoreImage.path)")
        let restore = try await RestoreImage.inspect(options.restoreImage)
        let cpuCount = max(options.cpuCount, restore.minimumCPUCount)
        let memoryBytes = max(options.memoryBytes, restore.minimumMemoryBytes)
        guard cpuCount <= VZVirtualMachineConfiguration.maximumAllowedCPUCount,
              memoryBytes <= VZVirtualMachineConfiguration.maximumAllowedMemorySize else {
            throw AgentVMError.virtualMachine(operation: "configure \(options.name)", message: "\(cpuCount) CPUs and \(memoryBytes >> 30) GB exceed what this Mac allows")
        }
        log("macOS \(restore.version) (\(restore.build)); \(cpuCount) CPUs, \(memoryBytes >> 30) GB memory, \(options.diskBytes >> 30) GB disk")

        let record = ImageRecord(
            formatVersion: ImageRecord.currentFormatVersion, name: options.name, state: .installing, failure: nil,
            createdAt: Date(), createdBy: AgentVM.version, macOSVersion: restore.version, macOSBuild: restore.build,
            cpuCount: cpuCount, memoryBytes: memoryBytes, diskBytes: options.diskBytes,
            macAddress: VZMACAddress.randomLocallyAdministered().string, userName: options.userName,
            installSeconds: nil, provisionSeconds: nil)
        let created = try store.create(record)
        var image = created.0
        let lock = created.1
        defer { lock.release() }

        do {
            // One machine for both steps: a second VZVirtualMachine on the same auxiliary
            // storage fails to start ("Failed to lock auxiliary storage") while the installer's
            // machine is still being torn down.
            let machine: MacMachine
            (image, machine) = try await install(image, restore: restore, from: options.restoreImage)
            image = try await provision(image, machine: machine, options: options)
            return image
        } catch {
            let reason = "\(error)"
            _ = try? store.update(image) { record in
                record.state = .failed
                record.failure = reason
            }
            throw error
        }
    }

    /// Refuses before anything is written when the build cannot succeed: without the
    /// virtualization entitlement every VM is refused, and an install needs about 30 GB.
    static func checkHost(_ facts: HostFacts, minimumFree: Int64 = minimumFreeBytes) throws {
        if facts.hasVirtualizationEntitlement == false {
            throw AgentVMError.hostNotReady("this agent-vm binary lacks the com.apple.security.virtualization entitlement; build it with Scripts/build.sh")
        }
        if let free = facts.storeFreeBytes, free < minimumFree {
            throw AgentVMError.hostNotReady("\(free >> 30) GB free on the volume of \(facts.storeRoot); \(minimumFree >> 30) GB free leaves room for the image and for the guest to work")
        }
    }

    static let minimumFreeBytes: Int64 = 40 << 30
    /// A derived image starts as a clone and grows by what its recipe installs.
    static let minimumFreeBytesToDerive: Int64 = 10 << 30

    // MARK: - Derived images

    /// Builds an image from a ready one: clones it (instant, copy-on-write; its own MAC and
    /// machine identifier), boots it on NAT, and applies the Command Line Tools if asked and
    /// missing, then the recipe, through the guest daemon. Minutes instead of a macOS install,
    /// and one base can carry several tool sets.
    public func derive(_ options: ImageDeriveOptions) async throws -> GoldenImage {
        guard ImageStore.isValidName(options.name) else {
            throw AgentVMError.invalidImageName(options.name)
        }
        if FileSystem.exists(store.imagesDirectory.appendingPathComponent(options.name).path) {
            let state = (try? store.image(named: options.name))?.record.state.rawValue ?? "unreadable"
            throw AgentVMError.imageExists(name: options.name, state: state)
        }
        let base = try store.image(named: options.base)
        guard base.record.state == .ready else {
            throw AgentVMError.wrongImageState(name: base.name, state: base.record.state.rawValue, operation: "build an image from")
        }
        guard base.record.guestProtocol == AgentVM.guestProtocolVersion else {
            throw AgentVMError.wrongImageState(name: base.name, state: "built with guest protocol \(base.record.guestProtocol.map(String.init) ?? "none"), not \(AgentVM.guestProtocolVersion)", operation: "build an image from")
        }
        try Self.checkHost(HostFacts.current(storeRoot: store.root), minimumFree: Self.minimumFreeBytesToDerive)
        if let guestDaemon = options.guestDaemon, access(guestDaemon.path, X_OK) != 0 {
            throw AgentVMError.hostNotReady("the guest daemon \(guestDaemon.path) is missing; Scripts/build.sh builds it next to agent-vm")
        }
        let cpuCount = options.cpuCount ?? base.record.cpuCount
        let memoryBytes = options.memoryBytes ?? base.record.memoryBytes
        guard cpuCount <= VZVirtualMachineConfiguration.maximumAllowedCPUCount,
              memoryBytes <= VZVirtualMachineConfiguration.maximumAllowedMemorySize else {
            throw AgentVMError.virtualMachine(operation: "configure \(options.name)", message: "\(cpuCount) CPUs and \(memoryBytes >> 30) GB exceed what this Mac allows")
        }

        guard let baseLock = try store.tryLock(base) else {
            throw AgentVMError.imageBusy(base.name)
        }
        var record = base.record
        // Written by this agent-vm, so in its format, whatever format the base was written in.
        record.formatVersion = ImageRecord.currentFormatVersion
        record.name = options.name
        record.state = .installing
        record.failure = nil
        record.createdAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        record.createdBy = AgentVM.version
        record.cpuCount = cpuCount
        record.memoryBytes = memoryBytes
        record.macAddress = VZMACAddress.randomLocallyAdministered().string
        record.installSeconds = nil
        record.provisionSeconds = nil
        record.recipe = nil
        record.derivedFrom = ImageRecord.DerivedFrom(image: base.name, recipeDigest: base.record.recipe?.digest)
        let created: (GoldenImage, ImageStore.Lock)
        do {
            created = try store.create(record)
        } catch {
            baseLock.release()
            throw error
        }
        var image = created.0
        let lock = created.1
        defer { lock.release() }

        let clock = ContinuousClock()
        let began = clock.now
        do {
            log("Cloning \(base.name) (macOS \(base.record.macOSBuild)\(base.record.recipe.map { ", recipe \($0.description ?? String($0.digest.prefix(12)))" } ?? ""))")
            do {
                defer { baseLock.release() }
                try BoxStore.cloneFile(base.diskURL, to: image.diskURL)
                try BoxStore.cloneFile(base.auxiliaryStorageURL, to: image.auxiliaryStorageURL)
                try BoxStore.cloneFile(base.hardwareModelURL, to: image.hardwareModelURL)
                try BoxStore.cloneFile(base.passwordURL, to: image.passwordURL)
                try VZMacMachineIdentifier().dataRepresentation.write(to: image.machineIdentifierURL)
            }
            image = try store.update(image) { $0.state = .provisioning }

            let auxiliaryStorage = VZMacAuxiliaryStorage(url: image.auxiliaryStorageURL)
            let machine = MacMachine(configuration: try spec(image).configuration(for: image.machineFiles, auxiliaryStorage: auxiliaryStorage))
            var replacedDaemon: (digest: String, replaced: Bool)?
            log("Booting")
            try await machine.start(provisioning: nil)
            do {
                // A clone boots like any box: the daemon answers once macOS is up.
                let hello = try await waitForDaemon(machine, attempts: 180)
                log("  agent-vm-guest \(hello.version ?? "?") answers over vsock")
                image = try store.update(image) { record in
                    record.guestVersion = hello.version
                    record.guestFeatures = hello.features
                }
                image = try await configure(image, machine: machine, commandLineTools: options.commandLineTools, recipe: options.recipe)
                // Last, so the recipe ran under the daemon it was tested with.
                if let guestDaemon = options.guestDaemon {
                    replacedDaemon = try await replaceGuestDaemon(guestDaemon, machine: machine)
                }
                try await shutDown(machine)
            } catch {
                if machine.isRunning {
                    try? await machine.forceStop()
                }
                throw error
            }
            if let replacedDaemon, replacedDaemon.replaced {
                image = try await checkGuestDaemon(image, digest: replacedDaemon.digest)
            } else if let replacedDaemon {
                image = try store.update(image) { record in
                    record.guestDigest = replacedDaemon.digest
                    // Probed in configure, under this same daemon (the base may not have had its digest).
                    record.fullDiskAccess?.guestDigest = replacedDaemon.digest
                }
            }
            let seconds = Self.seconds(clock.now - began)
            log("Built in \(Int(seconds)) s")
            return try store.update(image) { record in
                record.state = .ready
                record.provisionSeconds = seconds
            }
        } catch {
            let reason = "\(error)"
            _ = try? store.update(image) { record in
                record.state = .failed
                record.failure = reason
            }
            throw error
        }
    }

    // MARK: - Updating the guest daemon

    /// Puts this agent-vm's agent-vm-guest into a ready image, in place: boots it, replaces the
    /// daemon if it differs, shuts down, and boots once more to check the new one (a minute or
    /// two). Boxes made from the image earlier keep their own. The image stays ready, and is
    /// marked failed only when the new daemon does not answer.
    public func updateGuest(named name: String, guestDaemon: URL) async throws -> GoldenImage {
        var image = try store.image(named: name)
        guard image.record.state == .ready else {
            throw AgentVMError.wrongImageState(name: image.name, state: image.record.state.rawValue, operation: "update the guest daemon of")
        }
        guard access(guestDaemon.path, X_OK) == 0 else {
            throw AgentVMError.hostNotReady("the guest daemon \(guestDaemon.path) is missing; Scripts/build.sh builds it next to agent-vm")
        }
        try Self.checkHost(HostFacts.current(storeRoot: store.root), minimumFree: Self.minimumFreeBytesToUpdate)
        guard let lock = try store.tryLock(image) else {
            throw AgentVMError.imageBusy(image.name)
        }
        defer { lock.release() }

        let auxiliaryStorage = VZMacAuxiliaryStorage(url: image.auxiliaryStorageURL)
        let machine = MacMachine(configuration: try spec(image).configuration(for: image.machineFiles, auxiliaryStorage: auxiliaryStorage))
        log("Booting \(image.name)")
        try await machine.start(provisioning: nil)
        let outcome: (digest: String, replaced: Bool)
        do {
            let hello = try await waitForDaemon(machine, attempts: 180)
            log("  agent-vm-guest \(hello.version ?? "?") answers (\((hello.features ?? []).joined(separator: ", ")))")
            outcome = try await replaceGuestDaemon(guestDaemon, machine: machine)
            if !outcome.replaced {
                image = try store.update(image) { record in
                    record.guestFeatures = hello.features
                    record.guestDigest = outcome.digest
                }
                image = try await recordFullDiskAccess(image, machine: machine, digest: outcome.digest)
            }
            try await shutDown(machine)
        } catch {
            if machine.isRunning {
                try? await machine.forceStop()
            }
            throw error
        }
        guard outcome.replaced else {
            return image
        }
        do {
            return try await checkGuestDaemon(image, digest: outcome.digest)
        } catch {
            let reason = "the new agent-vm-guest did not start: \(error)"
            _ = try? store.update(image) { record in
                record.state = .failed
                record.failure = reason
            }
            throw error
        }
    }

    /// Updating writes little: a new daemon and whatever two boots write.
    static let minimumFreeBytesToUpdate: Int64 = 2 << 30

    // MARK: - Steps

    private func install(_ image: GoldenImage, restore: RestoreImage.Info, from restoreImage: URL) async throws -> (GoldenImage, MacMachine) {
        let clock = ContinuousClock()
        let began = clock.now
        try restore.hardwareModel.write(to: image.hardwareModelURL)
        try VZMacMachineIdentifier().dataRepresentation.write(to: image.machineIdentifierURL)
        try Self.writePassword(Self.newPassword(), to: image.passwordURL)
        try Self.createSparseDisk(at: image.diskURL, bytes: image.record.diskBytes)
        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: restore.hardwareModel) else {
            throw AgentVMError.virtualMachine(operation: "install macOS", message: "the restore image's hardware model is unreadable")
        }
        let auxiliaryStorage: VZMacAuxiliaryStorage
        do {
            auxiliaryStorage = try VZMacAuxiliaryStorage(creatingStorageAt: image.auxiliaryStorageURL, hardwareModel: hardwareModel, options: [])
        } catch {
            throw AgentVMError.virtualMachine(operation: "create auxiliary storage", message: error.localizedDescription)
        }
        let machine = MacMachine(configuration: try spec(image).configuration(for: image.machineFiles, auxiliaryStorage: auxiliaryStorage))

        log("Installing macOS (a few minutes)...")
        var reported = -1
        try await machine.install(from: restoreImage) { [log] fraction in
            let percent = Int(fraction * 100)
            if percent / 10 > reported / 10 {
                reported = percent
                log("  \(percent)%")
            }
        }
        // The installer reports success while the machine is still running. Stopping it here
        // is what exiting the process after install does, and the first boot then works.
        if !(await machine.waitUntilStopped(timeout: .seconds(10))) {
            try await machine.forceStop()
        }
        let seconds = Self.seconds(clock.now - began)
        log("Installed in \(Int(seconds)) s")
        let installed = try store.update(image) { record in
            record.state = .installed
            record.installSeconds = seconds
        }
        return (installed, machine)
    }

    private func provision(_ image: GoldenImage, machine: MacMachine, options: ImageBuildOptions) async throws -> GoldenImage {
        let clock = ContinuousClock()
        let began = clock.now
        var current = try store.update(image) { $0.state = .provisioning }
        let password = try String(contentsOf: image.passwordURL, encoding: .utf8)

        let provisioning = VZMacGuestProvisioningOptions()
        provisioning.fullName = "Agent"
        provisioning.username = image.record.userName
        provisioning.password = password
        provisioning.logsInAutomatically = true
        provisioning.enablesRemoteLogin = true

        log("First boot: creating account \(image.record.userName), logging in, turning on SSH")
        try await machine.start(provisioning: provisioning)

        do {
            let host = try await waitForSSH(machine, macAddress: image.record.macAddress)
            let ssh = GuestSSH(host: host, user: image.record.userName, passwordFile: image.passwordURL,
                               knownHostsFile: image.knownHostsURL, askpassProgram: options.askpassProgram)
            let facts = try await checkAccount(ssh, image: image)
            log("Guest \(host): \(facts)")

            log("Installing the guest daemon")
            try await installGuestDaemon(options.guestDaemon, user: image.record.userName, over: ssh, password: password)
            let hello = try await waitForDaemon(machine)
            let identity = try await guestCapture(machine, GuestRequest(op: .exec, argv: ["/usr/bin/id", "-un"]))
            guard identity.report == ExitReport(status: 0), identity.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == image.record.userName else {
                throw AgentVMError.guestCommandFailed(command: "id -un", status: identity.report.shellStatus,
                                                      output: "expected \(image.record.userName), got \"\(identity.stdout.trimmingCharacters(in: .whitespacesAndNewlines))\" \(identity.stderr)")
            }
            log("  agent-vm-guest \(hello.version ?? "?") answers over vsock (protocol \(hello.v ?? 0)), runs programs as \(image.record.userName)")
            current = try store.update(current) { record in
                record.guestVersion = hello.version
                record.guestProtocol = hello.v
                record.guestFeatures = hello.features
                record.guestDigest = try? Self.sha256(of: options.guestDaemon)
            }

            current = try await configure(current, machine: machine, commandLineTools: options.commandLineTools, recipe: options.recipe)

            // From here on the daemon is the only way in.
            let disabled = try await guestCapture(machine, GuestRequest(op: .exec, argv: ["/bin/sh", "-c", GuestDaemon.disableSSHCommand], user: "root"))
            guard disabled.report == ExitReport(status: 0) else {
                throw AgentVMError.guestCommandFailed(command: "turn off Remote Login", status: disabled.report.shellStatus, output: disabled.stderr)
            }
            try await Task.sleep(for: .seconds(1))
            let stillOpen = await Task.detached { GuestNetwork.isPortOpen(host, port: 22) }.value
            if stillOpen {
                throw AgentVMError.guestCommandFailed(command: "turn off Remote Login", status: 0, output: "SSH still answers on \(host)")
            }
            log("  Remote Login turned off")

            try await shutDown(machine)
        } catch {
            if machine.isRunning {
                try? await machine.forceStop()
            }
            throw error
        }
        let seconds = Self.seconds(clock.now - began)
        log("Set up in \(Int(seconds)) s")
        return try store.update(current) { record in
            record.state = .ready
            record.provisionSeconds = seconds
        }
    }

    /// What every image gets once its guest daemon answers: Spotlight indexing off, the
    /// Command Line Tools when asked for and missing, then the recipe. Returns the updated
    /// image.
    private func configure(_ image: GoldenImage, machine: MacMachine, commandLineTools: Bool, recipe: ImageRecipe?) async throws -> GoldenImage {
        var current = image
        // Boxes have no use for Spotlight, and indexing the whole new disk competes with the
        // first boot's installs: the Command Line Tools took 26 minutes during the first
        // boot's indexing and 83 s in a settled box (measured).
        let spotlight = try await guestCapture(machine, GuestRequest(op: .exec, argv: ["/usr/bin/mdutil", "-a", "-i", "off"], cwd: "/", user: "root"))
        if spotlight.report == ExitReport(status: 0) {
            log("  Spotlight indexing off")
        } else {
            log("  note: could not turn Spotlight indexing off: \((spotlight.stderr + spotlight.stdout).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        // A window on a box (box view) must never meet a lock screen that asks for the password.
        try await keepDesktopUnlocked(machine, user: current.record.userName,
                                      password: try String(contentsOf: current.passwordURL, encoding: .utf8))

        if commandLineTools {
            if let installed = current.record.commandLineTools {
                log("  Command Line Tools already installed (\(installed))")
            } else {
                let label = try await installCommandLineTools(machine)
                current = try store.update(current) { $0.commandLineTools = label }
            }
        }
        if let recipe {
            try await apply(recipe, machine: machine, boxUser: current.record.userName)
            try Data(recipe.text.utf8).write(to: current.recipeURL)
            current = try store.update(current) { record in
                record.recipe = ImageRecord.RecipeInfo(description: recipe.description, digest: recipe.digest)
            }
        }
        // Checked, so image list says whether boxes can open protected folders (image setup).
        return try await recordFullDiskAccess(current, machine: machine, digest: current.record.guestDigest)
    }

    /// `requestStop()` leaves a logged-in guest running; the daemon shuts it down.
    func shutDown(_ machine: MacMachine) async throws {
        log("Shutting down")
        try await withGuest(machine) { descriptor in
            try GuestClient.shutdown(descriptor)
        }
        guard await machine.waitUntilStopped(timeout: Self.shutdownTimeout) else {
            throw AgentVMError.guestUnreachable("the guest did not shut down within \(Self.shutdownTimeout)")
        }
        if let failure = machine.failure {
            throw AgentVMError.virtualMachine(operation: "shut down the guest", message: failure)
        }
    }

    /// Copies agent-vm-guest and its LaunchDaemon definition into the guest and loads it.
    private func installGuestDaemon(_ executable: URL, user: String, over ssh: GuestSSH, password: String) async throws {
        let plist = FileManager.default.temporaryDirectory.appendingPathComponent("agent-vm-guest-\(UUID().uuidString).plist")
        try GuestDaemon.launchdPlist(user: user).write(to: plist)
        defer { try? FileManager.default.removeItem(at: plist) }
        try await ssh.copy(executable, to: GuestDaemon.stagedExecutable)
        try await ssh.copy(plist, to: GuestDaemon.stagedPlist)
        try await ssh.check("/usr/bin/sudo -S -p '' /bin/sh -c '\(GuestDaemon.installCommand)'", input: Data((password + "\n").utf8))
    }

    /// Puts `executable` in the guest in place of its agent-vm-guest when the two differ (by
    /// SHA-256), through the running daemon; the new one runs from the next boot.
    private func replaceGuestDaemon(_ executable: URL, machine: MacMachine) async throws -> (digest: String, replaced: Bool) {
        let digest = try Self.sha256(of: executable)
        let installed = try await guestCapture(machine, GuestRequest(op: .exec, argv: ["/usr/bin/shasum", "-a", "256", GuestDaemon.executablePath],
                                                                     cwd: "/", user: "root"))
        if installed.report == ExitReport(status: 0), installed.stdout.hasPrefix(digest + " ") {
            log("  agent-vm-guest is already this agent-vm's")
            return (digest, false)
        }
        log("Replacing agent-vm-guest with this agent-vm's")
        let data = try Data(contentsOf: executable)
        let request = GuestRequest(op: .exec, argv: ["/bin/sh", "-c", GuestDaemon.replaceCommand(digest: digest)], cwd: "/", user: "root")
        let replaced = try await withGuest(machine, readTimeout: 120) { try GuestClient.capture($0, request, input: data) }
        guard replaced.report == ExitReport(status: 0), replaced.stdout.hasPrefix(digest + " ") else {
            throw AgentVMError.guestCommandFailed(command: "replace agent-vm-guest", status: replaced.report.shellStatus,
                                                  output: (replaced.stderr + replaced.stdout).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (digest, true)
    }

    /// Boots `image` once more, checks that its new agent-vm-guest answers with every feature
    /// this agent-vm knows, records it, and shuts down.
    private func checkGuestDaemon(_ image: GoldenImage, digest: String) async throws -> GoldenImage {
        let auxiliaryStorage = VZMacAuxiliaryStorage(url: image.auxiliaryStorageURL)
        let machine = MacMachine(configuration: try spec(image).configuration(for: image.machineFiles, auxiliaryStorage: auxiliaryStorage))
        log("Booting again to check the new agent-vm-guest")
        try await machine.start(provisioning: nil)
        do {
            let hello = try await waitForDaemon(machine, attempts: 180)
            let missing = GuestFeature.all.filter { !(hello.features ?? []).contains($0) }
            guard missing.isEmpty else {
                throw AgentVMError.guestCommandFailed(command: "hello", status: 0, output: "the new agent-vm-guest lacks \(missing.joined(separator: ", "))")
            }
            log("  agent-vm-guest \(hello.version ?? "?") answers (\((hello.features ?? []).joined(separator: ", ")))")
            let checked = try await recordFullDiskAccess(image, machine: machine, digest: digest)
            try await shutDown(machine)
            return try store.update(checked) { record in
                record.guestVersion = hello.version
                record.guestProtocol = hello.v
                record.guestFeatures = hello.features
                record.guestDigest = digest
            }
        } catch {
            if machine.isRunning {
                try? await machine.forceStop()
            }
            throw error
        }
    }

    static func sha256(of url: URL) throws -> String {
        return SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// Waits until the daemon answers hello (launchd starts it within a second or two).
    func waitForDaemon(_ machine: MacMachine, attempts: Int = 30) async throws -> GuestResponse {
        var lastError: Error = AgentVMError.guestUnreachable("the guest daemon did not answer")
        for _ in 0..<attempts {
            // A guest that stopped will not answer; say so now rather than after every attempt.
            guard machine.isRunning else {
                throw AgentVMError.guestUnreachable("the guest stopped before its daemon answered\(machine.failure.map { ": \($0)" } ?? "")")
            }
            do {
                let hello = try await withGuest(machine) { try GuestClient.hello($0) }
                guard hello.v == AgentVM.guestProtocolVersion else {
                    throw AgentVMError.guestCommandFailed(command: "hello", status: 0, output: "the guest daemon speaks protocol \(hello.v ?? 0), agent-vm \(AgentVM.guestProtocolVersion)")
                }
                return hello
            } catch let error as AgentVMError {
                // A daemon that answers but refuses, or speaks another protocol, will not change.
                switch error {
                case .guestRefused, .guestCommandFailed:
                    throw error
                default:
                    lastError = error
                }
            } catch {
                lastError = error
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw lastError
    }

    /// Installs the Command Line Tools through softwareupdate (over the image build's NAT) and
    /// checks them as the box user; returns the installed label.
    private func installCommandLineTools(_ machine: MacMachine) async throws -> String {
        let clock = ContinuousClock()
        let began = clock.now
        log("Installing the Command Line Tools (about 530 MB)")
        let listed = try await guestCapture(machine, CommandLineTools.listRequest, readTimeout: 300)
        guard listed.report == ExitReport(status: 0), let label = CommandLineTools.label(fromListOutput: listed.stdout) else {
            _ = try? await guestCapture(machine, CommandLineTools.cleanupRequest)
            throw AgentVMError.guestCommandFailed(command: "softwareupdate --list", status: listed.report.shellStatus,
                                                  output: "no Command Line Tools offered: \(String(listed.stdout.suffix(400)))")
        }
        log("  \(label)")
        // softwareupdate can be silent for minutes while it downloads.
        let installed = try await guestCapture(machine, CommandLineTools.installRequest(label: label), readTimeout: 1800)
        _ = try? await guestCapture(machine, CommandLineTools.cleanupRequest)
        guard installed.report == ExitReport(status: 0) else {
            throw AgentVMError.guestCommandFailed(command: "softwareupdate --install \(label)", status: installed.report.shellStatus,
                                                  output: String((installed.stdout + installed.stderr).suffix(400)))
        }
        let verified = try await guestCapture(machine, CommandLineTools.verifyRequest)
        guard verified.report == ExitReport(status: 0) else {
            throw AgentVMError.guestCommandFailed(command: "check the Command Line Tools", status: verified.report.shellStatus,
                                                  output: (verified.stderr + verified.stdout).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let summary = verified.stdout.split(whereSeparator: \.isNewline).dropFirst().joined(separator: "; ")
        log("  installed in \(Int(Self.seconds(clock.now - began))) s: \(summary)")
        return label
    }

    /// Runs a recipe's steps, then its checks; any failure fails the build with the step's name
    /// and the end of its output.
    func apply(_ recipe: ImageRecipe, machine: MacMachine, boxUser: String) async throws {
        let clock = ContinuousClock()
        let began = clock.now
        log("Recipe\(recipe.description.map { ": \($0)" } ?? "") (\(recipe.steps.count) steps, \(recipe.checks.count) checks)")
        for (index, step) in recipe.steps.enumerated() {
            let stepBegan = clock.now
            log("  [\(index + 1)/\(recipe.steps.count)] \(step.name)\(step.user == "root" ? " (as root)" : "")")
            let request: GuestRequest
            var input: Data?
            switch step.action {
            case let .run(command):
                request = ImageRecipe.runRequest(step, command: command, boxUser: boxUser)
            case let .copy(source, destination, mode):
                request = ImageRecipe.copyRequest(step, destination: destination, mode: mode)
                input = try ImageRecipe.copyContents(step, source: source)
            }
            let label = "recipe step \(index + 1) (\(step.name))"
            let emit = LineEmitter(log: log)
            let report: ExitReport
            do {
                report = try await runStreaming(machine, request, input: input, readTimeout: step.timeoutSeconds, emit: emit)
            } catch {
                emit.flush()
                throw Self.recipeFailure(label, error, timeoutSeconds: step.timeoutSeconds, output: emit.tail)
            }
            guard report == ExitReport(status: 0) else {
                throw AgentVMError.guestCommandFailed(command: label, status: report.shellStatus, output: emit.tail)
            }
            log("      done in \(Int(Self.seconds(clock.now - stepBegan))) s")
        }
        for check in recipe.checks {
            let result: (report: ExitReport, stdout: String, stderr: String)
            do {
                result = try await guestCapture(machine, ImageRecipe.checkRequest(check), readTimeout: Self.checkTimeoutSeconds)
            } catch {
                throw Self.recipeFailure("recipe check \(check)", error, timeoutSeconds: Self.checkTimeoutSeconds, output: "")
            }
            let output = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.report == ExitReport(status: 0) else {
                throw AgentVMError.guestCommandFailed(command: "recipe check \(check)", status: result.report.shellStatus, output: String(output.suffix(800)))
            }
            log("  check \(check): \(output.split(whereSeparator: \.isNewline).first.map(String.init) ?? "ok")")
        }
        log("  recipe applied in \(Int(Self.seconds(clock.now - began))) s")
    }

    nonisolated static let checkTimeoutSeconds = 300

    /// A step or check that ended without an exit status (silent past its timeout, refused, or
    /// the connection lost), as an error that names it and keeps the end of its output.
    nonisolated static func recipeFailure(_ label: String, _ error: Error, timeoutSeconds: Int, output: String) -> Error {
        let last = output.isEmpty ? "" : "; last output:\n\(output)"
        switch error {
        case GuestProtocolError.io(operation: "read", code: EAGAIN):
            // SO_RCVTIMEO expired; closing the connection makes the daemon stop the program.
            // 124 is what timeout(1) exits with.
            return AgentVMError.guestCommandFailed(command: label, status: 124, output: "no output for \(timeoutSeconds) s, stopped\(last)")
        case let refusal as ExecRefusal:
            return AgentVMError.guestCommandFailed(command: label, status: refusal.status, output: refusal.message)
        default:
            return AgentVMError.guestUnreachable("during \(label): \(error)\(last)")
        }
    }

    /// Runs one request with its output shown line by line in the build log (indented) through
    /// `emit`, and `input` as its standard input; returns how it ended.
    private func runStreaming(_ machine: MacMachine, _ request: GuestRequest, input: Data?, readTimeout: Int, emit: LineEmitter) async throws -> ExitReport {
        return try await withGuest(machine, readTimeout: readTimeout) { descriptor in
            let session = try ExecSession(descriptor: descriptor, request: request)
            if let input {
                try session.sendStdin(Array(input))
            }
            try session.sendStdinEnd()
            let report = try session.run(stdout: { emit.add($0) }, stderr: { emit.add($0) })
            emit.flush()
            return report
        }
    }

    func guestCapture(_ machine: MacMachine, _ request: GuestRequest, readTimeout: Int = 60) async throws -> (report: ExitReport, stdout: String, stderr: String) {
        return try await withGuest(machine, readTimeout: readTimeout) { try GuestClient.capture($0, request) }
    }

    /// Runs a blocking protocol exchange on a fresh vsock connection, off the main actor, with
    /// a read timeout (seconds without any frame) so a stuck guest cannot hang the build.
    func withGuest<T: Sendable>(_ machine: MacMachine, readTimeout: Int = 60, _ body: @escaping @Sendable (Int32) throws -> T) async throws -> T {
        let connection = try await machine.connect(toPort: GuestProtocol.port)
        defer { connection.close() }
        let descriptor = connection.descriptor
        var timeout = timeval(tv_sec: readTimeout, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return try await Task.detached {
            try body(descriptor)
        }.value
    }

    /// Waits for the guest's DHCP lease and for its SSH port to accept connections.
    private func waitForSSH(_ machine: MacMachine, macAddress: String) async throws -> String {
        let deadline = ContinuousClock.now + Self.provisionTimeout
        var announced: String?
        while ContinuousClock.now < deadline {
            guard machine.isRunning else {
                throw AgentVMError.guestUnreachable("the guest stopped during its first boot\(machine.failure.map { ": \($0)" } ?? "")")
            }
            if let host = GuestNetwork.address(forMAC: macAddress) {
                if announced != host {
                    announced = host
                    log("  address \(host)")
                }
                let open = await Task.detached { GuestNetwork.isPortOpen(host, port: 22) }.value
                if open {
                    return host
                }
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw AgentVMError.guestUnreachable("SSH did not come up within \(Self.provisionTimeout)")
    }

    /// Logs in (retrying while the account is still being created) and reads the guest's
    /// user, build and console user.
    private func checkAccount(_ ssh: GuestSSH, image: GoldenImage) async throws -> String {
        let attempts = 10
        var lastError: Error = AgentVMError.guestUnreachable("no login attempt")
        for attempt in 1...attempts {
            do {
                let output = try await ssh.check("/usr/bin/id -un; /usr/bin/sw_vers -buildVersion; /usr/bin/stat -f %Su /dev/console")
                let lines = output.split(whereSeparator: \.isNewline).map(String.init)
                guard lines.count == 3, lines[0] == image.record.userName else {
                    throw AgentVMError.guestCommandFailed(command: "id -un", status: 0, output: output)
                }
                if lines[1] != image.record.macOSBuild {
                    log("  note: the guest reports build \(lines[1]), the restore image \(image.record.macOSBuild)")
                }
                return "user \(lines[0]), macOS \(lines[1]), console user \(lines[2])"
            } catch {
                lastError = error
                if attempt < attempts {
                    try await Task.sleep(for: .seconds(3))
                }
            }
        }
        throw lastError
    }

    func spec(_ image: GoldenImage) -> MacMachineSpec {
        return MacMachineSpec(cpuCount: image.record.cpuCount, memoryBytes: image.record.memoryBytes, macAddress: image.record.macAddress)
    }

    // MARK: - Files

    /// A sparse raw disk: the file has its full logical size but takes space only as the
    /// guest writes.
    nonisolated static func createSparseDisk(at url: URL, bytes: UInt64) throws {
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw AgentVMError.system(operation: "create \(url.path)", code: errno)
        }
        defer { close(descriptor) }
        guard ftruncate(descriptor, off_t(bytes)) == 0 else {
            throw AgentVMError.system(operation: "size \(url.path)", code: errno)
        }
    }

    /// 24 random letters and digits from a 57-character alphabet (about 140 bits).
    nonisolated static func newPassword() throws -> String {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var result = ""
        while result.count < 24 {
            var byte: UInt8 = 0
            guard SecRandomCopyBytes(kSecRandomDefault, 1, &byte) == errSecSuccess else {
                throw AgentVMError.system(operation: "generate a password", code: EIO)
            }
            // Rejection sampling keeps every character equally likely.
            let limit = 256 - 256 % alphabet.count
            if Int(byte) < limit {
                result.append(alphabet[Int(byte) % alphabet.count])
            }
        }
        return result
    }

    nonisolated static func writePassword(_ password: String, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw AgentVMError.system(operation: "create \(url.path)", code: errno)
        }
        defer { close(descriptor) }
        let bytes = Array(password.utf8)
        guard write(descriptor, bytes, bytes.count) == bytes.count else {
            throw AgentVMError.system(operation: "write \(url.path)", code: errno)
        }
    }

    nonisolated static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

/// Turns a program's output into build-log lines ("      | ..."), sent to the main actor in
/// order, and keeps the last few kilobytes for error messages.
final class LineEmitter: @unchecked Sendable {
    let log: @MainActor (String) -> Void
    private let lock = NSLock()
    private var partial: [UInt8] = []
    private var recent: [UInt8] = []

    init(log: @escaping @MainActor (String) -> Void) {
        self.log = log
    }

    func add(_ bytes: [UInt8]) {
        lock.lock()
        recent.append(contentsOf: bytes)
        if recent.count > 4096 {
            recent.removeFirst(recent.count - 4096)
        }
        partial.append(contentsOf: bytes)
        var lines: [String] = []
        while let newline = partial.firstIndex(of: 10) {
            lines.append(Self.shownText(partial[..<newline]))
            partial.removeSubrange(...newline)
        }
        // A progress bar redraws its line with carriage returns: keep only what a terminal
        // would still show, and never hold more than a few kilobytes.
        if let lastReturn = partial.lastIndex(of: 13) {
            partial.removeSubrange(...lastReturn)
        }
        if partial.count > 4096 {
            lines.append(Self.shownText(partial[...]))
            partial = []
        }
        lock.unlock()
        send(lines)
    }

    /// A line as a terminal would show it: the text after its last carriage return.
    static func shownText(_ bytes: ArraySlice<UInt8>) -> String {
        let visible = bytes.lastIndex(of: 13).map { bytes[bytes.index(after: $0)...] } ?? bytes
        return String(decoding: visible, as: UTF8.self)
    }

    func flush() {
        lock.lock()
        let rest = partial.isEmpty ? [] : [String(decoding: partial, as: UTF8.self)]
        partial = []
        lock.unlock()
        send(rest)
    }

    var tail: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: recent, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send(_ lines: [String]) {
        guard !lines.isEmpty else {
            return
        }
        let log = self.log
        // Long lines are cut at 200 characters: the log is for following along.
        let shown = lines.map { "      | " + String($0.prefix(200)) }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                for line in shown {
                    log(line)
                }
            }
        }
    }
}
