// Tests/AgentVMKitTests/BoxEventsTests.swift
//
// The box event log: lines appended and read back across its two files, what is cut, the rules
// event a rule change writes, the log kept with a deleted box, and the names an exec start
// records. The events a supervisor writes need a running box: the extended tests see them.

import Foundation
import Testing
@testable import AgentVMKit

@Suite struct BoxEventsTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func eventsAreAppendedAndReadBack() throws {
        let scratch = try Scratch()
        let log = BoxEventLog(url: scratch.root.appendingPathComponent("events.jsonl"))
        #expect(log.events().isEmpty)
        let written: [BoxEventLog.Event] = [
            .init(.start, time: Self.now, pid: 7, detail: "image dev, network allowlist"),
            .init(.share, time: Self.now.addingTimeInterval(1), pid: 7, path: "/Users/me/project", readOnly: true),
            .init(.rules, time: Self.now.addingTimeInterval(2), pid: 9, before: BoxNetwork(mode: .allowlist, allow: ["a.example"]),
                  after: BoxNetwork(mode: .allowlist, allow: ["a.example", "pack:github"]), running: true),
            .init(.type, time: Self.now.addingTimeInterval(3), pid: 7, password: true),
            .init(.send, time: Self.now.addingTimeInterval(4), pid: 11, items: [.init(name: "tool.pkg", received: "tool 2.pkg", bytes: 1234)]),
            .init(.stop, time: Self.now.addingTimeInterval(5), pid: 7),
        ]
        for event in written {
            #expect(log.append(event) == nil)
        }
        #expect(log.events() == written)
        #expect(log.events(last: 2) == Array(written.suffix(2)))
        #expect(log.events { $0.event == .rules }.first?.after?.allow == ["a.example", "pack:github"])
        // The last N of what matches.
        #expect(log.events(last: 1) { $0.pid == 7 }.map(\.event) == [.stop])
        // The file is private, one object per line, with no key for what an event has not.
        #expect(((try FileManager.default.attributesOfItem(atPath: log.url.path))[.posixPermissions] as? Int) == 0o600)
        let lines = try String(contentsOf: log.url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == written.count)
        #expect(lines[0] == #"{"detail":"image dev, network allowlist","event":"start","pid":7,"time":"2026-09-21T14:13:20Z"}"#)
        // A line nobody can read is skipped; a link is not written through.
        try Data((String(lines.joined(separator: "\n")) + "\nnot json\n{\"event\":\"nosuch\",\"time\":\"2026-09-21T14:13:20Z\"}\n").utf8).write(to: log.url)
        #expect(log.events().count == written.count)
        let outside = scratch.root.appendingPathComponent("outside.txt")
        try Data("mine".utf8).write(to: outside)
        let linked = BoxEventLog(url: scratch.root.appendingPathComponent("linked.jsonl"))
        #expect(symlink(outside.path, linked.url.path) == 0)
        #expect(linked.append(.init(.stop)) != nil)
        #expect(try String(contentsOf: outside, encoding: .utf8) == "mine")
    }

    @Test func theLogMovesOnAtItsLimitAndLongTextIsCut() throws {
        let scratch = try Scratch()
        let log = BoxEventLog(url: scratch.root.appendingPathComponent("events.jsonl"), maxBytes: 400)
        for index in 0..<20 {
            #expect(log.append(.init(.view, time: Self.now.addingTimeInterval(Double(index)), pid: 1, interactive: index % 2 == 0)) == nil)
        }
        #expect(FileManager.default.fileExists(atPath: log.url.path + ".1"))
        let read = log.events()
        // Both files are read, in order; what moved out before the previous file is gone.
        #expect(read.count < 20 && read.count >= 6)
        #expect(read.map(\.time) == read.map(\.time).sorted() && read.last?.time == Self.now.addingTimeInterval(19))
        let long = String(repeating: "x", count: 5000)
        let wide = BoxEventLog(url: scratch.root.appendingPathComponent("wide.jsonl"))
        #expect(wide.append(.init(.send, path: long, items: (0..<300).map { .init(name: "\(long)\($0)") }, detail: long)) != nil)
        #expect(wide.append(.init(.send, path: long, items: (0..<3).map { .init(name: "\(long)\($0)") }, detail: long)) == nil)
        let cut = try #require(wide.events().first)
        #expect(cut.path?.count == 1027 && cut.detail?.hasSuffix("...") == true && cut.items?.count == 3 && cut.items?.first?.name.count == 1027)
        // Cut by scalars: one character of many combining marks is no way past the line's limit.
        let marks = "a" + String(repeating: "\u{301}", count: 100_000)
        #expect(marks.count == 1 && wide.append(.init(.ready, time: Self.now, detail: marks)) == nil)
        #expect(wide.events().last?.detail?.unicodeScalars.count == 1027)
        #expect(BoxEventLog.fileSize(wide.url.path) ?? 0 > 0 && BoxEventLog.fileSize(scratch.root.path) == nil)
    }

    @Test func aRuleChangeIsAnEventAndTheLogIsKeptWithTheBox() throws {
        let fixture = try BoxScratch()
        let box = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images,
                                           network: BoxNetwork(mode: .allowlist, allow: ["a.example"]))
        let log = BoxEventLog(url: box.eventsLogURL)
        #expect(log.events().isEmpty)
        // Saving the same rules is no change.
        _ = try fixture.boxes.updateNetwork(named: "b1", to: BoxNetwork(mode: .allowlist, allow: ["a.example"]))
        #expect(log.events().isEmpty)
        _ = try fixture.boxes.updateNetwork(named: "b1", to: BoxNetwork(mode: .allowlist, allow: ["a.example", "b.example"]))
        _ = try fixture.boxes.updateNetwork(named: "b1", to: BoxNetwork(mode: .off, allow: ["a.example", "b.example"]))
        let events = log.events()
        #expect(events.map(\.event) == [.rules, .rules])
        #expect(events[0].before?.allow == ["a.example"] && events[0].after?.allow == ["a.example", "b.example"])
        #expect(events[0].running == false && events[0].pid == getpid())
        #expect(events[1].before?.mode == .allowlist && events[1].after?.mode == .off)
        // Deleted, the box leaves its events with its other logs.
        let kept = try #require(try fixture.boxes.delete(named: "b1").keptLogs)
        let logs = KeptLogs(root: fixture.boxes.root)
        #expect(logs.list().first?.files == ["events.jsonl.gz"])
        let readable = try logs.readable(kept.lastPathComponent, temporary: fixture.scratch.root)
        #expect(BoxEventLog(url: readable.folder.appendingPathComponent("events.jsonl")).events() == events)
    }

    @Test func anExecStartNamesItsVariablesAndSecrets() throws {
        let scratch = try Scratch()
        let log = ExecLog(url: scratch.root.appendingPathComponent("exec.jsonl"))
        #expect(ExecLog.names([String]()) == nil)
        #expect(ExecLog.names(["B", "A", "B"]) == ["A", "B"])
        // What `--env c2VjcmV0=` or `--env "Bearer abc=x"` makes a name of is a value: not recorded.
        #expect(try ExecEnvironment.overrides(base: [:], files: [], entries: ["c2VjcmV0=", "Bearer abc=x", "9=1", "OK=1"], host: [:]).keys.sorted() == ["9", "Bearer abc", "OK", "c2VjcmV0"])
        #expect(ExecLog.names(["Bearer abc", "9", "a-b", "OK", ""]) == ["OK"])
        #expect(ExecLog.names(["Bearer abc"]) == nil)
        #expect(ExecLog.names((0..<500).map { "V\($0)" })?.count == 200)
        #expect(ExecLog.names([String(repeating: "N", count: 500)])?.first?.count == 203)
        #expect(log.append(ExecLog.Entry(id: "p1", event: .start, time: Self.now, argv: ["/bin/agent"], user: "agent",
                                         envNames: ExecLog.names(["TOKEN", "LANG"]), secretNames: ExecLog.names(["api_token"])) ) == nil)
        #expect(log.append(ExecLog.Entry(id: "p2", event: .start, time: Self.now, argv: ["/bin/ls"], user: "agent")) == nil)
        let records = log.records()
        #expect(records[0].envNames == ["LANG", "TOKEN"] && records[0].secretNames == ["api_token"])
        #expect(records[1].envNames == nil && records[1].secretNames == nil)
        // A line without them has no key for them.
        let text = try String(contentsOf: log.url, encoding: .utf8)
        #expect(text.split(separator: "\n")[1].contains("Names") == false)
    }
}
