// Tests/AgentVMKitTests/ConnectChoicesTests.swift
//
// The choices `agent-vm connect` remembers per folder: read back, a damaged file read as none
// and replaced, the oldest dropped past the limit, and the file private.

import Darwin
import Foundation
import Testing
@testable import AgentVMKit

@Suite struct ConnectChoicesTests {
    @Test func rememberAndRead() throws {
        let scratch = try Scratch()
        let choices = ConnectChoices(store: scratch.root)
        #expect(choices.choice(for: "/p") == nil)
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        try choices.remember(ConnectChoice(target: .box, box: "dev1", launch: "shell", readOnly: false, at: at), for: "/p")
        try choices.remember(ConnectChoice(target: .temporary, image: "dev-agents", launch: "claude", at: at), for: "/q")
        #expect(choices.choice(for: "/p") == ConnectChoice(target: .box, box: "dev1", launch: "shell", readOnly: false, at: at))
        #expect(ConnectChoices(store: scratch.root).choice(for: "/q")?.image == "dev-agents")
        #expect(choices.choice(for: "/other") == nil)
    }

    /// An agreement is to an agent's file as it was: another digest is not agreed to, and the
    /// folders' choices and the agreements are kept through each other's writes.
    @Test func agentAgreementsAreKeptByDigest() throws {
        let scratch = try Scratch()
        let choices = ConnectChoices(store: scratch.root)
        #expect(!choices.agreed(agent: "aider", digest: "aa"))
        try choices.agree(agent: "aider", digest: "aa")
        #expect(choices.agreed(agent: "aider", digest: "aa"))
        #expect(!choices.agreed(agent: "aider", digest: "bb"))
        #expect(!choices.agreed(agent: "other", digest: "aa"))
        try choices.remember(ConnectChoice(target: .box, box: "dev1"), for: "/p")
        #expect(choices.agreed(agent: "aider", digest: "aa"))
        try choices.agree(agent: "aider", digest: "bb")
        #expect(!choices.agreed(agent: "aider", digest: "aa"))
        #expect(choices.agreed(agent: "aider", digest: "bb"))
        #expect(choices.choice(for: "/p")?.box == "dev1")
        // A file from before agreements were kept, and a damaged one: nothing agreed to.
        try Data(#"{"version": 1, "projects": {}}"#.utf8).write(to: choices.url)
        #expect(!choices.agreed(agent: "aider", digest: "bb"))
        try Data("garbage".utf8).write(to: choices.url)
        #expect(!choices.agreed(agent: "aider", digest: "bb"))
        try choices.agree(agent: "aider", digest: "bb")
        #expect(choices.agreed(agent: "aider", digest: "bb"))
    }

    @Test func aDamagedFileIsEmpty() throws {
        let scratch = try Scratch()
        let choices = ConnectChoices(store: scratch.root)
        let choice = ConnectChoice(target: .box, box: "dev1", at: Date(timeIntervalSince1970: 1_790_000_000))
        for damage in ["garbage", #"{"version": 2, "projects": {}}"#, #"{"version": 1, "projects": {"/p": {"target": "nope"}}}"#, "directory"] {
            try? FileSystem.removeTree(choices.url.path)
            if damage == "directory" {
                try FileManager.default.createDirectory(at: choices.url.appendingPathComponent("inside"), withIntermediateDirectories: true)
            } else {
                try Data(damage.utf8).write(to: choices.url)
            }
            #expect(choices.choice(for: "/p") == nil, "\(damage)")
            try choices.remember(choice, for: "/p")
            #expect(choices.choice(for: "/p") == choice, "\(damage)")
        }
    }

    @Test func theOldestGoFirst() throws {
        let scratch = try Scratch()
        let choices = ConnectChoices(store: scratch.root)
        for index in 0...ConnectChoices.limit {
            try choices.remember(ConnectChoice(target: .box, box: "b", at: Date(timeIntervalSince1970: 1_790_000_000 + Double(index))),
                                 for: "/p\(index)")
        }
        #expect(choices.choice(for: "/p0") == nil)
        #expect(choices.choice(for: "/p1") != nil)
        #expect(choices.choice(for: "/p\(ConnectChoices.limit)") != nil)
    }

    @Test func theFileIsPrivate() throws {
        let scratch = try Scratch()
        let choices = ConnectChoices(store: scratch.root)
        try choices.remember(ConnectChoice(target: .box, box: "b"), for: "/p")
        var info = stat()
        #expect(stat(choices.url.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        // No temporary file is left next to it.
        let names = try FileManager.default.contentsOfDirectory(atPath: scratch.root.path)
        #expect(names.filter { $0.contains(ConnectChoices.fileName) } == [ConnectChoices.fileName])
    }
}
