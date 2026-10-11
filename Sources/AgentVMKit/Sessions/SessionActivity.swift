// Sources/AgentVMKit/Sessions/SessionActivity.swift
//
// What ran and what was contacted during a session, beside what changed in the project: the
// three records of one run, tied together.
//
// A session is of a project, and a program `agent-vm exec --project` (or `box shell`, or avm)
// starts in a box is of that session when the session is active for the project at that
// moment. The start line of the box's exec log then names the session, and the session's folder
// gets a line that names the box:
//
//   Sessions/<id>/runs.jsonl     one line per program: the box, the exec id, the time
//
// From those, `SessionActivity` reads the programs back from the boxes' exec logs and adds up
// the boxes' network logs over the session's time. A box that was deleted since is read from
// its kept logs (KeptLogs), which name the sessions whose programs they hold.
//
// The network part is of the box over that time, not of the session's programs alone: the
// proxy cannot tell which program made a connection, so anything else that ran in the same box
// meanwhile is in it too.

import Darwin
import Foundation

/// One program of a session: where it ran.
public struct SessionRun: Codable, Equatable, Sendable {
    public var box: String
    /// The program's id in the box's exec log.
    public var exec: String
    public var time: Date

    public init(box: String, exec: String, time: Date) {
        self.box = box
        self.exec = exec
        self.time = time
    }
}

extension SessionStore {
    static let runsName = "runs.jsonl"
    /// Runs are no longer noted past this size: about ten thousand programs.
    static let runsLimit: Int64 = 1 << 20

    /// The session that is active for `project` (a canonical path, as a session records it);
    /// nil when there is none or the sessions cannot be read.
    public func activeSession(project: String) -> Session? {
        guard FileSystem.exists(sessionsDirectory.path), let sessions = try? list() else {
            return nil
        }
        return sessions.first { $0.record.state == .active && $0.record.project == project }
    }

    /// Notes in the session's folder that a program of it started in `box`. One write of one
    /// line, so several programs can note at once. Returns why it could not, if so.
    @discardableResult
    public func noteRun(_ run: SessionRun, in session: Session) -> String? {
        let path = session.directory.appendingPathComponent(Self.runsName).path
        var info = stat()
        if lstat(path, &info) == 0, info.st_size >= Self.runsLimit {
            return "the session's list of programs is full"
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(run) else {
            return "the run could not be encoded"
        }
        line.append(10)
        let descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            return String(cString: strerror(errno))
        }
        defer { close(descriptor) }
        do {
            try FrameChannel.writeAll(descriptor, Array(line))
        } catch {
            return "\(error)"
        }
        return nil
    }

    /// The programs noted for the session, in the order they started; unreadable lines are
    /// skipped.
    public func runs(of session: Session) -> [SessionRun] {
        guard let text = try? String(contentsOf: session.directory.appendingPathComponent(Self.runsName), encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? decoder.decode(SessionRun.self, from: Data($0.utf8)) }
    }
}

/// The programs and the network of one session.
public struct SessionActivity: Encodable, Equatable, Sendable {
    public struct Program: Encodable, Equatable, Sendable {
        public var box: String
        public var program: ExecLog.Record
    }

    /// The boxes the session's programs ran in, in the order first used.
    public var boxes: [String]
    /// The programs, in the order they started.
    public var programs: [Program]
    /// The network of those boxes from the session's start to its end (or to now), by host.
    public var network: NetworkSummary
    /// What could not be read: a box whose logs are gone.
    public var notes: [String]

    public var isEmpty: Bool {
        return programs.isEmpty && network.hosts.isEmpty
    }

