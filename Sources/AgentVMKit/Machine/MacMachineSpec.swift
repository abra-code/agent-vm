// Sources/AgentVMKit/Machine/MacMachineSpec.swift
//
// A macOS guest: its Virtualization configuration, the two things only a Mac guest's machine
// does (installing from a restore image, and a start that sets the account up), and reading a
// restore image.
//
// Measured on macOS 27 (26A428), MacBook Air M5: installing from a local restore image takes
// about 3 minutes and leaves about 28 GB on disk; the zero-click first boot has the account
// logged in and SSH listening about 15 seconds after start. `requestStop()` does not shut down
// a guest with a logged-in user (it was still running after 3 minutes), so a clean shutdown
// goes through the guest itself.

import Foundation
import Virtualization

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

    /// Builds the configuration for the machine in `files`. `auxiliaryStorage` is given by
    /// whoever just created it (an install); else it is the one `files` names. `shareTag` adds
    /// one virtio file system device with that tag and nothing shared yet (`GuestMachine.share`
    /// fills it on the running machine; the device set itself is fixed at start).
    func configuration(for files: MachineFiles, auxiliaryStorage: VZMacAuxiliaryStorage? = nil, network: MachineNetwork = .nat, shareTag: String? = nil) throws -> VZVirtualMachineConfiguration {
        guard case let .mac(auxiliaryStorageURL, hardwareModelURL, machineIdentifierURL) = files.platform else {
            throw AgentVMError.corruptImageRecord(path: files.directory.path, reason: "its machine files are not a macOS guest's")
        }
        let auxiliaryStorage = auxiliaryStorage ?? VZMacAuxiliaryStorage(url: auxiliaryStorageURL)
        let hardwareData: Data
        let identifierData: Data
        do {
            hardwareData = try Data(contentsOf: hardwareModelURL)
            identifierData = try Data(contentsOf: machineIdentifierURL)
        } catch {
            throw AgentVMError.corruptImageRecord(path: files.directory.path, reason: "machine files unreadable: \(error.localizedDescription)")
        }
        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareData) else {
            throw AgentVMError.corruptImageRecord(path: hardwareModelURL.path, reason: "not a hardware model")
        }
        guard hardwareModel.isSupported else {
            throw AgentVMError.virtualMachine(operation: "configure \(files.name)", message: "this Mac cannot run the hardware model")
        }
        guard let identifier = VZMacMachineIdentifier(dataRepresentation: identifierData) else {
            throw AgentVMError.corruptImageRecord(path: machineIdentifierURL.path, reason: "not a machine identifier")
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
        case .none:
            // A macOS guest always has a card: its setup and its tools expect one.
            throw AgentVMError.virtualMachine(operation: "configure \(files.name)", message: "a macOS guest cannot be without a network card")
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

extension GuestMachine {
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
                    continuation.resume(throwing: AgentVMError.virtualMachine(operation: "install macOS", error: error))
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
        willStart()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            machine.start(options: options) { error in
                if let error {
                    continuation.resume(throwing: AgentVMError.virtualMachine(operation: "start the guest", error: error))
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

/// NSProgress is thread-safe, but not marked Sendable.
private struct UncheckedProgress: @unchecked Sendable {
    let progress: Progress

    init(_ progress: Progress) {
        self.progress = progress
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
