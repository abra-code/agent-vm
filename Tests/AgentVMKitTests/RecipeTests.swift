// Tests/AgentVMKitTests/RecipeTests.swift
//
// Image recipes: parsing, the checks that turn mistakes into clear errors before any image is
// built, copy sources confined to the recipe's folder, and the digest.

import Foundation
import Testing
@testable import AgentVMKit

@Suite struct RecipeTests {
    /// A recipe folder with `recipe.json` holding `json`, and optional extra files.
    func recipe(_ json: String, files: [String: String] = [:], in scratch: Scratch) throws -> URL {
        let folder = scratch.root.appendingPathComponent("recipe", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, text) in files {
            let url = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let url = folder.appendingPathComponent("recipe.json")
        try Data(json.utf8).write(to: url)
        return url
    }

    func reason(_ url: URL) -> String? {
        do {
            _ = try ImageRecipe.load(from: url)
            return nil
        } catch let AgentVMError.invalidRecipe(_, reason) {
            return reason
        } catch {
            return "\(error)"
        }
    }

    @Test func aFullRecipeParses() throws {
        let scratch = try Scratch()
        let url = try recipe("""
            {
              "version": 1,
              "description": "tools",
              "commandLineTools": false,
              "steps": [
                { "name": "folder", "user": "root", "run": "mkdir -p /opt/x", "env": { "A_B": "1" }, "timeoutSeconds": 60 },
                { "copy": "files/gitconfig", "to": "~/.gitconfig" },
                { "name": "script", "copy": "bin/tool.sh", "to": "/usr/local/bin/tool", "mode": "0755", "user": "root" }
              ],
              "checks": ["git --version", "tool --help"]
            }
            """, files: ["files/gitconfig": "[user]\n", "bin/tool.sh": "#!/bin/sh\n"], in: scratch)
        let parsed = try ImageRecipe.load(from: url)
        #expect(parsed.description == "tools")
        #expect(parsed.commandLineTools == false)
        #expect(parsed.steps.count == 3)
        #expect(parsed.steps[0] == ImageRecipe.Step(name: "folder", action: .run("mkdir -p /opt/x"), user: "root", environment: ["A_B": "1"], timeoutSeconds: 60))
        #expect(parsed.steps[1].name == "step 2")
        #expect(parsed.steps[1].user == nil)
        #expect(parsed.steps[1].timeoutSeconds == ImageRecipe.defaultTimeoutSeconds)
        if case let .copy(source, destination, mode) = parsed.steps[2].action {
            #expect(source.lastPathComponent == "tool.sh")
            #expect(destination == "/usr/local/bin/tool")
            #expect(mode == "0755")
        } else {
            Issue.record("expected a copy step")
        }
        #expect(parsed.checks == ["git --version", "tool --help"])
        #expect(parsed.digest.count == 64)
    }

    @Test func aRecipeIsNamedAfterItsFolderOrFile() {
        #expect(ImageRecipe.name(for: URL(fileURLWithPath: "/r/Recipes/xcode/recipe.json")) == "xcode")
        #expect(ImageRecipe.name(for: URL(fileURLWithPath: "/r/my tools.json")) == "my-tools")
        #expect(ImageRecipe.name(for: URL(fileURLWithPath: "/r/xcode/../node/recipe.json")) == "node")
        #expect(ImageRecipe.name(for: URL(fileURLWithPath: "/recipe.json")) == "recipe")
        #expect(ImageRecipe.name(for: URL(fileURLWithPath: "/r/" + String(repeating: "a", count: 60) + ".json")).count == 40)
    }

    @Test func aStoredCopyLoadsWithTheSameDigest() throws {
        let scratch = try Scratch()
        let url = try recipe(#"{"version": 1, "steps": [{"copy": "files/a", "to": "/tmp/a"}, {"run": "true"}, {"copy": "sub/../b", "to": "/tmp/b"}]}"#,
                             files: ["files/a": "one", "b": "two", "sub/other": ""], in: scratch)
        let original = try ImageRecipe.load(from: url)
        #expect(original.name == "recipe")
        let folder = scratch.root.appendingPathComponent("kept/1-recipe", isDirectory: true)
        try original.write(to: folder)
        let copy = try ImageRecipe.load(from: folder.appendingPathComponent("recipe.json"))
        #expect(copy.digest == original.digest)
        #expect(copy.steps.count == 3)
        #expect(try String(contentsOf: folder.appendingPathComponent("files/a"), encoding: .utf8) == "one")
        #expect(try String(contentsOf: folder.appendingPathComponent("b"), encoding: .utf8) == "two")

        // A file edited after the recipe was read is not stored under the old digest.
        try Data("changed".utf8).write(to: url.deletingLastPathComponent().appendingPathComponent("b"))
        #expect(throws: AgentVMError.self) { try original.write(to: scratch.root.appendingPathComponent("kept/2-recipe", isDirectory: true)) }
    }

    @Test func aStoredCopyKeepsAByteOrderMarkAndLinkedFiles() throws {
        let scratch = try Scratch()
        let url = try recipe("", files: ["tools/real": "one"], in: scratch)
        let source = url.deletingLastPathComponent()
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "tools/real")
        try (Data([0xEF, 0xBB, 0xBF]) + Data(#"{"version": 1, "steps": [{"copy": "link", "to": "/tmp/a"}]}"#.utf8)).write(to: url)
        let original = try ImageRecipe.load(from: url)
        // A folder URL without the trailing slash is still the folder.
        let folder = URL(fileURLWithPath: scratch.root.path + "/kept/1-recipe")
        try original.write(to: folder)
        let copy = try ImageRecipe.load(from: folder.appendingPathComponent("recipe.json"))
        #expect(copy.digest == original.digest)
        #expect(try Data(contentsOf: folder.appendingPathComponent("recipe.json")) == Data(contentsOf: url))
        #expect(try String(contentsOf: folder.appendingPathComponent("link"), encoding: .utf8) == "one")
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.root.appendingPathComponent("kept").path) == ["1-recipe"])
    }

