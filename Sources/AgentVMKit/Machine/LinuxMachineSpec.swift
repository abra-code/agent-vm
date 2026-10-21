// Sources/AgentVMKit/Machine/LinuxMachineSpec.swift
//
// A Linux guest: its Virtualization configuration. The machine is a generic one that boots its
// disk through EFI, the firmware interface a PC-style machine has, so a distribution's own
// cloud image starts unchanged. What the guest prints on its console goes to a file
// (ConsoleLog), and everything else goes through the guest daemon. It has no display, keyboard
// or pointer, unless its image installed a desktop (a recipe with "screen"): then it has a
// virtio display of the macOS guest's size, which `box view` shows, and a USB keyboard and
// pointer. Virtualization draws a Linux guest without 3D acceleration: the desktop is drawn by
// the processors (measured: XFCE logged in takes about 200 MB of the box's memory).
//
// Measured on macOS 27, MacBook Air M5, with Debian 13's cloud image: the daemon answers 2.7 s
// after start. The entropy device is required (without it the guest waits for randomness at
// boot); the balloon is there and gives nothing back to the Mac.

import Foundation
import Virtualization

/// What a Linux machine may have besides its own files.
struct LinuxMachineExtras {
    /// A second, read-only disk: the data a new image's first boot installs the guest daemon
    /// from.
    var seedDisk: URL?
    /// Where the guest's console output goes (the write end of ConsoleLog's pipe).
    var console: FileHandle?

    init(seedDisk: URL? = nil, console: FileHandle? = nil) {
        self.seedDisk = seedDisk
        self.console = console
    }
}

/// The resources and devices of a Linux guest.
public struct LinuxMachineSpec: Sendable {
    public var cpuCount: Int
    public var memoryBytes: UInt64
    public var macAddress: String
    /// A display, keyboard and pointer.
    public var screen: Bool

    public init(cpuCount: Int, memoryBytes: UInt64, macAddress: String, screen: Bool = false) {
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.macAddress = macAddress
        self.screen = screen
    }

    /// Creates what a new Linux machine has besides its disk: an empty store for the boot
    /// firmware's variables, and an identifier of its own.
    static func createFiles(variableStore: URL, machineIdentifier: URL) throws {
        do {
            _ = try VZEFIVariableStore(creatingVariableStoreAt: variableStore, options: [])
        } catch {
            throw AgentVMError.virtualMachine(operation: "create \(variableStore.path)", message: error.localizedDescription)
        }
        try createIdentifier(machineIdentifier)
    }

    /// A new identifier, for a machine whose other files are copies (a box, a derived image).
    static func createIdentifier(_ machineIdentifier: URL) throws {
        do {
            try VZGenericMachineIdentifier().dataRepresentation.write(to: machineIdentifier)
        } catch {
            throw AgentVMError.virtualMachine(operation: "create \(machineIdentifier.path)", message: error.localizedDescription)
        }
    }

