// Sources/AgentVMKit/Machine/MachineBuilder.swift
//
// The one place that decides which kind of machine a record means. Everything that starts a
// guest (a box's supervisor, an image's build, setup and update) asks here, so no caller builds
// a macOS configuration for a Linux disk.

import Foundation
import Virtualization

/// What a record says about its machine.
struct MachineShape: Sendable {
    var guest: GuestKind
    var cpuCount: Int
    var memoryBytes: UInt64
    var macAddress: String
    /// A display, keyboard and pointer; every macOS machine has them whatever this says.
    var screen: Bool

    init(guest: GuestKind, cpuCount: Int, memoryBytes: UInt64, macAddress: String, screen: Bool = false) {
        self.guest = guest
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.macAddress = macAddress
        self.screen = screen
    }

    init(_ record: ImageRecord) {
        self.init(guest: record.effectiveGuest, cpuCount: record.cpuCount, memoryBytes: record.memoryBytes, macAddress: record.macAddress, screen: record.hasScreen)
    }

    init(_ record: BoxRecord) {
        self.init(guest: record.effectiveGuest, cpuCount: record.cpuCount, memoryBytes: record.memoryBytes, macAddress: record.macAddress, screen: record.hasScreen)
    }
}

enum MachineBuilder {
    /// The configuration of the machine `shape` describes, from `files`. `share` adds the
    /// guest's project share devices, empty. `auxiliaryStorage` is for a macOS install, which
    /// has just created it; `extras` are a Linux machine's. What is given for the other guest
    /// is refused, not ignored: a caller that passes it has mixed the two up. `validate` is false
    /// only in unit tests (LinuxMachineSpec.configuration).
    static func configuration(_ shape: MachineShape, files: MachineFiles, network: MachineNetwork = .nat, share: Bool = false,
                              auxiliaryStorage: VZMacAuxiliaryStorage? = nil,
                              extras: LinuxMachineExtras = LinuxMachineExtras(), validate: Bool = true) throws -> VZVirtualMachineConfiguration {
        let shareTags = share ? ProjectShare.tags(for: shape.guest) : []
        switch shape.guest {
        case .macOS:
            guard extras.seedDisk == nil, extras.console == nil else {
                throw AgentVMError.virtualMachine(operation: "configure \(files.name)", message: "a macOS guest has no seed disk and no console log")
            }
            let spec = MacMachineSpec(cpuCount: shape.cpuCount, memoryBytes: shape.memoryBytes, macAddress: shape.macAddress)
            return try spec.configuration(for: files, auxiliaryStorage: auxiliaryStorage, network: network, shareTag: shareTags.first)
        case .linux:
            guard auxiliaryStorage == nil else {
                throw AgentVMError.virtualMachine(operation: "configure \(files.name)", message: "a Linux guest has no auxiliary storage")
            }
            let spec = LinuxMachineSpec(cpuCount: shape.cpuCount, memoryBytes: shape.memoryBytes, macAddress: shape.macAddress, screen: shape.screen)
            return try spec.configuration(for: files, network: network, shareTags: shareTags, extras: extras, validate: validate)
        }
    }

    /// The machine itself, ready to start.
    @MainActor
    static func machine(_ shape: MachineShape, files: MachineFiles, network: MachineNetwork = .nat, share: Bool = false,
                        auxiliaryStorage: VZMacAuxiliaryStorage? = nil,
                        extras: LinuxMachineExtras = LinuxMachineExtras()) throws -> GuestMachine {
        return GuestMachine(configuration: try configuration(shape, files: files, network: network, share: share,
                                                             auxiliaryStorage: auxiliaryStorage, extras: extras))
    }
}
