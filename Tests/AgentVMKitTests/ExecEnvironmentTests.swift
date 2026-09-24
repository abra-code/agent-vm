// Tests/AgentVMKitTests/ExecEnvironmentTests.swift
//
// The variables exec adds to a program's environment: --env NAME=VALUE, --env NAME passed on
// from agent-vm's own environment, --env-file, their order, and errors that never show a value.

import Foundation
import Testing
@testable import AgentVMKit

@Suite struct ExecEnvironmentTests {
    let host = ["API_KEY": "sk-host-secret", "EMPTY": ""]

    func writeFile(_ scratch: Scratch, _ text: String) throws -> String {
        let url = scratch.root.appendingPathComponent("agent.env")
        try Data(text.utf8).write(to: url)
        return url.path
    }

    @Test func namesFollowShellRules() {
        for name in ["A", "_", "API_KEY", "a1", "_x_9"] {
            #expect(ExecEnvironment.isValidName(name), "\(name)")
        }
        for name in ["", "1A", "A-B", "A B", "A.B", "\u{00C9}T\u{00C9}", "A=B"] {
            #expect(!ExecEnvironment.isValidName(name), "\(name)")
        }
    }

    @Test func entriesTakeValuesAsGivenOrFromTheHost() throws {
        #expect(try ExecEnvironment.entry("A=b=c", host: host) == ("A", "b=c"))
        #expect(try ExecEnvironment.entry("A=", host: host) == ("A", ""))
        #expect(try ExecEnvironment.entry("API_KEY", host: host) == ("API_KEY", "sk-host-secret"))
        #expect(try ExecEnvironment.entry("EMPTY", host: host) == ("EMPTY", ""))
    }

    @Test func entryErrorsNameTheProblem() {
        #expect(throws: AgentVMError.invalidEnvironment("--env MISSING: MISSING is not set in agent-vm's environment")) {
            try ExecEnvironment.entry("MISSING", host: host)
        }
        #expect(throws: AgentVMError.invalidEnvironment("--env needs NAME=VALUE or the NAME of a variable to pass on, got =x")) {
            try ExecEnvironment.entry("=x", host: host)
        }
        #expect(throws: AgentVMError.invalidEnvironment("--env needs NAME=VALUE or the NAME of a variable to pass on, got not-a-name")) {
            try ExecEnvironment.entry("not-a-name", host: host)
        }
    }

    @Test func filesReadLinesLiterally() throws {
        let scratch = try Scratch()
        let path = try writeFile(scratch, """
            # keys for the agent
              TOKEN=abc "quoted" # not a comment\r

            API_KEY
            URL=https://example.com/?a=b
            """)
        let entries = try ExecEnvironment.file(at: path, host: host)
        #expect(entries.map(\.name) == ["TOKEN", "API_KEY", "URL"])
        #expect(entries.map(\.value) == ["abc \"quoted\" # not a comment", "sk-host-secret", "https://example.com/?a=b"])
    }

    @Test func fileErrorsGiveTheLineButNeverTheValue() throws {
        let scratch = try Scratch()
        let bad = try writeFile(scratch, "GOOD=1\nexport SECRET=hunter2\n")
        do {
            _ = try ExecEnvironment.file(at: bad, host: host)
            Issue.record("expected an error")
        } catch let error as AgentVMError {
            #expect(error.description.contains("line 2"))
            #expect(!error.description.contains("hunter2"))
        }
        let missing = try writeFile(scratch, "NOT_ON_THE_HOST\n")
        #expect(throws: AgentVMError.invalidEnvironment("environment file \(missing), line 1: NOT_ON_THE_HOST is not set in agent-vm's environment")) {
            try ExecEnvironment.file(at: missing, host: host)
        }
    }

    @Test func symbolicLinksAreFollowed() throws {
        let scratch = try Scratch()
        let target = try writeFile(scratch, "A=1\n")
        let link = scratch.root.appendingPathComponent("link.env")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        let entries = try ExecEnvironment.file(at: link.path, host: host)
        #expect(entries.map(\.name) == ["A"])
        #expect(entries.map(\.value) == ["1"])
    }

    /// As `--env-file <(op read ...)` gives it: a pipe, read once.
    @Test func pipesAreRead() throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data("TOKEN=from-a-pipe\nAPI_KEY\n".utf8))
        try pipe.fileHandleForWriting.close()
        let entries = try ExecEnvironment.file(at: "/dev/fd/\(pipe.fileHandleForReading.fileDescriptor)", host: host)
        #expect(entries.map(\.value) == ["from-a-pipe", "sk-host-secret"])
    }

    @Test func unreadableFilesAreRefused() throws {
        let scratch = try Scratch()
        #expect(throws: AgentVMError.self) {
            try ExecEnvironment.file(at: scratch.root.appendingPathComponent("none.env").path, host: host)
        }
        #expect(throws: AgentVMError.invalidEnvironment("environment file \(scratch.root.path) is a folder")) {
            try ExecEnvironment.file(at: scratch.root.path, host: host)
        }
        let big = try writeFile(scratch, String(repeating: "A=1\n", count: ExecEnvironment.maximumFileSize / 4 + 1))
        #expect(throws: AgentVMError.invalidEnvironment("environment file \(big) is larger than 256 KB")) {
            try ExecEnvironment.file(at: big, host: host)
        }
        let binary = scratch.root.appendingPathComponent("binary.env")
        try Data([0x41, 0x3D, 0xFF, 0xFE]).write(to: binary)
        #expect(throws: AgentVMError.invalidEnvironment("environment file \(binary.path) is not UTF-8 text")) {
            try ExecEnvironment.file(at: binary.path, host: host)
        }
        let nul = scratch.root.appendingPathComponent("nul.env")
        try Data("KEY=abc\u{0}def\n".utf8).write(to: nul)
        #expect(throws: AgentVMError.invalidEnvironment("environment file \(nul.path) is not UTF-8 text")) {
            try ExecEnvironment.file(at: nul.path, host: host)
        }
    }

    @Test func laterSourcesWin() throws {
        let scratch = try Scratch()
        let path = try writeFile(scratch, "HTTPS_PROXY=http://file\nA=file\nB=file\n")
        let result = try ExecEnvironment.overrides(
            base: ["HTTPS_PROXY": "http://127.0.0.1:3128", "KEEP": "base"],
            files: [path], entries: ["B=flag", "API_KEY"], host: host)
        #expect(result == ["HTTPS_PROXY": "http://file", "KEEP": "base", "A": "file", "B": "flag", "API_KEY": "sk-host-secret"])
    }
}
