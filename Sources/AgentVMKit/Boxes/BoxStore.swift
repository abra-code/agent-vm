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
//   Boxes/<name>/events.jsonl        what happened to the box: started, shared, rules changed (BoxEventLog)
//   Boxes/<name>/Disk.img            APFS clone of the image's disk
//   Boxes/<name>/AuxiliaryStorage    APFS clone of the image's auxiliary storage
//   Boxes/<name>/HardwareModel       copy of the image's
//   Boxes/<name>/MachineIdentifier   the box's own
//   Boxes/<name>/Password            copy of the image's (the account is the same); not there
//                                    when the record names a Keychain item (AccountPassword)
//   Boxes/<name>/EFIVariableStore    a Linux box's boot firmware variables, a clone of the
//                                    image's; such a box has no AuxiliaryStorage, no
//                                    HardwareModel and no Password
//   Boxes/<name>/console.log         what a Linux guest printed on its console (ConsoleLog)
//   Boxes/<name>/tombstone           a disposable box that stopped; `box gc` deletes the folder
//   Boxes/.gc.lock                   held while `box gc` runs, so only one collects at a time
//
// A deleted box's logs are not deleted with it: they move to Logs/ in the store (KeptLogs).
//
// A clone takes no space until the box writes, so creating a box is instant; the image must
// be on the same volume. Each box gets its own MAC address and machine identifier, so two
// boxes of one image can run side by side.

import Darwin
import Foundation
import Virtualization

public struct BoxRecord: Codable, Equatable, Sendable {
    /// The newest format this agent-vm reads. 2: the record names its password's Keychain
    /// item; 3: the box is a Linux guest (see `ImageRecord.formatVersion`, which says what a
    /// new record is written as).
    public static let currentFormatVersion = 3

    public var formatVersion: Int
    public var name: String
    /// The image the box was cloned from, and what it held at that time.
    public var image: String
    /// nil in a Linux box.
    public var macOSVersion: String?
    public var macOSBuild: String?
    /// The system the box runs, as its image said when the box was made; nil in records written
    /// before there were Linux guests, which are macOS ones (`effectiveGuest`).
    public var guest: GuestKind?
    public var linux: LinuxSystem?
    /// A Linux box with a display, keyboard and pointer, as its image had when the box was made
    /// (`ImageRecord.screen`); nil for one without.
    public var screen: Bool?
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
    /// The image's `passwordID` when the box was made: the Keychain item with the account's
    /// password, shared with the image. Nil when the box has a `Password` file.
    public var passwordID: String?
    /// The names the box had before `box rename`, oldest first. What a session noted about a
    /// box, it noted under the name the box had then.
    public var formerNames: [String]?

    public var effectiveNetwork: BoxNetwork {
        return network ?? .legacy
    }

    public var effectiveGuest: GuestKind {
        return guest ?? .macOS
    }

    /// Whether the box's machine has a display, so `box view` can show it and its supervisor runs
    /// AppKit: every macOS box, and a Linux box whose image installed a desktop.
    public var hasScreen: Bool {
        return effectiveGuest == .macOS || screen == true
    }

    /// "macOS 27.0 (26A428)", "Debian GNU/Linux 13 (trixie)".
    public var systemDescription: String {
        return GuestSystemText.description(guest: effectiveGuest, macOSVersion: macOSVersion, macOSBuild: macOSBuild, linux: linux)
    }

    /// "macOS 27.0", "Debian 13".
    public var systemShort: String {
        return GuestSystemText.short(guest: effectiveGuest, macOSVersion: macOSVersion, linux: linux)
    }

