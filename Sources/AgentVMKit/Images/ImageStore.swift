// Sources/AgentVMKit/Images/ImageStore.swift
//
// Golden images under the store root (`$AGENT_VM_HOME`, default
// `~/Library/Application Support/agent-vm`):
//
//   Images/<name>/image.json          the ImageRecord
//   Images/<name>/.lock               flock held by whoever builds the image, changes its
//                                     files or clones them
//   Images/<name>/.update.lock        flock held for as long as a command changes a ready
//                                     image (update, update-guest, setup), one at a time
//   Images/<name>/.linux-vm.lock      flock held while a command runs a Linux guest of the
//                                     image (a build, an update), so that it is counted as one
//   Images/<name>/Disk.img            sparse raw disk
//   Images/<name>/AuxiliaryStorage    NVRAM and boot state (Apple format)
//   Images/<name>/HardwareModel       VZMacHardwareModel.dataRepresentation
//   Images/<name>/MachineIdentifier   VZMacMachineIdentifier.dataRepresentation
//   Images/<name>/Password            the guest account's password (0600); not there when the
//                                     record names a Keychain item (AccountPassword)
//   Images/<name>/known_hosts         the guest's SSH host key, recorded at first contact
//   Images/<name>/EFIVariableStore    a Linux image's boot firmware variables, in place of the
//                                     three files above it that are a Mac's
//   Images/<name>/console.log         what a Linux guest printed on its console at its last boot
//   Images/<name>/recipe.json         the recipe applied to the image, when it was one
//   Images/<name>/Recipes/<n>-<name>/ each recipe that ran on the disk, in order: recipe.json
//                                     and the files it copies, as they were
//   Images/<name>/Update/             `image update` at work: copies of the disk and the
//                                     auxiliary storage, then the new record
//   Images/<name>/Update.commit/      that folder once the update succeeded, until its files
//                                     have taken the image's files' place
//   Images/<name>.rebuild/            `image rebuild` at work: the image being built again,
//                                     an image like any other until it takes <name>'s place
//
// Creating the folder with mkdir is the atomic claim on a name; the lock keeps `delete` away
// from an image that is being built. `image update` works on a copy for minutes and holds
// `.lock` only while it makes the copy and while it puts it in place, so boxes can be made
// from the image meanwhile; `.update.lock` is what it holds throughout.

import Darwin
import Foundation

public struct ImageStore: Sendable {
    static let recordName = "image.json"
    static let lockName = ".lock"
    static let updateLockName = ".update.lock"
    static let linuxMachineLockName = ".linux-vm.lock"
    static let diskName = "Disk.img"
    static let auxiliaryStorageName = "AuxiliaryStorage"
    static let hardwareModelName = "HardwareModel"
    static let machineIdentifierName = "MachineIdentifier"
    static let efiVariableStoreName = "EFIVariableStore"
    static let consoleLogName = "console.log"
    static let passwordName = "Password"
    static let knownHostsName = "known_hosts"
    static let recipeName = "recipe.json"
    static let recipesName = "Recipes"
    static let updateName = "Update"
    static let updateCommitName = "Update.commit"

    public let root: URL
    /// The Keychain items of account passwords; a test names its own service.
    public var passwords = AccountPasswordStore()

    public init(root: URL) {
        self.root = FileSystem.canonicalRoot(root)
    }

    public var imagesDirectory: URL {
        return root.appendingPathComponent("Images", isDirectory: true)
    }

