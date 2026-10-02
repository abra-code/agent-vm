// Sources/AgentVMKit/Boxes/BoxStore.swift
//
// Boxes: copy-on-write clones of a ready golden image, one folder each under the store root:
//
//   Boxes/<name>/box.json            the BoxRecord
//   Boxes/<name>/.lock               held by the box's supervisor while it runs
//   Boxes/<name>/control.sock        the supervisor's control socket (0600) while it runs
//   Boxes/<name>/supervisor.log      the supervisor's output
//   Boxes/<name>/network.jsonl       the proxy's refused and failed connections (allowlist and off modes)
//   Boxes/<name>/network-allowed.jsonl  the connections it allowed (see NetworkLog)
//   Boxes/<name>/exec.jsonl          what agent-vm exec and box shell ran (start and end lines)
//   Boxes/<name>/Disk.img            APFS clone of the image's disk
//   Boxes/<name>/AuxiliaryStorage    APFS clone of the image's auxiliary storage
//   Boxes/<name>/HardwareModel       copy of the image's
//   Boxes/<name>/MachineIdentifier   the box's own
//   Boxes/<name>/Password            copy of the image's (the account is the same)
//   Boxes/<name>/tombstone           a disposable box that stopped; `box gc` deletes the folder
//   Boxes/.gc.lock                   held while `box gc` runs, so only one collects at a time
//
// A clone takes no space until the box writes, so creating a box is instant; the image must
// be on the same volume. Each box gets its own MAC address and machine identifier, so two
// boxes of one image can run side by side.

import Darwin
import Foundation
import Virtualization

public struct BoxRecord: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var name: String
    /// The image the box was cloned from, and what it held at that time.
    public var image: String
    public var macOSVersion: String
    public var macOSBuild: String
    public var guestProtocol: Int?
    public var createdAt: Date
    public var cpuCount: Int
    public var memoryBytes: UInt64
    public var macAddress: String
    public var userName: String
    /// What the box may reach; absent in boxes created before network policy (they ran on NAT).
    public var network: BoxNetwork?
    /// A box for one session: once it stops, its supervisor leaves a tombstone and `box gc`
    /// deletes it (`box create --disposable`).
    public var disposable: Bool?
    /// The image's agent-vm-guest when the box was made (a box's daemon changes only when it
    /// is made again): its version and the SHA-256 of its executable. Absent in boxes made
    /// before 0.4.3, and when the image recorded no digest.
    public var guestVersion: String?
    public var guestDigest: String?
    /// The image as it was when the box was made: when it was built, and how often `image
    /// update` had changed it (0: never). Absent in boxes made before 0.5.0.
    public var imageCreatedAt: Date?
    public var imageRevision: Int?

    public var effectiveNetwork: BoxNetwork {
        return network ?? .legacy
    }

    /// What the box lacks next to `image`, its image's record now (nil when it is gone): a
    /// `recreate` when the image is no longer what the box was cloned from. In the order
    /// checked: another image was built under the name, `image update` changed it, or its
    /// agent-vm-guest is not the one the box was made with. Each only when the box recorded
    /// what it compares: a box made before that says nothing.
    public func needs(image: ImageRecord?) -> [BoxNeed] {
        guard let image, image.state == .ready else {
            return []
        }
        if let builtAt = imageCreatedAt {
            if builtAt != image.createdAt {
                return [BoxNeed(kind: .recreate, reason: .imageRebuilt, macOSBuild: image.macOSBuild)]
            }
            if (imageRevision ?? 0) != (image.revision ?? 0) {
                return [BoxNeed(kind: .recreate, reason: .imageUpdated, macOSBuild: image.macOSBuild)]
            }
        }
        if let mine = guestDigest, let theirs = image.guestDigest, mine != theirs {
            return [BoxNeed(kind: .recreate, guestVersion: image.guestVersion, reason: .guestUpdate)]
        }
        return []
    }
}

