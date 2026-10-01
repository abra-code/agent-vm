// Tests/AgentVMKitTests/ImageUpdateTests.swift
//
// `image update` without a virtual machine: reading what softwareupdate offers, which of an
// image's recipes have update steps, and the store's part: an update is decided by one rename,
// finished by whoever uses the image next, and dropped when it was never decided.

import Foundation
import Testing
@testable import AgentVMKit

@Suite struct ImageUpdateTests {
    @Test func theOfferedMacOSUpdateIsRead() {
        let listed = """
            Software Update Tool

            Finding available software
            Software Update found the following new or updated software:
            * Label: Command Line Tools for Xcode 27.1-27.1
            \tTitle: Command Line Tools for Xcode, Version: 27.1, Size: 540000KiB, Recommended: YES,
            * Label: macOS 27.0.1-26A434
            \tTitle: macOS 27.0.1, Version: 27.0.1, Size: 3235867KiB, Recommended: YES, Action: restart,
            """
        #expect(MacOSUpdate.offered(inListOutput: listed, major: 27) == MacOSUpdate(label: "macOS 27.0.1-26A434", version: "27.0.1", build: "26A434"))
        // Another major version is a new image's job; the newest of this one wins; a release
        // name may follow "macOS".
        let several = """
            * Label: macOS 27.0.1-26A434
            * Label: macOS 27.1-26B50
            * Label: macOS Sequoia 15.7.2-24G325
            * Label: macOS 28.0-27A300
            * Label: macOS Background Security Improvement
            * Label: Safari 27.1-20000.1
            """
        #expect(MacOSUpdate.offered(inListOutput: several, major: 27)?.build == "26B50")
        #expect(MacOSUpdate.offered(inListOutput: several, major: 15) == MacOSUpdate(label: "macOS Sequoia 15.7.2-24G325", version: "15.7.2", build: "24G325"))
        #expect(MacOSUpdate.offered(inListOutput: several, major: 26) == nil)
        #expect(MacOSUpdate.offered(inListOutput: "No new software available.", major: 27) == nil)
        let request = MacOSUpdate.installRequest(label: "macOS 27.0.1-26A434", user: "agent")
        #expect(request.argv == ["/usr/sbin/softwareupdate", "--install", "macOS 27.0.1-26A434", "--restart", "--agree-to-license",
                                 "--user", "agent", "--stdinpass", "--verbose"])
        #expect(request.user == "root")
    }

    @Test func theDownloadPercentageIsReadFromARedrawnLine() {
        let percent = DownloadPercent()
        func add(_ text: String) -> Int? {
            return percent.add(Array(text.utf8))
        }
        #expect(add("Software Update Tool\n\nFinding available software\nDownloading macOS 27.0.1\n") == nil)
        #expect(add("\rDownloading: 0.10%") == 0)
        #expect(add("\rDownloading: 1.90%\rDownloading: 9.99%") == nil)
        // Split across two chunks: read once the line is whole.
        #expect(add("\rDownloading: 1") == nil)
        #expect(add("2.00%") == 12)
        #expect(add("\rDownloading: 18.00%") == nil)
        #expect(add("\rDownloading: 47.5%\rDownloading: 52%") == 52)
        #expect(add("\rDownloading: 97.45%") == 97)
        #expect(add("\rDownloading: 98.48%\rDownloading: 100.00%\nDownloaded: macOS 27.0.1\nRestarting...\n") == 100)
        #expect(add("\n") == nil)
        // A number too large for an Int is capped, not a crash.
        let odd = DownloadPercent()
        #expect(odd.add(Array("\rDownloading: nan%".utf8)) == nil)
        #expect(odd.add(Array("\rDownloading: inf%".utf8)) == 100)
        #expect(DownloadPercent().add(Array("\rDownloading: 1e400%".utf8)) == 100)
    }

    /// A ready image whose folder holds a disk, auxiliary storage and two kept recipes.
    private func image(in scratch: Scratch) throws -> (ImageStore, GoldenImage) {
        let store = ImageStore(root: scratch.root.appendingPathComponent("store", isDirectory: true))
        var record = ImageStoreTests.record("tools", state: .ready)
        record.recipes = [
            ImageRecord.RecipeInfo(description: "Node", digest: "aa", parameters: ["channel": "beta"], name: "node", folder: "1-node", inheritedFrom: "dev"),
            ImageRecord.RecipeInfo(description: "Xcode", digest: "bb", name: "xcode", folder: "2-xcode"),
            ImageRecord.RecipeInfo(description: "Agents", digest: "cc", name: "agents", folder: "3-agents"),
        ]
        let (image, lock) = try store.create(record)
        lock.release()
        try Data("disk".utf8).write(to: image.diskURL)
        try Data("aux".utf8).write(to: image.auxiliaryStorageURL)
        let recipes = [
            "1-node": #"{"version": 1, "parameters": {"channel": {"default": "lts"}}, "update": [{"run": "brew upgrade"}]}"#,
            "2-xcode": #"{"version": 1, "inputs": {"xcode": {}}, "steps": [{"run": "xip"}]}"#,
            "3-agents": #"{"version": 1, "parameters": {"extras": {"default": ""}}, "update": [{"run": "npm install"}]}"#,
        ]
        for (folder, json) in recipes {
            let url = image.recipesURL.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(json.utf8).write(to: url.appendingPathComponent("recipe.json"))
        }
        return (store, image)
    }

    @MainActor
    @Test func onlyRecipesWithUpdateStepsArePlanned() throws {
        let scratch = try Scratch()
        let (store, image) = try image(in: scratch)
        let builder = ImageBuilder(store: store) { (_: ProgressEvent) in }
        let plans = try builder.toolsPlans(image, set: ["extras": "gemini"])
        // In the order they ran, named as the record names them, with recorded values, then
        // --set, then defaults; a recipe that needed an input is no obstacle.
        #expect(plans.map(\.recipe.name) == ["node", "agents"])
        #expect(plans.map(\.index) == [0, 2])
        #expect(plans[0].recipe.parameterValues == ["channel": "beta"])
        #expect(plans[1].recipe.parameterValues == ["extras": "gemini"])

        func reason(_ set: [String: String], _ image: GoldenImage) -> String? {
            do {
                _ = try builder.toolsPlans(image, set: set)
                return nil
            } catch {
                return "\(error)"
            }
        }
        #expect(reason(["size": "1"], image)?.contains("no recipe with update steps in tools has that parameter (they have: channel, extras)") == true)
        // An image from before recipes were kept has nothing to run.
        let old = try store.update(image) { $0.recipes = nil }
        #expect(try builder.toolsPlans(old, set: [:]).isEmpty)
        #expect(reason(["channel": "x"], old)?.contains("keeps no recipe with update steps") == true)
    }

    @Test func anUpdateIsDecidedByOneRename() throws {
        let scratch = try Scratch()
        let (store, image) = try image(in: scratch)
        func contents(_ url: URL) -> String? {
            return try? String(contentsOf: url, encoding: .utf8)
        }
        func stage(_ folder: URL) throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("new disk".utf8).write(to: folder.appendingPathComponent(ImageStore.diskName))
            try Data("new aux".utf8).write(to: folder.appendingPathComponent(ImageStore.auxiliaryStorageName))
        }

        // Never decided (agent-vm was killed while it worked): dropped, the image as it was.
        try stage(image.updateURL)
        var settled = try store.settle(image)
        #expect(!FileManager.default.fileExists(atPath: image.updateURL.path))
        #expect(contents(image.diskURL) == "disk")
        #expect(settled.record == image.record)

        // Decided: the files and the record take their place, and the folders are gone.
        try stage(image.updateURL)
        var record = image.record
        record.macOSBuild = "26A434"
        record.revision = 1
        try store.commitUpdate(image, record: record)
        #expect(contents(image.diskURL) == "new disk")
        #expect(contents(image.auxiliaryStorageURL) == "new aux")
        #expect(try store.image(named: "tools").record.revision == 1)
        #expect(!FileManager.default.fileExists(atPath: image.updateURL.path))
        #expect(!FileManager.default.fileExists(atPath: image.updateCommitURL.path))

        // Decided, then killed after the disk had moved: the rest is finished by the next user.
        try stage(image.updateCommitURL)
        try FileManager.default.removeItem(at: image.updateCommitURL.appendingPathComponent(ImageStore.diskName))
        try Data("newer aux".utf8).write(to: image.updateCommitURL.appendingPathComponent(ImageStore.auxiliaryStorageName))
        record.revision = 2
        try SessionStore.encoder.encode(record).write(to: image.updateCommitURL.appendingPathComponent(ImageStore.recordName))
        settled = try store.settle(image)
        #expect(contents(image.diskURL) == "new disk")
        #expect(contents(image.auxiliaryStorageURL) == "newer aux")
        #expect(settled.record.revision == 2)
        #expect(!FileManager.default.fileExists(atPath: image.updateCommitURL.path))
    }

    /// While an update runs (it holds the update lock), its folder is nobody's leftover: a box
    /// can be made from the image as it is, and the image cannot be deleted or changed by
    /// another command.
    @Test func aRunningUpdateIsLeftAloneAndBoxesCanBeMade() throws {
        let fixture = try BoxScratch()
        let image = fixture.image
        let running = try #require(try fixture.images.tryLockForChange(image))
        try FileManager.default.createDirectory(at: image.updateURL, withIntermediateDirectories: true)
        try Data("half updated".utf8).write(to: image.updateURL.appendingPathComponent(ImageStore.diskName))
        #expect(fixture.images.isBeingChanged(image))

        let box = try fixture.boxes.create(name: "b1", from: image, imageStore: fixture.images)
        #expect(try Data(contentsOf: box.diskURL) == Data(contentsOf: image.diskURL))
        #expect(FileManager.default.fileExists(atPath: image.updateURL.path))
        #expect(try fixture.images.tryLockForChange(image) == nil)
        #expect(throws: AgentVMError.imageBusy(image.name)) { try fixture.images.delete(named: image.name) }
        // The update itself clears what an earlier one left.
        try fixture.images.settle(image, updating: true)
        #expect(!FileManager.default.fileExists(atPath: image.updateURL.path))

        // Once it ended (or was killed), the folder is a leftover again.
        try FileManager.default.createDirectory(at: image.updateURL, withIntermediateDirectories: true)
        running.release()
        #expect(!fixture.images.isBeingChanged(image))
        _ = try fixture.boxes.create(name: "b2", from: image, imageStore: fixture.images)
        #expect(!FileManager.default.fileExists(atPath: image.updateURL.path))
        try fixture.images.delete(named: image.name)
    }

    @Test func anUpdateIsDueWhenNoneEndedWellLately() {
        var record = ImageStoreTests.record("tools", state: .ready)
        let now = Date(timeIntervalSince1970: 1_800_100_000)
        #expect(record.isUpdateDue(macOS: true, tools: true, olderThanHours: 24, now: now))
        record.toolsCheckedAt = now.addingTimeInterval(-23 * 3600)
        // Each part by itself: a tools update says nothing about macOS.
        #expect(!record.isUpdateDue(macOS: false, tools: true, olderThanHours: 24, now: now))
        #expect(record.isUpdateDue(macOS: false, tools: true, olderThanHours: 23, now: now))
        #expect(record.isUpdateDue(macOS: true, tools: false, olderThanHours: 24, now: now))
        #expect(record.isUpdateDue(macOS: true, tools: true, olderThanHours: 24, now: now))
        record.macOSCheckedAt = now.addingTimeInterval(-3600)
        #expect(!record.isUpdateDue(macOS: true, tools: true, olderThanHours: 24, now: now))
        #expect(record.isUpdateDue(macOS: true, tools: true, olderThanHours: 0, now: now))
        #expect(!record.isUpdateDue(macOS: false, tools: false, olderThanHours: 0, now: now))
        // The expected duration travels in the event's JSON.
        var event = ProgressEvent(.progress, "Booting", step: "boot")
        event.expectedSeconds = 85
        #expect(event.jsonLine.contains("\"expectedSeconds\":85"))
    }

    /// A box made after a killed update gets the finished image, not half of it.
    @Test func aNewBoxFinishesADecidedUpdateFirst() throws {
        let fixture = try BoxScratch()
        let image = fixture.image
        try FileManager.default.createDirectory(at: image.updateCommitURL, withIntermediateDirectories: true)
        try Data("updated disk".utf8).write(to: image.updateCommitURL.appendingPathComponent(ImageStore.diskName))
        var record = image.record
        record.revision = 3
        try SessionStore.encoder.encode(record).write(to: image.updateCommitURL.appendingPathComponent(ImageStore.recordName))
        let box = try fixture.boxes.create(name: "b1", from: image, imageStore: fixture.images)
        #expect(try String(contentsOf: box.diskURL, encoding: .utf8) == "updated disk")
        #expect(box.record.imageRevision == 3)
    }
}
