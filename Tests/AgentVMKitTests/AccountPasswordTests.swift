// Tests/AgentVMKitTests/AccountPasswordTests.swift
//
// Account passwords named by their records: shared by an image and what is made from it,
// read through one accessor, removed with the last record that names them. The items are kept
// in memory here (a test process that stored Keychain items would make macOS ask the next
// build about them); one test, off unless AGENT_VM_TEST_KEYCHAIN=1, runs the same calls
// against the login Keychain.

import Darwin
import Foundation
import Testing
@testable import AgentVMKit

@Suite struct AccountPasswordTests {
    static let id = "0b1c2d3e-0000-4000-8000-000000000001"

    /// A store whose image `dev` keeps its password as an item.
    func fixture() throws -> (BoxScratch, AccountPasswordStore) {
        let fixture = try BoxScratch()
        let passwords = AccountPasswordStore(memory: AccountPasswordStore.Memory())
        fixture.images.passwords = passwords
        fixture.boxes.passwords = passwords
        try FileManager.default.removeItem(at: fixture.image.passwordURL)
        fixture.image = try fixture.images.update(fixture.image) { $0.passwordID = Self.id }
        try passwords.add(id: Self.id, password: "s3cret", label: "agent-vm account password (dev)", store: fixture.images.root)
        return (fixture, passwords)
    }