/// Something a box lacks, and the command that supplies it.
public struct BoxNeed: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Its image changed since the box was made (`reason`): `box recreate` makes it again
        /// from the image, losing what the box keeps.
        case recreate
    }

    public enum Reason: String, Codable, Sendable {
        /// The image's agent-vm-guest is another one (`image update-guest`).
        case guestUpdate = "guest-update"
        /// `image update` changed the image: macOS, or its tools.
        case imageUpdated = "image-updated"
        /// Another image was built under the name.
        case imageRebuilt = "image-rebuilt"
    }

    public var kind: Kind
    /// guest-update: the image's agent-vm-guest version now.
    public var guestVersion: String?
    public var reason: Reason?
    /// image-updated and image-rebuilt: the image's macOS build now.
    public var macOSBuild: String?

    public init(kind: Kind, guestVersion: String? = nil, reason: Reason? = nil, macOSBuild: String? = nil) {
        self.kind = kind
        self.guestVersion = guestVersion
        self.reason = reason
        self.macOSBuild = macOSBuild
    }
}

public struct Box: Sendable {
    public let record: BoxRecord
    public let directory: URL

    public var name: String { record.name }

    public var diskURL: URL { directory.appendingPathComponent(ImageStore.diskName) }
    public var auxiliaryStorageURL: URL { directory.appendingPathComponent(ImageStore.auxiliaryStorageName) }
    public var hardwareModelURL: URL { directory.appendingPathComponent(ImageStore.hardwareModelName) }
    public var machineIdentifierURL: URL { directory.appendingPathComponent(ImageStore.machineIdentifierName) }
    public var passwordURL: URL { directory.appendingPathComponent(ImageStore.passwordName) }
    public var lockPath: String { directory.appendingPathComponent(BoxStore.lockName).path }
    public var controlSocketPath: String { directory.appendingPathComponent(BoxStore.controlSocketName).path }
    public var logURL: URL { directory.appendingPathComponent(BoxStore.logName) }
    public var networkLogURL: URL { directory.appendingPathComponent(BoxStore.networkLogName) }
    public var execLogURL: URL { directory.appendingPathComponent(BoxStore.execLogName) }
    public var tombstoneURL: URL { directory.appendingPathComponent(BoxStore.tombstoneName) }

    /// A disposable box that stopped: it is not started again, only deleted. A tombstone in a
    /// box that is not disposable means nothing.
    public var isTombstoned: Bool {
        return record.disposable == true && FileSystem.exists(tombstoneURL.path)
    }

    /// Whether a supervisor runs this box (it holds the lock).
    public var isRunning: Bool {
        return FolderLock.isHeld(lockPath)
    }

    /// The machine files, as the VM configuration reads them.
    var machineFiles: MachineFiles {
        return MachineFiles(name: name, directory: directory, disk: diskURL, auxiliaryStorage: auxiliaryStorageURL,
                            hardwareModel: hardwareModelURL, machineIdentifier: machineIdentifierURL)
    }
}

public struct BoxStore: Sendable {
    static let recordName = "box.json"
    static let lockName = ".lock"
    static let controlSocketName = "control.sock"
    static let logName = "supervisor.log"
    static let networkLogName = "network.jsonl"
    static let execLogName = "exec.jsonl"
    static let tombstoneName = "tombstone"
    /// In Boxes/: held while `gc` runs (not a valid box name, so list skips it).
    static let gcLockName = ".gc.lock"

    /// How old a disposable box without a tombstone must be before `gc` deletes it: one that
    /// was never started, or whose supervisor died. A client creates and starts one within
    /// seconds, so a younger one may be about to start.
    public static let unstartedDisposableAge: TimeInterval = 600

    public let root: URL
    /// The built-in host packs file (NetworkPacks): next to the executable unless given.
    public let builtInPacks: URL?

    public init(root: URL, builtInPacks: URL? = NetworkPacks.builtInURL()) {
        self.root = FileSystem.canonicalRoot(root)
        self.builtInPacks = builtInPacks
    }

    public var boxesDirectory: URL {
        return root.appendingPathComponent("Boxes", isDirectory: true)
    }

