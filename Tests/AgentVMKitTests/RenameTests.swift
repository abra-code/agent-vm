// Tests/AgentVMKitTests/RenameTests.swift
//
// `box rename` and `image rename`: the folder and the record, everything else in the store that
// names the box or the image, what is refused, and a rename that was interrupted after the
// folder moved.

import Darwin
import Foundation
import Testing
@testable import AgentVMKit

@Suite struct RenameTests {
    private func choices(_ fixture: BoxScratch) -> ConnectChoices {
        return ConnectChoices(store: fixture.boxes.root)
    }

    @Test func aBoxGetsItsNewNameEverywhere() throws {
        let fixture = try BoxScratch()
        let made = try fixture.boxes.create(name: "avm-try", from: fixture.image, imageStore: fixture.images)
        _ = try fixture.boxes.create(name: "other", from: fixture.image, imageStore: fixture.images)
        try Data("log".utf8).write(to: made.directory.appendingPathComponent(BoxStore.logName))
        try choices(fixture).remember(ConnectChoice(target: .box, box: "avm-try", launch: "shell"), for: "/p")
        try choices(fixture).remember(ConnectChoice(target: .box, box: "other"), for: "/q")

        let renamed = try fixture.boxes.rename("avm-try", to: "work")
        #expect(renamed.rememberedFolders == 1)
        #expect(renamed.box.name == "work")
        let box = try fixture.boxes.box(named: "work")
        #expect(box.record.formerNames == ["avm-try"])
        #expect(box.record.macAddress == made.record.macAddress && box.record.image == "dev")
        #expect(try String(contentsOf: box.diskURL, encoding: .utf8) == "disk")
        #expect(FileManager.default.fileExists(atPath: box.directory.appendingPathComponent(BoxStore.logName).path))
        #expect(throws: AgentVMError.boxNotFound("avm-try")) { try fixture.boxes.box(named: "avm-try") }
        #expect(try fixture.boxes.list().boxes.map(\.name) == ["other", "work"])
        #expect(choices(fixture).choice(for: "/p")?.box == "work")
        #expect(choices(fixture).choice(for: "/q")?.box == "other")
        #expect(BoxEventLog(url: box.eventsLogURL).events().last?.detail == "from avm-try to work")
        #expect(!FileManager.default.fileExists(atPath: box.directory.appendingPathComponent(BoxStore.RenameMark.fileName).path))

        // Again, and back: the former names are the ones it no longer has, oldest first.
        _ = try fixture.boxes.rename("work", to: "work2")
        #expect(try fixture.boxes.box(named: "work2").record.formerNames == ["avm-try", "work"])
        _ = try fixture.boxes.rename("work2", to: "avm-try")
        #expect(try fixture.boxes.box(named: "avm-try").record.formerNames == ["work", "work2"])
    }

