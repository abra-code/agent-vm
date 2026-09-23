// Sources/AgentVMKit/Images/ImageStore.swift
//
// Golden images under the store root (`$AGENT_VM_HOME`, default
// `~/Library/Application Support/agent-vm`):
//
//   Images/<name>/image.json          the ImageRecord
//   Images/<name>/.lock               flock held by whoever builds or uses the image
//   Images/<name>/Disk.img            sparse raw disk
//   Images/<name>/AuxiliaryStorage    NVRAM and boot state (Apple format)
//   Images/<name>/HardwareModel       VZMacHardwareModel.dataRepresentation
//   Images/<name>/MachineIdentifier   VZMacMachineIdentifier.dataRepresentation
//   Images/<name>/Password            the guest account's password (0600)
//   Images/<name>/known_hosts         the guest's SSH host key, recorded at first contact
//
// Creating the folder with mkdir is the atomic claim on a name; the lock keeps `delete` away
// from an image that is being built.

import Darwin
import Foundation

public struct ImageStore: Sendable {
    static let recordName = "image.json"
    static let lockName = ".lock"
    static let diskName = "Disk.img"
    static let auxiliaryStorageName = "AuxiliaryStorage"
    static let hardwareModelName = "HardwareModel"
    static let machineIdentifierName = "MachineIdentifier"
    static let passwordName = "Password"
    static let knownHostsName = "known_hosts"

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
    public final class Lock: @unchecked Sendable {
        private var descriptor: Int32

        init(descriptor: Int32) {
            self.descriptor = descriptor
        }

        public func release() {
            if descriptor >= 0 {
                close(descriptor)
                descriptor = -1
            }
        }

        deinit {
            release()
        }
    }

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
        let path = image.directory.appendingPathComponent(Self.lockName).path
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw AgentVMError.system(operation: "open lock \(path)", code: errno)
        }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK {
                return nil
            }
            throw AgentVMError.system(operation: "lock \(path)", code: code)
        }
        return Lock(descriptor: descriptor)
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
        guard let lock = try tryLock(image) else {
            throw AgentVMError.imageBusy(name)
        }
        defer { lock.release() }
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
