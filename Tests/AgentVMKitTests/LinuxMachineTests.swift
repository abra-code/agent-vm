// Tests/AgentVMKitTests/LinuxMachineTests.swift
//
// A Linux guest's machine configuration, built from files in a scratch folder and looked at;
// no machine is started here, and Virtualization is not asked to validate (it answers only a
// process that may run virtual machines). And the one place that picks the configuration by the record's
// guest.

import Foundation
import Testing
import Virtualization
@testable import AgentVMKit

@Suite struct LinuxMachineTests {
    /// A scratch folder with what a Linux image's folder holds: a sparse disk, a new variable
    /// store, a new identifier.
    static func files(in scratch: Scratch, name: String = "deb") throws -> MachineFiles {
        let directory = scratch.root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = MachineFiles(name: name, directory: directory, guest: .linux)
        try ImageBuilder.createSparseDisk(at: files.disk, bytes: 64 << 20)
        guard case let .linux(variables, identifier) = files.platform else {
            throw AgentVMError.hostNotReady("not a Linux file set")
        }
        try LinuxMachineSpec.createFiles(variableStore: variables, machineIdentifier: identifier)
        return files
    }

    static let spec = LinuxMachineSpec(cpuCount: 2, memoryBytes: 2 << 30, macAddress: "da:51:72:d4:e5:73")

    @Test func theConfigurationHasALinuxMachinesDevices() throws {
        let scratch = try Scratch()
        let configuration = try Self.spec.configuration(for: try Self.files(in: scratch), validate: false)
        #expect(configuration.platform is VZGenericPlatformConfiguration)
        #expect(configuration.bootLoader is VZEFIBootLoader)
        #expect(configuration.cpuCount == 2 && configuration.memorySize == 2 << 30)
        #expect(configuration.storageDevices.count == 1)
        #expect(configuration.networkDevices.count == 1)
        #expect(configuration.networkDevices.first?.macAddress.string == "da:51:72:d4:e5:73")
        // What a guest cannot do without (it waits for randomness at boot), and what the
        // guest daemon is reached through.
        #expect(configuration.entropyDevices.count == 1)
        #expect(configuration.socketDevices.count == 1)
        #expect(configuration.memoryBalloonDevices.count == 1)
        // Nothing is shared, and nothing is printed, unless asked for.
        #expect(configuration.directorySharingDevices.isEmpty)
        #expect(configuration.serialPorts.isEmpty)
    }

    @Test func thereIsNoDisplay() throws {
        let scratch = try Scratch()
        let configuration = try Self.spec.configuration(for: try Self.files(in: scratch), validate: false)
        #expect(configuration.graphicsDevices.isEmpty)
        #expect(configuration.keyboards.isEmpty)
        #expect(configuration.pointingDevices.isEmpty)
    }

    @Test func noNetworkMeansNoCard() throws {
        let scratch = try Scratch()
        let configuration = try Self.spec.configuration(for: try Self.files(in: scratch), network: .none, validate: false)
        #expect(configuration.networkDevices.isEmpty)
    }

    @Test func aSeedDiskIsASecondReadOnlyDisk() throws {
        let scratch = try Scratch()
        let files = try Self.files(in: scratch)
        let seed = scratch.root.appendingPathComponent("seed.iso")
        try ImageBuilder.createSparseDisk(at: seed, bytes: 1 << 20)
        let configuration = try Self.spec.configuration(for: files, extras: LinuxMachineExtras(seedDisk: seed), validate: false)
        #expect(configuration.storageDevices.count == 2)
        let attachments = configuration.storageDevices.compactMap { $0.attachment as? VZDiskImageStorageDeviceAttachment }
        #expect(attachments.map(\.isReadOnly) == [false, true])
        #expect(attachments.map(\.url.lastPathComponent) == [ImageStore.diskName, "seed.iso"])
    }

