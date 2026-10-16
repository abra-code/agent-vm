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
            "2-xcode": #"{"version": 1, "inputs": {"xcode": {}}, "parameters": {"edition": {"default": "release"}}, "steps": [{"run": "xip"}], "checks": ["xcodebuild -version"]}"#,
            "3-agents": #"{"version": 1, "parameters": {"extras": {"default": ""}}, "update": [{"run": "npm install"}]}"#,
        ]
        for (folder, json) in recipes {
            let url = image.recipesURL.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(json.utf8).write(to: url.appendingPathComponent("recipe.json"))
        }
        return (store, image)
    }

    /// A recipe file in a folder of the name the image keeps it under.
    private func recipeFile(_ name: String, _ json: String, in scratch: Scratch, sub: String = "new") throws -> URL {
        let folder = scratch.root.appendingPathComponent(sub, isDirectory: true).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("recipe.json")
        try Data(json.utf8).write(to: url)
        return url
    }

    @MainActor
    @Test func aNewerRecipeTakesTheKeptOnesPlace() throws {
        let scratch = try Scratch()
        let (store, image) = try image(in: scratch)
        let builder = ImageBuilder(store: store) { (_: ProgressEvent) in }
        // xcode had no update steps; the newer one has, and keeps the recorded and default values.
        let xcode = try recipeFile("xcode", #"{"version": 1, "parameters": {"edition": {"default": "release"}}, "steps": [{"run": "xip"}], "update": [{"run": "xcodebuild -runFirstLaunch"}], "checks": ["xcodebuild -version"]}"#, in: scratch)
        let plans = try builder.toolsPlans(image, set: [:], replacing: [xcode])
        #expect(plans.map(\.recipe.name) == ["node", "xcode", "agents"])
        #expect(plans.map(\.checksOnly) == [false, false, false])
        #expect(plans.map(\.replaces) == [false, true, false])
        #expect(plans[1].recipe.updateSteps.count == 1)
        #expect(plans[1].recipe.parameterValues == ["edition": "release"])
        #expect(plans[1].recipe.digest == (try ImageRecipe.load(from: xcode)).digest)
        // A replaced recipe is run for its checks even when no recipe has update steps.
        let alone = try store.update(image) { $0.recipes = [$0.recipes![1]] }
        let checks = try recipeFile("xcode", #"{"version": 1, "steps": [{"run": "xip"}], "checks": ["xcodebuild -version", "swift --version"]}"#, in: scratch, sub: "checks")
        let only = try builder.toolsPlans(alone, set: [:], replacing: [checks])
        #expect(only.map(\.checksOnly) == [true] && only.map(\.replaces) == [true])
        // The recipe the image keeps already replaces nothing.
        let copy = try recipeFile("agents", try String(contentsOf: image.recipesURL.appendingPathComponent("3-agents/recipe.json"), encoding: .utf8), in: scratch)
        let digest = try ImageRecipe.load(from: copy).digest
        let recorded = try store.update(image) { $0.recipes![2].digest = digest }
        let same = try builder.toolsPlans(recorded, set: [:], replacing: [copy])
        #expect(same.map(\.replaces) == [false, false, false])

        func reason(_ urls: [URL]) -> String? {
            do {
                _ = try builder.toolsPlans(image, set: [:], replacing: urls)
                return nil
            } catch {
                return "\(error)"
            }
        }
        let python = try recipeFile("python", #"{"version": 1, "update": [{"run": "brew install python3"}]}"#, in: scratch)
        #expect(reason([python])?.contains("tools keeps no recipe named python to replace (it keeps: node, xcode, agents)") == true)
        let twice = try recipeFile("xcode", #"{"version": 1, "checks": ["true"]}"#, in: scratch, sub: "twice")
        #expect(reason([xcode, twice])?.contains("--recipe gives two recipes named xcode") == true)
        let linux = try recipeFile("node", #"{"version": 1, "guest": "linux", "update": [{"run": "apt-get update"}]}"#, in: scratch)
        #expect(reason([linux]) != nil)
    }

    /// `--input`: a new file for a kept recipe's input runs that recipe's steps again, with it
    /// and the parameters the image recorded, in the recipe's place among the others.
    @MainActor
    @Test func aNewInputRunsItsRecipeAgain() throws {
        let scratch = try Scratch()
        let (store, kept) = try image(in: scratch)
        let builder = ImageBuilder(store: store) { (_: ProgressEvent) in }
        let xip = scratch.root.appendingPathComponent("Xcode_27.1.xip")
        try Data("xip".utf8).write(to: xip)
        let image = try store.update(kept) { $0.recipes?[1].parameters = ["edition": "beta"] }
        let plans = try builder.toolsPlans(image, set: [:], inputs: ["xcode": xip.path])
        #expect(plans.map(\.recipe.name) == ["node", "xcode", "agents"])
        #expect(plans.map(\.reinstall) == [false, true, false])
        #expect(plans.map(\.checksOnly) == [false, false, false])
        #expect(plans[1].recipe.inputFiles["xcode"]?.lastPathComponent == "Xcode_27.1.xip")
        #expect(plans[1].recipe.parameterValues == ["edition": "beta"])
        // --set reaches it too.
        #expect(try builder.toolsPlans(image, set: ["edition": "release"], inputs: ["xcode": xip.path])[1].recipe.parameterValues == ["edition": "release"])
        // Without the input it is checked only, as before.
        #expect(try builder.toolsPlans(image, set: [:]).map(\.checksOnly) == [false, true, false])

        // An image that keeps the recipe twice (made before 0.7.56): only the last one runs.
        let twice = try store.update(image) { record in
            record.recipes?.append(ImageRecord.RecipeInfo(description: "Xcode", digest: "bb", name: "xcode", folder: "4-xcode"))
        }
        let folder = twice.recipesURL.appendingPathComponent("4-xcode", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: twice.recipesURL.appendingPathComponent("2-xcode/recipe.json"), to: folder.appendingPathComponent("recipe.json"))
        let last = try builder.toolsPlans(twice, set: [:], inputs: ["xcode": xip.path])
        #expect(last.map(\.reinstall) == [false, false, false, true])
        #expect(last[1].checksOnly && !last[3].checksOnly)

        func reason(_ inputs: [String: String]) -> String? {
            do {
                _ = try builder.toolsPlans(image, set: [:], inputs: inputs)
                return nil
            } catch {
                return "\(error)"
            }
        }
        #expect(reason(["ipa": xip.path])?.contains("--input ipa: tools keeps no recipe with that input (they have: xcode)") == true)
        #expect(reason(["xcode": scratch.root.appendingPathComponent("nosuch.xip").path])?.contains("does not exist") == true)
        // Only the tools update takes one.
        #expect { try builder.checkUpdate(ImageUpdateOptions(name: "tools", system: true, tools: false, inputs: ["xcode": xip.path])) }
            throws: { "\($0)".contains("--input xcode gives a recipe a new file, for the tools update") }

        // With --recipe the new file goes where the given recipe runs (the first kept one of
        // its name), also when it names the input differently from the kept ones.
        let given = try recipeFile("xcode", #"{"version": 1, "inputs": {"xip": {}}, "steps": [{"run": "xip"}]}"#, in: scratch)
        let renamed = try builder.toolsPlans(twice, set: [:], inputs: ["xip": xip.path], replacing: [given])
        #expect(renamed[1].reinstall && renamed[1].replaces && renamed[1].recipe.inputFiles["xip"]?.lastPathComponent == "Xcode_27.1.xip")
        #expect(!renamed[3].reinstall)
        // A newer built-in recipe without the input refuses the file instead of leaving it out.
        let withInput = #"{"version": 1, "inputs": {"py": {}}, "checks": ["python3 --version"]}"#
        let builtIn = try #require(BuiltInRecipes(folder: try BuiltInRecipesTests.folder(
            in: scratch, recipe: BuiltInRecipesTests.new, history: [BuiltInRecipesTests.digest(withInput), BuiltInRecipesTests.digest(BuiltInRecipesTests.new)])))
        let python = image.recipesURL.appendingPathComponent("4-python", isDirectory: true)
        try FileManager.default.createDirectory(at: python, withIntermediateDirectories: true)
        try Data(withInput.utf8).write(to: python.appendingPathComponent("recipe.json"))
        let pythonImage = try store.update(image) { $0.recipes?.append(ImageRecord.RecipeInfo(description: nil, digest: BuiltInRecipesTests.digest(withInput), name: "python", folder: "4-python")) }
        #expect { try builder.toolsPlans(pythonImage, set: [:], inputs: ["py": xip.path], builtIn: builtIn) }
            throws: { "\($0)".contains("--input py: the python recipe that runs has no such input") }
    }

    @MainActor
    @Test func aNewerBuiltInRecipeIsUsedByItself() throws {
        let scratch = try Scratch()
        let (store, kept) = try image(in: scratch)
        let builder = ImageBuilder(store: store) { (_: ProgressEvent) in }
        let old = BuiltInRecipesTests.digest(BuiltInRecipesTests.old)
        let new = BuiltInRecipesTests.digest(BuiltInRecipesTests.new)
        let recipes = try #require(BuiltInRecipes(folder: try BuiltInRecipesTests.folder(in: scratch, recipe: BuiltInRecipesTests.new, history: [old, new])))
        // The image keeps the old python recipe, which has no update steps.
        let folder = kept.recipesURL.appendingPathComponent("4-python", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(BuiltInRecipesTests.old.utf8).write(to: folder.appendingPathComponent("recipe.json"))
        let image = try store.update(kept) { $0.recipes!.append(ImageRecord.RecipeInfo(description: nil, digest: old, name: "python", folder: "4-python")) }
        let plans = try builder.toolsPlans(image, set: [:], builtIn: recipes)
        #expect(plans.map(\.recipe.name) == ["node", "xcode", "agents", "python"])
        #expect(plans.map(\.replaces) == [false, false, false, true])
        #expect(plans.map(\.builtIn) == [false, false, false, true])
        #expect(plans[3].recipe.digest == new && !plans[3].checksOnly)
        // Without the built-in recipes (--kept-recipes) the kept one runs, for its checks.
        let asKept = try builder.toolsPlans(image, set: [:])
        #expect(asKept.map(\.replaces) == [false, false, false, false] && asKept[3].checksOnly)
        // An update killed after the record was written and before the folder was replaced:
        // the record has the new digest and the folder the old recipe, which is replaced again.
        let halfway = try store.update(image) { $0.recipes![3].digest = new }
        let again = try builder.toolsPlans(halfway, set: [:], builtIn: recipes)
        #expect(again[3].replaces && again[3].builtIn && again[3].recipe.digest == new)
        // The same for one given with --recipe.
        let installed = recipes.folder.appendingPathComponent("python/recipe.json")
        let repeated = try builder.toolsPlans(halfway, set: [:], replacing: [installed])
        #expect(repeated[3].replaces && !repeated[3].builtIn)
        // A newer one that needs a parameter the image never recorded is refused here, before
        // anything boots, in words that say what to give.
        let needy = #"{"version": 1, "parameters": {"series": {}}, "update": [{"run": "brew install python@$AGENT_VM_PARAM_SERIES"}]}"#
        let other = try Scratch()
        let needs = try #require(BuiltInRecipes(folder: try BuiltInRecipesTests.folder(in: other, recipe: needy, history: [old, BuiltInRecipesTests.digest(needy)])))
        #expect { try builder.toolsPlans(image, set: [:], builtIn: needs) } throws: { "\($0)".contains("it needs --set series=VALUE") }
        #expect(try builder.toolsPlans(image, set: ["series": "3.14"], builtIn: needs)[3].recipe.parameterValues == ["series": "3.14"])
        // A recipe of the person's own that is only named python is left alone.
        try Data(#"{"version": 1, "checks": ["python3 -c 'import mine'"]}"#.utf8).write(to: folder.appendingPathComponent("recipe.json"))
        let own = try store.update(image) { $0.recipes![3].digest = "ee" }
        #expect(try builder.toolsPlans(own, set: [:], builtIn: recipes).map(\.replaces) == [false, false, false, false])
        try Data(BuiltInRecipesTests.old.utf8).write(to: folder.appendingPathComponent("recipe.json"))
        // One given with --recipe wins over the built-in one.
        let given = try recipeFile("python", #"{"version": 1, "update": [{"run": "uv python install"}]}"#, in: scratch)
        let explicit = try builder.toolsPlans(image, set: [:], replacing: [given], builtIn: recipes)
        let givenDigest = try ImageRecipe.load(from: given).digest
        #expect(explicit[3].replaces && !explicit[3].builtIn && explicit[3].recipe.digest == givenDigest)
    }

    @MainActor
    @Test func aKeptRecipeIsReplacedWithItsFiles() throws {
        let scratch = try Scratch()
        let recipes = scratch.root.appendingPathComponent("Recipes", isDirectory: true)
        let kept = recipes.appendingPathComponent("1-tool", isDirectory: true)
        try FileManager.default.createDirectory(at: kept.appendingPathComponent("files"), withIntermediateDirectories: true)
        try Data(#"{"version": 1, "steps": [{"copy": "files/old", "to": "~/old"}]}"#.utf8).write(to: kept.appendingPathComponent("recipe.json"))
        try Data("old".utf8).write(to: kept.appendingPathComponent("files/old"))
        let url = try recipeFile("tool", #"{"version": 1, "steps": [{"copy": "files/new", "to": "~/new"}], "update": [{"run": "true"}]}"#, in: scratch)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent().appendingPathComponent("files"), withIntermediateDirectories: true)
        try Data("new".utf8).write(to: url.deletingLastPathComponent().appendingPathComponent("files/new"))
        let recipe = try ImageRecipe.load(from: url)
        try ImageBuilder.replaceKeptRecipe(recipe, in: recipes, folder: "1-tool")
        // What the image keeps now loads as the new recipe, and nothing of the old one is left.
        #expect(try ImageRecipe.load(from: kept.appendingPathComponent("recipe.json")).digest == recipe.digest)
        #expect(try String(contentsOf: kept.appendingPathComponent("files/new"), encoding: .utf8) == "new")
        #expect(!FileManager.default.fileExists(atPath: kept.appendingPathComponent("files/old").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: recipes.path) == ["1-tool"])
        // A folder name that leads elsewhere is refused.
        #expect(throws: (any Error).self) { try ImageBuilder.replaceKeptRecipe(recipe, in: recipes, folder: "../1-tool") }
    }

    @MainActor
    @Test func onlyRecipesWithUpdateStepsArePlanned() throws {
        let scratch = try Scratch()
        let (store, image) = try image(in: scratch)
        let builder = ImageBuilder(store: store) { (_: ProgressEvent) in }
        let plans = try builder.toolsPlans(image, set: ["extras": "gemini"])
        // In the order they ran, named as the record names them, with recorded values, then
        // --set, then defaults. A recipe without update steps is there for its checks alone
        // (that it needed an input is no obstacle), and takes no --set.
        #expect(plans.map(\.recipe.name) == ["node", "xcode", "agents"])
        #expect(plans.map(\.checksOnly) == [false, true, false])
        #expect(plans.map(\.index) == [0, 1, 2])
        #expect(plans[0].recipe.parameterValues == ["channel": "beta"])
        #expect(plans[1].recipe.parameterValues == ["edition": "release"])
        #expect(plans[2].recipe.parameterValues == ["extras": "gemini"])
        #expect(reason(["edition": "beta"], image)?.contains("no recipe with update steps in tools has that parameter (they have: channel, extras)") == true)
        // Nothing to update means nothing to check either: no boot for checks alone.
        let checksOnly = try store.update(image) { $0.recipes = [$0.recipes![1]] }
        #expect(try builder.toolsPlans(checksOnly, set: [:]).isEmpty)

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

    /// An image command marks its Linux guest for as long as it holds the mark, and a second
    /// taker gets none.
    @Test func aLinuxGuestOfAnImageIsMarkedWhileItRuns() throws {
        let fixture = try BoxScratch()
        let image = fixture.image
        #expect(!fixture.images.runsLinuxMachine(image) && fixture.images.runningLinuxMachines() == 0)
        let mark = try #require(fixture.images.markLinuxMachine(of: image))
        #expect(fixture.images.runsLinuxMachine(image) && fixture.images.runningLinuxMachines() == 1)
        #expect(fixture.images.markLinuxMachine(of: image) == nil)
        // The mark is no part of a box made from the image.
        let box = try fixture.boxes.create(name: "b1", from: image, imageStore: fixture.images)
        #expect(!FileManager.default.fileExists(atPath: box.directory.appendingPathComponent(ImageStore.linuxMachineLockName).path))
        mark.release()
        #expect(!fixture.images.runsLinuxMachine(image) && fixture.images.runningLinuxMachines() == 0)
        try fixture.images.delete(named: image.name)
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
        #expect(record.isUpdateDue(system: true, tools: true, olderThanHours: 24, now: now))
        record.toolsCheckedAt = now.addingTimeInterval(-23 * 3600)
        // Each part by itself: a tools update says nothing about macOS.
        #expect(!record.isUpdateDue(system: false, tools: true, olderThanHours: 24, now: now))
        #expect(record.isUpdateDue(system: false, tools: true, olderThanHours: 23, now: now))
        #expect(record.isUpdateDue(system: true, tools: false, olderThanHours: 24, now: now))
        #expect(record.isUpdateDue(system: true, tools: true, olderThanHours: 24, now: now))
        record.macOSCheckedAt = now.addingTimeInterval(-3600)
        #expect(!record.isUpdateDue(system: true, tools: true, olderThanHours: 24, now: now))
        #expect(record.isUpdateDue(system: true, tools: true, olderThanHours: 0, now: now))
        #expect(!record.isUpdateDue(system: false, tools: false, olderThanHours: 0, now: now))
        // A Linux image's system has a stamp of its own; the macOS one says nothing about it.
        var linux = record
        linux.guest = .linux
        #expect(linux.isUpdateDue(system: true, tools: false, olderThanHours: 24, now: now))
        #expect(!linux.isUpdateDue(system: false, tools: true, olderThanHours: 24, now: now))
        linux.systemCheckedAt = now.addingTimeInterval(-3600)
        #expect(!linux.isUpdateDue(system: true, tools: true, olderThanHours: 24, now: now))
        #expect(linux.isUpdateDue(system: true, tools: false, olderThanHours: 0.5, now: now))
        // ... and a macOS image is not excused by a Linux stamp.
        record.macOSCheckedAt = nil
        record.systemCheckedAt = now
        #expect(record.isUpdateDue(system: true, tools: false, olderThanHours: 24, now: now))
        // The expected duration travels in the event's JSON.
        var event = ProgressEvent(.progress, "Booting", step: "boot")
        event.expectedSeconds = 85
        #expect(event.jsonLine.contains("\"expectedSeconds\":85"))
    }

    /// Whether a Linux system update changed anything is told by the list of installed
    /// packages before and after it.
    @Test func thePackageListTellsAChange() {
        let before = """
            adduser:all 3.152 installed
            libc6:arm64 2.41-12 installed
            linux-image-6.12.107+deb13-cloud-arm64:arm64 6.12.107-1 installed
            openssh-server:arm64 1:10.0p1-7 config-files
            zip:arm64 3.0-15 installed
            """
        #expect(LinuxSetup.packageChanges(before: before, after: before) == 0)
        #expect(LinuxSetup.packageChanges(before: before, after: before + "\n") == 0)
        // One upgraded, one removed, one added.
        let after = """
            adduser:all 3.152 installed
            libc6:arm64 2.41-12+deb13u1 installed
            linux-image-6.12.111+deb13-cloud-arm64:arm64 6.12.111-1 installed
            openssh-server:arm64 1:10.0p1-7 config-files
            zip:arm64 3.0-15 installed
            """
        #expect(LinuxSetup.packageChanges(before: before, after: after) == 3)
        // A package that is no longer installed counts, whatever dpkg still knows of it; what
        // is not a package's line does not.
        #expect(LinuxSetup.packageChanges(before: "a:arm64 1 installed\nb:arm64 1 installed", after: "a:arm64 1 installed\nb:arm64 1 config-files\nnoise") == 1)
        #expect(LinuxSetup.packageChanges(before: "", after: "") == 0)
        // The same name for two architectures is two packages.
        #expect(LinuxSetup.packageChanges(before: "a:arm64 1 installed", after: "a:arm64 1 installed\na:armhf 1 installed") == 1)
        #expect(LinuxSetup.packageList.contains("${Package}:${Architecture} ${Version} ${db:Status-Status}"))
    }

    @Test func aNewKernelAsksForASecondBoot() {
        #expect(LinuxSetup.kernelNeedsBoot(running: "6.12.107+deb13-cloud-arm64\n", newest: "/boot/vmlinuz-6.12.111+deb13-cloud-arm64\n"))
        #expect(!LinuxSetup.kernelNeedsBoot(running: "6.12.111+deb13-cloud-arm64\n", newest: "/boot/vmlinuz-6.12.111+deb13-cloud-arm64\n"))
        #expect(!LinuxSetup.kernelNeedsBoot(running: "6.12.111+deb13-cloud-arm64", newest: "/boot/vmlinuz-6.12.111+deb13-cloud-arm64"))
        // An answer that names no kernel asks for nothing.
        #expect(!LinuxSetup.kernelNeedsBoot(running: "6.12.111", newest: ""))
        #expect(!LinuxSetup.kernelNeedsBoot(running: "6.12.111", newest: "/boot/vmlinuz-"))
        #expect(!LinuxSetup.kernelNeedsBoot(running: "6.12.111", newest: "ls: cannot access"))
        // A failed list of packages must not pass for an update that found nothing: the step
        // itself fails.
        #expect(LinuxSetup.packageLists.script.contains("APT::Update::Error-Mode=any"))
        #expect(LinuxSetup.systemUpdate.map(\.name) == ["package lists", "system updates", "remove what is no longer needed"])
        #expect(LinuxSetup.systemUpdate[1].script.contains("--force-confold dist-upgrade"))
    }

    @Test func anImageBehindTheNewestMacOSIsNamed() throws {
        let asked = Date(timeIntervalSince1970: 1_800_100_000)
        let newest = NewestMacOS(version: "27.0.1", build: "26A434", checkedAt: asked)
        var record = ImageStoreTests.record("tools", state: .ready)
        record.macOSVersion = "27.0"
        record.macOSBuild = "26A428"
        #expect(newest.update(for: record) == NewestMacOS.Update(version: "27.0.1", build: "26A434", checkedAt: asked))
        // The image asked Apple itself since: softwareupdate decides, and it offered nothing.
        record.macOSCheckedAt = asked.addingTimeInterval(60)
        #expect(newest.update(for: record) == nil)
        record.macOSCheckedAt = asked.addingTimeInterval(-60)
        #expect(newest.update(for: record) != nil)
        // Up to date, ahead, another major version, or not ready: nothing to say.
        record.macOSVersion = "27.0.1"
        record.macOSBuild = "26A434"
        #expect(newest.update(for: record) == nil)
        record.macOSVersion = "27.1"
        record.macOSBuild = "26B50"
        #expect(newest.update(for: record) == nil)
        record.macOSVersion = "26.4"
        record.macOSBuild = "25E200"
        #expect(newest.update(for: record) == nil)
        #expect(NewestMacOS(version: "28.0", build: "27A300", checkedAt: asked).update(for: record) == nil)
        record.macOSVersion = "27.0"
        record.macOSBuild = "26A428"
        record.state = .failed
        #expect(newest.update(for: record) == nil)
        // The same version built again is an update; an older build of it is not.
        record.state = .ready
        record.macOSVersion = "27.0.1"
        record.macOSBuild = "26A430"
        #expect(newest.update(for: record)?.build == "26A434")
        record.macOSBuild = "26A1000"
        #expect(newest.update(for: record) == nil)
        // Kept in the store, and read back; a damaged file reads as never asked.
        let scratch = try Scratch()
        #expect(NewestMacOS.read(root: scratch.root) == nil)
        try newest.write(root: scratch.root)
        #expect(NewestMacOS.read(root: scratch.root) == newest)
        try Data("{".utf8).write(to: NewestMacOS.file(root: scratch.root))
        #expect(NewestMacOS.read(root: scratch.root) == nil)
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
