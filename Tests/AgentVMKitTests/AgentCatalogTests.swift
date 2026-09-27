// Tests/AgentVMKitTests/AgentCatalogTests.swift
//
// The agents catalog: the shipped file, user entries that add to or replace the built-in ones,
// every refusal of a broken file with its reason, and what connect passes for an agent (its
// secret, its variables, the rules a box lacks). Also the installed-agent probe's parsing.

import Foundation
import Testing
@testable import AgentVMKit

@Suite struct AgentCatalogTests {
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/agents.json")

    func store(_ files: [String: String]) throws -> Scratch {
        let scratch = try Scratch()
        let directory = AgentCatalog.userDirectory(store: scratch.root)
        try FileSystem.makeDirectories(directory.path)
        for (name, text) in files {
            try Data(text.utf8).write(to: directory.appendingPathComponent(name))
        }
        return scratch
    }

    /// A built-in file with `agents` (a JSON list's contents) in a scratch folder.
    func builtIn(_ agents: String, in scratch: Scratch, version: String = "1") throws -> URL {
        let url = scratch.root.appendingPathComponent("agents.json")
        try Data(#"{"version": \#(version), "agents": [\#(agents)]}"#.utf8).write(to: url)
        return url
    }

    @Test func theShippedFileIsValid() throws {
        let scratch = try Scratch()
        let catalog = AgentCatalog.load(store: scratch.root, builtIn: Self.repository)
        #expect(catalog.builtInProblem == nil)
        #expect(catalog.problems.isEmpty)
        #expect(catalog.entries.map(\.id) == ["claude", "codex", "opencode"])
        let claude = try #require(catalog.entry(id: "claude"))
        #expect(claude.command == ["claude"] && claude.secretsNeeded == .one && claude.source == .builtIn)
        #expect(claude.secrets.map(\.env) == ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY"])
        // Claude Code's first-run screens ignore a token until onboarding is marked done.
        #expect(claude.setup?.contains("hasCompletedOnboarding") == true)
        // Every rule is one a box takes.
        let packs = try NetworkPacks.load(store: scratch.root, builtIn: TestPacks.repository)
        for entry in catalog.entries {
            _ = try CompiledPolicy(BoxNetwork(mode: .allowlist, allow: entry.allow), packs: packs)
        }
    }

    /// Claude Code's setup, run as the session runs it, with `home` as the home folder.
    func runClaudeSetup(home: URL, token: String?) throws {
        let scratch = try Scratch()
        let setup = try #require(AgentCatalog.load(store: scratch.root, builtIn: Self.repository).entry(id: "claude")?.setup)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", setup]
        var environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        environment["CLAUDE_CODE_OAUTH_TOKEN"] = token
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test func theClaudeSetupMarksOnboardingDone() throws {
        let scratch = try Scratch()
        let file = scratch.root.appendingPathComponent(".claude.json")
        // No token: nothing written.
        try runClaudeSetup(home: scratch.root, token: nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        // No file: made, private.
        try runClaudeSetup(home: scratch.root, token: "t")
        var config = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(config["hasCompletedOnboarding"] as? Bool == true)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        // Other keys kept.
        try Data(#"{"theme": "dark", "hasCompletedOnboarding": false}"#.utf8).write(to: file)
        try runClaudeSetup(home: scratch.root, token: "t")
        config = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(config["theme"] as? String == "dark" && config["hasCompletedOnboarding"] as? Bool == true)
        // A file that is not JSON is left alone, with no temporary file behind.
        try Data("not json".utf8).write(to: file)
        try runClaudeSetup(home: scratch.root, token: "t")
        #expect(try String(contentsOf: file, encoding: .utf8) == "not json")
        #expect(!FileManager.default.fileExists(atPath: file.path + ".avm"))
    }

    @Test func aUserFileReplacesInPlace() throws {
        let scratch = try store(["codex.json": #"{"name": "My Codex", "command": ["/opt/codex/bin/codex", "--full-auto"]}"#])
        let catalog = AgentCatalog.load(store: scratch.root, builtIn: Self.repository)
        #expect(catalog.entries.map(\.id) == ["claude", "codex", "opencode"])
        let codex = try #require(catalog.entry(id: "codex"))
        #expect(codex.name == "My Codex" && codex.source == .user && codex.replacesBuiltIn)
        #expect(codex.command == ["/opt/codex/bin/codex", "--full-auto"])
        #expect(codex.path.hasSuffix("/Agents/codex.json"))
    }

    @Test func newUserEntriesFollowSortedById() throws {
        let scratch = try store([
            "zed.json": #"{"name": "Zed", "command": ["zed-agent"]}"#,
            "aider.json": #"{"id": "aider", "name": "Aider", "command": ["aider"], "allow": ["api.example.com:8443", "*.example.org"]}"#,
            ".hidden.json": "not read",
            "notes.txt": "not an agent",
        ])
        let catalog = AgentCatalog.load(store: scratch.root, builtIn: Self.repository)
        #expect(catalog.problems.isEmpty)
        #expect(catalog.entries.map(\.id) == ["claude", "codex", "opencode", "aider", "zed"])
        #expect(catalog.entry(id: "aider")?.replacesBuiltIn == false)
    }

    @Test func aBrokenUserFileIsAProblemForItsIdOnly() throws {
        let scratch = try store([
            "opencode.json": #"{"name": "opencode", "command": "opencode"}"#,
            "mine.json": "{not json",
            "Upper.json": #"{"name": "Upper", "command": ["x"]}"#,
        ])
        let catalog = AgentCatalog.load(store: scratch.root, builtIn: Self.repository)
        // A broken replacement does not give way to the built-in entry.
        #expect(catalog.entries.map(\.id) == ["claude", "codex"])
        #expect(catalog.problems["opencode"]?.reason == "\"command\" must be a list of words")
        #expect(catalog.problems["mine"]?.reason == "not a JSON object")
        #expect(catalog.problems["upper"] != nil)
    }

    @Test func aMissingBuiltInFileIsReported() throws {
        let scratch = try store(["mine.json": #"{"name": "Mine", "command": ["mine"]}"#])
        let catalog = AgentCatalog.load(store: scratch.root, builtIn: scratch.root.appendingPathComponent("nowhere.json"))
        #expect(catalog.entries.map(\.id) == ["mine"])
        #expect(catalog.builtInProblem?.reason.hasPrefix("cannot read it") == true)
        let none = AgentCatalog.load(store: scratch.root, builtIn: nil)
        #expect(none.builtInProblem != nil)
    }

    @Test func everyRefusalSaysWhy() throws {
        let scratch = try Scratch()
        let good = #"{"id": "a", "name": "A", "command": ["a"]}"#
        let cases: [(String, String, String)] = [
            (good, "true", "\"version\" must be 1"),
            (#"{"id": "Bad Id", "name": "A", "command": ["a"]}"#, "1", "\"id\" must be"),
            (#"{"id": "shell", "name": "A", "command": ["a"]}"#, "1", "login shell's id"),
            (good + ", " + good, "1", "a: listed twice"),
            (#"{"id": "a", "name": "A", "command": []}"#, "1", "\"command\" must be a list of words"),
            (#"{"id": "a", "name": "A", "command": ["bin/a"]}"#, "1", "a command name or an absolute path"),
            (#"{"id": "a", "name": "", "command": ["a"]}"#, "1", "\"name\" must be text"),
            (#"{"id": "a", "name": "A", "command": ["a"], "allow": ["public"]}"#, "1", "public is not a host name"),
            (#"{"id": "a", "name": "A", "command": ["a"], "allow": ["pack:no such"]}"#, "1", "pack:no such is not"),
            (#"{"id": "a", "name": "A", "command": ["a"], "env": {"1X": "y"}}"#, "1", "1X is not a variable name"),
            (#"{"id": "a", "name": "A", "command": ["a"], "secrets": [{"env": "K"}]}"#, "1", "\"label\" must be text"),
            (#"{"id": "a", "name": "A", "command": ["a"], "secretsNeeded": "one"}"#, "1", "there are no \"secrets\""),
            (#"{"id": "a", "name": "A", "command": ["a"], "secretsNeeded": "all", "secrets": [{"env": "K", "label": "k"}]}"#, "1", "\"one\" or \"optional\""),
            (#"{"id": "a", "name": "A", "command": ["a"], "setup": ["x"]}"#, "1", "\"setup\" must be text"),
        ]
        for (agents, version, reason) in cases {
            let url = try builtIn(agents, in: scratch, version: version)
            let catalog = AgentCatalog.load(store: scratch.root, builtIn: url)
            #expect(catalog.entries.isEmpty, "\(agents)")
            #expect(catalog.builtInProblem?.reason.contains(reason) == true, "\(agents): \(catalog.builtInProblem?.reason ?? "no problem")")
        }
        // A user file's own id must match its name.
        let user = try store(["b.json": #"{"id": "c", "name": "B", "command": ["b"]}"#])
        #expect(AgentCatalog.load(store: user.root, builtIn: Self.repository).problems["b"]?.reason.contains("must be the file's name") == true)
    }

    @Test func unknownKeysAreIgnored() throws {
        let scratch = try Scratch()
        let url = try builtIn(#"{"id": "a", "name": "A", "command": ["a"], "icon": "robot", "future": {"x": 1}}"#, in: scratch)
        let catalog = AgentCatalog.load(store: scratch.root, builtIn: url)
        #expect(catalog.builtInProblem == nil)
        #expect(catalog.entries.map(\.id) == ["a"])
    }

    @Test func secretArgumentsTakeTheFirstSet() throws {
        let entry = AgentEntry(id: "c", name: "C", command: ["c"],
                               secrets: [AgentEntry.Secret(env: "TOKEN", label: "t"), AgentEntry.Secret(env: "KEY", label: "k"),
                                         AgentEntry.Secret(env: "OTHER", secret: "STORED_AS", label: "o")],
                               secretsNeeded: .one)
        #expect(AgentCatalog.secretArguments(for: entry, set: ["KEY", "TOKEN"]) == ["TOKEN"])
        #expect(AgentCatalog.secretArguments(for: entry, set: ["KEY"]) == ["KEY"])
        #expect(AgentCatalog.secretArguments(for: entry, set: ["STORED_AS"]) == ["OTHER=STORED_AS"])
        // A Keychain name other than the variable's is looked up by the Keychain name.
        #expect(AgentCatalog.secretArguments(for: entry, set: ["OTHER"]) == [])
        #expect(AgentCatalog.secretArguments(for: entry, set: []) == [])
    }

    @Test func envArgumentsAreSortedByName() {
        let entry = AgentEntry(id: "c", name: "C", command: ["c"], env: ["ZED": "1", "ALPHA": "a b"])
        #expect(AgentCatalog.envArguments(for: entry) == ["ALPHA=a b", "ZED=1"])
    }

    @Test func missingRulesByExactMatch() {
        let entry = AgentEntry(id: "c", name: "C", command: ["c"], allow: ["pack:anthropic", "example.com"])
        #expect(AgentCatalog.missingRules(for: entry, in: ["api.anthropic.com", "example.com"]) == ["pack:anthropic"])
        #expect(AgentCatalog.missingRules(for: entry, in: ["pack:anthropic", "example.com"]) == [])
    }
}

@Suite struct AgentProbeTests {
    @Test func parseKeepsOnlyExactCommandNames() {
        let output = "Welcome to the box!\nclaude\nopencode \ncod\n/usr/local/bin/codex\r\nclaude\n"
        #expect(AgentProbe.parse(output, commands: ["claude", "codex", "opencode", "/usr/local/bin/codex"]) == ["claude", "/usr/local/bin/codex"])
        #expect(AgentProbe.parse("", commands: ["claude"]).isEmpty)
    }

    @Test func theRequestUsesTheLoginWrapper() throws {
        let request = AgentProbe.request(commands: ["claude", "codex"], user: "agent")
        let argv = try #require(request.argv)
        #expect(argv.starts(with: ConnectPlanner.loginWrapper))
        #expect(argv.suffix(2) == ["claude", "codex"])
        #expect(request.user == "agent")
    }

    @Test func theScriptPrintsWhatTheShellFinds() throws {
        // The probe's script, run by this Mac's /bin/sh without the wrapper.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", AgentProbe.script, "probe", "ls", "no-such-command-here", "/bin/cat", "a b"]
        process.environment = ["PATH": "/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(String(decoding: data, as: UTF8.self) == "ls\n/bin/cat\n")
    }
}
