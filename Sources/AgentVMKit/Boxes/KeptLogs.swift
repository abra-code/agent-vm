// Sources/AgentVMKit/Boxes/KeptLogs.swift
//
// The logs of boxes that were deleted. A box's folder goes with the box (`box delete`, `box
// recreate`, `box gc`, a temporary box of `avm`), and its logs are the record of what ran in it
// and what it contacted, so they are moved out first:
//
//   Logs/<box>-<time>/kept.json              which box they were of, and when it was deleted
//   Logs/<box>-<time>/supervisor.log         the box's files, as they were, with their .1 files
//   Logs/<box>-<time>/network.jsonl
//   Logs/<box>-<time>/network-allowed.jsonl
//   Logs/<box>-<time>/exec.jsonl
//   Logs/<box>-<time>/console.log            a Linux box's
//
// <time> is when the box was deleted (UTC, yyyyMMdd-HHmmss). A box that logged nothing leaves
// nothing. Kept logs are removed `holdDays` after the box was deleted, when `box gc` runs, or
// by hand (`store logs --remove`).

import Darwin
import Foundation

public struct KeptLogs: Sendable {
    /// How long a deleted box's logs are kept.
    public static let holdDays = 30
    static let recordName = "kept.json"

    /// The files of a box folder that are logs; each may have a ".1" file beside it.
    static var logNames: [String] {
        let network = URL(fileURLWithPath: BoxStore.networkLogName)
        return [BoxStore.logName, BoxStore.networkLogName, NetworkLog.allowedURL(for: network).lastPathComponent,
                BoxStore.execLogName, ImageStore.consoleLogName]
    }

    public struct Record: Codable, Equatable, Sendable {
        public var formatVersion = 1
        /// The folder's name in Logs/: what `store logs --remove` takes.
        public var id: String
        public var box: String
        /// What the box's record said; nil when it could not be read.
        public var image: String?
        public var guest: GuestKind?
        public var disposable: Bool?
        public var boxCreatedAt: Date?
        /// When the box was deleted.
        public var keptAt: Date
    }

    /// One deleted box's logs, as `store logs` lists them.
    public struct Entry: Encodable, Equatable, Sendable {
        public var logs: Record
        public var path: String
        /// The log files there, by name.
        public var files: [String]
        public var bytes: Int64
    }

    public let root: URL

    public init(root: URL) {
        self.root = FileSystem.canonicalRoot(root)
    }

    public var directory: URL {
        return root.appendingPathComponent("Logs", isDirectory: true)
    }

