// Tests/AgentVMKitTests/SessionActivityTests.swift
//
// A session's programs and network: the run noted in the session's folder, the programs read
// back from the box's exec log, the box's network over the session's time, the same from the
// kept logs once the box is deleted, and those logs staying while the session does.

import Foundation
import Testing
@testable import AgentVMKit

@Suite struct SessionActivityTests {
    struct Fixture {
        let boxes: BoxScratch
        let sessions: SessionStore
        let session: Session
        var root: URL { boxes.boxes.root }
        /// A minute on: the session is active, and its window ends now.
        var soon: Date { Date().addingTimeInterval(60) }

        init() throws {
            boxes = try BoxScratch()
            sessions = SessionStore(root: boxes.boxes.root)
            let project = boxes.scratch.root.appendingPathComponent("project", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: project.appendingPathComponent("file.txt"))
            session = try sessions.start(project: project.path)
        }

        /// A box whose logs hold one program of the session, one of no session, a connection
        /// during the session and one from the day before.
        func boxWithARun(_ name: String, exec: String) throws -> Box {
            let box = try boxes.boxes.create(name: name, from: boxes.image, imageStore: boxes.images)
            let log = ExecLog(url: box.execLogURL)
            let start = session.record.startedAt
            #expect(log.append(ExecLog.Entry(id: exec, event: .start, time: start.addingTimeInterval(1), argv: ["/bin/agent", "go"], user: "agent",
                                             project: session.record.project, session: session.id)) == nil)
            #expect(log.append(ExecLog.Entry(id: exec, event: .end, time: start.addingTimeInterval(2), status: 3, seconds: 1)) == nil)
            #expect(log.append(ExecLog.Entry(id: exec + "-other", event: .start, time: start.addingTimeInterval(1), argv: ["/bin/ls"], user: "agent")) == nil)
            #expect(sessions.noteRun(SessionRun(box: name, exec: exec, time: start.addingTimeInterval(1)), in: session) == nil)
            func line(_ host: String, _ offset: TimeInterval, up: Int) -> String {
                let time = ISO8601DateFormatter().string(from: start.addingTimeInterval(offset))
                return #"{"time":"\#(time)","timeMilliseconds":0,"method":"CONNECT","host":"\#(host)","port":443,"decision":"allowed","rule":"public","id":"\#(host)","bytesUp":\#(up),"bytesDown":7}"# + "\n"
            }
            // A connection in the second the session started in counts, though its logged time
            // (whole seconds) is before the session's start to the nanosecond.
            try Data((line("before.example", -86400, up: 999) + line("during.example", 5, up: 3000) + line("first.example", 0, up: 1000)).utf8)
                .write(to: NetworkLog.allowedURL(for: box.networkLogURL))
            return box
        }
    }

    @Test func aProgramStartedForAProjectIsOfItsActiveSession() throws {
        let fixture = try Fixture()
        #expect(fixture.sessions.activeSession(project: fixture.session.record.project)?.id == fixture.session.id)
        #expect(fixture.sessions.activeSession(project: fixture.session.record.project + "/sub") == nil)
        #expect(SessionStore(root: fixture.boxes.scratch.root.appendingPathComponent("no-store")).activeSession(project: "/x") == nil)
        #expect(fixture.sessions.runs(of: fixture.session).isEmpty)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        for index in 0..<3 {
            #expect(fixture.sessions.noteRun(SessionRun(box: "b\(index % 2)", exec: "e\(index)", time: now), in: fixture.session) == nil)
        }
        #expect(fixture.sessions.runs(of: fixture.session) == [SessionRun(box: "b0", exec: "e0", time: now), SessionRun(box: "b1", exec: "e1", time: now),
                                                               SessionRun(box: "b0", exec: "e2", time: now)])
        // An ended session takes no more programs.
        _ = try fixture.sessions.end(id: fixture.session.id)
        #expect(fixture.sessions.activeSession(project: fixture.session.record.project) == nil)
    }

    @Test func theSessionsProgramsAndNetworkAreReadFromItsBox() throws {
        let fixture = try Fixture()
        #expect(SessionActivity.of(fixture.session, root: fixture.root, now: fixture.soon).isEmpty)
        _ = try fixture.boxWithARun("b1", exec: "run1")
        let activity = SessionActivity.of(fixture.session, root: fixture.root, now: fixture.soon)
        #expect(activity.boxes == ["b1"] && activity.notes.isEmpty)
        #expect(activity.programs.map(\.program.id) == ["run1"])
        #expect(activity.programs.first?.box == "b1" && activity.programs.first?.program.status == 3)
        #expect(activity.programs.first?.program.session == fixture.session.id)
        // Only the connection made during the session.
        #expect(activity.network.hosts.map(\.host) == ["during.example", "first.example"])
        #expect(activity.network.bytesUp == 4000 && activity.network.connections == 2)
        #expect(activity.line { "\($0) B" } == "1 program in box b1; 2 hosts, 4000 B sent, 0 refused")
        // Once the session has ended, what the box does later is not of it: the connection made
        // five seconds on (the session ends at once here), and one an hour later.
        let ended = try fixture.sessions.end(id: fixture.session.id)
        let later = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let more = #"{"time":"\#(later)","timeMilliseconds":0,"method":"CONNECT","host":"after.example","port":443,"decision":"denied"}"# + "\n"
        try Data(more.utf8).write(to: fixture.boxes.boxes.box(named: "b1").networkLogURL)
        #expect(SessionActivity.of(ended, root: fixture.root, now: Date().addingTimeInterval(7200)).network.hosts.map(\.host) == ["first.example"])
        // A connection in the second the session ended in counts too, with the session read
        // back from its record, where the end is a whole second like the log's times.
        let stored = try fixture.sessions.session(id: fixture.session.id)
        let end = ISO8601DateFormatter().string(from: try #require(stored.record.endedAt))
        let last = #"{"time":"\#(end)","timeMilliseconds":0,"method":"CONNECT","host":"last.example","port":443,"decision":"denied"}"# + "\n"
        try Data((more + last).utf8).write(to: fixture.boxes.boxes.box(named: "b1").networkLogURL)
        #expect(SessionActivity.of(stored, root: fixture.root, now: Date().addingTimeInterval(7200)).network.hosts.map(\.host).sorted() == ["first.example", "last.example"])
    }

    @Test func aDeletedBoxIsReadFromItsKeptLogsWhichStayWithTheSession() throws {
        let fixture = try Fixture()
        _ = try fixture.boxWithARun("b1", exec: "run1")
        let before = SessionActivity.of(fixture.session, root: fixture.root, now: fixture.soon)
        let kept = try #require(try fixture.boxes.boxes.delete(named: "b1").keptLogs)
        let logs = KeptLogs(root: fixture.root)
        #expect(logs.list().first?.logs.sessions == [fixture.session.id])
        let after = SessionActivity.of(fixture.session, root: fixture.root, now: fixture.soon, temporary: fixture.boxes.scratch.root)
        #expect(after == before)
        // The expanded copy is gone again.
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.boxes.scratch.root.path).filter { $0.hasPrefix("agent-vm-kept-") }.isEmpty)
        // A box of the same name made again adds its own programs, and loses none.
        _ = try fixture.boxWithARun("b1", exec: "run2")
        #expect(SessionActivity.of(fixture.session, root: fixture.root, now: fixture.soon).programs.map(\.program.id).sorted() == ["run1", "run2"])
        _ = try fixture.boxes.boxes.delete(named: "b1")

        // While the session is not discarded its logs are not removed for their age by a gc,
        // and are by hand.
        let old = Date().addingTimeInterval(40 * 86400)
        #expect(logs.removeOlder(keepingSessions: true, now: old).removed.isEmpty)
        #expect(logs.list().count == 2)
        _ = try fixture.sessions.end(id: fixture.session.id)
        #expect(logs.removeOlder(keepingSessions: true, now: old).removed.isEmpty)
        // A record nobody can read is not known to be discarded: the logs stay.
        let recordURL = fixture.session.directory.appendingPathComponent("session.json")
        let record = try Data(contentsOf: recordURL)
        try Data("{".utf8).write(to: recordURL)
        #expect(logs.removeOlder(keepingSessions: true, now: old).removed.isEmpty)
        try record.write(to: recordURL)
        _ = try fixture.sessions.discard(id: fixture.session.id)
        #expect(logs.removeOlder(keepingSessions: true, now: old).removed.count == 2)
        _ = kept
        // With the logs gone the report says so instead of showing nothing.
        let gone = SessionActivity.of(try fixture.sessions.session(id: fixture.session.id), root: fixture.root)
        #expect(gone.programs.isEmpty && gone.boxes == ["b1"])
        #expect(gone.notes == ["the logs of box b1 are gone: its programs and connections are not listed"])
    }

    @Test func aStoreThatKeepsNoLogsKeepsNoneForASessionEither() throws {
        let fixture = try Fixture()
        _ = try fixture.boxWithARun("b1", exec: "run1")
        let logs = KeptLogs(root: fixture.root)
        _ = try #require(try fixture.boxes.boxes.delete(named: "b1").keptLogs)
        try logs.setHoldDays(0)
        #expect(logs.removeOlder(keepingSessions: true).removed.count == 1)
        // By hand, a live session's logs go too.
        try logs.setHoldDays(30)
        _ = try fixture.boxWithARun("b2", exec: "run2")
        _ = try fixture.boxes.boxes.delete(named: "b2")
        #expect(logs.removeOlder(thanDays: 0).removed.count == 1)
    }
}
