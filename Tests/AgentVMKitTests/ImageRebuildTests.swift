// Tests/AgentVMKitTests/ImageRebuildTests.swift
//
// `image rebuild` without a virtual machine: which recipes run again and with what, and the
// store's part: a finished build takes the image's place in one step, and what an interrupted
// rebuild left is told apart from an image that merely has the build's name.

import Foundation
import Testing
@testable import AgentVMKit

@Suite struct ImageRebuildTests {
    /// `dev` (one recipe), `tools`, built from it with two more, and `plain` (no recipe); the
    /// Xcode recipe's input was read from a file in the scratch folder.
    private func images(in scratch: Scratch) throws -> (ImageStore, URL) {
        let store = ImageStore(root: scratch.root.appendingPathComponent("store", isDirectory: true))
        let xip = scratch.root.appendingPathComponent("Xcode.xip")
        try Data("xip".utf8).write(to: xip)
        let recipes = [
            "1-node": #"{"version": 1, "parameters": {"channel": {"default": "lts"}}, "steps": [{"run": "brew install node"}]}"#,
            "2-xcode": #"{"version": 1, "commandLineTools": true, "inputs": {"xcode": {}}, "steps": [{"run": "xip"}]}"#,
            "3-agents": #"{"version": 1, "parameters": {"extras": {"default": ""}}, "steps": [{"run": "npm install"}]}"#,
        ]
        func make(_ record: ImageRecord, folders: [String]) throws {
            let (image, lock) = try store.create(record)
            lock.release()
            try Data("disk of \(record.name)".utf8).write(to: image.diskURL)
            for folder in folders {
                let url = image.recipesURL.appendingPathComponent(folder, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try Data((recipes[folder] ?? "").utf8).write(to: url.appendingPathComponent("recipe.json"))
            }
        }
        let node = ImageRecord.RecipeInfo(description: "Node", digest: "aa", parameters: ["channel": "beta"], name: "node", folder: "1-node")
        var dev = ImageStoreTests.record("dev", state: .ready)
        dev.recipes = [node]
        try make(dev, folders: ["1-node"])
        var tools = ImageStoreTests.record("tools", state: .ready)
        tools.createdAt = dev.createdAt.addingTimeInterval(3600)
        tools.derivedFrom = ImageRecord.DerivedFrom(image: "dev", recipeDigest: "aa")
        var inherited = node
        inherited.inheritedFrom = "dev"
        let input = ImageRecord.InputInfo(name: "xcode", file: "Xcode.xip", bytes: 3, sha256: "dd", path: xip.path)
        tools.recipes = [
            inherited,
            ImageRecord.RecipeInfo(description: "Xcode", digest: "bb", inputs: [input], name: "xcode", folder: "2-xcode"),
            ImageRecord.RecipeInfo(description: "Agents", digest: "cc", parameters: ["extras": "gemini"], name: "agents", folder: "3-agents"),
        ]
        try make(tools, folders: ["1-node", "2-xcode", "3-agents"])
        try make(ImageStoreTests.record("plain", state: .ready), folders: [])
        return (store, xip)
    }

    private func options(_ name: String, base: String? = nil, restore: Bool = false, inputs: [String: String] = [:],
                         parameters: [String: String] = [:]) -> ImageRebuildOptions {
        return ImageRebuildOptions(name: name, base: base, restoreImage: restore ? URL(fileURLWithPath: "/tmp/restore.ipsw") : nil,
                                   inputs: inputs, parameters: parameters, guestDaemon: URL(fileURLWithPath: "/usr/bin/true"), askpassProgram: "/usr/bin/true")
    }

    @MainActor
    @Test func theRecipesTheStartLacksRunAgain() throws {
        let scratch = try Scratch()
        let (store, xip) = try images(in: scratch)
        let builder = ImageBuilder(store: store) { (_: ProgressEvent) in }
        func reason(_ options: ImageRebuildOptions) -> String? {
            do {
                _ = try builder.rebuildPlan(options)
                return nil
            } catch {
                return "\(error)"
            }
        }

        // No start named: the image it was built from, and only what that one lacks, with the
        // recorded input file and parameters.
        var plan = try builder.rebuildPlan(options("tools"))
        #expect(plan.base == "dev")
        #expect(plan.buildName == "tools.rebuild")
        #expect(plan.recipes.map(\.name) == ["xcode", "agents"])
        #expect(plan.recipes[0].inputFiles["xcode"]?.lastPathComponent == "Xcode.xip")
        #expect(plan.recipes[1].parameterValues == ["extras": "gemini"])
        #expect(plan.commandLineTools)

        // A restore image: everything that ran on the disk, the inherited recipe first, with
        // its recorded parameter; --set goes over a recorded value.
        plan = try builder.rebuildPlan(options("tools", restore: true, parameters: ["extras": "aider"]))
        #expect(plan.base == nil)
        #expect(plan.recipes.map(\.name) == ["node", "xcode", "agents"])
        #expect(plan.recipes[0].parameterValues == ["channel": "beta"])
        #expect(plan.recipes[2].parameterValues == ["extras": "aider"])
        // The base holds a newer version of the inherited recipe by now: still not run again.
        let dev = try store.image(named: "dev")
        try store.update(dev) { $0.recipes?[0].digest = "a2" }
        #expect(try builder.rebuildPlan(options("tools")).recipes.map(\.name) == ["xcode", "agents"])
        try store.update(dev) { $0.recipes?[0].digest = "aa" }
        // Another start that holds none of them: all of them, too.
        #expect(try builder.rebuildPlan(options("tools", base: "plain")).recipes.count == 3)

        // Another file can be given for an input; once the recorded one is gone it must be.
        let other = scratch.root.appendingPathComponent("Xcode-28.xip")
        try Data("new".utf8).write(to: other)
        #expect(try builder.rebuildPlan(options("tools", inputs: ["xcode": other.path])).recipes[0].inputFiles["xcode"]?.lastPathComponent == "Xcode-28.xip")
        try FileManager.default.removeItem(at: xip)
        #expect(reason(options("tools"))?.contains("it needs --input xcode=PATH (the image was built with \(xip.path), 0 MB)") == true)
        #expect(reason(options("tools", inputs: ["xcode": other.path])) == nil)

        // Refused before anything boots.
        #expect(reason(options("tools", inputs: ["xcode": other.path], parameters: ["channel": "x"]))?.contains("--set channel: no recipe to run has that parameter (they have: extras)") == true)
        #expect(reason(options("tools", inputs: ["ipa": other.path]))?.contains("--input ipa: no recipe to run has that input (they have: xcode)") == true)
        #expect(reason(options("plain"))?.contains("was installed from a restore image: give --ipsw") == true)
        #expect(reason(options("dev", base: "plain")) == nil)
        #expect(reason(options("dev", base: "dev"))?.contains("cannot be rebuilt from itself") == true)
        #expect(reason(options("plain", base: "dev"))?.contains("keeps no recipe that dev lacks") == true)
        #expect(reason(options("tools", base: "nosuch"))?.contains("nosuch") == true)
        #expect(reason(options("nosuch")) != nil)
        // A plain image is rebuilt from a restore image, with nothing to run.
        #expect(try builder.rebuildPlan(options("plain", restore: true)).recipes.isEmpty)
        // Its base is gone and none is named.
        try store.delete(named: "dev")
        #expect(reason(options("tools", inputs: ["xcode": other.path]))?.contains("the image it was built from, dev, is gone") == true)
        // Built before every recipe was kept, from another image: what ran on its base is unknown.
        let tools = try store.image(named: "tools")
        try store.update(tools) { record in
            record.recipes = nil
            record.recipe = ImageRecord.RecipeInfo(description: "Agents", digest: "cc")
        }
        #expect(reason(options("tools", restore: true))?.contains("what ran on its base is not known") == true)
        // The same when its own recipes are listed, or it has none, but its base had a recipe
        // then and the list holds nothing of the base's: a restore image would lose that one.
        try store.update(tools) { record in
            record.recipes = [ImageRecord.RecipeInfo(description: "Agents", digest: "cc", parameters: ["extras": "gemini"], name: "agents", folder: "3-agents")]
        }
        #expect(reason(options("tools", restore: true))?.contains("what ran on its base is not known") == true)
        #expect(reason(options("tools", base: "plain")) == nil)
        try store.update(tools) { record in
            record.recipes = nil
            record.recipe = nil
        }
        #expect(reason(options("tools", restore: true))?.contains("what ran on its base is not known") == true)
        // A base that had no recipe leaves nothing unknown.
        try store.update(tools) { record in
            record.recipes = nil
            record.recipe = nil
            record.derivedFrom = ImageRecord.DerivedFrom(image: "dev", recipeDigest: nil)
        }
        #expect(try builder.rebuildPlan(options("tools", restore: true)).recipes.isEmpty)
    }

    @Test func aFinishedBuildTakesTheImagesPlaceInOneStep() throws {
        let scratch = try Scratch()
        let (store, _) = try images(in: scratch)
        let old = try store.image(named: "tools")
        let buildPath = old.directory.path + ".rebuild"
        /// An image at the build's name, made `seconds` after the image, whose record names `name`.
        func build(_ state: ImageRecord.State, at seconds: TimeInterval, named name: String = "tools.rebuild") throws -> GoldenImage {
            var record = ImageStoreTests.record("tools.rebuild", state: state)
            record.createdAt = old.record.createdAt.addingTimeInterval(seconds)
            let (image, lock) = try store.create(record)
            lock.release()
            try Data("new disk".utf8).write(to: image.diskURL)
            return name == record.name ? image : try store.update(image) { $0.name = name }
        }
        func leftover() throws -> String {
            switch try store.clearRebuildLeftover(of: try store.image(named: "tools")) {
            case .none:
                return FileManager.default.fileExists(atPath: buildPath) ? "kept" : "none"
            case let .finished(image):
                return "finished \(image.directory.lastPathComponent)"
            }
        }
        #expect(try leftover() == "none")

        // A failed build goes. A ready image that merely has the name, with no marker, is
        // somebody's own: refused, and kept.
        _ = try build(.failed, at: 60)
        #expect(try leftover() == "none")
        let own = try build(.ready, at: 60)
        #expect(throws: AgentVMError.self) { try leftover() }
        #expect(FileManager.default.fileExists(atPath: own.diskURL.path))

        // Marked: it is the finished build, and takes the image's place.
        try store.markRebuilt(own, of: "tools")
        #expect(try leftover() == "finished tools.rebuild")
        let lock = try #require(try store.tryLock(old))
        let changeLock = try #require(try store.tryLockForChange(old))
        let now = try store.replace(old, with: own)
        lock.release()
        changeLock.release()
        #expect(now.name == "tools")
        #expect(now.record.createdAt == own.record.createdAt)
        #expect(try String(contentsOf: now.diskURL, encoding: .utf8) == "new disk")
        #expect(!FileManager.default.fileExists(atPath: buildPath))
        #expect(!FileManager.default.fileExists(atPath: now.directory.appendingPathComponent(".rebuild-of").path))
        #expect(now.record.recipes == nil)
        #expect(try store.list().problems.isEmpty)

        // A kill after the exchange leaves the old image at the build's name, older than the
        // image in place and naming it: it goes, marked or not.
        let stale = try build(.ready, at: -60, named: "tools")
        try store.markRebuilt(stale, of: "tools")
        #expect(try leftover() == "none")
        // A kill just before the exchange leaves the new one there, already renamed: it is
        // still the finished build, and the exchange goes through.
        let renamed = try build(.ready, at: 120, named: "tools")
        try store.markRebuilt(renamed, of: "tools")
        #expect(try leftover() == "finished tools.rebuild")
        let again = try store.replace(try store.image(named: "tools"), with: renamed)
        #expect(again.record.createdAt == renamed.record.createdAt)
        #expect(try store.list().problems.isEmpty)
        // A build marked for another image is not this one's.
        let foreign = try build(.ready, at: 240)
        try store.markRebuilt(foreign, of: "other")
        #expect(try leftover() == "none")
    }

    @Test func anInputRecordsWhereItsFileWas() throws {
        // Records written before the path was kept still decode, without one.
        let old = try JSONDecoder().decode(ImageRecord.InputInfo.self, from: Data(#"{"name":"xcode","file":"Xcode.xip","bytes":3,"sha256":"dd"}"#.utf8))
        #expect(old.path == nil)
        #expect(ImageStore.rebuildName(for: "tools") == "tools.rebuild")
    }
}
