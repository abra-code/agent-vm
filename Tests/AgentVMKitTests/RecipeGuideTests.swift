// Tests/AgentVMKitTests/RecipeGuideTests.swift
//
// The guide for agents (Recipes/WRITING-RECIPES.md) against the program: its key tables list
// exactly the keys the loader knows, its example is a recipe that passes the check, and the
// file is found next to an executable.

import Foundation
import Testing
@testable import AgentVMKit

@Suite struct RecipeGuideTests {
    static let recipesFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(RecipeGuide.folderName, isDirectory: true)

    func guide() throws -> String {
        return try RecipeGuide.text(at: Self.recipesFolder.appendingPathComponent(RecipeGuide.fileName))
    }

    /// The keys in the first column of the table under `heading`: each row's first cell, a
    /// name in backquotes.
    func keys(under heading: String, in guide: String) throws -> Set<String> {
        let lines = guide.components(separatedBy: "\n")
        let start = try #require(lines.firstIndex(of: heading), "no heading \(heading)")
        var keys = Set<String>()
        for line in lines[(start + 1)...] {
            if line.hasPrefix("#") {
                break
            }
            guard line.hasPrefix("| `"), let end = line.dropFirst(3).firstIndex(of: "`") else {
                continue
            }
            keys.insert(String(line.dropFirst(3)[..<end]))
        }
        return keys
    }

    /// A key the loader learns must reach the guide, and the guide must not name one the
    /// loader refuses: an agent has only the guide.
    @Test func theGuidesTablesListTheKeysTheLoaderKnows() throws {
        let guide = try guide()
        #expect(try keys(under: "### Recipe keys", in: guide) == ImageRecipe.recipeKeys)
        #expect(try keys(under: "### Step keys", in: guide) == ImageRecipe.stepKeys)
        #expect(try keys(under: "### Input keys", in: guide) == ImageRecipe.inputKeys)
        #expect(try keys(under: "### Parameter keys", in: guide) == ImageRecipe.parameterKeys)
    }

    /// The loader refuses a key outside those sets, so the sets are what it knows.
    @Test func theLoaderRefusesAKeyOutsideItsSets() throws {
        for (json, place) in [(#"{"version": 1, "nope": 1}"#, "the recipe"), (#"{"version": 1, "steps": [{"run": "true", "nope": 1}]}"#, "step 1"),
                              (#"{"version": 1, "inputs": {"a": {"nope": 1}}}"#, "input a"), (#"{"version": 1, "parameters": {"a": {"nope": 1}}}"#, "parameter a")] {
            #expect(throws: AgentVMError.self, "\(place)") {
                _ = try ImageRecipe.parse(Data(json.utf8), folder: URL(fileURLWithPath: "/nowhere"), path: "recipe.json")
            }
        }
    }

    /// The guide's full example, written out with the file it copies, passes `recipe check`
    /// without a warning or a note: what the guide shows is what it asks for.
    @Test func theGuidesExampleIsAGoodRecipe() throws {
        let guide = try guide()
        let section = try #require(guide.components(separatedBy: "### A full example\n").last)
        let block = try #require(section.components(separatedBy: "```json\n").dropFirst().first?.components(separatedBy: "\n```").first)
        let scratch = try Scratch()
        let folder = scratch.root.appendingPathComponent("ripgrep", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("files"), withIntermediateDirectories: true)
        try Data("--smart-case\n".utf8).write(to: folder.appendingPathComponent("files/ripgreprc"))
        let file = folder.appendingPathComponent("recipe.json")
        try Data(block.utf8).write(to: file)
        let report = try #require(RecipeCheck.check(paths: [file.path]).recipes.first)
        #expect(report.error == nil)
        #expect(report.warnings.isEmpty, "\(report.warnings)")
        #expect(report.notes.isEmpty, "\(report.notes)")
        #expect(report.name == "ripgrep" && report.steps == 4 && report.updateSteps == 1 && report.checks == 2)
    }

    /// The recipes the guide's last table names are the ones shipped.
    @Test func theGuideNamesEveryShippedRecipe() throws {
        let guide = try guide()
        let shipped = try FileManager.default.contentsOfDirectory(atPath: Self.recipesFolder.path).filter {
            FileManager.default.fileExists(atPath: Self.recipesFolder.appendingPathComponent($0).appendingPathComponent("recipe.json").path)
        }
        #expect(!shipped.isEmpty)
        for name in shipped {
            #expect(guide.contains("| `\(name)/recipe.json` |"), "\(name)")
        }
    }

    /// Plain text for any reader: ASCII only.
    @Test func theGuideIsASCII() throws {
        let guide = try guide()
        let odd = guide.unicodeScalars.filter { !$0.isASCII }
        #expect(odd.isEmpty, "\(odd.prefix(5).map { String($0) })")
    }

    /// Found in Recipes next to the real executable, through a link; a missing one says where
    /// it was looked for.
    @Test func theGuideIsFoundNextToTheExecutable() throws {
        let scratch = try Scratch()
        let version = scratch.root.appendingPathComponent("versions/1", isDirectory: true)
        try FileManager.default.createDirectory(at: version.appendingPathComponent("Recipes"), withIntermediateDirectories: true)
        let executable = version.appendingPathComponent("agent-vm")
        try Data().write(to: executable)
        let link = scratch.root.appendingPathComponent("avm")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        let url = try #require(RecipeGuide.url(executable: link))
        #expect(url.path.hasSuffix("/versions/1/Recipes/WRITING-RECIPES.md"))
        #expect(throws: AgentVMError.self) {
            _ = try RecipeGuide.text(at: url)
        }
        do {
            _ = try RecipeGuide.text(at: url)
        } catch {
            #expect("\(error)".contains(url.path))
        }
        try Data("the guide\n".utf8).write(to: url)
        #expect(try RecipeGuide.text(at: url) == "the guide\n")
        #expect(throws: AgentVMError.self) {
            _ = try RecipeGuide.text(at: nil)
        }
    }
}