    /// Builds the configuration for the machine in `files`. `shareTags` adds one virtio file
    /// system device per tag, with nothing shared yet (`GuestMachine.share` fills it on the
    /// running machine; the device set itself is fixed at start). Validating asks Virtualization,
    /// which answers only a process that may run virtual machines: a unit test passes false
    /// and looks at the devices.
    func configuration(for files: MachineFiles, network: MachineNetwork = .nat, shareTags: [String] = [],
                       extras: LinuxMachineExtras = LinuxMachineExtras(), validate: Bool = true) throws -> VZVirtualMachineConfiguration {
        guard case let .linux(variableStoreURL, machineIdentifierURL) = files.platform else {
            throw AgentVMError.corruptImageRecord(path: files.directory.path, reason: "its machine files are not a Linux guest's")
        }
        let identifierData: Data
        do {
            identifierData = try Data(contentsOf: machineIdentifierURL)
        } catch {
            throw AgentVMError.corruptImageRecord(path: files.directory.path, reason: "machine files unreadable: \(error.localizedDescription)")
        }
        guard let identifier = VZGenericMachineIdentifier(dataRepresentation: identifierData) else {
            throw AgentVMError.corruptImageRecord(path: machineIdentifierURL.path, reason: "not a machine identifier")
        }
        // The store is opened by the machine when it starts; a missing one would only be
        // reported then, as an error that does not name the file.
        guard FileSystem.exists(variableStoreURL.path) else {
            throw AgentVMError.corruptImageRecord(path: files.directory.path, reason: "\(variableStoreURL.lastPathComponent) is missing")
        }
        guard let macAddress = VZMACAddress(string: self.macAddress) else {
            throw AgentVMError.corruptImageRecord(path: files.directory.path, reason: "bad MAC address \(self.macAddress)")
        }

        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = identifier

        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = VZEFIVariableStore(url: variableStoreURL)

        let configuration = VZVirtualMachineConfiguration()
        configuration.platform = platform
        configuration.bootLoader = bootLoader
        configuration.cpuCount = cpuCount
        configuration.memorySize = memoryBytes

        // Every disk of a Linux guest is attached with the Mac's file cache (`.cached`). With
        // `.automatic` or `.uncached`, a guest whose kernel has 4 KiB pages loses memory once
        // it has read a disk through the raw block device (as Ubuntu's GRUB services do at every
        // boot) and the Mac then pushes the guest's memory out: the memory reads as zeros and
        // the kernel faults. `.cached` did not show it in any test (macOS 26 and 27); Lima
        // attaches its disks the same way, after reports of corrupted guest disks (UTM issue
        // 4840). A macOS guest
        // has 16 KiB pages and keeps `.automatic` (MacMachineSpec).
        var disks: [VZStorageDeviceConfiguration] = []
        do {
            let disk = try VZDiskImageStorageDeviceAttachment(url: files.disk, readOnly: false, cachingMode: .cached, synchronizationMode: .full)
            disks.append(VZVirtioBlockDeviceConfiguration(attachment: disk))
        } catch {
            throw AgentVMError.virtualMachine(operation: "attach \(files.disk.path)", message: error.localizedDescription)
        }
        if let seedDisk = extras.seedDisk {
            do {
                disks.append(VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: seedDisk, readOnly: true, cachingMode: .cached, synchronizationMode: .full)))
            } catch {
                throw AgentVMError.virtualMachine(operation: "attach \(seedDisk.path)", message: error.localizedDescription)
            }
        }
        configuration.storageDevices = disks

        switch network {
        case .nat:
            let card = VZVirtioNetworkDeviceConfiguration()
            card.attachment = VZNATNetworkDeviceAttachment()
            card.macAddress = macAddress
            configuration.networkDevices = [card]
        case let .fileHandle(handle):
            let card = VZVirtioNetworkDeviceConfiguration()
            card.attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: handle)
            card.macAddress = macAddress
            configuration.networkDevices = [card]
        case .none:
            configuration.networkDevices = []
        }

        if let console = extras.console {
            let port = VZVirtioConsoleDeviceSerialPortConfiguration()
            port.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: console)
            configuration.serialPorts = [port]
        }
        if screen {
            let graphics = VZVirtioGraphicsDeviceConfiguration()
            graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: MacMachineSpec.displayWidth, heightInPixels: MacMachineSpec.displayHeight)]
            configuration.graphicsDevices = [graphics]
            configuration.keyboards = [VZUSBKeyboardConfiguration()]
            configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        }
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        configuration.directorySharingDevices = shareTags.map { VZVirtioFileSystemDeviceConfiguration(tag: $0) }

        guard validate else {
            return configuration
        }
        do {
            try configuration.validate()
        } catch {
            throw AgentVMError.virtualMachine(operation: "configure \(files.name)", message: error.localizedDescription)
        }
        return configuration
    }
}
