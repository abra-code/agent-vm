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
    /// agent-vm-guest installed in the image, as it reported itself over vsock.
    public var guestVersion: String?
    public var guestProtocol: Int?
    /// What that agent-vm-guest announced beyond protocol 1 (GuestFeature), and the SHA-256 of
    /// its executable; nil in images built before they were recorded.
    public var guestFeatures: [String]?
    public var guestDigest: String?
    /// What `image setup` last found; nil when it never ran on this image (or its base).
    public var fullDiskAccess: FullDiskAccess?

    /// Full Disk Access for agent-vm-guest inside the image. macOS ties the grant to the
    /// daemon's code signature, so it is recorded with the daemon it was checked for.
    public struct FullDiskAccess: Codable, Equatable, Sendable {
        public var granted: Bool
        /// SHA-256 of the agent-vm-guest that was checked.
        public var guestDigest: String?
        public var checkedAt: Date

        public init(granted: Bool, guestDigest: String?, checkedAt: Date) {
            self.granted = granted
            self.guestDigest = guestDigest
            self.checkedAt = checkedAt
        }
    }

    /// Whether programs in boxes of this image can open protected folders without a prompt:
    /// true or false when known for the current daemon, nil when unknown.
    public var hasFullDiskAccess: Bool? {
        guard let fullDiskAccess, fullDiskAccess.guestDigest == guestDigest else {
            return nil
        }
        return fullDiskAccess.granted
    }
    /// The Command Line Tools installed in the image (softwareupdate's label), if any.
    public var commandLineTools: String?
    /// The recipe applied to the image, if any (its text is kept as recipe.json next to it).
    public var recipe: RecipeInfo?

    /// The image this one was built from (`image create --from`), and that image's recipe
    /// digest at the time, if any.
    public var derivedFrom: DerivedFrom?

    public struct DerivedFrom: Codable, Equatable, Sendable {
        public var image: String
        public var recipeDigest: String?
    }

    public struct RecipeInfo: Codable, Equatable, Sendable {
        public var description: String?
        /// SHA-256 of the recipe and the files it copies.
        public var digest: String
    }
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
    public var recipeURL: URL { directory.appendingPathComponent(ImageStore.recipeName) }
}
