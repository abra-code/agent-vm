// Tests/AgentVMKitTests/RecipeCheckTests.swift
//
// `agent-vm recipe check`: the loader's errors per file, several files as one build takes them,
// values checked only when given, and the warnings.

import Foundation
import Testing
@testable import AgentVMKit

@Suite struct RecipeCheckTests {
    /// Writes `json` as `<name>/recipe.json` in the scratch folder and returns its path.
    func write(_ json: String, as name: String = "recipe", in scratch: Scratch) throws -> String {
        let folder = scratch.root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("recipe.json")
        try Data(json.utf8).write(to: url)
        return url.path
    }

    func findings(_ json: String) throws -> (warnings: [RecipeCheck.Finding], notes: [RecipeCheck.Finding]) {
        let scratch = try Scratch()
        let report = try #require(RecipeCheck.check(paths: [try write(json, in: scratch)]).recipes.first)
        #expect(report.error == nil)
        return (report.warnings, report.notes)
    }

    func codes(_ json: String) throws -> [String] {
        return try findings(json).warnings.map { "\($0.code) @ \($0.place)" }
    }

    @Test func aGoodRecipeIsDescribed() throws {
        let scratch = try Scratch()
        let path = try write("""
            {
              "version": 1,
              "description": "A tool",
              "inputs": { "archive": { "description": "the tool's archive" } },
              "parameters": { "release": { "description": "which release", "default": "stable" }, "extras": {} },
              "steps": [
                { "run": "tar xf \\"$AGENT_VM_INPUT_ARCHIVE\\" -C /opt/tool" },
                { "run": "/opt/tool/install --release \\"$AGENT_VM_PARAM_RELEASE\\" $AGENT_VM_PARAM_EXTRAS" }
              ],
              "update": [{ "run": "/opt/tool/bin/tool self-update --release \\"$AGENT_VM_PARAM_RELEASE\\"" }],
              "checks": ["tool --version"]
            }
            """, as: "tool", in: scratch)
        let result = RecipeCheck.check(paths: [path])
        #expect(!result.hasErrors && !result.hasWarnings && result.error == nil)
        let report = try #require(result.recipes.first)
        #expect(report.path == path && report.name == "tool" && report.description == "A tool")
        #expect(report.digest == (try ImageRecipe.load(from: URL(fileURLWithPath: path))).digest)
        #expect(report.steps == 2 && report.updateSteps == 1 && report.checks == 1)
        #expect(report.inputs == [RecipeCheck.Declared(name: "archive", description: "the tool's archive", default: nil)])
        #expect(report.parameters == [RecipeCheck.Declared(name: "extras", description: nil, default: nil),
                                      RecipeCheck.Declared(name: "release", description: "which release", default: "stable")])
        #expect(report.warnings.isEmpty && report.notes.isEmpty)
    }

    /// The error is the loader's reason, word for word, and one bad file does not hide the
    /// verdict on the others.
    @Test func eachFileGetsTheLoadersOwnError() throws {
        let scratch = try Scratch()
        let good = try write(#"{"version": 1, "steps": [{"run": "true"}], "update": [{"run": "true"}], "checks": ["true"]}"#, as: "good", in: scratch)
        let misspelled = try write(#"{"version": 1, "steps": [{"run": "true", "usr": "root"}]}"#, as: "misspelled", in: scratch)
        let notJSON = try write("{", as: "broken", in: scratch)
        let missing = scratch.root.appendingPathComponent("none.json").path
        let result = RecipeCheck.check(paths: [misspelled, good, notJSON, missing])
        #expect(result.hasErrors && result.error == nil)
        #expect(result.recipes.map(\.path) == [misspelled, good, notJSON, missing])
        for (report, path) in zip(result.recipes, [misspelled, good, notJSON, missing]) {
            var expected: String?
            do {
                _ = try ImageRecipe.load(from: URL(fileURLWithPath: path))
            } catch let AgentVMError.invalidRecipe(_, reason) {
                expected = reason
            }
            #expect(report.error == expected)
            #expect((report.name == nil) == (expected != nil))
        }
        #expect(result.recipes[0].error?.contains("unknown key \"usr\"") == true)
        #expect(result.recipes[1].error == nil && result.recipes[1].steps == 1)
        #expect(result.recipes[3].error?.hasPrefix("cannot read it") == true)
    }

    @Test func theSameRecipeTwiceIsSaidAboutTheSecond() throws {
        let scratch = try Scratch()
        let text = #"{"version": 1, "steps": [{"run": "true"}], "checks": ["true"]}"#
        let first = try write(text, as: "one", in: scratch)
        let second = try write(text, as: "two", in: scratch)
        let result = RecipeCheck.check(paths: [first, second])
        #expect(result.recipes[0].error == nil)
        #expect(result.recipes[1].error == "it is given twice")
        // As a build says it.
        let recipes = try [first, second].map { try ImageRecipe.load(from: URL(fileURLWithPath: $0)) }
        #expect(throws: AgentVMError.invalidRecipe(path: second, reason: "it is given twice")) {
            _ = try ImageRecipe.binding(recipes, inputs: [:], parameters: [:])
        }
    }

    /// Without --input or --set a missing value is no mistake; with one given, everything a
    /// build checks is checked.
    @Test func valuesAreCheckedOnlyWhenGiven() throws {
        let scratch = try Scratch()
        let path = try write("""
            {"version": 1, "inputs": {"archive": {}}, "parameters": {"release": {}},
             "steps": [{"run": "x \\"$AGENT_VM_INPUT_ARCHIVE\\" $AGENT_VM_PARAM_RELEASE"}], "update": [{"run": "true"}], "checks": ["true"]}
            """, in: scratch)
        #expect(!RecipeCheck.check(paths: [path]).hasErrors)

        let file = scratch.root.appendingPathComponent("archive.tar")
        try Data("x".utf8).write(to: file)
        #expect(!RecipeCheck.check(paths: [path], inputs: ["archive": file.path], parameters: ["release": "1"]).hasErrors)
        var result = RecipeCheck.check(paths: [path], parameters: ["release": "1"])
        #expect(result.recipes[0].error?.hasPrefix("it needs --input archive=PATH") == true)
        result = RecipeCheck.check(paths: [path], inputs: ["archive": scratch.root.appendingPathComponent("gone").path], parameters: ["release": "1"])
        #expect(result.recipes[0].error?.contains("does not exist") == true)
        result = RecipeCheck.check(paths: [path], inputs: ["archive": file.path])
        #expect(result.recipes[0].error?.hasPrefix("it needs --set release=VALUE") == true)
        result = RecipeCheck.check(paths: [path], inputs: ["archive": file.path], parameters: ["release": "1", "nope": "2"])
        #expect(result.recipes[0].error?.hasPrefix("it has no parameter nope") == true)
    }

    /// Several recipes: a name goes to those that declare it, and one that none declares is
    /// an error about them together. Not looked at when a file does not load.
    @Test func valuesGoToTheRecipesThatDeclareThem() throws {
        let scratch = try Scratch()
        let one = try write(#"{"version": 1, "parameters": {"release": {"default": "a"}}, "steps": [{"run": "x $AGENT_VM_PARAM_RELEASE"}], "checks": ["true"]}"#, as: "one", in: scratch)
        let two = try write(#"{"version": 1, "steps": [{"run": "true"}], "checks": ["true"]}"#, as: "two", in: scratch)
        #expect(!RecipeCheck.check(paths: [one, two], parameters: ["release": "b"]).hasErrors)
        let result = RecipeCheck.check(paths: [one, two], parameters: ["other": "b"])
        #expect(result.hasErrors && result.recipes.allSatisfy { $0.error == nil })
        #expect(result.error == "none of the recipes has a parameter other (they have: release)")

        let broken = try write("{", as: "broken", in: scratch)
        let partial = RecipeCheck.check(paths: [one, broken], parameters: ["other": "b"])
        #expect(partial.error == nil && partial.recipes[0].error == nil && partial.recipes[1].error != nil)
    }

    @Test func sudoIsFoundAsACommandOnly() throws {
        for command in ["sudo make install", "cd /tmp && sudo ./install", "a;sudo b", "echo x | sudo tee /etc/y", "(sudo true)", "if ! sudo -n true; then exit 1; fi", "x=$(sudo id)", "sudo",
                        "/usr/bin/sudo make install", "cd /tmp && /usr/bin/sudo -n true"] {
            #expect(RecipeCheck.usesSudo(command), "\(command)")
        }
        for command in ["pseudo-tool --run", "cat /etc/sudoers", "ls /usr/bin/sudo", "echo sudo-rs", "brew install sudoku", "visudo -c"] {
            #expect(!RecipeCheck.usesSudo(command), "\(command)")
        }
        #expect(try codes(#"{"version": 1, "steps": [{"run": "true"}, {"run": "sudo true"}], "update": [{"run": "sudo softwareupdate"}], "checks": ["sudo -n true"]}"#)
            == ["sudo @ step 2", "sudo @ update step 1", "sudo @ check 1"])
        // Root is asked for no password: a root step may use sudo to run one thing as the box user.
        #expect(try codes(#"{"version": 1, "steps": [{"user": "root", "run": "sudo -u \"$AGENT_VM_BOX_USER\" true"}], "update": [{"user": "root", "run": "sudo -u x true"}], "checks": ["true"]}"#).isEmpty)
    }

    /// A variable read only by a script the recipe copies is used.
    @Test func aCopiedScriptThatReadsAVariableUsesIt() throws {
        let scratch = try Scratch()
        let path = try write("""
            {"version": 1, "inputs": {"archive": {}}, "parameters": {"release": {"default": "a"}, "spare": {"default": ""}},
             "steps": [{"copy": "files/install.sh", "to": "/usr/local/bin/install-tool", "mode": "0755", "user": "root"}, {"run": "install-tool"}],
             "update": [{"run": "true"}], "checks": ["true"]}
            """, in: scratch)
        let files = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("files")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try Data("#!/bin/sh\ntar xf \"$AGENT_VM_INPUT_ARCHIVE\" && ./setup --release \"$AGENT_VM_PARAM_RELEASE\"\n".utf8).write(to: files.appendingPathComponent("install.sh"))
        let report = try #require(RecipeCheck.check(paths: [path]).recipes.first)
        #expect(report.error == nil)
        #expect(report.warnings.map { "\($0.code) @ \($0.place)" } == ["unused-parameter @ parameter spare"])
    }

    @Test func variablesMustBeDeclaredAndUsed() throws {
        #expect(try codes("""
            {"version": 1, "inputs": {"archive": {}, "spare": {}}, "parameters": {"release": {"default": "a"}, "unused": {"default": ""}},
             "steps": [{"run": "x $AGENT_VM_INPUT_ARCHIVE ${AGENT_VM_PARAM_RELEASE} $AGENT_VM_INPUT_OTHER $AGENT_VM_PARAM_MISSING"}],
             "update": [{"run": "true"}], "checks": ["true"]}
            """) == ["undeclared-input @ step 1", "undeclared-parameter @ step 1", "unused-input @ input spare", "unused-parameter @ parameter unused"])
        // The name ends where a shell ends it.
        let used = RecipeCheck.variables(in: #"a "$AGENT_VM_INPUT_XCODE"/x ${AGENT_VM_PARAM_A_B}c $AGENT_VM_PARAM_V2.tar AGENT_VM_BOX_USER"#)
        #expect(used.inputs == ["xcode"] && used.parameters == ["a_b", "v2"] && used.misspelled.isEmpty)
        // A shell tells AGENT_VM_PARAM_release from AGENT_VM_PARAM_RELEASE: the first is never set.
        let lower = try findings(#"{"version": 1, "parameters": {"release": {"default": "a"}}, "steps": [{"run": "x $AGENT_VM_PARAM_release"}], "update": [{"run": "true"}], "checks": ["true"]}"#)
        #expect(lower.warnings.map { "\($0.code) @ \($0.place)" } == ["undeclared-parameter @ step 1", "unused-parameter @ parameter release"])
        #expect(lower.warnings.first?.message.contains("AGENT_VM_PARAM_release, which is never set") == true)
    }

    /// An input is gone after the build: an update step or a check that names it runs without it.
    @Test func inputsAreNotThereAfterTheBuild() throws {
        let all = try findings("""
            {"version": 1, "inputs": {"archive": {}},
             "steps": [{"run": "x $AGENT_VM_INPUT_ARCHIVE"}],
             "update": [{"run": "x $AGENT_VM_INPUT_ARCHIVE"}],
             "checks": ["test -f $AGENT_VM_INPUT_ARCHIVE"]}
            """)
        #expect(all.warnings.map { "\($0.code) @ \($0.place)" } == ["input-in-update @ update step 1", "input-in-check @ check 1"])
        #expect(all.warnings.allSatisfy { $0.message.contains("AGENT_VM_INPUT_ARCHIVE") })
        // Used only where it is gone: still not "unused".
        #expect(try codes(#"{"version": 1, "inputs": {"archive": {}}, "steps": [{"run": "true"}], "update": [{"run": "true"}], "checks": ["ls $AGENT_VM_INPUT_ARCHIVE"]}"#)
            == ["input-in-check @ check 1"])
    }

    @Test func aParameterNamedLikeASecretIsWarnedAbout() throws {
        for name in ["token", "api_key", "db_password", "npm_token", "secret", "keys", "credentials"] {
            #expect(RecipeCheck.looksLikeASecret(name), "\(name)")
        }
        for name in ["monkey", "tokenizer", "keyboard", "platforms", "release", "passes"] {
            #expect(!RecipeCheck.looksLikeASecret(name), "\(name)")
        }
        #expect(try codes(#"{"version": 1, "parameters": {"api_key": {}}, "steps": [{"run": "x $AGENT_VM_PARAM_API_KEY"}], "update": [{"run": "true"}], "checks": ["true"]}"#)
            == ["secret-parameter @ parameter api_key"])
    }

    /// No checks is a warning; steps without update steps is a note, which is not a warning.
    @Test func noChecksWarnsAndNoUpdateIsANote() throws {
        var all = try findings(#"{"version": 1, "steps": [{"run": "true"}]}"#)
        #expect(all.warnings.map(\.code) == ["no-checks"] && all.notes.map(\.code) == ["no-update"])
        all = try findings(#"{"version": 1, "steps": [{"run": "true"}], "checks": ["true"]}"#)
        #expect(all.warnings.isEmpty && all.notes.map(\.code) == ["no-update"])
        // Nothing to update when nothing is installed; copy steps have no command to read.
        all = try findings(#"{"version": 1, "checks": ["true"]}"#)
        #expect(all.warnings.isEmpty && all.notes.isEmpty)
        let scratch = try Scratch()
        let path = try write(#"{"version": 1, "steps": [{"run": "true"}], "checks": ["true"]}"#, in: scratch)
        let result = RecipeCheck.check(paths: [path])
        #expect(!result.hasWarnings && !result.hasErrors)
    }

    /// The recipes this repository ships load, and have no warnings.
    @Test func theShippedRecipesPass() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Recipes")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted().filter {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).appendingPathComponent("recipe.json").path)
        }
        #expect(names.count >= 7)
        let result = RecipeCheck.check(paths: names.map { folder.appendingPathComponent($0).appendingPathComponent("recipe.json").path })
        for report in result.recipes {
            #expect(report.error == nil, "\(report.path)")
            #expect(report.warnings.isEmpty, "\(report.path): \(report.warnings)")
        }
    }

    /// The JSON the application reads: these keys, and nothing about a file that does not load
    /// but its path and error.
    @Test func theJSONHasTheKeysTheApplicationReads() throws {
        let scratch = try Scratch()
        let good = try write(#"{"version": 1, "description": "d", "parameters": {"token": {"default": "x"}}, "steps": [{"run": "sudo x"}]}"#, as: "good", in: scratch)
        let bad = try write("[]", as: "bad", in: scratch)
        let data = try JSONEncoder().encode(RecipeCheck.check(paths: [good, bad]))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let recipes = try #require(object["recipes"] as? [[String: Any]])
        #expect(Set(recipes[0].keys) == ["path", "name", "description", "digest", "steps", "updateSteps", "checks", "inputs", "parameters", "warnings", "notes"])
        let parameter = try #require((recipes[0]["parameters"] as? [[String: Any]])?.first)
        #expect(parameter["name"] as? String == "token" && parameter["default"] as? String == "x")
        let warning = try #require((recipes[0]["warnings"] as? [[String: Any]])?.first)
        #expect(Set(warning.keys) == ["code", "place", "message"])
        #expect(Set(recipes[1].keys) == ["path", "error", "warnings", "notes"])
        #expect(object["error"] == nil)
    }
}