    /// Lower-case letters, digits, ".", "_" and "-", starting with a letter or digit; at most 63.
    public static func isValidName(_ name: String) -> Bool {
        return name.range(of: #"^[a-z0-9][a-z0-9._-]{0,62}$"#, options: .regularExpression) != nil
    }

    /// Holds an image's lock until released or deallocated.
    public typealias Lock = FolderLock

    /// Claims `name` for a new image and writes its first record. The returned lock must be
    /// held for as long as the image is being built.
    public func create(_ record: ImageRecord) throws -> (GoldenImage, Lock) {
        guard Self.isValidName(record.name) else {
            throw AgentVMError.invalidImageName(record.name)
        }
        try StoreRoot.prepare(root)
        try FileSystem.makeDirectories(imagesDirectory.path)
        let directory = imagesDirectory.appendingPathComponent(record.name, isDirectory: true)
        if mkdir(directory.path, 0o700) != 0 {
            let code = errno
            if code == EEXIST {
                let state = (try? image(named: record.name))?.record.state.rawValue ?? "unreadable"
                throw AgentVMError.imageExists(name: record.name, state: state)
            }
            throw AgentVMError.system(operation: "create \(directory.path)", code: code)
        }
        let image = GoldenImage(record: record, directory: directory)
        guard let lock = try tryLock(image) else {
            throw AgentVMError.imageBusy(record.name)
        }
        try save(image)
        return (image, lock)
    }

    /// Takes the lock of an existing image; nil when another process holds it.
    public func tryLock(_ image: GoldenImage) throws -> Lock? {
        return try FolderLock.tryAcquire(image.directory.appendingPathComponent(Self.lockName).path)
    }

    /// Takes an image's update lock, for a command that changes a ready image; nil when
    /// another one is at it.
    public func tryLockForChange(_ image: GoldenImage) throws -> Lock? {
        // With patience: `isBeingChanged` (a list, a status poll) holds it for a moment to test it.
        return try FolderLock.tryAcquire(image.directory.appendingPathComponent(Self.updateLockName).path, patience: FolderLock.testPatience)
    }

    /// Whether a command is changing the image now (it holds the update lock).
    public func isBeingChanged(_ image: GoldenImage) -> Bool {
        return FolderLock.isHeld(image.directory.appendingPathComponent(Self.updateLockName).path)
    }

    /// Marks that a Linux guest of `image` runs (a build, an update, a rebuild), for as long as
    /// the returned lock is held: `status` and `doctor` then know that this virtual machine is
    /// no macOS guest. Nil when the mark cannot be taken, which costs only that.
    func markLinuxMachine(of image: GoldenImage) -> Lock? {
        // With patience: `runsLinuxMachine` (a status poll) holds it for a moment to test it.
        return try? FolderLock.tryAcquire(image.directory.appendingPathComponent(Self.linuxMachineLockName).path, patience: FolderLock.testPatience)
    }

    /// Whether a command runs a Linux guest of the image now.
    public func runsLinuxMachine(_ image: GoldenImage) -> Bool {
        return FolderLock.isHeld(image.directory.appendingPathComponent(Self.linuxMachineLockName).path)
    }

    /// How many images of this store have a Linux guest running now.
    public func runningLinuxMachines() -> Int {
        let images = (try? list().images) ?? []
        return images.filter { runsLinuxMachine($0) }.count
    }

    public func image(named name: String) throws -> GoldenImage {
        guard Self.isValidName(name) else {
            throw AgentVMError.invalidImageName(name)
        }
        let directory = imagesDirectory.appendingPathComponent(name, isDirectory: true)
        let path = directory.appendingPathComponent(Self.recordName).path
        guard FileSystem.exists(directory.path) else {
            throw AgentVMError.imageNotFound(name)
        }
        let record: ImageRecord
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            record = try SessionStore.decoder.decode(ImageRecord.self, from: data)
        } catch {
            throw AgentVMError.corruptImageRecord(path: path, reason: error.localizedDescription)
        }
        guard record.name == name else {
            if let mark = BoxStore.RenameMark.read(in: directory), mark.to == name {
                throw AgentVMError.corruptImageRecord(path: path, reason: "renaming image \(mark.from) to \(mark.to) was interrupted; `agent-vm image rename \(mark.from) \(mark.to)` finishes it")
            }
            throw AgentVMError.corruptImageRecord(path: path, reason: "it names image \(record.name)")
        }
        if let problem = record.numbersProblem {
            throw AgentVMError.corruptImageRecord(path: path, reason: problem)
        }
        guard record.formatVersion <= ImageRecord.currentFormatVersion else {
            throw AgentVMError.corruptImageRecord(path: path, reason: "written by a newer agent-vm (format \(record.formatVersion))")
        }
        return GoldenImage(record: record, directory: directory)
    }