    /// Reads the session's activity from the store at `root`. Kept logs are expanded into
    /// `temporary` for the reading and removed again.
    public static func of(_ session: Session, root: URL, now: Date = Date(),
                          temporary: URL = FileManager.default.temporaryDirectory) -> SessionActivity {
        let sessions = SessionStore(root: root)
        let boxStore = BoxStore(root: root)
        let kept = KeptLogs(root: root)
        var boxes: [String] = []
        for run in sessions.runs(of: session) where !boxes.contains(run.box) && ImageStore.isValidName(run.box) {
            boxes.append(run.box)
        }
        let window = Self.window(of: session.record, now: now)
        let keptEntries = boxes.isEmpty ? [] : kept.list()
        let renamed = boxes.isEmpty ? [] : ((try? boxStore.list().boxes) ?? []).filter { $0.record.formerNames != nil }
        var programs: [Program] = []
        var entries: [NetworkLog.Entry] = []
        var notes: [String] = []
        // The folders read so far (a kept folder by its id, a box by its path), and whether each
        // held programs of the session. A session that went on in a box after `box rename`
        // noted the box under both names: its logs are read once.
        var read: [String: Bool] = [:]
        for name in boxes {
            // The box as it is now, and every kept folder of a box of that name that holds
            // programs of this session (the box may have been deleted and made again).
            var folders: [(key: String, folder: URL, temporary: Bool)] = []
            var found = false
            for entry in keptEntries where (entry.logs.box == name || entry.logs.formerNames?.contains(name) == true)
                && entry.logs.sessions?.contains(session.id) == true {
                let key = "kept " + entry.logs.id
                if let held = read[key] {
                    found = found || held
                } else if let readable = try? kept.readable(entry.logs.id, temporary: temporary) {
                    folders.append((key, readable.folder, readable.temporary))
                } else {
                    read[key] = false
                    notes.append("the kept logs \(entry.logs.id) of box \(name) could not be read")
                }
            }
            var current: [Box] = []
            if let box = try? boxStore.box(named: name) {
                current.append(box)
            }
            // A box that had this name when the session ran (`box rename`).
            current += renamed.filter { $0.record.formerNames?.contains(name) == true }
            for box in current {
                if let held = read[box.directory.path] {
                    found = found || held
                } else {
                    folders.append((box.directory.path, box.directory, false))
                }
            }
            for source in folders {
                let ran = ExecLog(url: source.folder.appendingPathComponent(BoxStore.execLogName)).records { $0.session == session.id }
                read[source.key] = !ran.isEmpty
                if !ran.isEmpty {
                    found = true
                    programs += ran.map { Program(box: name, program: $0) }
                    // Nothing counts as open: a summary takes each connection's last bytes.
                    entries += NetworkLog(url: source.folder.appendingPathComponent(BoxStore.networkLogName))
                        .entries(liveSince: .distantFuture, matching: window.accepts)
                }
                if source.temporary {
                    try? FileSystem.removeTree(source.folder.path)
                }
            }
            if !found {
                notes.append("the logs of box \(name) are gone: its programs and connections are not listed")
            }
        }
        programs.sort { ($0.program.started, $0.program.id) < ($1.program.started, $1.program.id) }
        return SessionActivity(boxes: boxes, programs: programs, network: NetworkSummary(entries), notes: notes)
    }

    /// The session's time as a window on a log: from the second it started in (a log's times
    /// are whole seconds, so a connection made right after the start would else fall before it)
    /// to its end, or to `now` while it is active. The end is that of the second the session
    /// ended in, for the same reason: the record holds the end as a whole second, and a window
    /// ends before its `until`, so a connection made in the last second would else be left out.
    public static func window(of record: SessionRecord, now: Date = Date()) -> LogFilter {
        let until = record.endedAt.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down) + 1) } ?? now
        return LogFilter(since: Date(timeIntervalSince1970: TimeInterval(record.startSeconds)), until: until)
    }

    /// One line for the end of a run: "3 programs in box dev1; 12 hosts, 4.1 MB sent, 2 refused".
    /// `size` writes a number of bytes.
    public func line(size: (Int64) -> String) -> String? {
        guard !isEmpty else {
            return nil
        }
        var text = "\(programs.count) program\(programs.count == 1 ? "" : "s")"
        if !boxes.isEmpty {
            text += " in box\(boxes.count == 1 ? "" : "es") \(boxes.joined(separator: ", "))"
        }
        let hosts = network.hosts.count
        text += "; \(hosts) host\(hosts == 1 ? "" : "s"), \(size(Int64(network.bytesUp))) sent, \(network.refused) refused"
        return text
    }
}
