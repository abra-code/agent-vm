// Sources/AgentVMKit/Images/ImageBuilder.swift
//
// Builds a golden image with no clicks: install macOS from a restore image, then boot once
// with Virtualization's guest provisioning (macOS 27), which creates an administrator account,
// logs it in automatically and turns on Remote Login. The build checks the account over SSH
// and shuts the guest down from inside, since `requestStop()` does not stop a macOS guest with
// a logged-in user. Every step is written to the image record, so an interrupted or failed
// build is visible in `agent-vm image list`.

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

    public init(name: String, restoreImage: URL, cpuCount: Int, memoryBytes: UInt64, diskBytes: UInt64,
                userName: String, askpassProgram: String, guestDaemon: URL, commandLineTools: Bool = true) {
        self.name = name
        self.restoreImage = restoreImage
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
        self.userName = userName
        self.askpassProgram = askpassProgram
        self.guestDaemon = guestDaemon
        self.commandLineTools = commandLineTools
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

@MainActor
public final class ImageBuilder {
    public let store: ImageStore
    private let log: @MainActor (String) -> Void

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
    static func checkHost(_ facts: HostFacts) throws {
        if facts.hasVirtualizationEntitlement == false {
            throw AgentVMError.hostNotReady("this agent-vm binary lacks the com.apple.security.virtualization entitlement; build it with Scripts/build.sh")
        }
        if let free = facts.storeFreeBytes, free < minimumFreeBytes {
            throw AgentVMError.hostNotReady("\(free >> 30) GB free on the volume of \(facts.storeRoot); an image needs about 30 GB, and \(minimumFreeBytes >> 30) GB free leaves room for the guest to work")
        }
    }

    static let minimumFreeBytes: Int64 = 40 << 30

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
            }

            // Boxes have no use for Spotlight, and indexing the whole new disk competes with the
            // first boot's installs: the Command Line Tools took 26 minutes during the first
            // boot's indexing and 83 s in a settled box (measured).
            let spotlight = try await guestCapture(machine, GuestRequest(op: .exec, argv: ["/usr/bin/mdutil", "-a", "-i", "off"], cwd: "/", user: "root"))
            if spotlight.report == ExitReport(status: 0) {
                log("  Spotlight indexing off")
            } else {
                log("  note: could not turn Spotlight indexing off: \((spotlight.stderr + spotlight.stdout).trimmingCharacters(in: .whitespacesAndNewlines))")
            }

            if options.commandLineTools {
                let label = try await installCommandLineTools(machine)
                current = try store.update(current) { $0.commandLineTools = label }
            }

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

            // `requestStop()` leaves a logged-in guest running; the daemon shuts it down.
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

    /// Copies agent-vm-guest and its LaunchDaemon definition into the guest and loads it.
    private func installGuestDaemon(_ executable: URL, user: String, over ssh: GuestSSH, password: String) async throws {
        let plist = FileManager.default.temporaryDirectory.appendingPathComponent("agent-vm-guest-\(UUID().uuidString).plist")
        try GuestDaemon.launchdPlist(user: user).write(to: plist)
        defer { try? FileManager.default.removeItem(at: plist) }
        try await ssh.copy(executable, to: GuestDaemon.stagedExecutable)
        try await ssh.copy(plist, to: GuestDaemon.stagedPlist)
        try await ssh.check("/usr/bin/sudo -S -p '' /bin/sh -c '\(GuestDaemon.installCommand)'", input: Data((password + "\n").utf8))
    }

    /// Waits until the daemon answers hello (launchd starts it within a second or two).
    private func waitForDaemon(_ machine: MacMachine) async throws -> GuestResponse {
        var lastError: Error = AgentVMError.guestUnreachable("the guest daemon did not answer")
        for _ in 0..<30 {
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

    private func guestCapture(_ machine: MacMachine, _ request: GuestRequest, readTimeout: Int = 60) async throws -> (report: ExitReport, stdout: String, stderr: String) {
        return try await withGuest(machine, readTimeout: readTimeout) { try GuestClient.capture($0, request) }
    }

    /// Runs a blocking protocol exchange on a fresh vsock connection, off the main actor, with
    /// a read timeout (seconds without any frame) so a stuck guest cannot hang the build.
    private func withGuest<T: Sendable>(_ machine: MacMachine, readTimeout: Int = 60, _ body: @escaping @Sendable (Int32) throws -> T) async throws -> T {
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

    private func spec(_ image: GoldenImage) -> MacMachineSpec {
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