    /// Every image, sorted by name; unreadable ones are returned as problems.
    public func list() throws -> (images: [GoldenImage], problems: [String]) {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: imagesDirectory.path)
        } catch {
            if !FileSystem.exists(imagesDirectory.path) {
                return ([], [])
            }
            throw AgentVMError.system(operation: "list \(imagesDirectory.path)", code: FileSystem.posixCode(error))
        }
        var images: [GoldenImage] = []
        var problems: [String] = []
        for name in names.sorted() where Self.isValidName(name) {
            do {
                images.append(try image(named: name))
            } catch {
                problems.append("\(error)")
            }
        }
        return (images, problems)
    }

    /// Writes the record atomically; returns the image with the new record.
    @discardableResult
    public func update(_ image: GoldenImage, _ change: (inout ImageRecord) -> Void) throws -> GoldenImage {
        var record = image.record
        change(&record)
        let updated = GoldenImage(record: record, directory: image.directory)
        try save(updated)
        return updated
    }

    /// Makes an update final: writes the new record into the image's `Update/` folder, renames
    /// the folder to `Update.commit` (the one step that decides it), and moves its files into
    /// the image's place. The caller holds the image's lock.
    public func commitUpdate(_ image: GoldenImage, record: ImageRecord) throws {
        let staged = image.updateURL.appendingPathComponent(Self.recordName)
        do {
            try SessionStore.encoder.encode(record).write(to: staged, options: .atomic)
        } catch {
            throw AgentVMError.corruptImageRecord(path: staged.path, reason: "cannot write: \(error.localizedDescription)")
        }
        guard Darwin.rename(image.updateURL.path, image.updateCommitURL.path) == 0 else {
            throw AgentVMError.system(operation: "rename \(image.updateURL.path)", code: errno)
        }
        _ = try settle(image, updating: true)
    }

    /// Brings an image's folder to rest after `image update`, for whoever is about to use its
    /// disk (they hold its lock): a decided update (`Update.commit`) is finished, its disk,
    /// auxiliary storage (a Linux image: its firmware variables) and record moved into place in
    /// that order, so the record changes last; an undecided one (`Update`, left by an agent-vm
    /// that was killed) is deleted, and the image is as it was. An `Update` folder whose update is still running (its update
    /// lock is held) is left alone; `updating` is for that update itself, which holds the
    /// lock and clears what an earlier one left. Returns the image as it is now.
    @discardableResult
    public func settle(_ image: GoldenImage, updating: Bool = false) throws -> GoldenImage {
        let commit = image.updateCommitURL
        if FileSystem.exists(commit.path) {
            // Whichever of them the update made: a Mac's auxiliary storage or a Linux guest's
            // firmware variables.
            for name in [Self.diskName, Self.auxiliaryStorageName, Self.efiVariableStoreName, Self.recordName] {
                let source = commit.appendingPathComponent(name).path
                // Moved already by the run that was interrupted.
                guard FileSystem.exists(source) else {
                    continue
                }
                guard Darwin.rename(source, image.directory.appendingPathComponent(name).path) == 0 else {
                    throw AgentVMError.system(operation: "move \(source) into place", code: errno)
                }
            }
            try FileSystem.removeTree(commit.path)
        }
        if FileSystem.exists(image.updateURL.path), updating || !isBeingChanged(image) {
            try FileSystem.removeTree(image.updateURL.path)
        }
        return try self.image(named: image.name)
    }

    /// Deletes an image unless another process holds its lock (it is being built or run).
    public func delete(named name: String) throws {
        guard Self.isValidName(name) else {
            throw AgentVMError.invalidImageName(name)
        }
        let directory = imagesDirectory.appendingPathComponent(name, isDirectory: true)
        guard FileSystem.exists(directory.path) else {
            throw AgentVMError.imageNotFound(name)
        }
        // A folder without a readable record (an interrupted create) can still be deleted.
        let image = (try? self.image(named: name)) ?? GoldenImage(record: Self.placeholder(name), directory: directory)
        // Both: an update in progress holds only the second for most of its time.
        guard let lock = try tryLock(image), let changeLock = try tryLockForChange(image) else {
            throw AgentVMError.imageBusy(name)
        }
        defer {
            changeLock.release()
            lock.release()
        }
        try FileSystem.removeTree(directory.path)
        // The account password goes with the last image or box that names it.
        passwords.removeUnused(store: root)
    }

    // MARK: - Renaming

    public struct Renamed: Sendable {
        public var image: GoldenImage
        /// The boxes made from the image, whose records name it by its new name now.
        public var boxes: [String]
        /// The images built from it (`image create --from`), likewise.
        public var images: [String]
        /// How many folders' remembered choices (avm) named the image.
        public var rememberedFolders: Int
    }

    /// Gives an image another name: its folder and record, the records of the boxes made from
    /// it and of the images built from it, and avm's remembered choices. Boxes of it may be
    /// running: a box is a clone and only its record names the image. Refused while the image
    /// is being built, updated or cloned, while an image built from it is being built or changed, for a
    /// name that is taken, and while a job that has not ended was started for it.
    @discardableResult
    public func rename(_ old: String, to new: String) throws -> Renamed {
        guard Self.isValidName(old) else {
            throw AgentVMError.invalidImageName(old)
        }
        guard Self.isValidName(new) else {
            throw AgentVMError.invalidImageName(new)
        }
        guard old != new else {
            throw AgentVMError.cannotRename(what: "image \(old)", reason: "\(new) is the name it has")
        }
        // Box records are rewritten: the lock that guards them (see BoxStore.resize).
        guard let recordLock = try FolderLock.tryAcquire(AccountPasswordStore.lockPath(store: root), patience: AccountPasswordStore.lockPatience) else {
            throw AgentVMError.system(operation: "rename image \(old) while account passwords are moved into the Keychain", code: EBUSY)
        }
        defer { recordLock.release() }
        let oldDirectory = imagesDirectory.appendingPathComponent(old, isDirectory: true)
        let newDirectory = imagesDirectory.appendingPathComponent(new, isDirectory: true)
        let mark = BoxStore.RenameMark(from: old, to: new)
        let resuming = !FileSystem.exists(oldDirectory.path)
        if resuming {
            // The folder moved and the rest did not happen: finished below.
            guard BoxStore.RenameMark.read(in: newDirectory) == mark else {
                throw AgentVMError.imageNotFound(old)
            }
        } else if FileSystem.exists(newDirectory.path) {
            throw AgentVMError.imageExists(name: new, state: (try? image(named: new))?.record.state.rawValue ?? "unreadable")
        }
        let directory = resuming ? newDirectory : oldDirectory
        // Both, as for a delete: a build or a clone holds the first, an update the second.
        guard let lock = try FolderLock.tryAcquire(directory.appendingPathComponent(Self.lockName).path),
              let changeLock = try FolderLock.tryAcquire(directory.appendingPathComponent(Self.updateLockName).path, patience: FolderLock.testPatience) else {
            throw AgentVMError.imageBusy(resuming ? new : old)
        }
        defer {
            changeLock.release()
            lock.release()
        }
        if !resuming {
            // An update that was decided and not finished is finished first: its record
            // would otherwise replace the renamed one.
            _ = try settle(try image(named: old), updating: true)
            if let job = JobStore(root: root).unfinishedJob(for: "image:\(old)", naming: old, with: ["--from", "--image"]) {
                throw AgentVMError.cannotRename(what: "image \(old)", reason: "job \(job) names it and has not ended")
            }
            // A rebuild of it that is under way or waiting to take its place is found by the
            // image's name, and would be left behind as an image of its own.
            let rebuild = Self.rebuildName(for: old)
            if FileSystem.exists(imagesDirectory.appendingPathComponent(rebuild).path) {
                throw AgentVMError.cannotRename(what: "image \(old)", reason: "a rebuild of it (\(rebuild)) is under way or was left unfinished; `agent-vm image rebuild \(old)` finishes it, `agent-vm image delete \(rebuild)` drops it")
            }
        }
        // The images built from it name it in their records; a build or an update of one of
        // them writes its record from a copy read earlier, so none may be under way. Both
        // locks: a build (`image create --from`, a rebuild) holds the first while its recipes
        // run, an update the second.
        let dependents = try list().images.filter { $0.name != old && $0.name != new && $0.record.names(image: old) }
        var dependentLocks: [FolderLock] = []
        defer { dependentLocks.forEach { $0.release() } }
        for dependent in dependents {
            // With patience: a box being cloned from it holds the first for a moment.
            guard let built = try FolderLock.tryAcquire(dependent.directory.appendingPathComponent(Self.lockName).path, patience: FolderLock.testPatience) else {
                throw AgentVMError.cannotRename(what: "image \(old)", reason: "image \(dependent.name), which was built from it, is being built or used by another agent-vm process")
            }
            dependentLocks.append(built)
            guard let held = try tryLockForChange(dependent) else {
                throw AgentVMError.cannotRename(what: "image \(old)", reason: "image \(dependent.name), which was built from it, is being changed by another agent-vm process")
            }
            dependentLocks.append(held)
            // As for the image itself: an update of it that was decided and not finished
            // holds a record that names the old name, and would put it back later.
            if FileSystem.exists(dependent.updateCommitURL.path) {
                _ = try settle(dependent, updating: true)
            }
        }
        if !resuming {
            try mark.write(in: oldDirectory)
            guard renamex_np(oldDirectory.path, newDirectory.path, UInt32(RENAME_EXCL)) == 0 else {
                let code = errno
                BoxStore.RenameMark.remove(in: oldDirectory)
                if code == EEXIST {
                    throw AgentVMError.imageExists(name: new, state: "made meanwhile")
                }
                throw AgentVMError.system(operation: "rename \(oldDirectory.path) to \(newDirectory.path)", code: code)
            }
        }
        // From here every step may be taken again.
        let path = newDirectory.appendingPathComponent(Self.recordName).path
        var record: ImageRecord
        do {
            record = try SessionStore.decoder.decode(ImageRecord.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            throw AgentVMError.corruptImageRecord(path: path, reason: error.localizedDescription)
        }
        guard record.name == old || record.name == new else {
            throw AgentVMError.corruptImageRecord(path: path, reason: "it names image \(record.name)")
        }
        record.name = new
        let renamed = GoldenImage(record: record, directory: newDirectory)
        try save(renamed)
        var images: [String] = []
        for dependent in dependents {
            // Read again under its lock.
            let current = try image(named: dependent.name)
            try update(current) { $0.rename(image: old, to: new) }
            images.append(dependent.name)
        }
        let boxes = try BoxStore(root: root).repointImage(from: old, to: new)
        // Not worth failing for: avm's lists then start at the top for those folders.
        let folders = (try? ConnectChoices(store: root).rename(image: old, to: new)) ?? 0
        BoxStore.RenameMark.remove(in: newDirectory)
        return Renamed(image: renamed, boxes: boxes, images: images.sorted(), rememberedFolders: folders)
    }

    private func save(_ image: GoldenImage) throws {
        let path = image.directory.appendingPathComponent(Self.recordName)
        do {
            try SessionStore.encoder.encode(image.record).write(to: path, options: .atomic)
        } catch {
            throw AgentVMError.corruptImageRecord(path: path.path, reason: "cannot write: \(error.localizedDescription)")
        }
    }

    static func placeholder(_ name: String) -> ImageRecord {
        return ImageRecord(formatVersion: 1, name: name, state: .failed, failure: nil,
                           createdAt: Date(timeIntervalSince1970: 0), createdBy: "", macOSVersion: "", macOSBuild: "",
                           cpuCount: 0, memoryBytes: 0, diskBytes: 0, macAddress: "", userName: "")
    }
}