    @Test func aBoxSharesItsImagesItemAndHasNoFile() throws {
        let (fixture, passwords) = try fixture()
        let box = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images)
        #expect(box.record.passwordID == Self.id)
        #expect(box.passwordStorage == .keychain)
        #expect(!FileSystem.exists(box.passwordURL.path))
        #expect(try box.accountPassword(keychain: passwords) == "s3cret")
        #expect(try fixture.image.accountPassword(keychain: passwords) == "s3cret")
        #expect(try fixture.boxes.box(named: "b1").record.passwordID == Self.id)
        // A record that names an item is in the format an older agent-vm refuses: it would
        // look for a file, and drop the identifier when it rewrote the record.
        #expect(box.record.formatVersion == 2)
        #expect(ImageRecord.formatVersion(passwordID: Self.id) == 2 && ImageRecord.formatVersion(passwordID: nil) == 1)
    }

    /// Building from an image, or updating its macOS, needs the password minutes in: a missing
    /// one is found before anything is cloned or booted, without reading it.
    @Test func aMissingPasswordIsFoundBeforeTheWorkStarts() throws {
        let (fixture, passwords) = try fixture()
        try fixture.image.requireAccountPassword(keychain: passwords)
        try passwords.delete(id: Self.id)
        #expect(throws: AgentVMError.self) { try fixture.image.requireAccountPassword(keychain: passwords) }
        let filed = try BoxScratch()
        try filed.image.requireAccountPassword(keychain: passwords)
        try FileManager.default.removeItem(at: filed.image.passwordURL)
        #expect(throws: AgentVMError.self) { try filed.image.requireAccountPassword(keychain: passwords) }
    }

    @Test func aRecordWithoutAnIdentifierKeepsItsFile() throws {
        let fixture = try BoxScratch()
        let passwords = AccountPasswordStore(memory: AccountPasswordStore.Memory())
        let box = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images)
        #expect(box.record.passwordID == nil)
        #expect(box.passwordStorage == .file)
        #expect(box.record.formatVersion == 1)
        #expect(try box.accountPassword(keychain: passwords) == "secret")
        try FileManager.default.removeItem(at: box.passwordURL)
        do {
            _ = try box.accountPassword(keychain: passwords)
            Issue.record("a missing Password file gave a password")
        } catch {
            #expect("\(error)".contains("box b1 (image dev)") && "\(error)".contains("image rebuild"), "\(error)")
        }
    }

    @Test func theItemGoesWithTheLastRecordThatNamesIt() throws {
        let (fixture, passwords) = try fixture()
        _ = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images)
        _ = try fixture.boxes.create(name: "b2", from: fixture.image, imageStore: fixture.images)
        // Another store's item, and one of this store that nothing names.
        let other = fixture.scratch.root.appendingPathComponent("other-store")
        try passwords.add(id: "other", password: "x", label: "", store: other)
        try passwords.add(id: "leftover", password: "x", label: "", store: fixture.images.root)

        try fixture.boxes.delete(named: "b1")
        #expect(passwords.contains(Self.id))
        #expect(!passwords.contains("leftover"))
        #expect(passwords.contains("other"))
        // A box outlives its image, and so does the password.
        try fixture.images.delete(named: "dev")
        #expect(passwords.contains(Self.id))
        #expect(try fixture.boxes.box(named: "b2").accountPassword(keychain: passwords) == "s3cret")
        try fixture.boxes.delete(named: "b2")
        #expect(!passwords.contains(Self.id))
        #expect(passwords.contains("other"))
    }

    @Test func aRebuiltImagesOldItemStaysForTheBoxesMadeBefore() throws {
        let (fixture, passwords) = try fixture()
        _ = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images)
        // A rebuild from a restore file: built beside the image, with a password of its own.
        var record = ImageStoreTests.record("dev.rebuild", state: .ready)
        record.createdAt = fixture.image.record.createdAt.addingTimeInterval(60)
        record.passwordID = "rebuilt"
        let (built, lock) = try fixture.images.create(record)
        lock.release()
        try passwords.add(id: "rebuilt", password: "n3w", label: "", store: fixture.images.root)
        try fixture.images.markRebuilt(built, of: "dev")

        let now = try fixture.images.replace(fixture.image, with: built)
        #expect(try now.accountPassword(keychain: passwords) == "n3w")
        #expect(try fixture.boxes.box(named: "b1").accountPassword(keychain: passwords) == "s3cret")
        try fixture.boxes.delete(named: "b1")
        #expect(!passwords.contains(Self.id))
        #expect(passwords.contains("rebuilt"))
    }

    @Test func nothingIsRemovedWhileARecordCannotBeRead() throws {
        let (fixture, passwords) = try fixture()
        let box = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images)
        try passwords.add(id: "leftover", password: "x", label: "", store: fixture.images.root)
        try Data("{ not a record".utf8).write(to: box.directory.appendingPathComponent(BoxStore.recordName))
        #expect(passwords.removeUnused(store: fixture.images.root).isEmpty)
        #expect(passwords.contains("leftover"))
        // An image being updated has a second record; both are read.
        try FileManager.default.removeItem(at: box.directory.appendingPathComponent(BoxStore.recordName))
        let staged = fixture.image.directory.appendingPathComponent("Update", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("{\"passwordID\": \"leftover\"}".utf8).write(to: staged.appendingPathComponent(ImageStore.recordName))
        #expect(passwords.removeUnused(store: fixture.images.root).isEmpty)
        try FileManager.default.removeItem(at: staged)
        #expect(passwords.removeUnused(store: fixture.images.root) == ["leftover"])
        #expect(passwords.contains(Self.id))
    }

    @Test func aMissingItemSaysWhatStillWorksAndTheWayOut() throws {
        let (fixture, passwords) = try fixture()
        try passwords.delete(id: Self.id)
        do {
            _ = try fixture.image.accountPassword(keychain: passwords)
            Issue.record("a missing item gave a password")
        } catch let error as AgentVMError {
            #expect(error == .accountPasswordMissing(owner: "image dev", reason: "it is not in this Mac's login Keychain; a store copied from another Mac or restored from a backup comes without it"))
            #expect(error.description.contains("still start") && error.description.contains("agent-vm image rebuild <image> --ipsw latest")
                && error.description.contains("agent-vm box recreate"))
        }
    }

    @Test func nothingIsRemovedWhileAFolderCannotBeRead() throws {
        let (fixture, passwords) = try fixture()
        let box = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images)
        try fixture.images.delete(named: "dev")
        try passwords.add(id: "leftover", password: "x", label: "", store: fixture.images.root)
        // A plain file among the folders is no record, and stops nothing.
        try Data("x".utf8).write(to: fixture.images.imagesDirectory.appendingPathComponent(".DS_Store"))
        defer {
            chmod(box.directory.path, 0o700)
            chmod(fixture.boxes.boxesDirectory.path, 0o700)
        }
        // The box's record is there and cannot be read: the box may be what names an item.
        chmod(box.directory.path, 0)
        #expect(passwords.removeUnused(store: fixture.images.root).isEmpty)
        chmod(box.directory.path, 0o700)
        // Nor can the boxes be listed.
        chmod(fixture.boxes.boxesDirectory.path, 0)
        #expect(passwords.removeUnused(store: fixture.images.root).isEmpty)
        #expect(passwords.contains(Self.id) && passwords.contains("leftover"))
        chmod(fixture.boxes.boxesDirectory.path, 0o700)
        #expect(passwords.removeUnused(store: fixture.images.root) == ["leftover"])
        #expect(passwords.contains(Self.id))
    }

    @Test func askpassReadsTheItemItIsGiven() throws {
        let (_, passwords) = try fixture()
        let prompt = ["agent-vm", "(agent@192.168.64.9) Password:"]
        #expect(GuestSSH.askpassAnswer(arguments: prompt, environment: [GuestSSH.askpassItemVariable: Self.id], keychain: passwords) == .password("s3cret"))
        #expect(GuestSSH.askpassAnswer(arguments: prompt, environment: [GuestSSH.askpassItemVariable: "no-such-item"], keychain: passwords) == .refuse)
        #expect(GuestSSH.askpassAnswer(arguments: ["agent-vm", "Are you sure (yes/no)?"], environment: [GuestSSH.askpassItemVariable: Self.id], keychain: passwords) == .refuse)
        #expect(GuestSSH.askpassAnswer(arguments: ["agent-vm", "image", "list"], environment: [:], keychain: passwords) == .notAskpass)
    }

    // MARK: - moving what was made before

    /// A store as 0.5 left it: `dev` with a box, `tools` derived from it (the same password),
    /// and `other`, installed on its own.
    func oldStore() throws -> (BoxScratch, AccountPasswordStore) {
        let fixture = try BoxScratch()
        let passwords = AccountPasswordStore(memory: AccountPasswordStore.Memory())
        fixture.images.passwords = passwords
        fixture.boxes.passwords = passwords
        for (name, password) in [("tools", "secret"), ("other", "another")] {
            let (image, lock) = try fixture.images.create(ImageStoreTests.record(name, state: .ready))
            lock.release()
            try ImageBuilder.writePassword(password, to: image.passwordURL)
        }
        _ = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images)
        return (fixture, passwords)
    }

    @Test func aLineageEndsUpNamingOneItem() throws {
        let (fixture, passwords) = try oldStore()
        #expect(AccountPasswordMove.fileCount(store: fixture.images.root) == 4)
        let result = try AccountPasswordMove.run(images: fixture.images, boxes: fixture.boxes)
        #expect(result.moved == ["image dev", "image other", "image tools", "box b1"])
        #expect(result.skipped.isEmpty)
        #expect(result.items == 2)
        #expect(AccountPasswordMove.fileCount(store: fixture.images.root) == 0)

        let dev = try fixture.images.image(named: "dev")
        let id = try #require(dev.record.passwordID)
        #expect(dev.record.formatVersion == 2)
        #expect(try fixture.images.image(named: "tools").record.passwordID == id)
        let box = try fixture.boxes.box(named: "b1")
        #expect(box.record.passwordID == id && box.record.formatVersion == 2)
        #expect(try box.accountPassword(keychain: passwords) == "secret")
        let other = try fixture.images.image(named: "other")
        #expect(other.record.passwordID != id)
        #expect(try other.accountPassword(keychain: passwords) == "another")
        // Nothing left to do, and nothing the sweep would take for a leftover.
        #expect(try AccountPasswordMove.run(images: fixture.images, boxes: fixture.boxes) == AccountPasswordMove.Result())
        #expect(passwords.removeUnused(store: fixture.images.root).isEmpty)
    }

    @Test func whatIsInUseOrLeftOutKeepsItsFileAndJoinsLater() throws {
        let (fixture, passwords) = try oldStore()
        // A running box: its supervisor holds the lock.
        let box = try fixture.boxes.box(named: "b1")
        let running = try #require(try FolderLock.tryAcquire(box.lockPath))
        var result = try AccountPasswordMove.run(images: fixture.images, boxes: fixture.boxes, except: ["other"])
        #expect(result.moved == ["image dev", "image tools"])
        #expect(result.skipped.map(\.name) == ["image other", "box b1"])
        #expect(result.skipped.last?.reason.contains("running") == true)
        #expect(result.items == 1)
        #expect(try String(contentsOf: box.passwordURL, encoding: .utf8) == "secret")
        #expect(try fixture.boxes.box(named: "b1").record.passwordID == nil)
        #expect(try fixture.images.image(named: "other").record.passwordID == nil)

        running.release()
        result = try AccountPasswordMove.run(images: fixture.images, boxes: fixture.boxes, except: ["other"])
        #expect(result.moved == ["box b1"])
        #expect(result.items == 0)
        #expect(try fixture.boxes.box(named: "b1").record.passwordID == fixture.images.image(named: "dev").record.passwordID)
        #expect(try fixture.boxes.box(named: "b1").accountPassword(keychain: passwords) == "secret")
        #expect(AccountPasswordMove.fileCount(store: fixture.images.root) == 1)
    }

    /// Killed after the record was written and before the item was added: the password is
    /// still read, from the file, and the next run finishes the move.
    @Test func aMoveKilledHalfwayLosesNothing() throws {
        let (fixture, passwords) = try oldStore()
        let half = try fixture.images.update(try fixture.images.image(named: "other")) { record in
            record.passwordID = "0b1c2d3e-0000-4000-8000-0000000000ff"
            record.formatVersion = 2
        }
        #expect(!passwords.contains("0b1c2d3e-0000-4000-8000-0000000000ff"))
        #expect(try half.accountPassword(keychain: passwords) == "another")
        try half.requireAccountPassword(keychain: passwords)
        #expect(passwords.removeUnused(store: fixture.images.root).isEmpty)

        let result = try AccountPasswordMove.run(images: fixture.images, boxes: fixture.boxes)
        #expect(result.moved.contains("image other"))
        #expect(!FileSystem.exists(half.passwordURL.path))
        #expect(try passwords.read(id: "0b1c2d3e-0000-4000-8000-0000000000ff", owner: "image other") == "another")
    }

    /// An update that was killed once it was decided left its record, written before the
    /// move, in `Update.commit`: it is put in place first, not over the record the move wrote.
    @Test func anUpdateLeftDecidedIsFinishedBeforeItsImageIsMoved() throws {
        let (fixture, passwords) = try oldStore()
        let dev = try fixture.images.image(named: "dev")
        try FileSystem.makeDirectories(dev.updateCommitURL.path)
        var updated = dev.record
        updated.revision = 7
        try SessionStore.encoder.encode(updated).write(to: dev.updateCommitURL.appendingPathComponent(ImageStore.recordName))

        let result = try AccountPasswordMove.run(images: fixture.images, boxes: fixture.boxes)
        #expect(result.moved.contains("image dev"))
        #expect(!FileSystem.exists(dev.updateCommitURL.path))
        // What every later command on the image does first.
        let settled = try fixture.images.settle(dev)
        #expect(settled.record.revision == 7)
        #expect(settled.record.passwordID != nil && settled.record.formatVersion == 2)
        #expect(try settled.accountPassword(keychain: passwords) == "secret")
    }

    @Test func aNameLeftOutMustBeAnImage() throws {
        let (fixture, _) = try oldStore()
        #expect(throws: AgentVMError.imageNotFound("dve")) {
            try AccountPasswordMove.run(images: fixture.images, boxes: fixture.boxes, except: ["dve"])
        }
        #expect(AccountPasswordMove.fileCount(store: fixture.images.root) == 4)
        #expect(try fixture.images.image(named: "dev").record.passwordID == nil)
        // An image that is gone is named for the boxes made from it.
        try fixture.images.delete(named: "dev")
        let result = try AccountPasswordMove.run(images: fixture.images, boxes: fixture.boxes, except: ["dev"])
        #expect(result.skipped.map(\.name) == ["box b1"])
        #expect(try fixture.boxes.box(named: "b1").record.passwordID == nil)
    }

    /// A record that names an item and still has a file with another password: the item is
    /// what is read, and the file stays.
    @Test func aFileThatDiffersFromItsItemIsKept() throws {
        let (fixture, passwords) = try oldStore()
        try passwords.add(id: Self.id, password: "s3cret", label: "x", store: fixture.images.root)
        let other = try fixture.images.update(try fixture.images.image(named: "other")) { record in
            record.passwordID = Self.id
            record.formatVersion = 2
        }
        #expect(try other.accountPassword(keychain: passwords) == "s3cret")
        let result = try AccountPasswordMove.run(images: fixture.images, boxes: fixture.boxes)
        #expect(result.skipped.map(\.name) == ["image other"])
        #expect(try String(contentsOf: other.passwordURL, encoding: .utf8) == "another")
        #expect(try passwords.read(id: Self.id, owner: "image other") == "s3cret")
    }

    /// The sweep of unused items and a move never run at once (a record that joins an item
    /// names it only during the move), and neither do two moves.
    @Test func aMoveKeepsTheSweepAndASecondMoveOut() throws {
        let (fixture, passwords) = try oldStore()
        try passwords.add(id: Self.id, password: "unused", label: "x", store: fixture.images.root)
        let moving = try #require(try FolderLock.tryAcquire(AccountPasswordStore.lockPath(store: fixture.images.root)))
        #expect(passwords.removeUnused(store: fixture.images.root, lockPatience: .milliseconds(50)).isEmpty)
        #expect(passwords.contains(Self.id))
        #expect(throws: AgentVMError.self) {
            try AccountPasswordMove.run(images: fixture.images, boxes: fixture.boxes, lockPatience: .milliseconds(50))
        }
        #expect(AccountPasswordMove.fileCount(store: fixture.images.root) == 4)
        moving.release()
        #expect(passwords.removeUnused(store: fixture.images.root) == [Self.id])
        #expect(try AccountPasswordMove.run(images: fixture.images, boxes: fixture.boxes).moved.count == 4)
    }

    /// One record that cannot be written is reported with its error, and the others are moved.
    @Test func aRecordThatFailsDoesNotStopTheOthers() throws {
        let (fixture, passwords) = try oldStore()
        let box = try fixture.boxes.box(named: "b1")
        chmod(box.directory.path, 0o500)
        defer { chmod(box.directory.path, 0o700) }
        let result = try AccountPasswordMove.run(images: fixture.images, boxes: fixture.boxes)
        #expect(result.moved == ["image dev", "image other", "image tools"])
        #expect(result.failed.map(\.name) == ["box b1"])
        #expect(try String(contentsOf: box.passwordURL, encoding: .utf8) == "secret")
        #expect(try fixture.boxes.box(named: "b1").accountPassword(keychain: passwords) == "secret")
    }

    /// With no file left there is nothing to lock and no item to read.
    @Test func aStoreWithoutFilesIsLeftAlone() throws {
        let (fixture, _) = try fixture()
        #expect(try AccountPasswordMove.run(images: fixture.images, boxes: fixture.boxes) == AccountPasswordMove.Result())
        #expect(!FileSystem.exists(AccountPasswordStore.lockPath(store: fixture.images.root)))
    }

    /// The same calls against the login Keychain, under a service of its own. Off by default.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENT_VM_TEST_KEYCHAIN"] == "1"))
    func theLoginKeychainKeepsAndRemovesItems() throws {
        let scratch = try Scratch()
        let passwords = AccountPasswordStore(service: "agent-vm-tests-\(UUID().uuidString).account")
        let id = UUID().uuidString.lowercased()
        defer { try? passwords.delete(id: id) }
        #expect(!passwords.contains(id))
        try passwords.add(id: id, password: "s3cret", label: "agent-vm account password (test)", store: scratch.root)
        #expect(passwords.contains(id))
        #expect(try passwords.read(id: id, owner: "image test") == "s3cret")
        #expect(throws: AgentVMError.self) { try passwords.add(id: id, password: "again", label: "", store: scratch.root) }
        #expect(throws: AgentVMError.self) { try passwords.read(id: "none", owner: "image test") }
        // No record names it: a leftover of this store.
        #expect(passwords.removeUnused(store: scratch.root.appendingPathComponent("elsewhere")).isEmpty)
        #expect(passwords.removeUnused(store: scratch.root) == [id])
        #expect(!passwords.contains(id))
        try passwords.delete(id: id)
    }
}
