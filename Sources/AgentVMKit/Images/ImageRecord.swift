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
    /// That executable's designated code requirement (CodeSignature); nil in images built
    /// before it was recorded, or for an unsigned daemon.
    public var guestRequirement: String?
    /// What `image setup` last found; nil when it never ran on this image (or its base).
    public var fullDiskAccess: FullDiskAccess?

    /// Full Disk Access for agent-vm-guest inside the image. macOS ties the grant to the
    /// daemon's designated code requirement, so it is recorded with the daemon it was checked
    /// for: its digest, and its requirement.
    public struct FullDiskAccess: Codable, Equatable, Sendable {
        public var granted: Bool
        /// SHA-256 of the agent-vm-guest that was checked.
        public var guestDigest: String?
        /// Its designated code requirement.
        public var guestRequirement: String?
        public var checkedAt: Date

        public init(granted: Bool, guestDigest: String?, guestRequirement: String? = nil, checkedAt: Date) {
            self.granted = granted
            self.guestDigest = guestDigest
            self.guestRequirement = guestRequirement
            self.checkedAt = checkedAt
        }

        /// Whether this finding holds for a daemon with `digest` and `requirement`: the same
        /// executable, or one with the same requirement naming a signer (a Developer ID build;
        /// macOS keeps the grant for it, measured). An ad hoc requirement is one build's hash,
        /// which the digest already covers.
        public func applies(toDigest digest: String?, requirement: String?) -> Bool {
            if guestDigest == digest {
                return true
            }
            guard let guestRequirement, guestRequirement == requirement else {
                return false
            }
            return CodeSignature.namesASigner(guestRequirement)
        }
    }

    /// Whether programs in boxes of this image can open protected folders without a prompt:
    /// true or false when known for the current daemon, nil when unknown.
    public var hasFullDiskAccess: Bool? {
        guard let fullDiskAccess, fullDiskAccess.applies(toDigest: guestDigest, requirement: guestRequirement) else {
            return nil
        }
        return fullDiskAccess.granted
    }

    /// What a ready image lacks, as `image list` names it; empty for other states and for
    /// images that lack nothing.
    public var needs: [ImageNeed] {
        guard state == .ready else {
            return []
        }
        var needs: [ImageNeed] = []
        let missing = GuestFeature.all.filter { !(guestFeatures ?? []).contains($0) }
        if !missing.isEmpty {
            needs.append(ImageNeed(kind: .guestUpdate, missing: missing))
        }
        switch hasFullDiskAccess {
        case true?:
            break
        case false?:
            needs.append(ImageNeed(kind: .fullDiskAccess, reason: .notGranted))
        case nil:
            needs.append(ImageNeed(kind: .fullDiskAccess, reason: .notChecked))
        }
        return needs
    }
    /// The Command Line Tools installed in the image (softwareupdate's label), if any.
    public var commandLineTools: String?
    /// What the image's own recipes installed, as one: a single recipe's entry, or for several
    /// their descriptions joined, a digest of their digests, and their inputs and parameters
    /// together (without a parameter that has different values in two of them). nil for an
    /// image built without a recipe.
    public var recipe: RecipeInfo?
    /// Every recipe whose steps ran on this disk, in the order they ran: those of the image it
    /// was built from first (`inheritedFrom`), then its own. Each one's files are kept in the
    /// image's `Recipes/` folder (`folder`). nil in images built before recipes were listed.
    public var recipes: [RecipeInfo]?

    /// How often `image update` changed the image's disk (nil: never), and when it last did.
    /// A box records the revision it was cloned at, so it can tell that its image moved on.
    public var revision: Int?
    public var updatedAt: Date?
    /// When `image update` last looked for a macOS update, and when it last ran the recipes'
    /// update steps, and ended well, whether or not anything changed; nil when it never did.
    /// Kept apart: a quick tools update before a session says nothing about macOS.
    public var macOSCheckedAt: Date?
    public var toolsCheckedAt: Date?
    /// How long the last `image update` took that ran the tools' update steps and neither
    /// installed a macOS update nor replaced the guest daemon, in seconds: what the next one
    /// of that kind can be expected to take.
    public var updateSeconds: Double?

    /// Whether an update of the parts named is due: for one of them, none ended well within
    /// the last `hours`.
    public func isUpdateDue(macOS: Bool, tools: Bool, olderThanHours hours: Double, now: Date = Date()) -> Bool {
        func due(_ checked: Date?) -> Bool {
            guard let checked else {
                return true
            }
            return now.timeIntervalSince(checked) >= hours * 3600
        }
        return (macOS && due(macOSCheckedAt)) || (tools && due(toolsCheckedAt))
    }

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
        /// The files given as its inputs (not part of the digest), by name.
        public var inputs: [InputInfo]?
        /// Every parameter's value, given or default.
        public var parameters: [String: String]?
        /// In `recipes`: the recipe's name (its folder's, or its file's without the extension).
        public var name: String?
        /// In `recipes`: the folder in the image's `Recipes/` that keeps the recipe and the
        /// files it copies.
        public var folder: String?
        /// In `recipes`: the image this one was built from, for a recipe that ran there.
        public var inheritedFrom: String?

        public init(description: String?, digest: String, inputs: [InputInfo]? = nil, parameters: [String: String]? = nil,
                    name: String? = nil, folder: String? = nil, inheritedFrom: String? = nil) {
            self.description = description
            self.digest = digest
            self.inputs = inputs
            self.parameters = parameters
            self.name = name
            self.folder = folder
            self.inheritedFrom = inheritedFrom
        }

        /// Several recipes as one entry (see `ImageRecord.recipe`); nil for none. One recipe is
        /// itself, without the keys that belong to the list.
        public static func combined(_ recipes: [RecipeInfo]) -> RecipeInfo? {
            guard let first = recipes.first else {
                return nil
            }
            guard recipes.count > 1 else {
                return RecipeInfo(description: first.description, digest: first.digest, inputs: first.inputs, parameters: first.parameters)
            }
            let descriptions = recipes.map { $0.description ?? $0.name ?? String($0.digest.prefix(12)) }
            // An input two recipes share (`--input` gives the file to both) is listed once.
            var inputs: [InputInfo] = []
            for input in recipes.flatMap({ $0.inputs ?? [] }) where !inputs.contains(input) {
                inputs.append(input)
            }
            // A name two recipes share has one value when `--set` gave it to both; left to
            // their own defaults they can differ, and then only `recipes` says which is whose.
            var parameters: [String: String] = [:]
            var differing: Set<String> = []
            for (name, value) in recipes.flatMap({ $0.parameters ?? [:] }) {
                if let other = parameters.updateValue(value, forKey: name), other != value {
                    differing.insert(name)
                }
            }
            for name in differing {
                parameters[name] = nil
            }
            return RecipeInfo(description: descriptions.joined(separator: "; "),
                              digest: ImageRecipe.sha256(Data(recipes.map(\.digest).joined(separator: "\n").utf8)),
                              inputs: inputs.isEmpty ? nil : inputs, parameters: parameters.isEmpty ? nil : parameters)
        }
    }

    /// One recipe input as it was streamed into the guest.
    public struct InputInfo: Codable, Equatable, Sendable {
        public var name: String
        /// The file's name on the Mac that built the image.
        public var file: String
        public var bytes: Int64
        public var sha256: String
        /// Where the file was on that Mac, so `image rebuild` can take it again; nil in images
        /// built before it was recorded.
        public var path: String? = nil
    }
}