    /// "macOS 26A428", "Debian 13": the system by what tells two states of it apart.
    public var systemBuild: String {
        return GuestSystemText.build(guest: effectiveGuest, macOSBuild: macOSBuild, linux: linux)
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
                return [BoxNeed(kind: .recreate, reason: .imageRebuilt, macOSBuild: image.macOSBuild, system: image.systemBuild)]
            }
            if (imageRevision ?? 0) != (image.revision ?? 0) {
                return [BoxNeed(kind: .recreate, reason: .imageUpdated, macOSBuild: image.macOSBuild, system: image.systemBuild)]
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
    /// image-updated and image-rebuilt: the image's macOS build now (macOS images only), and
    /// its system now in words, for either guest ("macOS 26A434", "Debian 13").
    public var macOSBuild: String?
    public var system: String?

    public init(kind: Kind, guestVersion: String? = nil, reason: Reason? = nil, macOSBuild: String? = nil, system: String? = nil) {
        self.kind = kind
        self.guestVersion = guestVersion
        self.reason = reason
        self.macOSBuild = macOSBuild
        self.system = system
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
    /// A Linux box's boot firmware variables, and what its guest printed on its console.
    public var efiVariableStoreURL: URL { directory.appendingPathComponent(ImageStore.efiVariableStoreName) }
    public var consoleLogURL: URL { directory.appendingPathComponent(ImageStore.consoleLogName) }
    public var passwordURL: URL { directory.appendingPathComponent(ImageStore.passwordName) }
    public var lockPath: String { directory.appendingPathComponent(BoxStore.lockName).path }
    public var controlSocketPath: String { directory.appendingPathComponent(BoxStore.controlSocketName).path }
    public var logURL: URL { directory.appendingPathComponent(BoxStore.logName) }
    public var networkLogURL: URL { directory.appendingPathComponent(BoxStore.networkLogName) }
    public var execLogURL: URL { directory.appendingPathComponent(BoxStore.execLogName) }
    public var eventsLogURL: URL { directory.appendingPathComponent(BoxStore.eventsLogName) }
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
        return MachineFiles(name: name, directory: directory, guest: record.effectiveGuest)
    }
}

public struct BoxStore: Sendable {
    static let recordName = "box.json"
    static let lockName = ".lock"
    static let controlSocketName = "control.sock"
    static let logName = "supervisor.log"
    static let networkLogName = "network.jsonl"
    static let execLogName = "exec.jsonl"
    static let eventsLogName = "events.jsonl"
    static let tombstoneName = "tombstone"
    /// In Boxes/: held while `gc` runs (not a valid box name, so list skips it).
    static let gcLockName = ".gc.lock"

    /// How old a disposable box without a tombstone must be before `gc` deletes it: one that
    /// was never started, or whose supervisor died. A client creates and starts one within
    /// seconds, so a younger one may be about to start.
    public static let unstartedDisposableAge: TimeInterval = 600

    public let root: URL
    /// The Keychain items of account passwords; a test names its own service.
    public var passwords = AccountPasswordStore()
    /// The built-in host packs file (NetworkPacks): next to the executable unless given.
    public let builtInPacks: URL?

    public init(root: URL, builtInPacks: URL? = NetworkPacks.builtInURL()) {
        self.root = FileSystem.canonicalRoot(root)
        self.builtInPacks = builtInPacks
    }

    public var boxesDirectory: URL {
        return root.appendingPathComponent("Boxes", isDirectory: true)
    }

    /// The longest box name a box of this store can start with: its control socket,
    /// Boxes/<name>/control.sock, must fit the 103 bytes macOS allows a socket's path. At most
    /// 63 (`ImageStore.isValidName`); 0 when the store's folder leaves no room.
    public var maxBoxNameLength: Int {
        return Self.maxNameLength(boxes: boxesDirectory.path)
    }

    static func maxNameLength(boxes: String) -> Int {
        let around = (boxes + "/" + "/" + controlSocketName).utf8.count
        return max(0, min(63, ControlChannel.maxPathBytes - around))
    }

    /// Refuses `name` when it is longer than `maxBoxNameLength`. `existing`: a box that has the
    /// name already, which the refusal tells to rename.
    public func checkNameLength(_ name: String, existing: Bool = false) throws {
        try Self.checkNameLength(name, boxes: boxesDirectory.path, existing: existing)
    }

    /// Refuses a name a new box cannot have here: too long for the store, or another box's in
    /// other case. A box of that very name is the caller's to refuse (`boxExists`).
    public func checkNewName(_ name: String) throws {
        try checkNameLength(name)
        try StoreName.checkFree(name, in: boxesDirectory, what: "box")
    }

