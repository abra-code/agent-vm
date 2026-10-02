// Sources/AgentVMKit/Host/AccountPasswordMove.swift
//
// `agent-vm store secure-passwords`: moves the account passwords that images and boxes keep in
// `Password` files (everything made before 0.6.0) into the login Keychain. An image, the
// images derived from it and their boxes hold the same password, so they end up naming one
// item: records are matched by the password's value.
//
// For each record, in this order: the record names the identifier (and takes the format that
// older versions refuse), the item is added unless it is there, the item is read back and
// compared, and only then the file is removed. A kill at any point leaves a record whose
// password can still be read (`AccountPassword.read` falls back to a file that is still
// there), and running the command again finishes the job.

import Darwin
import Foundation

public enum AccountPasswordMove {
    public struct Skipped: Codable, Equatable, Sendable {
        /// "image dev" or "box b1".
        public var name: String
        public var reason: String
    }

    public struct Result: Codable, Equatable, Sendable {
        /// What now keeps its password in the Keychain, as "image dev" or "box b1".
        public var moved: [String] = []
        /// What still has a file, and why.
        public var skipped: [Skipped] = []
        /// Keychain items made (one per distinct password).
        public var items = 0
        /// What could not be moved because something went wrong, with the error. Its file, if
        /// it had one, is still there.
        public var failed: [Skipped] = []
    }

