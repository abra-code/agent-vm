// Sources/AgentVMKit/Boxes/BoxEvents.swift
//
// What happened to a box that is neither a program (ExecLog) nor a connection (NetworkLog): it
// started and stopped, a folder of the Mac was shared with it, its rules were changed, its
// screen was shown and typed into, files were sent to it. One JSON object per line in
// Boxes/<name>/events.jsonl on the Mac, where nothing in the box can change it; at `maxBytes`
// the file moves to `events.jsonl.1`, replacing the previous one.
//
// The supervisor writes what it does (start, ready, stop, share, unshare, view, type); the
// command that changes the rules writes `rules`, also for a stopped box, and the one that sends
// files writes `send`. `supervisor.log` stays as it is, for a person finding out why a box did
// not start; this file is for a program, and for reading the network log against the rules
// that were in force at the time.

import Darwin
import Foundation

public struct BoxEventLog: Sendable {
    public enum Kind: String, Codable, Sendable {
        /// The supervisor started the box's virtual machine.
        case start
        /// The guest daemon answered: programs can run.
        case ready
        case stop
        /// A folder of the Mac became the box's project (`path`, `readOnly`).
        case share
        case unshare
        /// The box's network rules or mode changed (`before`, `after`).
        case rules
        /// The box's screen was shown in a window (`interactive`).
        case view
        /// Something was typed into the screen: the account's password (`password`), or text
        /// of `characters` characters. What was typed is never here.
        case type
        /// Files were copied into the box (`items`).
        case send
    }

    /// A file or folder sent to the box.
    public struct Item: Codable, Equatable, Sendable {
        /// Its name on the Mac, without the folder it was in.
        public var name: String
        /// The name it got in the box's Downloads folder, when another.
        public var received: String?
        /// A file's size; absent for a folder.
        public var bytes: Int64?

        public init(name: String, received: String? = nil, bytes: Int64? = nil) {
            self.name = name
            self.received = received
            self.bytes = bytes
        }
    }

    public struct Event: Codable, Equatable, Sendable {
        public var time: Date
        public var event: Kind
        /// The process that wrote the line: the box's supervisor, or the agent-vm that changed
        /// the rules or sent the files.
        public var pid: Int32?
        /// share, unshare: the folder on the Mac.
        public var path: String?
        public var readOnly: Bool?
        public var interactive: Bool?
        public var password: Bool?
        public var characters: Int?
        public var before: BoxNetwork?
        public var after: BoxNetwork?
        /// rules: whether the box ran, so that the change took effect at once.
        public var running: Bool?
        public var items: [Item]?
        /// start: the image and the network mode; ready: the guest daemon's version; stop:
        /// why, when it was not asked for.
        public var detail: String?

        public init(_ event: Kind, time: Date = Date(), pid: Int32? = getpid(), path: String? = nil, readOnly: Bool? = nil,
                    interactive: Bool? = nil, password: Bool? = nil, characters: Int? = nil, before: BoxNetwork? = nil,
                    after: BoxNetwork? = nil, running: Bool? = nil, items: [Item]? = nil, detail: String? = nil) {
            self.time = time
            self.event = event
            self.pid = pid
            self.path = path
            self.readOnly = readOnly
            self.interactive = interactive
            self.password = password
            self.characters = characters
            self.before = before
            self.after = after
            self.running = running
            self.items = items
            self.detail = detail
        }
    }

    public let url: URL
    /// The size at which the log moves to `<name>.1` (replacing the previous one).
    public let maxBytes: Int64
    /// A longer line is not written: nothing here is long but a list of sent files.
    static let maxLineBytes = 64 << 10
    /// The most sent items one line names.
    static let maxItems = 100
    static let maxTextLength = 1024

    public init(url: URL, maxBytes: Int64 = 4 << 20) {
        self.url = url
        self.maxBytes = maxBytes
    }

    /// The size of a regular file, for a sent item; nil for a folder or anything else.
    public static func fileSize(_ path: String) -> Int64? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            return nil
        }
        return Int64(info.st_size)
    }

    static func clipped(_ text: String?) -> String? {
        // By scalars: one character can be any number of them (combining marks), and the cut
        // is what keeps a line under `maxLineBytes`.
        guard let text, text.unicodeScalars.count > maxTextLength else {
            return text
        }
        return String(text.unicodeScalars.prefix(maxTextLength)) + "..."
    }

    /// Appends one line; returns why it could not, if so. One write per line: the supervisor
    /// and commands may append at once.
    @discardableResult
    public func append(_ event: Event) -> String? {
        var event = event
        event.path = Self.clipped(event.path)
        event.detail = Self.clipped(event.detail)
        if let items = event.items {
            event.items = items.prefix(Self.maxItems).map { Item(name: Self.clipped($0.name) ?? "", received: Self.clipped($0.received), bytes: $0.bytes) }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(event) else {
            return "the event could not be encoded"
        }
        line.append(10)
        guard line.count <= Self.maxLineBytes else {
            return "the event is \(line.count) bytes long"
        }
        var info = stat()
        if lstat(url.path, &info) == 0, info.st_size + Int64(line.count) > maxBytes {
            _ = rename(url.path, url.path + ".1")
        }
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
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

    /// The last `count` events (all when nil) that `matching` accepts, oldest first, from the
    /// file before this one (`.1`) and this one; unreadable lines are skipped.
    public func events(last count: Int? = nil, matching: (Event) -> Bool = { _ in true }) -> [Event] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var events: [Event] = []
        for path in [url.path + ".1", url.path] {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                continue
            }
            for line in text.split(separator: "\n") {
                if let event = try? decoder.decode(Event.self, from: Data(line.utf8)), matching(event) {
                    events.append(event)
                }
            }
        }
        if let count, events.count > count {
            return Array(events.suffix(max(count, 0)))
        }
        return events
    }
}