    /// Whether `id` can be the name of a folder in Logs/: a box's name, "-" and a time.
    public static func isValidID(_ id: String) -> Bool {
        return id.range(of: #"^[a-z0-9][a-z0-9._-]{0,90}$"#, options: .regularExpression) != nil
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// The log files in `folder` that hold something: regular files only, so nothing a link
    /// points at is ever moved or measured.
    static func logFiles(in folder: URL) -> [(name: String, bytes: Int64)] {
        var found: [(String, Int64)] = []
        for base in logNames {
            for name in [base, base + ".1"] {
                var info = stat()
                if lstat(folder.appendingPathComponent(name).path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0 {
                    found.append((name, Int64(info.st_size)))
                }
            }
        }
        return found
    }

    /// Moves the logs out of a box's folder, which is about to be removed; the caller holds the
    /// box's lock. Returns where they are now, or nil when the box logged nothing. `record` is
    /// the box's, when it could be read.
    func keep(box name: String, folder: URL, record: BoxRecord?, now: Date = Date()) throws -> URL? {
        let files = Self.logFiles(in: folder)
        guard !files.isEmpty else {
            return nil
        }
        try FileSystem.makeDirectories(directory.path)
        let base = "\(name)-\(Self.stamp(now))"
        var id = base
        var attempt = 1
        while mkdir(directory.appendingPathComponent(id).path, 0o700) != 0 {
            let code = errno
            attempt += 1
            guard code == EEXIST, attempt <= 100 else {
                throw AgentVMError.system(operation: "create folder \(directory.appendingPathComponent(id).path)", code: code)
            }
            id = "\(base)-\(attempt)"
        }
        let kept = directory.appendingPathComponent(id, isDirectory: true)
        var moved = 0
        var failure: AgentVMError?
        for file in files {
            do {
                try FileSystem.rename(folder.appendingPathComponent(file.name).path, to: kept.appendingPathComponent(file.name).path)
                moved += 1
            } catch let error as AgentVMError {
                failure = failure ?? error
            }
        }
        guard moved > 0 else {
            _ = rmdir(kept.path)
            throw failure ?? AgentVMError.system(operation: "move the logs of box \(name)", code: EIO)
        }
        let entry = Record(id: id, box: name, image: record?.image, guest: record?.effectiveGuest, disposable: record?.disposable,
                           boxCreatedAt: record?.createdAt, keptAt: now)
        // Without its record the folder is still there to open, and is removed by its age.
        try? SessionStore.encoder.encode(entry).write(to: kept.appendingPathComponent(Self.recordName), options: .atomic)
        if let failure {
            throw Partial.some(kept: kept, reason: "\(failure)")
        }
        return kept
    }

    /// Some of a box's logs were kept and some could not be moved.
    enum Partial: Error {
        case some(kept: URL, reason: String)
    }

    /// The folders in Logs/, by name; nothing when there is no such folder.
    private func folders() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter(Self.isValidID).sorted()
    }

    private func record(of id: String) -> Record? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(id).appendingPathComponent(Self.recordName)),
              let record = try? SessionStore.decoder.decode(Record.self, from: data), record.id == id else {
            return nil
        }
        return record
    }

    /// Every deleted box's logs, the newest first. A folder without a readable record is not
    /// listed; it is still removed by its age.
    public func list() -> [Entry] {
        var entries: [Entry] = []
        for id in folders() {
            guard let record = record(of: id) else {
                continue
            }
            let folder = directory.appendingPathComponent(id, isDirectory: true)
            let files = Self.logFiles(in: folder)
            entries.append(Entry(logs: record, path: folder.path, files: files.map(\.name), bytes: files.reduce(0) { $0 + $1.bytes }))
        }
        return entries.sorted { ($0.logs.keptAt, $0.logs.id) > ($1.logs.keptAt, $1.logs.id) }
    }

    /// Whether Logs/ has a folder of that name: one `list` shows, or one without a readable
    /// record, which `remove` takes too.
    public func exists(_ id: String) -> Bool {
        return Self.isValidID(id) && FileSystem.exists(directory.appendingPathComponent(id, isDirectory: true).path)
    }

    /// Removes one deleted box's logs.
    public func remove(_ id: String) throws {
        let folder = directory.appendingPathComponent(id, isDirectory: true)
        guard exists(id) else {
            throw AgentVMError.keptLogsNotFound(id)
        }
        try FileSystem.removeTree(folder.path)
    }

    /// Removes the logs of boxes deleted `days` or more days ago; returns their ids, and what
    /// could not be removed. A folder without a readable record is as old as its last change.
    public func removeOlder(thanDays days: Int = KeptLogs.holdDays, now: Date = Date()) -> (removed: [String], problems: [String]) {
        var removed: [String] = []
        var problems: [String] = []
        for id in folders() {
            let folder = directory.appendingPathComponent(id, isDirectory: true)
            var keptAt = record(of: id)?.keptAt
            if keptAt == nil {
                var info = stat()
                guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                    continue
                }
                keptAt = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            }
            guard let keptAt, now.timeIntervalSince(keptAt) >= TimeInterval(days) * 86400 else {
                continue
            }
            do {
                try FileSystem.removeTree(folder.path)
                removed.append(id)
            } catch {
                // Gone all the same: another gc, or `store logs --remove`, was removing it too.
                guard FileSystem.exists(folder.path) else {
                    continue
                }
                problems.append("cannot remove the kept logs \(id): \(error)")
            }
        }
        return (removed, problems)
    }
}