    /// Moves every file-stored password of the store. `except`: images to leave alone, with
    /// their boxes (a test image, which an ad hoc build must be able to read without a
    /// question). An image or box in use (being built, updated, running) is skipped and named.
    public static func run(images: ImageStore, boxes: BoxStore, except: Set<String> = [],
                           lockPatience: Duration = AccountPasswordStore.lockPatience) throws -> Result {
        let passwords = images.passwords
        var result = Result()
        // Nothing to move: no lock is taken and no item is read.
        guard FileSystem.exists(images.root.path), fileCount(store: images.root) != 0 else {
            return result
        }
        let allImages = try images.list().images
        // A mistyped name would move the very image that was to be left alone. An image that
        // is gone can still be named for its boxes.
        let boxImages = Set(try boxes.list().boxes.map(\.record.image))
        for name in except.sorted() where !boxImages.contains(name) {
            guard ImageStore.isValidName(name), FileSystem.exists(images.imagesDirectory.appendingPathComponent(name).path) else {
                throw AgentVMError.imageNotFound(name)
            }
        }
        // One move at a time (two would give one lineage two items), and none while another
        // agent-vm removes unused items: a record that joins an item here names it only now,
        // and that sweep could have listed the item before, and remove it after the file went.
        guard let storeLock = try FolderLock.tryAcquire(AccountPasswordStore.lockPath(store: images.root), patience: lockPatience) else {
            throw AgentVMError.keychain(operation: "move account passwords into the Keychain", message: "another agent-vm is moving them, or removing unused ones; try again in a moment")
        }
        defer { storeLock.release() }
        // The items this store has already, by their value: a second run, or a box whose image
        // was moved earlier, joins the item that is there.
        var known: [String: String] = [:]
        for id in (AccountPasswordStore.identifiersInUse(store: images.root) ?? []).sorted() {
            if let value = try? passwords.read(id: id, owner: "the store") {
                known[value] = id
            }
        }

        /// One record's move. `write` puts the identifier into the record; `named` reads the
        /// record's identifier again.
        func move(_ owner: String, label: String, current: String?, file: URL, write: (String) throws -> Void, named: () -> String?) throws {
            guard let text = try? String(contentsOf: file, encoding: .utf8), !text.isEmpty else {
                result.skipped.append(Skipped(name: owner, reason: "its Password file is empty or cannot be read"))
                return
            }
            let id = current ?? known[text] ?? UUID().uuidString.lowercased()
            if current == nil {
                try write(id)
            }
            if !passwords.contains(id) {
                try passwords.add(id: id, password: text, label: label, store: images.root)
                result.items += 1
            }
            // The file goes only once the Keychain gives the same password back.
            guard (try? passwords.read(id: id, owner: owner)) == text else {
                result.skipped.append(Skipped(name: owner, reason: "the Keychain did not give back what was stored; its Password file is kept"))
                return
            }
            // A command that changes a box's record takes no lock for some changes (its network
            // rules): one that read the record before the identifier was written writes it
            // back without.
            guard named() == id else {
                result.skipped.append(Skipped(name: owner, reason: "its record was changed meanwhile; its Password file is kept, run the command again"))
                return
            }
            guard unlink(file.path) == 0 || errno == ENOENT else {
                throw AgentVMError.system(operation: "remove \(file.path)", code: errno)
            }
            known[text] = id
            result.moved.append(owner)
        }

        func moveImage(_ listed: GoldenImage, owner: String) throws {
            guard !except.contains(listed.name) else {
                result.skipped.append(Skipped(name: owner, reason: "left out (--except)"))
                return
            }
            guard let lock = try images.tryLock(listed) else {
                result.skipped.append(Skipped(name: owner, reason: "it is in use (being built, or a box is being made from it)"))
                return
            }
            defer { lock.release() }
            guard let changeLock = try images.tryLockForChange(listed) else {
                result.skipped.append(Skipped(name: owner, reason: "it is being updated or set up"))
                return
            }
            defer { changeLock.release() }
            // Read again under its locks, and an update that a kill left decided (`Update.commit`)
            // finished first: its record, written before this move, would otherwise take this
            // one's place later, and name no item when the file is gone.
            let image = try images.settle(listed, updating: true)
            try move(owner, label: "agent-vm account password (\(image.name))", current: image.record.passwordID, file: image.passwordURL, write: { id in
                _ = try images.update(image) { record in
                    record.passwordID = id
                    record.formatVersion = ImageRecord.formatVersion(passwordID: id)
                }
            }, named: { (try? images.image(named: image.name))?.record.passwordID })
        }

        func moveBox(_ listed: Box, owner: String) throws {
            guard !except.contains(listed.record.image) else {
                result.skipped.append(Skipped(name: owner, reason: "left out (--except \(listed.record.image))"))
                return
            }
            // A running box's supervisor may be an older agent-vm, which reads the file.
            guard let lock = try FolderLock.tryAcquire(listed.lockPath) else {
                result.skipped.append(Skipped(name: owner, reason: "it is running; run the command again once it has stopped"))
                return
            }
            defer { lock.release() }
            let box = try boxes.box(named: listed.name)
            try move(owner, label: "agent-vm account password (\(box.record.image))", current: box.record.passwordID, file: box.passwordURL, write: { id in
                try boxes.setPasswordID(id, of: box)
            }, named: { (try? boxes.box(named: box.name))?.record.passwordID })
        }

        // One record's failure (it was deleted meanwhile, its folder cannot be written) is
        // reported with the rest and does not stop the others.
        func each(_ owner: String, _ body: () throws -> Void) {
            do {
                try body()
            } catch {
                result.failed.append(Skipped(name: owner, reason: "\(error)"))
            }
        }

        for listed in allImages {
            let owner = "image \(listed.name)"
            guard FileSystem.exists(listed.passwordURL.path) else {
                continue
            }
            each(owner) { try moveImage(listed, owner: owner) }
        }
        for listed in try boxes.list().boxes {
            let owner = "box \(listed.name)"
            guard FileSystem.exists(listed.passwordURL.path) else {
                continue
            }
            each(owner) { try moveBox(listed, owner: owner) }
        }
        return result
    }

    /// How many images and boxes of the store keep their password in a file; nil when the
    /// store cannot be listed. For doctor.
    public static func fileCount(store root: URL) -> Int? {
        var count = 0
        for folder in ["Images", "Boxes"] {
            let directory = root.appendingPathComponent(folder, isDirectory: true)
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            } catch {
                guard !FileSystem.exists(directory.path) else {
                    return nil
                }
                continue
            }
            for name in names where FileSystem.exists(directory.appendingPathComponent(name).appendingPathComponent(ImageStore.passwordName).path) {
                count += 1
            }
        }
        return count
    }
}
