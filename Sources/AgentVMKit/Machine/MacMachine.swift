// Sources/AgentVMKit/Machine/MacMachine.swift
//
// A macOS guest: its Virtualization configuration, and the running machine. Virtualization
// runs a machine on one serial queue; this wrapper uses the main queue, so it is a main-actor
// class and every call happens on the main actor. The command-line tool's async entry point
// runs there.
//
// Measured on macOS 27 (26A428), MacBook Air M5: installing from a local restore image takes
// about 3 minutes and leaves about 28 GB on disk; the zero-click first boot has the account
// logged in and SSH listening about 15 seconds after start. `requestStop()` does not shut down
// a guest with a logged-in user (it was still running after 3 minutes), so a clean shutdown
// goes through the guest itself.

import Foundation
import Virtualization

/// The files that make up one macOS guest (an image's or a box's).
struct MachineFiles: Sendable {
    var name: String
    var directory: URL
    var disk: URL
    var auxiliaryStorage: URL
    var hardwareModel: URL
    var machineIdentifier: URL
}

extension GoldenImage {
    var machineFiles: MachineFiles {
        return MachineFiles(name: name, directory: directory, disk: diskURL, auxiliaryStorage: auxiliaryStorageURL,
                            hardwareModel: hardwareModelURL, machineIdentifier: machineIdentifierURL)
    }
}

/// The resources and devices of a macOS guest.
public struct MacMachineSpec: Sendable {
    public var cpuCount: Int
    public var memoryBytes: UInt64
    public var macAddress: String

    public init(cpuCount: Int, memoryBytes: UInt64, macAddress: String) {
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.macAddress = macAddress
    }

    /// Guest display size. Small, because it is only looked at now and then (`box view`): macOS
    /// guests need a display to keep Metal and the login session, and a smaller one costs less
    /// GPU time.
    static let displayWidth = 1280
    static let displayHeight = 800

    /// How the guest's network card is connected.
    enum Network {
        /// NAT through the host: the internet and the local network.
        case nat
        /// A card whose other end is this handle (a box's dead-end link).
        case fileHandle(FileHandle)
    }

    /// Builds the configuration for the machine in `files`. `shareTag` adds one virtio file
    /// system device with that tag and nothing shared yet (`MacMachine.share` fills it on the
    /// running machine; the device set itself is fixed at start).
    func configuration(for files: MachineFiles, auxiliaryStorage: VZMacAuxiliaryStorage, network: Network = .nat, shareTag: String? = nil) throws -> VZVirtualMachineConfiguration {
        let hardwareData: Data
        let identifierData: Data
        do {
            hardwareData = try Data(contentsOf: files.hardwareModel)
            identifierData = try Data(contentsOf: files.machineIdentifier)
        } catch {
            throw AgentVMError.corruptImageRecord(path: files.directory.path, reason: "machine files unreadable: \(error.localizedDescription)")
        }
        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareData) else {
            throw AgentVMError.corruptImageRecord(path: files.hardwareModel.path, reason: "not a hardware model")
        }
        guard hardwareModel.isSupported else {
            throw AgentVMError.virtualMachine(operation: "configure \(files.name)", message: "this Mac cannot run the hardware model")
        }
        guard let identifier = VZMacMachineIdentifier(dataRepresentation: identifierData) else {
            throw AgentVMError.corruptImageRecord(path: files.machineIdentifier.path, reason: "not a machine identifier")
        }
        guard let macAddress = VZMACAddress(string: self.macAddress) else {
            throw AgentVMError.corruptImageRecord(path: files.directory.path, reason: "bad MAC address \(self.macAddress)")
        }

        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = identifier
        platform.auxiliaryStorage = auxiliaryStorage

        let configuration = VZVirtualMachineConfiguration()
        configuration.platform = platform
        configuration.bootLoader = VZMacOSBootLoader()
        configuration.cpuCount = cpuCount
        configuration.memorySize = memoryBytes

        let disk: VZDiskImageStorageDeviceAttachment
        do {
            disk = try VZDiskImageStorageDeviceAttachment(url: files.disk, readOnly: false, cachingMode: .automatic, synchronizationMode: .full)
        } catch {
            throw AgentVMError.virtualMachine(operation: "attach \(files.disk.path)", message: error.localizedDescription)
        }
        configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]

        let card = VZVirtioNetworkDeviceConfiguration()
        switch network {
        case .nat:
            card.attachment = VZNATNetworkDeviceAttachment()
        case let .fileHandle(handle):
            card.attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: handle)
        }
        card.macAddress = macAddress
        configuration.networkDevices = [card]

        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: Self.displayWidth, heightInPixels: Self.displayHeight, pixelsPerInch: 80)]
        configuration.graphicsDevices = [graphics]
        configuration.keyboards = [VZMacKeyboardConfiguration()]
        configuration.pointingDevices = [VZMacTrackpadConfiguration()]
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        if let shareTag {
            configuration.directorySharingDevices = [VZVirtioFileSystemDeviceConfiguration(tag: shareTag)]
        }

        do {
            try configuration.validate()
        } catch {
            throw AgentVMError.virtualMachine(operation: "configure \(files.name)", message: error.localizedDescription)
        }
        return configuration
    }
}

