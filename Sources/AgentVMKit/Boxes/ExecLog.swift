// Sources/AgentVMKit/Boxes/ExecLog.swift
//
// What ran in a box: `agent-vm exec` (and `box shell`) append a line when a program starts and
// another when it ends, in Boxes/<name>/exec.jsonl on the Mac, where nothing in the box can
// change them. The program's arguments, account, folders and exit status are recorded; its
// environment never is (it may hold API keys). A client killed with SIGKILL leaves a start
// without an end.

import Darwin
import Foundation

public final class ExecLog: @unchecked Sendable {
    public enum Event: String, Codable, Sendable {
        case start
        case end
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
        /// The exec client on the Mac, and the program in the guest.
        public var hostPid: Int32?
        public var guestPid: Int32?
        /// The shell status exec exited with (the program's, or 125-127 for failures).
        public var status: Int32?
        public var seconds: Double?

        public init(id: String, event: Event, time: Date, argv: [String]? = nil, user: String? = nil, cwd: String? = nil,
                    project: String? = nil, readOnly: Bool? = nil, terminal: Bool? = nil, hostPid: Int32? = nil,
                    guestPid: Int32? = nil, status: Int32? = nil, seconds: Double? = nil) {
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
                records[position].guestPid = records[position].guestPid ?? entry.guestPid
            }
        }
        if let count, records.count > count {
            return Array(records.suffix(max(count, 0)))
        }
        return records
    }

    /// A short random id pairing a start with its end.
    public static func newID() -> String {
        return String(UUID().uuidString.prefix(8)).lowercased()
    }
}
