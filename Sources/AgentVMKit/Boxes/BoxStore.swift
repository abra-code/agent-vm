// Sources/AgentVMKit/Boxes/BoxStore.swift
//
// Boxes: copy-on-write clones of a ready golden image, one folder each under the store root:
//
//   Boxes/<name>/box.json            the BoxRecord
//   Boxes/<name>/.lock               held by the box's supervisor while it runs
//   Boxes/<name>/control.sock        the supervisor's control socket (0600) while it runs
//   Boxes/<name>/supervisor.log      the supervisor's output
//   Boxes/<name>/Disk.img            APFS clone of the image's disk
//   Boxes/<name>/AuxiliaryStorage    APFS clone of the image's auxiliary storage
//   Boxes/<name>/HardwareModel       copy of the image's
//   Boxes/<name>/MachineIdentifier   the box's own
//   Boxes/<name>/Password            copy of the image's (the account is the same)
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

    public let root: URL

    public init(root: URL) {
        self.root = FileSystem.canonicalRoot(root)
    }

    public var boxesDirectory: URL {
        return root.appendingPathComponent("Boxes", isDirectory: true)
    }

    /// Clones a ready image into a new box. The image's lock is held while cloning, so the
    /// image cannot be deleted or rebuilt halfway.
    public func create(name: String, from image: GoldenImage, imageStore: ImageStore,
                       cpuCount: Int? = nil, memoryBytes: UInt64? = nil) throws -> Box {
        guard ImageStore.isValidName(name) else {
            throw AgentVMError.invalidImageName(name)
        }
        guard image.record.state == .ready else {
            throw AgentVMError.wrongImageState(name: image.name, state: image.record.state.rawValue, operation: "create a box from")
        }
        guard let imageLock = try imageStore.tryLock(image) else {
            throw AgentVMError.imageBusy(image.name)
        }
        defer { imageLock.release() }

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
            formatVersion: BoxRecord.currentFormatVersion, name: name, image: image.name,
            macOSVersion: image.record.macOSVersion, macOSBuild: image.record.macOSBuild,
            // Whole seconds: the record is stored with ISO 8601 dates, which drop fractions.
            guestProtocol: image.record.guestProtocol, createdAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)),
            cpuCount: cpuCount ?? image.record.cpuCount, memoryBytes: memoryBytes ?? image.record.memoryBytes,
            macAddress: VZMACAddress.randomLocallyAdministered().string, userName: image.record.userName)
        let box = Box(record: record, directory: directory)
        do {
            try Self.cloneFile(image.diskURL, to: box.diskURL)
            try Self.cloneFile(image.auxiliaryStorageURL, to: box.auxiliaryStorageURL)
            try Self.cloneFile(image.hardwareModelURL, to: box.hardwareModelURL)
            try Self.cloneFile(image.passwordURL, to: box.passwordURL)
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
            throw AgentVMError.invalidImageName(name)
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
            throw AgentVMError.corruptImageRecord(path: path, reason: error.localizedDescription)
        }
        guard record.name == name else {
            throw AgentVMError.corruptImageRecord(path: path, reason: "it names box \(record.name)")
        }
        guard record.formatVersion <= BoxRecord.currentFormatVersion else {
            throw AgentVMError.corruptImageRecord(path: path, reason: "written by a newer agent-vm (format \(record.formatVersion))")
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

    /// Deletes a box and its disk; refused while its supervisor runs.
    public func delete(named name: String) throws {
        guard ImageStore.isValidName(name) else {
            throw AgentVMError.invalidImageName(name)
        }
        let directory = boxesDirectory.appendingPathComponent(name, isDirectory: true)
        guard FileSystem.exists(directory.path) else {
            throw AgentVMError.boxNotFound(name)
        }
        guard let lock = try FolderLock.tryAcquire(directory.appendingPathComponent(Self.lockName).path) else {
            throw AgentVMError.boxRunning(name)
        }
        defer { lock.release() }
        try FileSystem.removeTree(directory.path)
    }

    private func save(_ box: Box) throws {
        let path = box.directory.appendingPathComponent(Self.recordName)
        do {
            try SessionStore.encoder.encode(box.record).write(to: path, options: .atomic)
        } catch {
            throw AgentVMError.corruptImageRecord(path: path.path, reason: "cannot write: \(error.localizedDescription)")
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