    @Test func theConsoleIsOneSerialPort() throws {
        let scratch = try Scratch()
        let log = try ConsoleLog(url: scratch.root.appendingPathComponent("console.log"))
        defer { log.close() }
        let configuration = try Self.spec.configuration(for: try Self.files(in: scratch), extras: LinuxMachineExtras(console: log.writeHandle), validate: false)
        #expect(configuration.serialPorts.count == 1)
        #expect(configuration.serialPorts.first is VZVirtioConsoleDeviceSerialPortConfiguration)
    }

    @Test func theShareTagsAreTheLinuxOnes() throws {
        let scratch = try Scratch()
        let shape = MachineShape(guest: .linux, cpuCount: 2, memoryBytes: 2 << 30, macAddress: "da:51:72:d4:e5:73")
        let shared = try MachineBuilder.configuration(shape, files: try Self.files(in: scratch), network: .none, share: true, validate: false)
        let devices = shared.directorySharingDevices.compactMap { $0 as? VZVirtioFileSystemDeviceConfiguration }
        // One device per folder the box can share at once.
        #expect(devices.map(\.tag) == ProjectShare.tags(for: .linux))
        #expect(devices.first?.tag == "agent-vm-project")
        #expect(ProjectShare.tag(for: .linux) == "agent-vm-project")
        // A macOS guest keeps Apple's automount tag: any other is a network volume to it.
        #expect(ProjectShare.tag(for: .macOS) == VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
        let plain = try MachineBuilder.configuration(shape, files: try Self.files(in: scratch, name: "other"), validate: false)
        #expect(plain.directorySharingDevices.isEmpty)
    }

    @Test func aRecordsGuestPicksTheMachine() throws {
        let scratch = try Scratch()
        let files = try Self.files(in: scratch)
        // A Linux file set is never configured as a Mac, whatever the caller's record says.
        let mac = MachineShape(guest: .macOS, cpuCount: 2, memoryBytes: 2 << 30, macAddress: "da:51:72:d4:e5:73")
        #expect(throws: AgentVMError.corruptImageRecord(path: files.directory.path, reason: "its machine files are not a macOS guest's")) {
            _ = try MachineBuilder.configuration(mac, files: files)
        }
        let macFiles = MachineFiles(name: "dev", directory: files.directory, guest: .macOS)
        let linux = MachineShape(guest: .linux, cpuCount: 2, memoryBytes: 2 << 30, macAddress: "da:51:72:d4:e5:73")
        #expect(throws: AgentVMError.corruptImageRecord(path: files.directory.path, reason: "its machine files are not a Linux guest's")) {
            _ = try MachineBuilder.configuration(linux, files: macFiles)
        }
        // What belongs to the other guest is refused, not dropped.
        #expect(throws: AgentVMError.self) {
            _ = try MachineBuilder.configuration(mac, files: macFiles, extras: LinuxMachineExtras(seedDisk: files.disk))
        }
        // The shape is the record's: a record without a guest is a Mac's.
        #expect(MachineShape(ImageStoreTests.record("dev", state: .ready)).guest == .macOS)
        #expect(MachineShape(GuestRecordTests.linuxRecord()).guest == .linux)
    }

    @Test func missingOrBrokenFilesAreNamed() throws {
        let scratch = try Scratch()
        let files = try Self.files(in: scratch)
        guard case let .linux(variables, identifier) = files.platform else {
            return
        }
        try Data("not an identifier".utf8).write(to: identifier)
        #expect(throws: AgentVMError.corruptImageRecord(path: identifier.path, reason: "not a machine identifier")) {
            _ = try Self.spec.configuration(for: files, validate: false)
        }
        try LinuxMachineSpec.createIdentifier(identifier)
        try FileManager.default.removeItem(at: variables)
        #expect(throws: AgentVMError.corruptImageRecord(path: files.directory.path, reason: "EFIVariableStore is missing")) {
            _ = try Self.spec.configuration(for: files, validate: false)
        }
        var odd = Self.spec
        odd.macAddress = "nonsense"
        try LinuxMachineSpec.createFiles(variableStore: variables, machineIdentifier: identifier)
        #expect(throws: AgentVMError.corruptImageRecord(path: files.directory.path, reason: "bad MAC address nonsense")) {
            _ = try odd.configuration(for: files, validate: false)
        }
    }
}