    static func checkNameLength(_ name: String, boxes: String, existing: Bool) throws {
        let limit = maxNameLength(boxes: boxes)
        guard name.utf8.count > limit else {
            return
        }
        throw AgentVMError.boxNameTooLong(name: name, limit: limit, boxes: boxes, existing: existing)
    }

    /// Clones a ready image into a new box. The image's lock is held while cloning, so the
    /// image cannot be deleted or rebuilt halfway.
    public func create(name: String, from image: GoldenImage, imageStore: ImageStore,
                       cpuCount: Int? = nil, memoryBytes: UInt64? = nil,
                       network: BoxNetwork = BoxNetwork(mode: .allowlist), disposable: Bool = false) throws -> Box {
        guard ImageStore.isValidName(name) else {
            throw AgentVMError.invalidBoxName(name)
        }
        // A box whose supervisor could not listen would never start; one whose name another
        // box has in other case would share its folder.
        try checkNewName(name)
        // A size that was asked for and this Mac cannot run; the image's own is not checked,
        // it may come from another Mac and the start says so.
        if let problem = MachineSize.problem(cpuCount: cpuCount, memoryBytes: memoryBytes) {
            throw AgentVMError.virtualMachine(operation: "configure \(name)", message: problem)
        }
        // The image's own size too: a box too small to start is refused now, not at its start.
        if let refusal = MachineSize.memoryRefusal(memoryBytes: memoryBytes ?? image.record.memoryBytes, guest: image.record.effectiveGuest) {
            throw AgentVMError.virtualMachine(operation: "configure \(name)", message: refusal)
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

        try StoreRoot.prepare(root)
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
            formatVersion: ImageRecord.formatVersion(passwordID: current.record.passwordID, guest: current.record.guest), name: name, image: current.name,
            macOSVersion: current.record.macOSVersion, macOSBuild: current.record.macOSBuild,
            guest: current.record.guest, linux: current.record.linux, screen: current.record.screen,
            // Whole seconds: the record is stored with ISO 8601 dates, which drop fractions.
            guestProtocol: current.record.guestProtocol, createdAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)),
            cpuCount: cpuCount ?? current.record.cpuCount, memoryBytes: memoryBytes ?? current.record.memoryBytes,
            macAddress: VZMACAddress.randomLocallyAdministered().string, userName: current.record.userName,
            network: network, disposable: disposable ? true : nil,
            guestVersion: current.record.guestVersion, guestDigest: current.record.guestDigest,
            imageCreatedAt: current.record.createdAt, imageRevision: current.record.revision ?? 0,
            passwordID: current.record.passwordID)
        let box = Box(record: record, directory: directory)
        do {
            try Self.cloneFile(current.diskURL, to: box.diskURL)
            switch current.record.effectiveGuest {
            case .macOS:
                try Self.cloneFile(current.auxiliaryStorageURL, to: box.auxiliaryStorageURL)
                try Self.cloneFile(current.hardwareModelURL, to: box.hardwareModelURL)
                // A password in the Keychain is shared by its identifier, in the record.
                if current.record.passwordID == nil {
                    try Self.cloneFile(current.passwordURL, to: box.passwordURL)
                }
                try VZMacMachineIdentifier().dataRepresentation.write(to: box.machineIdentifierURL)
            case .linux:
                // The firmware's variables go with the disk they were written for; there is
                // no account password to carry.
                try Self.cloneFile(current.efiVariableStoreURL, to: box.efiVariableStoreURL)
                try LinuxMachineSpec.createIdentifier(box.machineIdentifierURL)
            }
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
        try StoreName.checkExact(name, in: boxesDirectory, what: "box")
        return try Self.read(name: name, directory: boxesDirectory.appendingPathComponent(name, isDirectory: true))
    }

    /// `box` as its record says now. Whoever read a box before taking its lock reads it again
    /// under the lock with this: `box set` and `box network` change the record of a stopped box.
    public static func reread(_ box: Box) throws -> Box {
        return try read(name: box.name, directory: box.directory)
    }