    @Test func aCopySourceTheImageCouldNotKeepIsRefused() throws {
        let scratch = try Scratch()
        // Out of the folder and back in: the stored folder has another name.
        var url = try recipe(#"{"version": 1, "steps": [{"copy": "../recipe/a", "to": "/tmp/a"}]}"#, files: ["a": "one", "sub/a": "two", "sub/deep/x": ""], in: scratch)
        #expect(reason(url)?.contains("goes out of the recipe's folder and back") == true)
        // Through a link, ".." is another folder than the name says.
        let source = url.deletingLastPathComponent()
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("linked").path, withDestinationPath: "sub/deep")
        url = try recipe(#"{"version": 1, "steps": [{"copy": "linked/../a", "to": "/tmp/a"}]}"#, in: scratch)
        #expect(reason(url)?.contains("goes through a link") == true)
        // Another file where the stored recipe goes.
        let named = source.appendingPathComponent("tools.json")
        try Data(#"{"version": 1, "steps": [{"copy": "recipe.json", "to": "/tmp/a"}]}"#.utf8).write(to: named)
        #expect(reason(named)?.contains("the image keeps the recipe as recipe.json") == true)
        // A recipe may copy itself.
        url = try recipe(#"{"version": 1, "steps": [{"copy": "recipe.json", "to": "/tmp/a"}, {"copy": "./sub//a", "to": "/tmp/b"}]}"#, in: scratch)
        #expect(reason(url) == nil)
        #expect(ImageRecipe.pathInsideFolder("sub/../../x") == nil)
        #expect(ImageRecipe.pathInsideFolder("sub/..") == nil)
        #expect(ImageRecipe.pathInsideFolder("./sub//a/../b") == "sub/b")
    }

    @Test func severalRecipesShareInputsAndParameters() throws {
        let scratch = try Scratch()
        func load(_ name: String, _ json: String) throws -> ImageRecipe {
            let url = scratch.root.appendingPathComponent(name + ".json")
            try Data(json.utf8).write(to: url)
            return try ImageRecipe.load(from: url)
        }
        func reason(_ body: () throws -> Any) -> String? {
            do {
                _ = try body()
                return nil
            } catch let AgentVMError.invalidRecipe(_, reason) {
                return reason
            } catch {
                return "\(error)"
            }
        }
        let node = try load("node", #"{"version": 1, "parameters": {"channel": {"default": "lts"}}}"#)
        let agents = try load("agents", #"{"version": 1, "parameters": {"channel": {"default": "stable"}, "extras": {"default": ""}}}"#)
        let xcode = try load("xcode", #"{"version": 1, "inputs": {"xcode": {}}}"#)
        let xip = scratch.root.appendingPathComponent("Xcode.xip")
        try Data("xip".utf8).write(to: xip)

        let bound = try ImageRecipe.binding([node, agents, xcode], inputs: ["xcode": xip.path], parameters: ["channel": "beta"])
        #expect(bound.map(\.name) == ["node", "agents", "xcode"])
        #expect(bound[0].parameterValues == ["channel": "beta"])
        #expect(bound[1].parameterValues == ["channel": "beta", "extras": ""])
        #expect(bound[2].inputFiles["xcode"]?.lastPathComponent == "Xcode.xip")
        // Without a value each keeps its own default.
        let defaults = try ImageRecipe.binding([node, agents], inputs: [:], parameters: [:])
        #expect(defaults[0].parameterValues["channel"] == "lts")
        #expect(defaults[1].parameterValues["channel"] == "stable")

        #expect(reason { try ImageRecipe.binding([node, agents], inputs: [:], parameters: ["size": "1"]) }?
            .contains("none of the recipes has a parameter size (they have: channel, extras)") == true)
        #expect(reason { try ImageRecipe.binding([node, agents], inputs: ["xcode": xip.path], parameters: [:]) }?
            .contains("none of the recipes has an input xcode") == true)
        #expect(reason { try ImageRecipe.binding([node, xcode], inputs: [:], parameters: [:]) }?.contains("needs --input xcode=PATH") == true)
        #expect(reason { try ImageRecipe.binding([node, agents, node], inputs: [:], parameters: [:]) }?.contains("given twice") == true)
        // One recipe refuses in its own words.
        #expect(reason { try ImageRecipe.binding([node], inputs: [:], parameters: ["size": "1"]) }?.contains("it has no parameter size") == true)
        #expect(try ImageRecipe.binding([], inputs: [:], parameters: [:]).isEmpty)
    }

    @Test func severalRecipesAreRecordedAsOne() {
        typealias Info = ImageRecord.RecipeInfo
        #expect(Info.combined([]) == nil)
        let node = Info(description: "Node", digest: "aa", parameters: ["channel": "lts"], name: "node", folder: "1-node")
        // One recipe is recorded as it always was.
        #expect(Info.combined([node]) == Info(description: "Node", digest: "aa", parameters: ["channel": "lts"]))
        let input = ImageRecord.InputInfo(name: "xcode", file: "Xcode.xip", bytes: 3, sha256: "cc")
        let xcode = Info(description: nil, digest: "bb", inputs: [input], parameters: ["channel": "beta", "platforms": "iOS"], name: "xcode", folder: "2-xcode")
        let both = Info.combined([node, xcode])
        #expect(both?.description == "Node; xcode")
        #expect(both?.digest == ImageRecipe.sha256(Data("aa\nbb".utf8)))
        #expect(both?.digest != Info.combined([xcode, node])?.digest)
        #expect(both?.inputs == [input])
        // Each kept its own default for channel: the combined entry names neither.
        #expect(both?.parameters == ["platforms": "iOS"])
        let set = Info.combined([node, Info(description: nil, digest: "bb", inputs: [input], parameters: ["channel": "lts"]),
                                 Info(description: nil, digest: "dd", inputs: [input])])
        #expect(set?.parameters == ["channel": "lts"])
        #expect(set?.inputs == [input])
        #expect(both?.name == nil && both?.folder == nil)
    }

    @Test func updateStepsParseAndAreKept() throws {
        let scratch = try Scratch()
        let json = #"""
            {
              "version": 1,
              "parameters": {"channel": {"default": "lts"}, "team": {}},
              "inputs": {"xcode": {}},
              "steps": [{"run": "install"}],
              "update": [
                {"name": "upgrade", "run": "upgrade \"$AGENT_VM_PARAM_CHANNEL\"", "timeoutSeconds": 90},
                {"copy": "files/settings", "to": "~/.settings"}
              ],
              "checks": ["tool --version"]
            }
            """#
        let url = try recipe(json, files: ["files/settings": "one"], in: scratch)
        let parsed = try ImageRecipe.load(from: url)
        #expect(parsed.steps.count == 1)
        #expect(parsed.updateSteps.map(\.name) == ["upgrade", "update step 2"])
        #expect(parsed.updateSteps[0].timeoutSeconds == 90)
        // The files update steps copy are part of the digest, and kept with the recipe.
        let other = try Scratch()
        #expect(try ImageRecipe.load(from: recipe(json, files: ["files/settings": "two"], in: other)).digest != parsed.digest)
        let folder = scratch.root.appendingPathComponent("kept/1-recipe", isDirectory: true)
        try parsed.write(to: folder)
        let kept = try ImageRecipe.load(from: folder.appendingPathComponent("recipe.json"))
        #expect(kept.digest == parsed.digest)
        #expect(kept.updateSteps.count == 2)

        // For an update: --set, else what the image recorded, else the default; no inputs.
        let bound = try kept.bindingForUpdate(recorded: ["channel": "beta", "team": "a"], set: ["team": "b"])
        #expect(bound.parameterValues == ["channel": "beta", "team": "b"])
        #expect(bound.variables == ["AGENT_VM_PARAM_CHANNEL": "beta", "AGENT_VM_PARAM_TEAM": "b"])
        #expect(try kept.bindingForUpdate(recorded: ["team": "a"], set: [:]).parameterValues == ["channel": "lts", "team": "a"])
        #expect(throws: AgentVMError.self) { try kept.bindingForUpdate(recorded: [:], set: [:]) }

        #expect(reason(try recipe(#"{"version": 1, "update": {"run": "x"}}"#, in: other))?.contains("\"update\" must be a list") == true)
        #expect(reason(try recipe(#"{"version": 1, "update": [{"run": "x", "usr": "root"}]}"#, in: other))?.contains("update step 1 has unknown key \"usr\"") == true)
    }

    @Test func theDigestCoversCopiedFiles() throws {
        let first = try Scratch()
        let second = try Scratch()
        let json = #"{"version": 1, "steps": [{"copy": "f", "to": "/tmp/f"}]}"#
        let a = try ImageRecipe.load(from: recipe(json, files: ["f": "one"], in: first))
        let b = try ImageRecipe.load(from: recipe(json, files: ["f": "two"], in: second))
        #expect(a.digest != b.digest)
        #expect(a.text == json)
    }

    /// A copied file edited during the build would be recorded under the old digest: the
    /// step refuses it.
    @Test func aCopySourceChangedAfterLoadingIsRefused() throws {
        let scratch = try Scratch()
        let url = try recipe(#"{"version": 1, "steps": [{"copy": "f", "to": "/tmp/f"}]}"#, files: ["f": "one"], in: scratch)
        let step = try ImageRecipe.load(from: url).steps[0]
        guard case let .copy(source, _, _) = step.action else {
            Issue.record("expected a copy step")
            return
        }
        #expect(try ImageRecipe.copyContents(step, source: source) == Data("one".utf8))
        try Data("two".utf8).write(to: source)
        #expect(throws: AgentVMError.self) {
            _ = try ImageRecipe.copyContents(step, source: source)
        }
    }

    /// A step that ends without an exit status still names itself and keeps its output.
    @Test func stepFailuresNameTheStep() throws {
        // What a silent guest produces: the read timeout the builder sets on its connection.
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[0]); close(pair[1]) }
        var timeout = timeval(tv_sec: 0, tv_usec: 100_000)
        _ = setsockopt(pair[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        #expect(throws: GuestProtocolError.io(operation: "read", code: EAGAIN)) {
            _ = try FrameChannel(descriptor: pair[1]).receive()
        }

        let silent = ImageBuilder.recipeFailure("recipe step 2 (x)", GuestProtocolError.io(operation: "read", code: EAGAIN), timeoutSeconds: 60, output: "last line")
        #expect(silent as? AgentVMError == .guestCommandFailed(command: "recipe step 2 (x)", status: 124, output: "no output for 60 s, stopped; last output:\nlast line"))
        let refused = ImageBuilder.recipeFailure("recipe step 1 (y)", ExecRefusal(message: "no such user", status: 126), timeoutSeconds: 60, output: "")
        #expect(refused as? AgentVMError == .guestCommandFailed(command: "recipe step 1 (y)", status: 126, output: "no such user"))
        let lost = ImageBuilder.recipeFailure("recipe step 3 (z)", GuestProtocolError.disconnected, timeoutSeconds: 60, output: "")
        #expect("\(lost)".contains("recipe step 3 (z)"))
        // withGuest named the step already: not named twice, and the output is kept.
        let named = ImageBuilder.recipeFailure("recipe step 4 (w)", AgentVMError.guestUnreachable("recipe step 4 (w): write failed: Broken pipe"), timeoutSeconds: 60, output: "tail")
        #expect(named as? AgentVMError == .guestUnreachable("recipe step 4 (w): write failed: Broken pipe; last output:\ntail"))
    }

    @Test func mistakesAreExplained() throws {
        let cases: [(String, String)] = [
            (#"{"steps": []}"#, "\"version\" is missing"),
            (#"{"version": true}"#, "\"version\" is missing"),
            (#"{"version": 2}"#, "version 2 is not supported"),
            (#"{"version": 1, "step": []}"#, "unknown key \"step\""),
            (#"{"version": 1, "commandLineTools": 1}"#, "must be true or false"),
            (#"{"version": 1, "steps": [{"run": "x", "usr": "root"}]}"#, "step 1 has unknown key \"usr\""),
            (#"{"version": 1, "steps": [{"name": "x"}]}"#, "needs \"run\" or \"copy\""),
            (#"{"version": 1, "steps": [{"run": "x", "copy": "y"}]}"#, "both \"run\" and \"copy\""),
            (#"{"version": 1, "steps": [{"run": "  "}]}"#, "\"run\" is empty"),
            (#"{"version": 1, "steps": [{"run": "x", "user": "admin"}]}"#, "can only be \"root\""),
            (#"{"version": 1, "steps": [{"run": "x", "env": {"A-B": "1"}}]}"#, "not an environment variable name"),
            (#"{"version": 1, "steps": [{"run": "x", "env": {"A": 1}}]}"#, "must map names to strings"),
            (#"{"version": 1, "steps": [{"run": "x", "timeoutSeconds": 0}]}"#, "timeoutSeconds"),
            (#"{"version": 1, "steps": [{"run": "x", "timeoutSeconds": true}]}"#, "timeoutSeconds"),
            (#"{"version": 1, "steps": [{"run": "x", "to": "/y"}]}"#, "belong to copy steps"),
            (#"{"version": 1, "steps": [{"copy": "f"}]}"#, "needs \"to\""),
            (#"{"version": 1, "steps": [{"copy": "f", "to": "relative"}]}"#, "needs \"to\""),
            (#"{"version": 1, "steps": [{"copy": "f", "to": "/y", "mode": "rw"}]}"#, "must be octal"),
            (#"{"version": 1, "steps": [{"copy": "f", "to": "~/"}]}"#, "needs \"to\""),
            (#"{"version": 1, "steps": [{"copy": "f", "to": "/usr/local/"}]}"#, "needs \"to\""),
            (#"{"version": 1, "checks": ["\n"]}"#, "\"checks\" must be a list"),
            (#"{"version": 1, "steps": [{"copy": "missing", "to": "/y"}]}"#, "does not exist"),
            (#"{"version": 1, "steps": [{"copy": "/etc/hosts", "to": "/y"}]}"#, "relative to the recipe"),
            (#"{"version": 1, "steps": [{"copy": "../outside", "to": "/y"}]}"#, "outside the recipe's folder"),
            (#"{"version": 1, "steps": [{"copy": "sub", "to": "/y"}]}"#, "not a regular file"),
            (#"{"version": 1, "checks": ["ok", ""]}"#, "\"checks\" must be a list"),
            (#"[1, 2]"#, "top level must be a JSON object"),
            (#"{"version": 1,"#, "not valid JSON"),
        ]
        for (json, expected) in cases {
            let scratch = try Scratch()
            try Data("x".utf8).write(to: scratch.root.appendingPathComponent("outside"))
            let url = try recipe(json, files: ["f": "data", "sub/keep": "x"], in: scratch)
            let message = reason(url)
            #expect(message?.contains(expected) == true, "\(json): \(message ?? "no error")")
        }
    }

    @Test func aSymlinkOutOfTheFolderIsRefused() throws {
        let scratch = try Scratch()
        let url = try recipe(#"{"version": 1, "steps": [{"copy": "link", "to": "/y"}]}"#, in: scratch)
        symlink("/etc/hosts", url.deletingLastPathComponent().appendingPathComponent("link").path)
        #expect(reason(url)?.contains("outside the recipe's folder") == true)
    }

    @Test func requests() {
        let step = ImageRecipe.Step(name: "n", action: .run("echo hi"), user: nil, environment: ["X": "1"], timeoutSeconds: 10)
        let run = ImageRecipe.runRequest(step, command: "echo hi", boxUser: "agent")
        #expect(run.argv == ["/bin/bash", "-c", "echo hi"])
        #expect(run.env == ["X": "1", "AGENT_VM_BOX_USER": "agent"])
        #expect(run.user == nil)

        let rootStep = ImageRecipe.Step(name: "n", action: .copy(source: URL(fileURLWithPath: "/f"), destination: "~/.x", mode: "0600"), user: "root", environment: [:], timeoutSeconds: 10)
        let copy = ImageRecipe.copyRequest(rootStep, destination: "~/.x", mode: "0600")
        #expect(copy.user == "root")
        #expect(Array(copy.argv?.suffix(3) ?? []) == ["copy", "~/.x", "0600"])
        #expect(ImageRecipe.checkRequest("git --version").user == nil)
    }

    /// The copy script, run here with bash: `~/` goes to $HOME, parents are created, the mode
    /// is applied, and stdin becomes the file.
    @Test func theCopyScriptWritesTheFile() throws {
        let scratch = try Scratch()
        let step = ImageRecipe.Step(name: "n", action: .run("x"), user: nil, environment: [:], timeoutSeconds: 10)
        let request = ImageRecipe.copyRequest(step, destination: "~/deep/er/file.txt", mode: "0600")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.argv![0])
        process.arguments = Array(request.argv!.dropFirst())
        process.environment = ["HOME": scratch.root.path, "PATH": "/usr/bin:/bin"]
        let input = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data("contents".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let file = scratch.root.appendingPathComponent("deep/er/file.txt")
        #expect(try String(contentsOf: file, encoding: .utf8) == "contents")
        #expect(try FileSystem.status(file.path).st_mode & 0o777 == 0o600)
    }

    @Test func progressBarsShowTheirLastState() {
        #expect(LineEmitter.shownText(Array("10%\r50%\r100%".utf8)[...]) == "100%")
        #expect(LineEmitter.shownText(Array("plain".utf8)[...]) == "plain")
    }
}