    @Test func aBoxRenameIsRefusedWhenItCannotBeWhole() throws {
        let fixture = try BoxScratch()
        let box = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images)
        _ = try fixture.boxes.create(name: "b2", from: fixture.image, imageStore: fixture.images)
        #expect(throws: AgentVMError.boxExists("b2")) { try fixture.boxes.rename("b1", to: "b2") }
        #expect(throws: AgentVMError.boxNotFound("gone")) { try fixture.boxes.rename("gone", to: "b3") }
        #expect(throws: AgentVMError.invalidBoxName("Bad Name")) { try fixture.boxes.rename("b1", to: "Bad Name") }
        #expect(throws: AgentVMError.cannotRename(what: "box b1", reason: "b1 is the name it has")) { try fixture.boxes.rename("b1", to: "b1") }
        // Running: its supervisor holds the lock.
        let running = try #require(try FolderLock.tryAcquire(box.lockPath))
        #expect(throws: AgentVMError.boxRunning("b1")) { try fixture.boxes.rename("b1", to: "b3") }
        running.release()
        // A temporary box is deleted once it stops.
        _ = try fixture.boxes.create(name: "tmp", from: fixture.image, imageStore: fixture.images, disposable: true)
        #expect(throws: AgentVMError.cannotRename(what: "box tmp", reason: "it is a temporary box, deleted once it stops")) {
            try fixture.boxes.rename("tmp", to: "kept")
        }
        #expect(try fixture.boxes.list().boxes.map(\.name) == ["b1", "b2", "tmp"])
        #expect(try fixture.boxes.box(named: "b1").record.formerNames == nil)
    }

    /// The command of a job that has not ended names the box or the image.
    @Test func aJobThatHasNotEndedKeepsTheNames() throws {
        let fixture = try BoxScratch()
        _ = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images)
        let jobs = JobStore(root: fixture.boxes.root)
        let script = fixture.scratch.root.appendingPathComponent("wait.sh").path
        try Data("#!/bin/sh\n/bin/sleep 30\n".utf8).write(to: URL(fileURLWithPath: script))
        chmod(script, 0o755)
        let runner = [try ConnectScratch.builtAgentVM(), "job", "run"]
        let id = try jobs.start(executable: script, arguments: [], targets: ["box:b1", "image:dev"], directory: "/", runner: runner).id
        defer {
            try? jobs.cancel(id)
            let deadline = Date().addingTimeInterval(5)
            while jobs.runnerHoldsLock(id) && Date() < deadline {
                usleep(50_000)
            }
        }
        #expect(jobs.unfinishedJob(for: "box:b1") == id)
        #expect(jobs.unfinishedJob(for: "box:b2") == nil)
        #expect(throws: AgentVMError.cannotRename(what: "box b1", reason: "job \(id) was started for it and has not ended")) {
            try fixture.boxes.rename("b1", to: "b2")
        }
        #expect(throws: AgentVMError.cannotRename(what: "image dev", reason: "job \(id) names it and has not ended")) {
            try fixture.images.rename("dev", to: "dev2")
        }
        // A job that builds on an image is started for what it makes, and names the image.
        #expect(jobs.unfinishedJob(for: "image:base", naming: "base", with: ["--from", "--image"]) == nil)
        let building = try jobs.start(executable: script, arguments: ["image", "create", "x", "--from", "base"], targets: ["image:x"], directory: "/", runner: runner).id
        let making = try jobs.start(executable: script, arguments: ["box", "create", "y", "--image=other"], targets: ["box:y"], directory: "/", runner: runner).id
        defer {
            try? jobs.cancel(building)
            try? jobs.cancel(making)
        }
        #expect(jobs.unfinishedJob(for: "image:base", naming: "base", with: ["--from", "--image"]) == building)
        #expect(jobs.unfinishedJob(for: "image:other", naming: "other", with: ["--from", "--image"]) == making)
        #expect(jobs.unfinishedJob(for: "image:x2", naming: "x2", with: ["--from", "--image"]) == nil)
        #expect(try fixture.images.image(named: "dev").name == "dev")
    }

    /// Killed after the folder moved: the box is not usable under either name and says how to
    /// finish, and the same command finishes.
    @Test func anInterruptedBoxRenameIsFinishedByTheSameCommand() throws {
        let fixture = try BoxScratch()
        let box = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images)
        try choices(fixture).remember(ConnectChoice(target: .box, box: "b1"), for: "/p")
        try BoxStore.RenameMark(from: "b1", to: "b2").write(in: box.directory)
        let moved = fixture.boxes.boxesDirectory.appendingPathComponent("b2").path
        #expect(rename(box.directory.path, moved) == 0)
        #expect { try fixture.boxes.box(named: "b2") } throws: { error in
            "\(error)".contains("renaming box b1 to b2 was interrupted; `agent-vm box rename b1 b2` finishes it")
        }
        // Not another rename: only the one that was under way.
        #expect(throws: AgentVMError.boxNotFound("b1")) { try fixture.boxes.rename("b1", to: "b3") }
        let renamed = try fixture.boxes.rename("b1", to: "b2")
        #expect(renamed.rememberedFolders == 1)
        #expect(try fixture.boxes.box(named: "b2").record.formerNames == ["b1"])
        #expect(!FileManager.default.fileExists(atPath: moved + "/" + BoxStore.RenameMark.fileName))
    }

    /// A session noted its programs under the name the box had then: they are found after a
    /// rename, and after the renamed box is deleted (its kept logs).
    @Test func aSessionStillFindsARenamedBox() throws {
        let fixture = try SessionActivityTests.Fixture()
        _ = try fixture.boxWithARun("b1", exec: "run1")
        let before = SessionActivity.of(fixture.session, root: fixture.root, now: fixture.soon)
        #expect(before.programs.map(\.program.id) == ["run1"])
        _ = try fixture.boxes.boxes.rename("b1", to: "kept")
        let after = SessionActivity.of(fixture.session, root: fixture.root, now: fixture.soon)
        #expect(after == before)
        _ = try fixture.boxes.boxes.delete(named: "kept")
        #expect(KeptLogs(root: fixture.root).list().first?.logs.formerNames == ["b1"])
        let deleted = SessionActivity.of(fixture.session, root: fixture.root, now: fixture.soon, temporary: fixture.boxes.scratch.root)
        #expect(deleted == before)
    }

    /// A session that went on in the box after the rename noted it under both names: each
    /// program and connection is counted once, also once the box is deleted.
    @Test func aSessionThatSpansARenameCountsEachProgramOnce() throws {
        let fixture = try SessionActivityTests.Fixture()
        _ = try fixture.boxWithARun("b1", exec: "run1")
        let box = try fixture.boxes.boxes.rename("b1", to: "b2").box
        let start = fixture.session.record.startedAt
        let log = ExecLog(url: box.execLogURL)
        #expect(log.append(ExecLog.Entry(id: "run2", event: .start, time: start.addingTimeInterval(3), argv: ["/bin/agent"], user: "agent",
                                         project: fixture.session.record.project, session: fixture.session.id)) == nil)
        #expect(fixture.sessions.noteRun(SessionRun(box: "b2", exec: "run2", time: start.addingTimeInterval(3)), in: fixture.session) == nil)
        let activity = SessionActivity.of(fixture.session, root: fixture.root, now: fixture.soon)
        #expect(activity.boxes == ["b1", "b2"] && activity.notes.isEmpty)
        #expect(activity.programs.map(\.program.id) == ["run1", "run2"])
        #expect(activity.network.connections == 2 && activity.network.bytesUp == 4000)
        _ = try fixture.boxes.boxes.delete(named: "b2")
        let deleted = SessionActivity.of(fixture.session, root: fixture.root, now: fixture.soon, temporary: fixture.boxes.scratch.root)
        #expect(deleted == activity)
    }

    @Test func anImageGetsItsNewNameEverywhere() throws {
        let fixture = try BoxScratch()
        _ = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images)
        let second = try fixture.boxes.create(name: "b2", from: fixture.image, imageStore: fixture.images)
        // An image built from it, and one that is not.
        var tools = ImageStoreTests.record("dev-tools", state: .ready)
        tools.derivedFrom = ImageRecord.DerivedFrom(image: "dev", recipeDigest: "aa")
        tools.recipes = [ImageRecord.RecipeInfo(description: nil, digest: "aa", name: "homebrew", inheritedFrom: "dev"),
                         ImageRecord.RecipeInfo(description: nil, digest: "bb", name: "node")]
        try fixture.images.create(tools).1.release()
        var alone = ImageStoreTests.record("alone", state: .ready)
        alone.derivedFrom = ImageRecord.DerivedFrom(image: "another", recipeDigest: nil)
        try fixture.images.create(alone).1.release()
        let other = try fixture.images.image(named: "alone")
        for (url, text) in [(other.diskURL, "disk"), (other.auxiliaryStorageURL, "aux"), (other.hardwareModelURL, "hw"), (other.machineIdentifierURL, "id")] {
            try Data(text.utf8).write(to: url)
        }
        try ImageBuilder.writePassword("secret", to: other.passwordURL)
        let third = try fixture.boxes.create(name: "b3", from: other, imageStore: fixture.images)
        try choices(fixture).remember(ConnectChoice(target: .temporary, image: "dev"), for: "/p")
        try choices(fixture).remember(ConnectChoice(target: .temporary, image: "alone"), for: "/q")

        // A box of the image may be running: only its record names the image.
        let running = try #require(try FolderLock.tryAcquire(second.lockPath))
        let renamed = try fixture.images.rename("dev", to: "base")
        running.release()
        #expect(renamed.boxes == ["b1", "b2"])
        #expect(renamed.images == ["dev-tools"])
        #expect(renamed.rememberedFolders == 1)
        let image = try fixture.images.image(named: "base")
        #expect(image.record.createdAt == fixture.image.record.createdAt)
        #expect(try String(contentsOf: image.diskURL, encoding: .utf8) == "disk")
        #expect(throws: AgentVMError.imageNotFound("dev")) { try fixture.images.image(named: "dev") }
        #expect(try fixture.boxes.box(named: "b1").record.image == "base")
        #expect(try fixture.boxes.box(named: "b2").record.image == "base")
        #expect(try fixture.boxes.box(named: "b3").record == third.record)
        // The box is still what its image is: nothing to recreate.
        #expect(try fixture.boxes.box(named: "b1").record.needs(image: image.record).isEmpty)
        let built = try fixture.images.image(named: "dev-tools").record
        #expect(built.derivedFrom == ImageRecord.DerivedFrom(image: "base", recipeDigest: "aa"))
        #expect(built.recipes?.map(\.inheritedFrom) == ["base", nil])
        #expect(try fixture.images.image(named: "alone").record.derivedFrom?.image == "another")
        #expect(choices(fixture).choice(for: "/p")?.image == "base")
        #expect(choices(fixture).choice(for: "/q")?.image == "alone")
        // A new box can be made from it under its new name.
        #expect(try fixture.boxes.create(name: "b4", from: image, imageStore: fixture.images).record.image == "base")
    }

    /// An update of an image built from it was decided and killed before its record was in
    /// place: that record names the old name, and must not come back after the rename.
    @Test func aDecidedUpdateOfAnImageBuiltFromItIsFinishedFirst() throws {
        let fixture = try BoxScratch()
        var tools = ImageStoreTests.record("dev-tools", state: .ready)
        tools.derivedFrom = ImageRecord.DerivedFrom(image: "dev", recipeDigest: nil)
        try fixture.images.create(tools).1.release()
        let built = try fixture.images.image(named: "dev-tools")
        tools.revision = 1
        try FileManager.default.createDirectory(at: built.updateCommitURL, withIntermediateDirectories: true)
        try SessionStore.encoder.encode(tools).write(to: built.updateCommitURL.appendingPathComponent(ImageStore.recordName))
        #expect(try fixture.images.rename("dev", to: "base").images == ["dev-tools"])
        let lock = try #require(try fixture.images.tryLock(built))
        let settled = try fixture.images.settle(built).record
        lock.release()
        #expect(settled.derivedFrom?.image == "base" && settled.revision == 1)
    }

    @Test func anImageRenameIsRefusedWhenItCannotBeWhole() throws {
        let fixture = try BoxScratch()
        var tools = ImageStoreTests.record("dev-tools", state: .ready)
        tools.derivedFrom = ImageRecord.DerivedFrom(image: "dev", recipeDigest: nil)
        try fixture.images.create(tools).1.release()
        let built = try fixture.images.image(named: "dev-tools")
        #expect(throws: AgentVMError.imageExists(name: "dev-tools", state: "ready")) { try fixture.images.rename("dev", to: "dev-tools") }
        #expect(throws: AgentVMError.imageNotFound("gone")) { try fixture.images.rename("gone", to: "x") }
        #expect(throws: AgentVMError.invalidImageName("-x")) { try fixture.images.rename("dev", to: "-x") }
        // Being built or cloned, and being updated.
        let building = try #require(try fixture.images.tryLock(fixture.image))
        #expect(throws: AgentVMError.imageBusy("dev")) { try fixture.images.rename("dev", to: "base") }
        building.release()
        let updating = try #require(try fixture.images.tryLockForChange(fixture.image))
        #expect(throws: AgentVMError.imageBusy("dev")) { try fixture.images.rename("dev", to: "base") }
        updating.release()
        // An image built from it is being updated: its record is written from an older copy.
        let dependent = try #require(try fixture.images.tryLockForChange(built))
        #expect(throws: AgentVMError.cannotRename(what: "image dev", reason: "image dev-tools, which was built from it, is being changed by another agent-vm process")) {
            try fixture.images.rename("dev", to: "base")
        }
        dependent.release()
        // An image built from it is being built: its builder writes its record from its own copy.
        let built2 = try #require(try fixture.images.tryLock(built))
        #expect(throws: AgentVMError.cannotRename(what: "image dev", reason: "image dev-tools, which was built from it, is being built or used by another agent-vm process")) {
            try fixture.images.rename("dev", to: "base")
        }
        built2.release()
        // A rebuild of it that waits to take its place is found by the image's name.
        try FileManager.default.createDirectory(at: fixture.images.imagesDirectory.appendingPathComponent("dev.rebuild"), withIntermediateDirectories: false)
        #expect { try fixture.images.rename("dev", to: "base") } throws: { "\($0)".contains("a rebuild of it (dev.rebuild) is under way or was left unfinished") }
        try FileManager.default.removeItem(at: fixture.images.imagesDirectory.appendingPathComponent("dev.rebuild"))
        #expect(try fixture.images.list().images.map(\.name) == ["dev", "dev-tools"])
        #expect(try fixture.images.image(named: "dev-tools").record.derivedFrom?.image == "dev")
    }

    @Test func anInterruptedImageRenameIsFinishedByTheSameCommand() throws {
        let fixture = try BoxScratch()
        _ = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images)
        try BoxStore.RenameMark(from: "dev", to: "base").write(in: fixture.image.directory)
        let moved = fixture.images.imagesDirectory.appendingPathComponent("base").path
        #expect(rename(fixture.image.directory.path, moved) == 0)
        #expect { try fixture.images.image(named: "base") } throws: { error in
            "\(error)".contains("renaming image dev to base was interrupted; `agent-vm image rename dev base` finishes it")
        }
        #expect(throws: AgentVMError.imageNotFound("dev")) { try fixture.images.rename("dev", to: "other") }
        let renamed = try fixture.images.rename("dev", to: "base")
        #expect(renamed.boxes == ["b1"])
        #expect(try fixture.images.image(named: "base").name == "base")
        #expect(!FileManager.default.fileExists(atPath: moved + "/" + BoxStore.RenameMark.fileName))
        // Without its mark a folder under another name is no rename under way.
        #expect(throws: AgentVMError.imageNotFound("dev")) { try fixture.images.rename("dev", to: "base") }
    }
}
