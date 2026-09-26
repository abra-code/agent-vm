// Tests/AgentVMKitTests/NetworkPacksTests.swift
//
// Host packs from files: the built-in packs file, the store's user packs (a new one, one that
// replaces a built-in pack, broken ones), and what a policy does with each.

import Foundation
import Testing
@testable import AgentVMKit

@Suite struct NetworkPacksTests {
    func store(_ files: [String: String]) throws -> Scratch {
        let scratch = try Scratch()
        let directory = NetworkPacks.userDirectory(store: scratch.root)
        try FileSystem.makeDirectories(directory.path)
        for (name, text) in files {
            try Data(text.utf8).write(to: directory.appendingPathComponent(name))
        }
        return scratch
    }

    @Test func userPacksAddToAndReplaceBuiltInOnes() throws {
        let scratch = try store([
            "mine.json": #"{"description": "Our servers", "hosts": ["git.example.com", "*.example.org", "example.net:8443"]}"#,
            "npm.json": #"{"hosts": ["npm.example.com"]}"#,
            ".hidden.json": "not read",
            "notes.txt": "not a pack",
        ])
        let packs = try NetworkPacks.load(store: scratch.root, builtIn: TestPacks.repository)
        #expect(packs.problems.isEmpty)
        let mine = try #require(packs.packs["mine"])
        #expect(mine.source == .user && mine.description == "Our servers" && !mine.replacesBuiltIn)
        #expect(mine.path.hasSuffix("/Packs/mine.json"))
        let npm = try #require(packs.packs["npm"])
        #expect(npm.source == .user && npm.replacesBuiltIn && npm.hosts == ["npm.example.com"])
        #expect(packs.packs["github"]?.source == .builtIn)

        let policy = try CompiledPolicy(BoxNetwork(mode: .allowlist, allow: ["pack:mine", "pack:npm"]), packs: packs)
        #expect(policy.allows(host: "a.example.org", port: 443, tunnel: true) == "pack:mine")
        #expect(policy.allows(host: "example.net", port: 8443, tunnel: true) == "pack:mine")
        #expect(policy.allows(host: "npm.example.com", port: 443, tunnel: true) == "pack:npm")
        // The built-in npm pack is replaced, not added to.
        #expect(policy.allows(host: "registry.npmjs.org", port: 443, tunnel: true) == nil)
    }

    @Test func aBrokenUserPackIsRefusedNotReplacedByTheBuiltInOne() throws {
        let scratch = try store([
            "npm.json": #"{"hosts": ["not a host"]}"#,
            "open.json": #"{"hosts": ["public"]}"#,
            "empty.json": #"{"hosts": []}"#,
            "garbled.json": "{",
            "Upper.json": #"{"hosts": ["example.com"]}"#,
            "PyPI.json": #"{"hosts": ["pypi.example.com"]}"#,
            "worded.json": #"{"hosts": ["example.com"], "description": 3}"#,
        ])
        let packs = try NetworkPacks.load(store: scratch.root, builtIn: TestPacks.repository)
        #expect(Set(packs.problems.keys) == ["npm", "open", "empty", "garbled", "upper", "worded", "pypi"])
        #expect(packs.packs["npm"] == nil && packs.packs["pypi"] == nil)
        #expect(packs.problems["open"]?.reason.contains("public is not a host name") == true)
        do {
            _ = try CompiledPolicy(BoxNetwork(mode: .allowlist, allow: ["pack:npm"]), packs: packs)
            Issue.record("a broken pack was used")
        } catch let AgentVMError.invalidNetworkRule(rule, reason) {
            #expect(rule == "pack:npm")
            #expect(reason.contains("/Packs/npm.json"), "\(reason)")
        }
        #expect(throws: AgentVMError.self) { _ = try packs.hosts(of: "nope") }
        #expect(throws: AgentVMError.self) { _ = try packs.hosts(of: "pypi") }
    }

    /// A Packs folder that cannot be listed may hide a user pack replacing a built-in one.
    @Test func anUnreadablePacksFolderIsAnError() throws {
        let scratch = try store(["npm.json": #"{"hosts": ["npm.example.com"]}"#])
        let directory = NetworkPacks.userDirectory(store: scratch.root)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
        // Restored before the scratch folder is removed (the closure keeps it alive until then).
        defer { withExtendedLifetime(scratch) { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) } }
        #expect(throws: AgentVMError.self) { _ = try NetworkPacks.load(store: scratch.root, builtIn: TestPacks.repository) }
    }

    @Test func theBuiltInFileIsRequiredAndChecked() throws {
        let scratch = try Scratch()
        #expect(throws: AgentVMError.self) {
            _ = try NetworkPacks.load(store: scratch.root, builtIn: scratch.root.appendingPathComponent("missing.json"))
        }
        for text in ["[]", #"{"version": true, "packs": {}}"#, #"{"version": 2, "packs": {}}"#, #"{"version": 1}"#, #"{"version": 1, "packs": {"Bad": {"hosts": ["a.com"]}}}"#,
                     #"{"version": 1, "packs": {"x": {"hosts": ["public"]}}}"#] {
            let file = scratch.root.appendingPathComponent("packs.json")
            try Data(text.utf8).write(to: file)
            #expect(throws: AgentVMError.self, "\(text)") { _ = try NetworkPacks.load(store: scratch.root, builtIn: file) }
        }
    }

    @Test func packsAreReadOnlyWhenARuleNamesOne() throws {
        let scratch = try Scratch()
        let missing = scratch.root.appendingPathComponent("missing.json")
        let plain = try NetworkPacks.needed(for: BoxNetwork(mode: .allowlist, allow: ["example.com", "public"]), store: scratch.root, builtIn: missing)
        #expect(plain.packs.isEmpty && plain.problems.isEmpty)
        #expect(throws: AgentVMError.self) {
            _ = try NetworkPacks.needed(for: BoxNetwork(mode: .allowlist, allow: ["PACK:npm"]), store: scratch.root, builtIn: missing)
        }
    }

    @Test func theFileNextToTheExecutableUnlessOverridden() {
        #expect(NetworkPacks.builtInURL(environment: ["AGENT_VM_PACKS_FILE": "/tmp/p.json"])?.path == "/tmp/p.json")
        #expect(NetworkPacks.builtInURL(environment: [:])?.lastPathComponent == "packs.json")
    }
}
