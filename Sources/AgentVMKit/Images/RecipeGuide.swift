// Sources/AgentVMKit/Images/RecipeGuide.swift
//
// The guide to writing recipes, for an AI agent that has nothing else in its context:
// Recipes/WRITING-RECIPES.md, installed with the shipped recipes in the `Recipes` folder beside
// the executable. `agent-vm recipe guide` prints it, so an agent needs no path. It is a file
// and not text built into the program, so it can also be read without running anything.

import Foundation

public enum RecipeGuide {
    public static let folderName = "Recipes"
    public static let fileName = "WRITING-RECIPES.md"

    /// Where the guide is: in `Recipes` next to the real executable (links resolved, as for
    /// packs.json and agents.json). Nil when the executable cannot be found.
    public static func url(executable: URL? = Bundle.main.executableURL) -> URL? {
        return executable?.resolvingSymlinksInPath().deletingLastPathComponent()
            .appendingPathComponent(folderName, isDirectory: true).appendingPathComponent(fileName)
    }

    /// The guide's text; a missing file is said plainly, with where it was looked for.
    public static func text(at url: URL? = url()) throws -> String {
        guard let url else {
            throw AgentVMError.recipeGuideMissing(path: "\(folderName)/\(fileName)", reason: "cannot find the agent-vm executable, so not the folder next to it")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AgentVMError.recipeGuideMissing(path: url.path, reason: error.localizedDescription)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw AgentVMError.recipeGuideMissing(path: url.path, reason: "it is not UTF-8 text")
        }
        return text
    }
}
