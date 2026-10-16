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

    private func options(_ name: String, base: String? = nil, restore: Bool = false, linux: Bool = false, inputs: [String: String] = [:],
                         parameters: [String: String] = [:]) -> ImageRebuildOptions {
        return ImageRebuildOptions(name: name, base: base, restoreImage: restore ? URL(fileURLWithPath: "/tmp/restore.ipsw") : nil,
                                   linux: linux ? ImageRebuildOptions.LinuxStart(base: LinuxBase.known[0]) : nil,
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
        // A start that runs the other system: an image built from a Linux image is a Linux one.
        var debian = ImageStoreTests.record("deb", state: .ready)
        debian.guest = .linux
        debian.formatVersion = ImageRecord.formatVersion(passwordID: nil, guest: .linux)
        let (_, debianLock) = try store.create(debian)
        debianLock.release()
        #expect(reason(options("dev", base: "deb"))?.contains("image deb runs Linux and dev runs macOS") == true)
        #expect(reason(options("dev", base: "plain", linux: true))?.contains("give one start: a Linux release, a restore image, or an image to start from") == true)
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
        // Made since 0.7.56 from a base that listed its recipes, all of which ran again here and
        // took their places: what ran on the base is known, and a restore image is fine.
        try store.update(tools) { $0.derivedFrom?.recipesListed = true }
        #expect(reason(options("tools", restore: true))?.contains("what ran on its base is not known") != true)
        try store.update(tools) { $0.derivedFrom?.recipesListed = nil }
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

    /// A Linux image starts again from its release's cloud image or from a Linux image, never
    /// from a restore image; a macOS image never from a Linux release.
    @MainActor
    @Test func aLinuxImageWantsLinuxOrFrom() throws {
        let scratch = try Scratch()
        let store = try ImageStore(root: scratch.root.appendingPathComponent("store"))
        func make(_ record: ImageRecord, recipe: String? = nil) throws {
            let (image, lock) = try store.create(record)
            lock.release()
            if let recipe {
                let url = image.recipesURL.appendingPathComponent("1-tool", isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try Data(recipe.utf8).write(to: url.appendingPathComponent("recipe.json"))
            }
        }
        func linux(_ name: String) -> ImageRecord {
            var record = ImageStoreTests.record(name, state: .ready)
            record.guest = .linux
            record.formatVersion = ImageRecord.formatVersion(passwordID: nil, guest: .linux)
            return record
        }
        let tool = ImageRecord.RecipeInfo(description: "Tool", digest: "aa", name: "tool", folder: "1-tool")
        var deb = linux("deb")
        deb.base = ImageRecord.BaseSource(release: "debian-13", file: "debian-13.tar.xz", url: nil, sha512: String(repeating: "a", count: 128), build: nil)
        try make(deb)
        var ubuntu = linux("ubu")
        ubuntu.base = ImageRecord.BaseSource(release: "ubuntu-26.04", file: "resolute-server-cloudimg-arm64.img", url: nil, sha512: "", sha256: String(repeating: "a", count: 64), build: nil)
        try make(ubuntu)
        var tools = linux("debtools")
        tools.derivedFrom = ImageRecord.DerivedFrom(image: "deb", recipeDigest: nil)
        tools.recipes = [tool]
        tools.commandLineTools = "build-essential 12.12"
        try make(tools, recipe: #"{"version": 1, "guest": "linux", "steps": [{"run": "true"}]}"#)
        var odd = linux("debodd")
        odd.derivedFrom = ImageRecord.DerivedFrom(image: "deb", recipeDigest: nil)
        odd.recipes = [tool]
        try make(odd, recipe: #"{"version": 1, "steps": [{"run": "true"}]}"#)
        try make(ImageStoreTests.record("dev", state: .ready))

        let builder = ImageBuilder(store: store) { (_: ProgressEvent) in }
        func reason(_ options: ImageRebuildOptions) -> String? {
            do {
                _ = try builder.rebuildPlan(options)
                return nil
            } catch {
                return "\(error)"
            }
        }
        // Made from a cloud image: it says which release, and what to give.
        #expect(reason(options("deb"))?.contains("deb was made from a cloud image (debian-13): give --linux (a release to start from again) or --from (a ready image)") == true)
        // A release this agent-vm does not offer (Ubuntu) is not suggested to start from again.
        if ProcessInfo.processInfo.environment[LinuxBase.withheldVariable] != "1" {
            #expect(reason(options("ubu"))?.contains("ubu was made from a cloud image (ubuntu-26.04), which this agent-vm does not offer: give --from (a ready image to start from)") == true)
        }
        // From its release again: every recipe runs, on no base.
        var plan = try builder.rebuildPlan(options("debtools", linux: true))
        #expect(plan.base == nil && plan.recipes.map(\.name) == ["tool"] && plan.commandLineTools)
        // With nothing given, from the image it was built from.
        plan = try builder.rebuildPlan(options("debtools"))
        #expect(plan.base == "deb" && plan.recipes.map(\.name) == ["tool"])
        // The other system's start is refused, in both directions.
        #expect(reason(options("debtools", restore: true)) == "--ipsw installs macOS, and image debtools runs Linux: give --linux (a release to start from again) or --from (a ready image)")
        #expect(reason(options("dev", linux: true)) == "--linux builds a Linux image, and image dev runs macOS: give --ipsw (a restore image to install) or --from (a ready image)")
        #expect(reason(options("debtools", base: "dev")) == "image dev runs macOS and debtools runs Linux: an image is rebuilt from an image of its own system")
        // A kept recipe that is not for Linux (a folder edited by hand) is caught by the plan.
        #expect(reason(options("debodd", linux: true))?.contains("it is for macOS images, and image debodd runs Linux") == true)
    }

    @Test func anInputRecordsWhereItsFileWas() throws {
        // Records written before the path was kept still decode, without one.
        let old = try JSONDecoder().decode(ImageRecord.InputInfo.self, from: Data(#"{"name":"xcode","file":"Xcode.xip","bytes":3,"sha256":"dd"}"#.utf8))
        #expect(old.path == nil)
        #expect(ImageStore.rebuildName(for: "tools") == "tools.rebuild")
    }

    /// A recipe the start ran with another input file (or other parameters) is not what the
    /// start holds: it runs again. Before 0.7.56 the recipe's digest alone decided, and an image
    /// that got a newer Xcode on top of its base's came back with the base's Xcode.
    @MainActor
    @Test func aRecipeTheStartRanAnotherWayRunsAgain() throws {
        let scratch = try Scratch()
        let (store, xip) = try images(in: scratch)
        let builder = ImageBuilder(store: store) { (_: ProgressEvent) in }
        // `dev` gets the Xcode recipe from Xcode_27.xip; `tools` ran it again, from another file.
        let dev = try store.image(named: "dev")
        let folder = dev.recipesURL.appendingPathComponent("2-xcode", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try store.image(named: "tools").recipesURL.appendingPathComponent("2-xcode/recipe.json"),
                                         to: folder.appendingPathComponent("recipe.json"))
        let older = ImageRecord.InputInfo(name: "xcode", file: "Xcode_27.xip", bytes: 3, sha256: "d0", path: xip.path)
        try store.update(dev) { record in
            record.recipes?.append(ImageRecord.RecipeInfo(description: "Xcode", digest: "bb", inputs: [older], name: "xcode", folder: "2-xcode"))
        }
        #expect(try builder.rebuildPlan(options("tools")).recipes.map(\.name) == ["xcode", "agents"])
        // The same file: the start holds it, so it does not run again.
        let tools = try store.image(named: "tools")
        try store.update(tools) { $0.recipes?[1].inputs = [older] }
        #expect(try builder.rebuildPlan(options("tools")).recipes.map(\.name) == ["agents"])
        // The same file and other parameters: it runs again.
        try store.update(tools) { $0.recipes?[1].parameters = ["beta": "1"] }
        #expect(try builder.rebuildPlan(options("tools")).recipes.map(\.name) == ["xcode", "agents"])
    }

    @Test func aRecipeTakesThePlaceOfOneOfItsName() {
        func info(_ name: String?, _ folder: String?, digest: String = "aa") -> ImageRecord.RecipeInfo {
            return ImageRecord.RecipeInfo(description: nil, digest: digest, name: name, folder: folder)
        }
        let base = [info("homebrew", "1-homebrew"), info("xcode", "2-xcode"), info("platforms", "3-platforms")]
        // In the old one's place, so what came after it (the simulators, say) still comes after.
        var placed = ImageRecord.RecipeInfo.placing(info("xcode", "4-xcode", digest: "bb"), in: base)
        #expect(placed.list.map(\.folder) == ["1-homebrew", "4-xcode", "3-platforms"])
        #expect(placed.list[1].digest == "bb" && placed.dropped == ["2-xcode"])
        // A new name goes at the end; a recipe without a name is always added.
        placed = ImageRecord.RecipeInfo.placing(info("node", "4-node"), in: base)
        #expect(placed.list.map(\.folder) == ["1-homebrew", "2-xcode", "3-platforms", "4-node"] && placed.dropped.isEmpty)
        placed = ImageRecord.RecipeInfo.placing(info(nil, "4-recipe"), in: [info(nil, "1-recipe")])
        #expect(placed.list.count == 2 && placed.dropped.isEmpty)
        // An image that lists one twice (made before 0.7.56): both go, the first one's place is kept.
        let twice = [info("xcode", "6-xcode"), info("agents", "7-agents"), info("xcode", "8-xcode")]
        placed = ImageRecord.RecipeInfo.placing(info("xcode", "9-xcode", digest: "cc"), in: twice)
        #expect(placed.list.map(\.folder) == ["9-xcode", "7-agents"] && placed.dropped == ["6-xcode", "8-xcode"])
        // The same folder (written again in place) is never one to remove.
        placed = ImageRecord.RecipeInfo.placing(info("xcode", "2-xcode", digest: "cc"), in: base)
        #expect(placed.dropped.isEmpty)
    }

    @Test func ranLikeComparesFilesInputsAndParameters() {
        let input = ImageRecord.InputInfo(name: "xcode", file: "Xcode.xip", bytes: 3, sha256: "dd")
        let one = ImageRecord.RecipeInfo(description: "a", digest: "aa", inputs: [input], parameters: ["p": "1"], name: "x", folder: "1-x", inheritedFrom: "dev")
        var two = one
        // Where it is kept and who ran it are not how it ran.
        two.folder = "5-x"
        two.inheritedFrom = nil
        two.description = "b"
        #expect(one.ranLike(two))
        two.inputs?[0].sha256 = "ee"
        #expect(!one.ranLike(two))
        two = one
        two.parameters = nil
        #expect(!one.ranLike(two))
        two = one
        two.digest = "ab"
        #expect(!one.ranLike(two))
    }
}