    /// Clones a ready image into a new box. The image's lock is held while cloning, so the
    /// image cannot be deleted or rebuilt halfway.
    public func create(name: String, from image: GoldenImage, imageStore: ImageStore,
                       cpuCount: Int? = nil, memoryBytes: UInt64? = nil,
                       network: BoxNetwork = BoxNetwork(mode: .allowlist), disposable: Bool = false) throws -> Box {
        guard ImageStore.isValidName(name) else {
            throw AgentVMError.invalidBoxName(name)
        }
        // Reject bad rules and unknown packs before anything is created.
        _ = try CompiledPolicy(network, packs: try NetworkPacks.needed(for: network, store: root, builtIn: builtInPacks))
        guard image.record.state == .ready else {
            throw AgentVMError.wrongImageState(name: image.name, state: image.record.state.rawValue, operation: "create a box from")
        }
        guard let imageLock = try imageStore.tryLock(image) else {
            throw AgentVMError.imageBusy(image.name)
        }
        defer { imageLock.release() }
        // Read again under the lock: an update or rebuild that ended after the caller read the
        // record changed the disk and the record together, and the box records what it clones.
        // An `image update` that was killed is finished or dropped first.
        let current = try imageStore.settle(image)
        guard current.record.state == .ready else {
            throw AgentVMError.wrongImageState(name: current.name, state: current.record.state.rawValue, operation: "create a box from")
        }

        try FileSystem.makeDirectories(boxesDirectory.path)
        let directory = boxesDirectory.appendingPathComponent(name, isDirectory: true)
        if mkdir(directory.path, 0o700) != 0 {
            let code = errno
            if code == EEXIST {
                throw AgentVMError.boxExists(name)
            }
            throw AgentVMError.system(operation: "create \(directory.path)", code: code)
        }
        let record = BoxRecord(
            formatVersion: BoxRecord.currentFormatVersion, name: name, image: current.name,
            macOSVersion: current.record.macOSVersion, macOSBuild: current.record.macOSBuild,
            // Whole seconds: the record is stored with ISO 8601 dates, which drop fractions.
            guestProtocol: current.record.guestProtocol, createdAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)),
            cpuCount: cpuCount ?? current.record.cpuCount, memoryBytes: memoryBytes ?? current.record.memoryBytes,
            macAddress: VZMACAddress.randomLocallyAdministered().string, userName: current.record.userName,
            network: network, disposable: disposable ? true : nil,
            guestVersion: current.record.guestVersion, guestDigest: current.record.guestDigest,
            imageCreatedAt: current.record.createdAt, imageRevision: current.record.revision ?? 0)
        let box = Box(record: record, directory: directory)
        do {
            try Self.cloneFile(current.diskURL, to: box.diskURL)
            try Self.cloneFile(current.auxiliaryStorageURL, to: box.auxiliaryStorageURL)
            try Self.cloneFile(current.hardwareModelURL, to: box.hardwareModelURL)
            try Self.cloneFile(current.passwordURL, to: box.passwordURL)
            try VZMacMachineIdentifier().dataRepresentation.write(to: box.machineIdentifierURL)
            try save(box)
        } catch {
            try? FileSystem.removeTree(directory.path)
            throw error
        }
        return box
    }

    public func box(named name: String) throws -> Box {
        guard ImageStore.isValidName(name) else {
            throw AgentVMError.invalidBoxName(name)
        }
        let directory = boxesDirectory.appendingPathComponent(name, isDirectory: true)
        guard FileSystem.exists(directory.path) else {
            throw AgentVMError.boxNotFound(name)
        }
        let path = directory.appendingPathComponent(Self.recordName).path
        let record: BoxRecord
        do {
            record = try SessionStore.decoder.decode(BoxRecord.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            throw AgentVMError.corruptBoxRecord(path: path, reason: error.localizedDescription)
        }
        guard record.name == name else {
            throw AgentVMError.corruptBoxRecord(path: path, reason: "it names box \(record.name)")
        }
        guard record.formatVersion <= BoxRecord.currentFormatVersion else {
            throw AgentVMError.corruptBoxRecord(path: path, reason: "written by a newer agent-vm (format \(record.formatVersion))")
        }
        return Box(record: record, directory: directory)
    }

    /// Every box, sorted by name; unreadable ones are returned as problems.
    public func list() throws -> (boxes: [Box], problems: [String]) {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: boxesDirectory.path)
        } catch {
            if !FileSystem.exists(boxesDirectory.path) {
                return ([], [])
            }
            throw AgentVMError.system(operation: "list \(boxesDirectory.path)", code: FileSystem.posixCode(error))
        }
        var boxes: [Box] = []
        var problems: [String] = []
        for name in names.sorted() where ImageStore.isValidName(name) {
            do {
                boxes.append(try box(named: name))
            } catch {
                problems.append("\(error)")
            }
        }
        return (boxes, problems)
    }

    /// Replaces the box's network policy. The mode decides the network card, so it changes
    /// only while the box is stopped; rules can change any time (a running supervisor rereads
    /// them on the control socket's `reload`).
    @discardableResult
    public func updateNetwork(named name: String, to network: BoxNetwork) throws -> Box {
        _ = try CompiledPolicy(network, packs: try NetworkPacks.needed(for: network, store: root, builtIn: builtInPacks))
        let current = try box(named: name)
        // A mode change holds the box lock while saving, so no start can slip in between the
        // check and the write.
        var lock: FolderLock?
        if network.mode != current.record.effectiveNetwork.mode {
            lock = try FolderLock.tryAcquire(current.lockPath, patience: FolderLock.testPatience)
            guard lock != nil else {
                throw AgentVMError.boxRunning(name)
            }
        }
        defer { lock?.release() }
        var record = current.record
        record.network = network
        let updated = Box(record: record, directory: current.directory)
        try save(updated)
        return updated
    }

    /// Deletes box `name` and creates it again from `image` with the same CPUs, memory,
    /// network rules and disposable flag: a fresh clone of the image, with a new identity and
    /// empty logs. It checks first what it can (the box stopped, the image ready and free, the
    /// rules and packs usable), so a refusal leaves the box as it was; a create that still fails
    /// after the delete says how to create the box by hand.
    public func recreate(name: String, from image: GoldenImage, imageStore: ImageStore, collectionPatience: Duration = .seconds(30)) throws -> Box {
        let old = try box(named: name)
        guard !old.isRunning else {
            throw AgentVMError.boxRunning(name)
        }
        let network = old.record.network ?? .legacy
        let disposable = old.record.disposable == true
        _ = try CompiledPolicy(network, packs: try NetworkPacks.needed(for: network, store: root, builtIn: builtInPacks))
        guard image.record.state == .ready else {
            throw AgentVMError.wrongImageState(name: image.name, state: image.record.state.rawValue, operation: "create a box from")
        }
        guard let imageLock = try imageStore.tryLock(image) else {
            throw AgentVMError.imageBusy(image.name)
        }
        imageLock.release()
        // A collection lists disposable boxes, then deletes them by name: one running now could
        // take the new box for the old one's garbage. The same lock keeps it out until the new
        // box exists.
        var collecting: FolderLock?
        if disposable {
            collecting = try FolderLock.tryAcquire(boxesDirectory.appendingPathComponent(Self.gcLockName).path, patience: collectionPatience)
            guard collecting != nil else {
                throw AgentVMError.boxBusy(name, reason: "box gc is deleting stopped disposable boxes")
            }
        }
        defer { collecting?.release() }
        try delete(named: name)
        do {
            return try create(name: name, from: image, imageStore: imageStore, cpuCount: old.record.cpuCount,
                              memoryBytes: old.record.memoryBytes, network: network, disposable: disposable)
        } catch {
            throw AgentVMError.boxNotRecreated(name: name, reason: "\(error)",
                                               command: Self.createCommand(name: name, image: image.name, record: old.record, network: network))
        }
    }

    /// The `box create` command that makes a box like `record`, for a person to run.
    static func createCommand(name: String, image: String, record: BoxRecord, network: BoxNetwork) -> String {
        var words = ["agent-vm", "box", "create", name, "--image", image, "--cpus", String(record.cpuCount),
                     "--memory-gb", String(max(1, (record.memoryBytes + (1 << 30) - 1) >> 30)), "--net", network.mode.rawValue]
        for rule in network.allow {
            words += ["--allow", rule]
        }
        if record.disposable == true {
            words.append("--disposable")
        }
        return words.map(shellQuoted).joined(separator: " ")
    }

    /// `word` as a shell would read it back: as is when plain, else in single quotes.
    static func shellQuoted(_ word: String) -> String {
        let plain = !word.isEmpty && word.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "-_.:/=@+".unicodeScalars.contains(scalar))
        }
        return plain ? word : "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Deletes a box and its disk; refused while its supervisor runs.
    public func delete(named name: String) throws {
        guard ImageStore.isValidName(name) else {
            throw AgentVMError.invalidBoxName(name)
        }
        let directory = boxesDirectory.appendingPathComponent(name, isDirectory: true)
        guard FileSystem.exists(directory.path) else {
            throw AgentVMError.boxNotFound(name)
        }
        let lock: FolderLock?
        do {
            lock = try FolderLock.tryAcquire(directory.appendingPathComponent(Self.lockName).path, patience: FolderLock.testPatience)
        } catch AgentVMError.system(_, ENOENT) {
            // Deleted meanwhile by another process.
            throw AgentVMError.boxNotFound(name)
        }
        guard let lock else {
            throw AgentVMError.boxRunning(name)
        }
        defer { lock.release() }
        // The record goes first. A supervisor starting meanwhile can only hold a lock once this
        // one's file is unlinked (it recreates one while the folder is removed) or released,
        // and it then finds no record and gives up (BoxSupervisor.run), instead of passing
        // that check and booting a box whose files are vanishing.
        _ = unlink(directory.appendingPathComponent(Self.recordName).path)
        try FileSystem.removeTree(directory.path)
    }

    /// Deletes stopped disposable boxes: those with a tombstone, and those without one created
    /// more than `unstartedDisposableAge` ago. A box that runs (its lock is held) is never
    /// touched: delete takes the lock. Returns the boxes deleted, and what could not be done.
    /// `except`: a box to leave alone (the one `box start` is about to start).
    public func collectGarbage(now: Date = Date(), except: String? = nil) -> (deleted: [String], problems: [String]) {
        guard FileSystem.exists(boxesDirectory.path) else {
            return ([], [])
        }
        // One collection at a time: box list, box start and doctor can run at once, and two of
        // them deleting the same box trip over each other (one recreates the lock file in a
        // folder the other is removing) and report errors for a box that is gone.
        guard let collecting = try? FolderLock.tryAcquire(boxesDirectory.appendingPathComponent(Self.gcLockName).path, patience: .seconds(10)) else {
            return ([], [])
        }
        defer { collecting.release() }
        guard let boxes = try? list().boxes else {
            return ([], [])
        }
        var deleted: [String] = []
        var problems: [String] = []
        for box in boxes where box.record.disposable == true && box.name != except && !box.isRunning {
            let old = now.timeIntervalSince(box.record.createdAt) >= Self.unstartedDisposableAge
            guard box.isTombstoned || old else {
                continue
            }
            do {
                try delete(named: box.name)
                deleted.append(box.name)
            } catch AgentVMError.boxRunning {
                // Started meanwhile: no longer garbage.
            } catch {
                problems.append("cannot delete disposable box \(box.name): \(error)")
            }
        }
        return (deleted, problems)
    }

    private func save(_ box: Box) throws {
        let path = box.directory.appendingPathComponent(Self.recordName)
        do {
            try SessionStore.encoder.encode(box.record).write(to: path, options: .atomic)
        } catch {
            throw AgentVMError.corruptBoxRecord(path: path.path, reason: "cannot write: \(error.localizedDescription)")
        }
    }

    /// clonefile(2) for one file: copy-on-write, atomic, keeps the mode; fails across volumes.
    static func cloneFile(_ source: URL, to destination: URL) throws {
        guard clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW)) == 0 else {
            let code = errno
            if code == EXDEV {
                throw AgentVMError.differentVolume(project: destination.deletingLastPathComponent().path, store: source.deletingLastPathComponent().path)
            }
            throw AgentVMError.system(operation: "clone \(source.lastPathComponent)", code: code)
        }
    }
}