/// A running (or startable) macOS guest, operated on the main queue.
@MainActor
public final class MacMachine: NSObject, VZVirtualMachineDelegate {
    private let machine: VZVirtualMachine
    private var stopped = false
    private var stopError: String?
    // Listeners and their delegates (the delegate reference is weak) live as long as the machine.
    private var listeners: [VZVirtioSocketListener] = []
    private var acceptors: [SocketAcceptor] = []

    public init(configuration: VZVirtualMachineConfiguration) {
        machine = VZVirtualMachine(configuration: configuration)
        super.init()
        machine.delegate = self
    }

    public var isRunning: Bool {
        return machine.state == .running || machine.state == .starting
    }

    /// Why the guest stopped on its own with an error, if it did.
    public var failure: String? {
        return stopError
    }

    /// Shows this machine's display in `view`.
    public func attach(_ view: VZVirtualMachineView) {
        view.virtualMachine = machine
    }

    /// Installs macOS from a local restore image onto the machine's (empty) disk.
    /// With `cancellation`, a cancel stops the install (the installer's progress is canceled,
    /// and the install fails).
    public func install(from restoreImage: URL, cancellation: BuildCancellation? = nil,
                        progress: @escaping @MainActor (Double) -> Void) async throws {
        let installer = VZMacOSInstaller(virtualMachine: machine, restoringFromImageAt: restoreImage)
        let observation = installer.progress.observe(\.fractionCompleted, options: [.new]) { observed, _ in
            let fraction = observed.fractionCompleted
            Task { @MainActor in
                progress(fraction)
            }
        }
        defer { observation.invalidate() }
        // Progress is thread-safe; canceling it is how an install is stopped.
        let installProgress = UncheckedProgress(installer.progress)
        let key = cancellation?.whenCanceled { installProgress.progress.cancel() }
        defer {
            if let key {
                cancellation?.remove(key)
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            installer.install { result in
                switch result {
                case .success:
                    continuation.resume()
                case let .failure(error):
                    continuation.resume(throwing: AgentVMError.virtualMachine(operation: "install macOS", message: error.localizedDescription))
                }
            }
        }
    }

    /// Starts the guest; with `provisioning`, macOS creates the account and applies the
    /// settings on this boot (the first boot after install only).
    public func start(provisioning: VZMacGuestProvisioningOptions?) async throws {
        let options = VZMacOSVirtualMachineStartOptions()
        if let provisioning {
            do {
                try options.setGuestProvisioning(provisioning)
            } catch {
                throw AgentVMError.virtualMachine(operation: "set up the guest account", message: error.localizedDescription)
            }
        }
        stopped = false
        stopError = nil
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            machine.start(options: options) { error in
                if let error {
                    continuation.resume(throwing: AgentVMError.virtualMachine(operation: "start the guest", message: error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Waits for the guest to stop by itself; false when `timeout` passes first.
    public func waitUntilStopped(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !stopped && machine.state != .stopped && machine.state != .error {
            if ContinuousClock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return true
    }

    /// Pulls the plug. The guest gets no chance to flush its disk; use only when it does not
    /// shut down by itself.
    public func forceStop() async throws {
        guard machine.canStop else {
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            machine.stop { error in
                if let error {
                    continuation.resume(throwing: AgentVMError.virtualMachine(operation: "stop the guest", message: error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
        stopped = true
    }

    /// Opens a vsock connection to `port` in the guest (the guest daemon listens on
    /// `GuestProtocol.port`). Fails at once when nothing listens there yet.
    public func connect(toPort port: UInt32) async throws -> GuestConnection {
        guard let device = machine.socketDevices.first as? VZVirtioSocketDevice else {
            throw AgentVMError.virtualMachine(operation: "connect to the guest", message: "the machine has no vsock device")
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GuestConnection, Error>) in
            device.connect(toPort: port) { result in
                switch result {
                case let .success(connection):
                    continuation.resume(returning: GuestConnection(connection))
                case let .failure(error):
                    continuation.resume(throwing: AgentVMError.guestUnreachable("vsock port \(port): \(error.localizedDescription)"))
                }
            }
        }
    }

    /// Shares `directory` (or nothing) through the file system device tagged `tag`, as the
    /// one entry of a synthetic read-only root, named after the folder. The guest must not
    /// have it mounted while the share changes.
    public func share(tag: String, directory: URL?, readOnly: Bool) throws {
        guard let device = machine.directorySharingDevices.compactMap({ $0 as? VZVirtioFileSystemDevice }).first(where: { $0.tag == tag }) else {
            throw AgentVMError.virtualMachine(operation: "share a folder", message: "the machine has no file system device \(tag)")
        }
        guard let directory else {
            device.share = nil
            return
        }
        let name = directory.lastPathComponent
        do {
            try VZMultipleDirectoryShare.validateName(name)
        } catch {
            throw AgentVMError.virtualMachine(operation: "share \(directory.path)", message: error.localizedDescription)
        }
        device.share = VZMultipleDirectoryShare(directories: [name: VZSharedDirectory(url: directory, readOnly: readOnly)])
    }

    /// Accepts guest-initiated vsock connections to `port`; `accept` runs on the main queue
    /// and owns the connection (close it when done).
    public func listen(port: UInt32, accept: @escaping @Sendable (GuestConnection) -> Void) throws {
        guard let device = machine.socketDevices.first as? VZVirtioSocketDevice else {
            throw AgentVMError.virtualMachine(operation: "listen for the guest", message: "the machine has no vsock device")
        }
        let listener = VZVirtioSocketListener()
        let acceptor = SocketAcceptor(accept)
        listener.delegate = acceptor
        acceptors.append(acceptor)
        listeners.append(listener)
        device.setSocketListener(listener, forPort: port)
    }

    // MARK: - VZVirtualMachineDelegate (called on the main queue)

    nonisolated public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        MainActor.assumeIsolated {
            stopped = true
        }
    }

    nonisolated public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated {
            stopError = message
            stopped = true
        }
    }
}

/// Hands each accepted guest connection to a closure.
private final class SocketAcceptor: NSObject, VZVirtioSocketListenerDelegate {
    private let accept: @Sendable (GuestConnection) -> Void

    init(_ accept: @escaping @Sendable (GuestConnection) -> Void) {
        self.accept = accept
    }

    func listener(_ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection, from socketDevice: VZVirtioSocketDevice) -> Bool {
        accept(GuestConnection(connection))
        return true
    }
}

/// NSProgress is thread-safe, but not marked Sendable.
private struct UncheckedProgress: @unchecked Sendable {
    let progress: Progress

    init(_ progress: Progress) {
        self.progress = progress
    }
}

/// One vsock connection to the guest. Its descriptor stays valid only while this object is
/// alive and not closed: closing it also breaks copies handed to other processes (measured),
/// so the owner closes it only when every user of the descriptor is done.
public final class GuestConnection: @unchecked Sendable {
    private let connection: VZVirtioSocketConnection
    private let lock = NSLock()
    private var closed = false

    init(_ connection: VZVirtioSocketConnection) {
        self.connection = connection
    }

    public var descriptor: Int32 {
        return connection.fileDescriptor
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if !closed {
            closed = true
            connection.close()
        }
    }

    deinit {
        close()
    }
}

/// Reading a restore image (an .ipsw file).
public enum RestoreImage {
    public struct Info: Sendable {
        public var version: String
        public var build: String
        public var minimumCPUCount: Int
        public var minimumMemoryBytes: UInt64
        public var hardwareModel: Data
    }

    public static func inspect(_ url: URL) async throws -> Info {
        // The restore image object is not Sendable: read what is needed inside the handler.
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Info, Error>) in
            VZMacOSRestoreImage.load(from: url) { result in
                continuation.resume(with: Result { try info(from: result.get(), url: url) }.mapError { error in
                    if let error = error as? AgentVMError {
                        return error
                    }
                    return AgentVMError.virtualMachine(operation: "read restore image \(url.path)", message: error.localizedDescription)
                })
            }
        }
    }

    static func info(from image: VZMacOSRestoreImage, url: URL) throws -> Info {
        guard let requirements = image.mostFeaturefulSupportedConfiguration, requirements.hardwareModel.isSupported else {
            throw AgentVMError.virtualMachine(operation: "read restore image \(url.path)", message: "this Mac cannot run macOS \(image.buildVersion) as a guest")
        }
        let os = image.operatingSystemVersion
        return Info(
            version: os.patchVersion == 0 ? "\(os.majorVersion).\(os.minorVersion)" : "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            build: image.buildVersion,
            minimumCPUCount: requirements.minimumSupportedCPUCount,
            minimumMemoryBytes: requirements.minimumSupportedMemorySize,
            hardwareModel: requirements.hardwareModel.dataRepresentation
        )
    }
}