/// Something a ready image lacks, and the command that supplies it.
public struct ImageNeed: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Its agent-vm-guest lacks features of this agent-vm's: `image update-guest`.
        case guestUpdate = "guest-update"
        /// Its agent-vm-guest has no Full Disk Access, or it was not checked for this daemon:
        /// `image setup`.
        case fullDiskAccess = "full-disk-access"
    }

    public enum Reason: String, Codable, Sendable {
        /// `image setup` found no grant for the current daemon.
        case notGranted = "not-granted"
        /// `image setup` never checked the current daemon.
        case notChecked = "not-checked"
    }

    public var kind: Kind
    /// guest-update: the features the daemon lacks (GuestFeature).
    public var missing: [String]?
    /// full-disk-access: whether it was refused or never checked.
    public var reason: Reason?

    public init(kind: Kind, missing: [String]? = nil, reason: Reason? = nil) {
        self.kind = kind
        self.missing = missing
        self.reason = reason
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
    public var recipesURL: URL { directory.appendingPathComponent(ImageStore.recipesName, isDirectory: true) }
    /// Where `image update` works on a copy of the disk, and that folder once the update is
    /// decided (see `ImageStore.settle`).
    public var updateURL: URL { directory.appendingPathComponent(ImageStore.updateName, isDirectory: true) }
    public var updateCommitURL: URL { directory.appendingPathComponent(ImageStore.updateCommitName, isDirectory: true) }
}
