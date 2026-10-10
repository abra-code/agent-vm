// Sources/AgentVMKit/Images/BuiltInRecipes.swift
//
// The recipes that come with agent-vm (the `Recipes` folder next to the executable), for
// `image update`. An image keeps a copy of each recipe it was built with, and its tools update
// runs those copies, so a recipe corrected in a later agent-vm would never reach an image built
// before. `Recipes/history.json` (written by Scripts/recipe-history.py) lists the digest of
// every version each built-in recipe ever had. A kept recipe whose digest is listed under its
// name is one of ours, and the installed recipe of that name takes its place when it is another
// version. A recipe of the person's own with the same name is not in the list and is left as
// the image keeps it.

import Foundation

public struct BuiltInRecipes: Sendable {
    public static let historyName = "history.json"

    /// The `Recipes` folder.
    public let folder: URL
    /// Each recipe's name and the digests of all its versions.
    let history: [String: Set<String>]

    private struct History: Decodable {
        var version: Int
        var recipes: [String: [String]]
    }

    /// The recipes next to the real executable (links resolved, as for packs.json); nil when
    /// the folder or its history is not there or cannot be read: then no recipe is replaced.
    public static func installed(executable: URL? = Bundle.main.executableURL) -> BuiltInRecipes? {
        guard let executable else {
            return nil
        }
        return BuiltInRecipes(folder: executable.resolvingSymlinksInPath().deletingLastPathComponent()
            .appendingPathComponent(RecipeGuide.folderName, isDirectory: true))
    }

    public init?(folder: URL) {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(Self.historyName)),
              let history = try? JSONDecoder().decode(History.self, from: data), history.version == 1 else {
            return nil
        }
        self.folder = folder
        self.history = history.recipes.mapValues(Set.init)
    }

    /// The installed recipe that takes the place of the kept recipe `name` with `digest`: nil
    /// when the kept one is not a version of a built-in recipe, when it is the installed
    /// version, and when the installed one cannot be loaded or is not in the history itself
    /// (a folder someone changed by hand is not what agent-vm shipped).
    public func newer(name: String, digest: String) -> ImageRecipe? {
        // The name becomes a folder's: never one that leads elsewhere.
        guard name.range(of: #"^[A-Za-z0-9_][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil,
              let known = history[name], known.contains(digest) else {
            return nil
        }
        let url = folder.appendingPathComponent(name, isDirectory: true).appendingPathComponent(ImageStore.recipeName)
        guard let recipe = try? ImageRecipe.load(from: url), recipe.digest != digest, known.contains(recipe.digest) else {
            return nil
        }
        return recipe
    }
}