    private static func read(name: String, directory: URL) throws -> Box {
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
            if let mark = RenameMark.read(in: directory), mark.to == name {
                throw AgentVMError.corruptBoxRecord(path: path, reason: "renaming box \(mark.from) to \(mark.to) was interrupted; `agent-vm box rename \(mark.from) \(mark.to)` finishes it")
            }
            throw AgentVMError.corruptBoxRecord(path: path, reason: "it names box \(record.name)")
        }
        if let problem = RecordNumbers.problem(cpuCount: record.cpuCount, memoryBytes: record.memoryBytes, diskBytes: nil) {
            throw AgentVMError.corruptBoxRecord(path: path, reason: problem)
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
        // A rule change takes no box lock (the box may be running), and the record is read,
        // changed and written back here. Not while account passwords are moved into the
        // Keychain: that writes the same record, and a copy read before would undo it.
        guard let recordLock = try FolderLock.tryAcquire(AccountPasswordStore.lockPath(store: root), patience: AccountPasswordStore.lockPatience) else {
            throw AgentVMError.system(operation: "change the rules of box \(name) while account passwords are moved into the Keychain", code: EBUSY)
        }
        defer { recordLock.release() }
        let current = try box(named: name)
        // Before this takes the box's lock itself, which reads as running.
        let wasRunning = current.isRunning
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
        // The network log is read against the rules in force at the time: this is when they changed.
        if network != current.record.effectiveNetwork {
            BoxEventLog(url: updated.eventsLogURL).append(.init(.rules, before: current.record.effectiveNetwork, after: network, running: wasRunning))
        }
        return updated
    }

    /// Changes the box's CPUs, memory or both (nil: as it is). They are read when the box
    /// starts, so only a stopped box takes them; its lock is held while the record is written,
    /// and a supervisor reads the record again once it holds the lock (BoxSupervisor.run), so
    /// no box runs at one size while its record names another.
    @discardableResult
    public func resize(named name: String, cpuCount: Int? = nil, memoryBytes: UInt64? = nil) throws -> Box {
        if let problem = MachineSize.problem(cpuCount: cpuCount, memoryBytes: memoryBytes) {
            throw AgentVMError.virtualMachine(operation: "configure \(name)", message: problem)
        }
        // As in `updateNetwork`: the record is read, changed and written back, and moving
        // account passwords into the Keychain writes the same record.
        guard let recordLock = try FolderLock.tryAcquire(AccountPasswordStore.lockPath(store: root), patience: AccountPasswordStore.lockPatience) else {
            throw AgentVMError.system(operation: "change the size of box \(name) while account passwords are moved into the Keychain", code: EBUSY)
        }
        defer { recordLock.release() }
        let listed = try box(named: name)
        let lock: FolderLock?
        do {
            lock = try FolderLock.tryAcquire(listed.lockPath, patience: FolderLock.testPatience)
        } catch AgentVMError.system(_, ENOENT) {
            // Deleted meanwhile by another process.
            throw AgentVMError.boxNotFound(name)
        }
        guard let lock else {
            throw AgentVMError.boxRunning(name)
        }
        defer { lock.release() }
        // Read again under the lock: a delete or a recreate that ran since the first read
        // must not get the old record written back (into a folder that is going away, or
        // over the new box's identity). As in BoxSupervisor.run, a lock file made in what a
        // delete left is taken away again.
        guard FileSystem.exists(listed.directory.appendingPathComponent(Self.recordName).path) else {
            unlink(listed.lockPath)
            rmdir(listed.directory.path)
            throw AgentVMError.boxNotFound(name)
        }
        let current = try box(named: name)
        var record = current.record
        record.cpuCount = cpuCount ?? record.cpuCount
        record.memoryBytes = memoryBytes ?? record.memoryBytes
        if let problem = RecordNumbers.problem(cpuCount: record.cpuCount, memoryBytes: record.memoryBytes, diskBytes: nil) {
            throw AgentVMError.virtualMachine(operation: "configure \(name)", message: problem)
        }
        if memoryBytes != nil, let refusal = MachineSize.memoryRefusal(memoryBytes: record.memoryBytes, guest: record.effectiveGuest) {
            throw AgentVMError.virtualMachine(operation: "configure \(name)", message: refusal)
        }
        let updated = Box(record: record, directory: current.directory)
        try save(updated)
        return updated
    }

