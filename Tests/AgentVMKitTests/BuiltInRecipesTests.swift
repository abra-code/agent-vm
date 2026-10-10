// Tests/AgentVMKitTests/BuiltInRecipesTests.swift
//
// The recipes that come with agent-vm, as `image update` sees them: a kept recipe that is an
// older version of one of them is replaced by the installed one, and nothing else is.

import Foundation
import Testing
@testable import AgentVMKit

@Suite struct BuiltInRecipesTests {
    static let old = #"{"version": 1, "steps": [{"run": "brew install python"}], "checks": ["python3 --version"]}"#
    static let new = #"{"version": 1, "steps": [{"run": "brew install python3"}], "update": [{"run": "brew install python3"}], "checks": ["python3 --version"]}"#

    /// A `Recipes` folder with one recipe, `python`, and a history of the digests given.
    static func folder(in scratch: Scratch, recipe: String, history: [String]) throws -> URL {
        let folder = scratch.root.appendingPathComponent("Recipes", isDirectory: true)
        let python = folder.appendingPathComponent("python", isDirectory: true)
        try FileManager.default.createDirectory(at: python, withIntermediateDirectories: true)
        try Data(recipe.utf8).write(to: python.appendingPathComponent("recipe.json"))
        let json = try JSONSerialization.data(withJSONObject: ["version": 1, "recipes": ["python": history]])
        try json.write(to: folder.appendingPathComponent(BuiltInRecipes.historyName))
        return folder
    }

    static func digest(_ text: String) -> String {
        return ImageRecipe.sha256(Data(text.utf8))
    }

    @Test func anOlderVersionIsReplacedByTheInstalledOne() throws {
        let scratch = try Scratch()
        let old = Self.digest(Self.old)
        let new = Self.digest(Self.new)
        let recipes = try #require(BuiltInRecipes(folder: try Self.folder(in: scratch, recipe: Self.new, history: [old, new])))
        let newer = try #require(recipes.newer(name: "python", digest: old))
        #expect(newer.digest == new && newer.name == "python" && newer.updateSteps.count == 1)
        // The installed version itself, a recipe of the person's own with the name, and a name
        // that is not a built-in recipe's.
        #expect(recipes.newer(name: "python", digest: new) == nil)
        #expect(recipes.newer(name: "python", digest: Self.digest("mine")) == nil)
        #expect(recipes.newer(name: "node", digest: old) == nil)
        #expect(recipes.newer(name: "../python", digest: old) == nil)
    }

    @Test func aFolderThatIsNotWhatWasShippedReplacesNothing() throws {
        let scratch = try Scratch()
        let old = Self.digest(Self.old)
        // The installed recipe was changed by hand: its digest is not in the history.
        let changed = try #require(BuiltInRecipes(folder: try Self.folder(in: scratch, recipe: Self.new, history: [old])))
        #expect(changed.newer(name: "python", digest: old) == nil)
        // No history, or one that cannot be read: no recipes at all.
        let folder = scratch.root.appendingPathComponent("Recipes", isDirectory: true)
        try Data("{".utf8).write(to: folder.appendingPathComponent(BuiltInRecipes.historyName))
        #expect(BuiltInRecipes(folder: folder) == nil)
        try FileManager.default.removeItem(at: folder.appendingPathComponent(BuiltInRecipes.historyName))
        #expect(BuiltInRecipes(folder: folder) == nil)
        #expect(BuiltInRecipes.installed(executable: nil) == nil)
    }

    /// Scripts/recipe-history.py was run after the last change to a recipe: an image built
    /// with today's recipes must be recognized by the agent-vm that comes next.
    @Test func everyShippedRecipeIsInTheHistory() throws {
        let folder = RecipeGuideTests.recipesFolder
        let recipes = try #require(BuiltInRecipes(folder: folder))
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).appendingPathComponent("recipe.json").path)
        }
        #expect(names.count >= 10)
        for name in names {
            let recipe = try ImageRecipe.load(from: folder.appendingPathComponent(name).appendingPathComponent("recipe.json"))
            #expect(recipes.history[name]?.contains(recipe.digest) == true, "run python3 Scripts/recipe-history.py: \(name) changed")
        }
        #expect(Set(recipes.history.keys) == Set(names))
    }
}
