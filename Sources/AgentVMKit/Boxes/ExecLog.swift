// Sources/AgentVMKit/Boxes/ExecLog.swift
//
// What ran in a box: `agent-vm exec` (and `box shell`) append a line when a program starts and
// another when it ends, in Boxes/<name>/exec.jsonl on the Mac, where nothing in the box can
// change them; in between, a notice line as soon as a program waits on a permission prompt.
// The program's arguments, account, folders and exit status are recorded; its environment
// never is (it may hold API keys). A client killed with SIGKILL leaves a start without an end.

import Darwin
import Foundation

public final class ExecLog: @unchecked Sendable {
    public enum Event: String, Codable, Sendable {
        case start
        case end
        /// A program of the run waits on a permission prompt nobody sees (written at once).
        case notice
    }

    /// One line. A start has the program's details, an end its outcome; `id` pairs them.
    public struct Entry: Codable, Equatable, Sendable {
        public var id: String
        public var event: Event
        public var time: Date
        public var argv: [String]?
        public var user: String?
        public var cwd: String?
        public var project: String?
        public var readOnly: Bool?
        public var terminal: Bool?
        /// The exec client on the Mac, and the program in the guest (in a notice: the program
        /// that waits on the prompt, which may be one the exec'd program started).
        public var hostPid: Int32?
        public var guestPid: Int32?
        /// The shell status exec exited with (the program's, or 125-127 for failures).
        public var status: Int32?
        public var seconds: Double?
        /// What the program waited on a permission prompt for (an end line; see GuestNotice).
        public var prompts: [String]?
        /// A notice: what the program waits for in words ("the Downloads folder"), the privacy
        /// service, the program, and whether agent-vm set out to stop it (`exec --prompts stop`;
        /// written before the kill, whose rare failure is reported on the exec's stderr).
        public var prompt: String?
        public var service: String?
        public var program: String?
        public var stopped: Bool?

        public init(id: String, event: Event, time: Date, argv: [String]? = nil, user: String? = nil, cwd: String? = nil,
                    project: String? = nil, readOnly: Bool? = nil, terminal: Bool? = nil, hostPid: Int32? = nil,
                    guestPid: Int32? = nil, status: Int32? = nil, seconds: Double? = nil, prompts: [String]? = nil,
                    prompt: String? = nil, service: String? = nil, program: String? = nil, stopped: Bool? = nil) {
            self.prompt = prompt
            self.service = service
            self.program = program
            self.stopped = stopped
            self.prompts = prompts
            self.id = id
            self.event = event
            self.time = time
            self.argv = argv
            self.user = user
            self.cwd = cwd
            self.project = project
            self.readOnly = readOnly
            self.terminal = terminal
            self.hostPid = hostPid
            self.guestPid = guestPid
            self.status = status
            self.seconds = seconds
        }
    }

    /// A start and its end, if one was written.
    public struct Record: Codable, Equatable, Sendable {
        public var id: String
        public var started: Date
        public var argv: [String]
        public var user: String?
        public var cwd: String?
        public var project: String?
        public var readOnly: Bool?
        public var terminal: Bool?
        public var hostPid: Int32?
        public var guestPid: Int32?
        /// Nil while running, or when the client died without writing an end.
        public var status: Int32?
        public var seconds: Double?
        /// Permission prompts the program waited on, as soon as each was noticed.
        public var prompts: [String]?
        /// Whether agent-vm stopped a program that waited on one (`exec --prompts stop`).
        public var stoppedOnPrompt: Bool?
    }

    public let url: URL
    /// The size at which the log moves to `<name>.1` (replacing the previous one).
    public let maxBytes: Int64

    public init(url: URL, maxBytes: Int64 = 16 << 20) {
        self.url = url
        self.maxBytes = maxBytes
    }

    /// Appends one line; a failure to write is ignored (the program still runs).
    public func append(_ entry: Entry) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(entry) else {
            return
        }
        line.append(10)
        var info = stat()
        if lstat(url.path, &info) == 0, info.st_size + Int64(line.count) > maxBytes {
            _ = rename(url.path, url.path + ".1")
        }
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            return
        }
        defer { close(descriptor) }
        // One write per line: several exec clients may append at once.
        try? FrameChannel.writeAll(descriptor, Array(line))
    }

    /// The last `count` programs (all when nil), oldest first; unreadable lines are skipped.
    public func records(last count: Int? = nil) -> [Record] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var records: [Record] = []
        var index: [String: Int] = [:]
        for line in text.split(separator: "\n") {
            guard let entry = try? decoder.decode(Entry.self, from: Data(line.utf8)) else {
                continue
            }
            switch entry.event {
            case .start:
                index[entry.id] = records.count
                records.append(Record(id: entry.id, started: entry.time, argv: entry.argv ?? [], user: entry.user, cwd: entry.cwd,
                                      project: entry.project, readOnly: entry.readOnly, terminal: entry.terminal,
                                      hostPid: entry.hostPid, guestPid: entry.guestPid))
            case .end:
                guard let position = index[entry.id] else {
                    continue
                }
                records[position].status = entry.status
                records[position].seconds = entry.seconds
                records[position].prompts = Self.merged(records[position].prompts, entry.prompts ?? [])
                records[position].guestPid = records[position].guestPid ?? entry.guestPid
            case .notice:
                guard let position = index[entry.id] else {
                    continue
                }
                records[position].prompts = Self.merged(records[position].prompts, entry.prompt.map { [$0] } ?? [])
                if entry.stopped == true {
                    records[position].stoppedOnPrompt = true
                }
            }
        }
        if let count, records.count > count {
            return Array(records.suffix(max(count, 0)))
        }
        return records
    }

    /// `list` with `more` added, each once, in order; nil when empty.
    static func merged(_ list: [String]?, _ more: [String]) -> [String]? {
        var result = list ?? []
        for item in more where !result.contains(item) {
            result.append(item)
        }
        return result.isEmpty ? nil : result
    }

    /// A short random id pairing a start with its end.
    public static func newID() -> String {
        return String(UUID().uuidString.prefix(8)).lowercased()
    }
}