    /// The memory of the boxes that run now, without `name`: what a start of `name` adds to.
    public func runningMemory(except name: String) -> [UInt64] {
        guard let boxes = try? list().boxes else {
            return []
        }
        return boxes.filter { $0.name != name && $0.isRunning }.map(\.record.memoryBytes)
    }

    /// Deletes box `name` and creates it again from `image` with the same CPUs, memory,
    /// network rules and disposable flag: a fresh clone of the image, with a new identity and
    /// empty logs (the old box's are kept, and `deleted` is told where). It checks first what it can (the box stopped, its name short enough for this store, its memory enough to start, its size within what this Mac allows, the image ready and free, the
    /// rules and packs usable), so a refusal leaves the box as it was; a create that still fails
    /// after the delete says how to create the box by hand.
    public func recreate(name: String, from image: GoldenImage, imageStore: ImageStore, collectionPatience: Duration = .seconds(30),
                         deleted: ((Deleted) -> Void)? = nil) throws -> Box {
        let old = try box(named: name)
        guard !old.isRunning else {
            throw AgentVMError.boxRunning(name)
        }
        // A box made before the length was checked (0.7.53), or in a store that moved:
        // `create` would refuse its name only after the delete.
        try checkNameLength(name, existing: true)
        let network = old.record.network ?? .legacy
        let disposable = old.record.disposable == true
        _ = try CompiledPolicy(network, packs: try NetworkPacks.needed(for: network, store: root, builtIn: builtInPacks))
        // A box made before the smallest size was checked (0.7.51): `create` would refuse its
        // size only after the delete.
        let guest = image.record.effectiveGuest
        if let refusal = MachineSize.memoryRefusal(memoryBytes: old.record.memoryBytes, guest: guest) {
            throw AgentVMError.virtualMachine(operation: "configure \(name)",
                                              message: "\(refusal); `agent-vm box set \(name) --memory-gb \(MachineSize.gigabytes(MachineSize.comfortableMemory(for: guest, screen: image.record.screen == true)))` gives it more")
        }
        // A box larger than this Mac allows (made on a larger Mac, or before a change to what
        // it allows): `create` would refuse its size only after the delete.
        if let problem = MachineSize.problem(cpuCount: old.record.cpuCount, memoryBytes: old.record.memoryBytes) {
            throw AgentVMError.virtualMachine(operation: "configure \(name)",
                                              message: "\(problem); \(MachineSize.fittingCommand(box: name, cpuCount: old.record.cpuCount, memoryBytes: old.record.memoryBytes)) makes it fit")
        }
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
        let gone = try delete(named: name)
        deleted?(gone)
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

    /// What `delete` did with the box's logs.
    public struct Deleted: Sendable, Equatable {
        /// Where the logs are now (a folder in Logs/); nil when the box logged nothing, or
        /// when none could be kept.
        public var keptLogs: URL?
        /// Why some or all of the logs were not kept.
        public var logsProblem: String?

        public init(keptLogs: URL? = nil, logsProblem: String? = nil) {
            self.keptLogs = keptLogs
            self.logsProblem = logsProblem
        }
    }

    /// Deletes a box and its disk; refused while its supervisor runs. Its logs are moved out
    /// first (KeptLogs); a box whose logs cannot be moved is deleted all the same, and the
    /// result says so.
    @discardableResult
    public func delete(named name: String, now: Date = Date()) throws -> Deleted {
        guard ImageStore.isValidName(name) else {
            throw AgentVMError.invalidBoxName(name)
        }
        try StoreName.checkExact(name, in: boxesDirectory, what: "box")
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
        var deleted = Deleted()
        do {
            deleted.keptLogs = try KeptLogs(root: root).keep(box: name, folder: directory, record: try? Self.read(name: name, directory: directory).record, now: now)
        } catch let KeptLogs.Partial.some(kept, reason) {
            deleted.keptLogs = kept
            deleted.logsProblem = reason
        } catch {
            deleted.logsProblem = "\(error)"
        }
        // The record goes first. A supervisor starting meanwhile can only hold a lock once this
        // one's file is unlinked (it recreates one while the folder is removed) or released,
        // and it then finds no record and gives up (BoxSupervisor.run), instead of passing
        // that check and booting a box whose files are vanishing.
        _ = unlink(directory.appendingPathComponent(Self.recordName).path)
        try FileSystem.removeTree(directory.path)
        // The account password goes with the last image or box that names it.
        passwords.removeUnused(store: root)
        return deleted
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
                let gone = try delete(named: box.name)
                deleted.append(box.name)
                if let problem = gone.logsProblem {
                    problems.append("not all of the logs of disposable box \(box.name) were kept: \(problem)")
                }
            } catch AgentVMError.boxRunning {
                // Started meanwhile: no longer garbage.
            } catch {
                problems.append("cannot delete disposable box \(box.name): \(error)")
            }
        }
        return (deleted, problems)
    }

    // MARK: - Renaming

    /// In a box's or an image's folder while it is renamed: the two names. A rename that was
    /// interrupted after the folder moved is finished by giving the same command again.
    struct RenameMark: Codable, Equatable {
        static let fileName = ".rename"
        var from: String
        var to: String

        static func read(in directory: URL) -> RenameMark? {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else {
                return nil
            }
            return try? JSONDecoder().decode(RenameMark.self, from: data)
        }

        func write(in directory: URL) throws {
            let url = directory.appendingPathComponent(Self.fileName)
            do {
                try JSONEncoder().encode(self).write(to: url, options: .atomic)
            } catch {
                throw AgentVMError.system(operation: "write \(url.path)", code: EIO)
            }
        }

        static func remove(in directory: URL) {
            _ = unlink(directory.appendingPathComponent(fileName).path)
        }
    }

    public struct Renamed: Sendable {
        public var box: Box
        /// How many folders' remembered choices (avm) named the box and name it by its new
        /// name now.
        public var rememberedFolders: Int
    }

    /// Gives a stopped box another name: its folder and record, and avm's remembered choices.
    /// What the box holds, its rules and its logs stay; its former name is kept in the record,
    /// so a session that ran programs in it still finds them. Refused for a running box, a
    /// temporary one (it is deleted once it stops), a name that is taken, and a box a job
    /// that has not ended was started for.
    @discardableResult
    public func rename(_ old: String, to new: String) throws -> Renamed {
        guard ImageStore.isValidName(old) else {
            throw AgentVMError.invalidBoxName(old)
        }
        guard ImageStore.isValidName(new) else {
            throw AgentVMError.invalidBoxName(new)
        }
        try checkNameLength(new)
        guard old != new else {
            throw AgentVMError.cannotRename(what: "box \(old)", reason: "\(new) is the name it has")
        }
        // As in `resize`: the record is rewritten, and so is it when account passwords move
        // into the Keychain.
        guard let recordLock = try FolderLock.tryAcquire(AccountPasswordStore.lockPath(store: root), patience: AccountPasswordStore.lockPatience) else {
            throw AgentVMError.system(operation: "rename box \(old) while account passwords are moved into the Keychain", code: EBUSY)
        }
        defer { recordLock.release() }
        let oldDirectory = boxesDirectory.appendingPathComponent(old, isDirectory: true)
        let newDirectory = boxesDirectory.appendingPathComponent(new, isDirectory: true)
        let mark = RenameMark(from: old, to: new)
        // Listed, not merely found: the disk ignores case, so after a change of case only the
        // old path still opens the folder.
        if try !StoreName.isListed(old, in: boxesDirectory) {
            // The folder moved and the rest did not happen: finished here.
            guard RenameMark.read(in: newDirectory) == mark else {
                try StoreName.checkExact(old, in: boxesDirectory, what: "box")
                throw AgentVMError.boxNotFound(old)
            }
            guard let lock = try FolderLock.tryAcquire(newDirectory.appendingPathComponent(Self.lockName).path, patience: FolderLock.testPatience) else {
                throw AgentVMError.boxRunning(new)
            }
            defer { lock.release() }
            return try finishRename(mark, directory: newDirectory)
        }
        // A change of case only ("work" to "Work") is a rename of the folder onto itself.
        try StoreName.checkFree(new, in: boxesDirectory, what: "box", except: old)
        guard try !StoreName.isListed(new, in: boxesDirectory) else {
            throw AgentVMError.boxExists(new)
        }
        let lock: FolderLock?
        do {
            lock = try FolderLock.tryAcquire(oldDirectory.appendingPathComponent(Self.lockName).path, patience: FolderLock.testPatience)
        } catch AgentVMError.system(_, ENOENT) {
            throw AgentVMError.boxNotFound(old)
        }
        guard let lock else {
            throw AgentVMError.boxRunning(old)
        }
        defer { lock.release() }
        // As in `resize`: a lock file made in what a delete left is taken away again.
        guard FileSystem.exists(oldDirectory.appendingPathComponent(Self.recordName).path) else {
            unlink(oldDirectory.appendingPathComponent(Self.lockName).path)
            rmdir(oldDirectory.path)
            throw AgentVMError.boxNotFound(old)
        }
        let current = try box(named: old)
        guard current.record.disposable != true else {
            throw AgentVMError.cannotRename(what: "box \(old)", reason: "it is a temporary box, deleted once it stops")
        }
        if let job = JobStore(root: root).unfinishedJob(for: "box:\(old)") {
            throw AgentVMError.cannotRename(what: "box \(old)", reason: "job \(job) was started for it and has not ended")
        }
        try mark.write(in: oldDirectory)
        guard renamex_np(oldDirectory.path, newDirectory.path, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            RenameMark.remove(in: oldDirectory)
            if code == EEXIST {
                throw AgentVMError.boxExists(new)
            }
            throw AgentVMError.system(operation: "rename \(oldDirectory.path) to \(newDirectory.path)", code: code)
        }
        return try finishRename(mark, directory: newDirectory)
    }

    /// The steps after the folder has its new name; each may be taken again.
    private func finishRename(_ mark: RenameMark, directory: URL) throws -> Renamed {
        let path = directory.appendingPathComponent(Self.recordName).path
        var record: BoxRecord
        do {
            record = try SessionStore.decoder.decode(BoxRecord.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            throw AgentVMError.corruptBoxRecord(path: path, reason: error.localizedDescription)
        }
        guard record.name == mark.from || record.name == mark.to else {
            throw AgentVMError.corruptBoxRecord(path: path, reason: "it names box \(record.name)")
        }
        record.name = mark.to
        var former = (record.formerNames ?? []).filter { $0 != mark.to && $0 != mark.from }
        former.append(mark.from)
        record.formerNames = former
        let box = Box(record: record, directory: directory)
        try save(box)
        BoxEventLog(url: box.eventsLogURL).append(.init(.rename, detail: "from \(mark.from) to \(mark.to)"))
        // Not worth failing for: avm's lists then start at the top for those folders.
        let folders = (try? ConnectChoices(store: root).rename(box: mark.from, to: mark.to)) ?? 0
        RenameMark.remove(in: directory)
        return Renamed(box: box, rememberedFolders: folders)
    }

    /// Makes every box of image `old` name `new` as its image; returns their names. The caller
    /// holds the lock that guards box records (AccountPasswordStore.lockPath). A running box
    /// is changed too: its record is read only by commands, as for a rule change.
    func repointImage(from old: String, to new: String) throws -> [String] {
        var changed: [String] = []
        for box in try list().boxes where box.record.image == old {
            var record = box.record
            record.image = new
            try save(Box(record: record, directory: box.directory))
            changed.append(box.name)
        }
        return changed
    }

    /// Records the Keychain item that holds the box's password (AccountPasswordMove); the
    /// caller holds the box's lock.
    func setPasswordID(_ id: String, of box: Box) throws {
        var record = box.record
        record.passwordID = id
        record.formatVersion = ImageRecord.formatVersion(passwordID: id, guest: record.guest)
        try save(Box(record: record, directory: box.directory))
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
