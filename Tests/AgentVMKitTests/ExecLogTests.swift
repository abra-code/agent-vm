// Tests/AgentVMKitTests/ExecLogTests.swift
//
// The box's exec log (start and end lines paired into records, a client that died without an
// end, unreadable lines, rotation) and the terminal type a box program is given.

import Foundation
import Testing
@testable import AgentVMKit

@Suite struct ExecLogTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func startsAndEndsPairIntoRecords() throws {
        let scratch = try Scratch()
        let log = ExecLog(url: scratch.root.appendingPathComponent("exec.jsonl"))
        log.append(ExecLog.Entry(id: "a", event: .start, time: t0, argv: ["uname", "-a"], user: "agent", hostPid: 10))
        log.append(ExecLog.Entry(id: "b", event: .start, time: t0.addingTimeInterval(1), argv: ["/bin/sh"], user: "root", cwd: "/tmp",
                                 project: "/Users/me/src/app", readOnly: true, terminal: true, hostPid: 11))
        log.append(ExecLog.Entry(id: "a", event: .end, time: t0.addingTimeInterval(2), guestPid: 500, status: 0, seconds: 0.25))
        log.append(ExecLog.Entry(id: "zz", event: .end, time: t0, status: 1))
        let records = log.records()
        #expect(records.map(\.id) == ["a", "b"])
        #expect(records[0].argv == ["uname", "-a"])
        #expect(records[0].status == 0)
        #expect(records[0].seconds == 0.25)
        #expect(records[0].guestPid == 500)
        // No end: still running, or its client was killed.
        #expect(records[1].status == nil)
        #expect(records[1].terminal == true)
        #expect(records[1].project == "/Users/me/src/app")
        #expect(log.records(last: 1).map(\.id) == ["b"])
        #expect(log.records(last: -1).isEmpty)
    }

    /// A notice counts as soon as it is written: a running exec already shows its prompts.
    @Test func noticesReachTheRecordAtOnce() throws {
        let scratch = try Scratch()
        let log = ExecLog(url: scratch.root.appendingPathComponent("exec.jsonl"))
        log.append(ExecLog.Entry(id: "a", event: .start, time: t0, argv: ["/bin/sh", "-c", "ls ~/Downloads"]))
        log.append(ExecLog.Entry(id: "a", event: .notice, time: t0.addingTimeInterval(1), guestPid: 688, prompt: "the Downloads folder",
                                 service: "kTCCServiceSystemPolicyDownloadsFolder", program: "/bin/ls", stopped: true))
        var record = try #require(log.records().first)
        #expect(record.prompts == ["the Downloads folder"])
        #expect(record.stoppedOnPrompt == true)
        #expect(record.status == nil)
        // The end line repeats the prompt; it is kept once, next to any the end adds.
        log.append(ExecLog.Entry(id: "a", event: .end, time: t0.addingTimeInterval(2), status: 137, prompts: ["the Downloads folder", "the Desktop folder"]))
        record = try #require(log.records().first)
        #expect(record.prompts == ["the Downloads folder", "the Desktop folder"])
        #expect(record.status == 137)
        // A notice for no known start is skipped, as an end would be.
        log.append(ExecLog.Entry(id: "zz", event: .notice, time: t0, prompt: "the Documents folder"))
        #expect(log.records().count == 1)
    }

    @Test func unreadableLinesAreSkipped() throws {
        let scratch = try Scratch()
        let url = scratch.root.appendingPathComponent("exec.jsonl")
        let log = ExecLog(url: url)
        log.append(ExecLog.Entry(id: "a", event: .start, time: t0, argv: ["true"]))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n{\"id\":1}\n".utf8))
        try handle.close()
        log.append(ExecLog.Entry(id: "a", event: .end, time: t0, status: 3))
        #expect(log.records().map(\.status) == [3])
    }

    @Test func theFileIsPrivateAndRotates() throws {
        let scratch = try Scratch()
        let url = scratch.root.appendingPathComponent("exec.jsonl")
        let log = ExecLog(url: url, maxBytes: 300)
        for index in 0..<6 {
            log.append(ExecLog.Entry(id: "\(index)", event: .start, time: t0, argv: ["echo", String(repeating: "x", count: 40)]))
        }
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(FileManager.default.fileExists(atPath: url.path + ".1"))
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        #expect(size <= 300)
    }

    @Test func noLogIsNoRecords() {
        #expect(ExecLog(url: URL(fileURLWithPath: "/nonexistent/exec.jsonl")).records().isEmpty)
    }

    @Test func idsAreShortAndDistinct() {
        let ids = Set((0..<100).map { _ in ExecLog.newID() })
        #expect(ids.count == 100)
        #expect(ids.allSatisfy { $0.count == 8 })
    }

    @Test func terminalTypesTheGuestKnowsArePassedOn() throws {
        let scratch = try Scratch()
        let terminfo = scratch.root.appendingPathComponent("terminfo")
        try FileManager.default.createDirectory(at: terminfo.appendingPathComponent("78"), withIntermediateDirectories: true)
        try Data().write(to: terminfo.appendingPathComponent("78/xterm-256color"))
        try FileManager.default.createDirectory(at: terminfo.appendingPathComponent("74"), withIntermediateDirectories: true)
        try Data().write(to: terminfo.appendingPathComponent("74/tmux-256color"))
        #expect(ExecEnvironment.terminalType(host: "tmux-256color", terminfo: terminfo.path) == "tmux-256color")
        for unknown in ["xterm-ghostty", nil, "", "../78/xterm-256color", "t/../x"] {
            #expect(ExecEnvironment.terminalType(host: unknown, terminfo: terminfo.path) == "xterm-256color", "\(unknown ?? "nil")")
        }
        // This Mac's own database, which the guest shares.
        #expect(ExecEnvironment.terminalType(host: "vt100") == "vt100")
    }
}
