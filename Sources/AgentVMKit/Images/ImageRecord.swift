// Sources/AgentVMKit/Images/ImageRecord.swift
//
// A golden image is an installed and set-up macOS guest that boxes are cloned from. The record
// below is what `image.json` holds; the machine itself is the set of files next to it (disk,
// auxiliary storage, hardware model, machine identifier), whose formats Apple defines.

import Foundation

public struct ImageRecord: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        /// macOS is being installed from the restore image.
        case installing
        /// macOS is installed; the first boot (user account, login, SSH) has not run yet.
        case installed
        /// The first boot is running.
        case provisioning
        /// Set up and shut down cleanly; boxes can be cloned from it.
        case ready
        /// A step failed; `failure` says which. Delete the image and create it again.
        case failed
    }

    /// Bumped on incompatible changes to this record.
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var name: String
    public var state: State
    public var failure: String?
    public var createdAt: Date
    /// Version of agent-vm that created the image.
    public var createdBy: String
    /// From the restore image, for example "27.0" and "26A428".
    public var macOSVersion: String
    public var macOSBuild: String
    public var cpuCount: Int
    public var memoryBytes: UInt64
    /// Logical size of the disk; the file is sparse and takes only what the guest wrote.
    public var diskBytes: UInt64
    /// The guest's network card address; the host's DHCP server keys its lease on it.
    public var macAddress: String
    /// The account created at first boot. Its password is in the `Password` file (mode 0600).
    public var userName: String
    public var installSeconds: Double?
    public var provisionSeconds: Double?
}

public struct GoldenImage: Sendable {
    public let record: ImageRecord
    /// The image's folder in the store.
    public let directory: URL

    public var name: String { record.name }

    public var diskURL: URL { directory.appendingPathComponent(ImageStore.diskName) }
    public var auxiliaryStorageURL: URL { directory.appendingPathComponent(ImageStore.auxiliaryStorageName) }
    public var hardwareModelURL: URL { directory.appendingPathComponent(ImageStore.hardwareModelName) }
    public var machineIdentifierURL: URL { directory.appendingPathComponent(ImageStore.machineIdentifierName) }
    public var passwordURL: URL { directory.appendingPathComponent(ImageStore.passwordName) }
    public var knownHostsURL: URL { directory.appendingPathComponent(ImageStore.knownHostsName) }
}
