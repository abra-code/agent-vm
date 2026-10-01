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
//   Images/<name>/Disk.img            sparse raw disk
//   Images/<name>/AuxiliaryStorage    NVRAM and boot state (Apple format)
//   Images/<name>/HardwareModel       VZMacHardwareModel.dataRepresentation
//   Images/<name>/MachineIdentifier   VZMacMachineIdentifier.dataRepresentation
//   Images/<name>/Password            the guest account's password (0600)
//   Images/<name>/known_hosts         the guest's SSH host key, recorded at first contact
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
    static let diskName = "Disk.img"
    static let auxiliaryStorageName = "AuxiliaryStorage"
    static let hardwareModelName = "HardwareModel"
    static let machineIdentifierName = "MachineIdentifier"
    static let passwordName = "Password"
    static let knownHostsName = "known_hosts"
    static let recipeName = "recipe.json"
    static let recipesName = "Recipes"
    static let updateName = "Update"
    static let updateCommitName = "Update.commit"

    public let root: URL

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
            throw AgentVMError.corruptImageRecord(path: path, reason: "it names image \(record.name)")
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
        guard rename(image.updateURL.path, image.updateCommitURL.path) == 0 else {
            throw AgentVMError.system(operation: "rename \(image.updateURL.path)", code: errno)
        }
        _ = try settle(image, updating: true)
    }

    /// Brings an image's folder to rest after `image update`, for whoever is about to use its
    /// disk (they hold its lock): a decided update (`Update.commit`) is finished, its disk,
    /// auxiliary storage and record moved into place in that order, so the record changes
    /// last; an undecided one (`Update`, left by an agent-vm that was killed) is deleted, and
    /// the image is as it was. An `Update` folder whose update is still running (its update
    /// lock is held) is left alone; `updating` is for that update itself, which holds the
    /// lock and clears what an earlier one left. Returns the image as it is now.
    @discardableResult
    public func settle(_ image: GoldenImage, updating: Bool = false) throws -> GoldenImage {
        let commit = image.updateCommitURL
        if FileSystem.exists(commit.path) {
            for name in [Self.diskName, Self.auxiliaryStorageName, Self.recordName] {
                let source = commit.appendingPathComponent(name).path
                // Moved already by the run that was interrupted.
                guard FileSystem.exists(source) else {
                    continue
                }
                guard rename(source, image.directory.appendingPathComponent(name).path) == 0 else {
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
        return ImageRecord(formatVersion: ImageRecord.currentFormatVersion, name: name, state: .failed, failure: nil,
                           createdAt: Date(timeIntervalSince1970: 0), createdBy: "", macOSVersion: "", macOSBuild: "",
                           cpuCount: 0, memoryBytes: 0, diskBytes: 0, macAddress: "", userName: "")
    }
}
