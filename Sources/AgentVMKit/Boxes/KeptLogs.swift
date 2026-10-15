// Sources/AgentVMKit/Boxes/KeptLogs.swift
//
// The logs of boxes that were deleted. A box's folder goes with the box (`box delete`, `box
// recreate`, `box gc`, a temporary box of `avm`), and its logs are the record of what ran in it
// and what it contacted, so they are taken out first, compressed (gzip):
//
//   Logs/<box>-<time>/kept.json                 which box they were of, and when it was deleted
//   Logs/<box>-<time>/supervisor.log.gz         the box's files, with their .1 files
//   Logs/<box>-<time>/network.jsonl.gz
//   Logs/<box>-<time>/network-allowed.jsonl.gz
//   Logs/<box>-<time>/exec.jsonl.gz
//   Logs/<box>-<time>/events.jsonl.gz
//   Logs/<box>-<time>/console.log.gz            a Linux box's
//   kept-logs.json                              in the store: for how many days they are kept
//
// <time> is when the box was deleted (UTC, yyyyMMdd-HHmmss). A box that logged nothing leaves
// nothing. A log that cannot be compressed is moved as it is, and the folders agent-vm 0.7.14
// and 0.7.15 made hold the files as they were; both are read like the others.
//
// Kept logs are removed `holdDays` days after the box was deleted, when `box gc` runs, or by
// hand (`store logs --remove`). `store logs --hold-days` changes the number; with 0 nothing is
// kept, and what was kept before goes at the next `box gc`.

import Darwin
import Foundation
import zlib

public struct KeptLogs: Sendable {
    /// How long a deleted box's logs are kept unless the store says otherwise.
    public static let defaultHoldDays = 30
    /// The most days `store logs --hold-days` takes.
    public static let maximumHoldDays = 3650
    static let recordName = "kept.json"
    static let settingsName = "kept-logs.json"
    static let compressedSuffix = ".gz"
    /// The largest log a compressed file is expanded to: a box's largest log is 64 MB.
    static let expandLimit: Int64 = 1 << 30

    /// The files of a box folder that are logs; each may have a ".1" file beside it.
    static var logNames: [String] {
        let network = URL(fileURLWithPath: BoxStore.networkLogName)
        return [BoxStore.logName, BoxStore.networkLogName, NetworkLog.allowedURL(for: network).lastPathComponent,
                BoxStore.execLogName, BoxStore.eventsLogName, ImageStore.consoleLogName]
    }

    public struct Record: Codable, Equatable, Sendable {
        public var formatVersion = 1
        /// The folder's name in Logs/: what `store logs --remove` takes.
        public var id: String
        public var box: String
        /// The names the box had before (`box rename`), when it had any.
        public var formerNames: [String]?
        /// What the box's record said; nil when it could not be read.
        public var image: String?
        public var guest: GuestKind?
        public var disposable: Bool?
        public var boxCreatedAt: Date?
        /// When the box was deleted.
        public var keptAt: Date
        /// What the logs took in the box's folder, before they were compressed. Absent in
        /// folders made before 0.7.16, which hold the files as they were.
        public var logBytes: Int64?
        /// The sessions whose programs ran in the box, as its exec log names them (agent-vm
        /// 0.7.17 and later). While one of them is not discarded, the logs are not removed for
        /// their age: a session's record of what ran lasts as long as the session.
        public var sessions: [String]?
    }

    /// One deleted box's logs, as `store logs` lists them.
    public struct Entry: Encodable, Equatable, Sendable {
        public var logs: Record
        public var path: String
        /// The log files there, by name.
        public var files: [String]
        /// What they take on disk now.
        public var bytes: Int64
    }

    /// All of them at a glance, for `status`.
    public struct Totals: Encodable, Equatable, Sendable {
        public var directory: String
        public var holdDays: Int
        public var count: Int
        public var bytes: Int64
    }

    struct Settings: Codable, Equatable {
        var holdDays: Int
    }

    public let root: URL

    public init(root: URL) {
        self.root = FileSystem.canonicalRoot(root)
    }

    public var directory: URL {
        return root.appendingPathComponent("Logs", isDirectory: true)
    }

    private var settingsURL: URL {
        return root.appendingPathComponent(Self.settingsName)
    }

    /// For how many days a deleted box's logs are kept in this store; 0: they are not kept.
    /// A setting that cannot be read, or is out of range, is the default.
    public var holdDays: Int {
        guard let data = try? Data(contentsOf: settingsURL), let settings = try? JSONDecoder().decode(Settings.self, from: data),
              (0...Self.maximumHoldDays).contains(settings.holdDays) else {
            return Self.defaultHoldDays
        }
        return settings.holdDays
    }

    /// Changes `holdDays` for this store.
    public func setHoldDays(_ days: Int) throws {
        guard (0...Self.maximumHoldDays).contains(days) else {
            throw AgentVMError.system(operation: "keep logs for \(days) days", code: EINVAL)
        }
        try FileSystem.makeDirectories(root.path)
        do {
            try JSONEncoder().encode(Settings(holdDays: days)).write(to: settingsURL, options: .atomic)
        } catch {
            throw AgentVMError.system(operation: "write \(settingsURL.path)", code: FileSystem.posixCode(error))
        }
    }

    /// Whether `id` can be the name of a folder in Logs/: a box's name, "-" and a time.
    public static func isValidID(_ id: String) -> Bool {
        return id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,90}$"#, options: .regularExpression) != nil
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// The log files in `folder` that hold something: regular files only, so nothing a link
    /// points at is ever moved or measured. With `kept`, a kept folder's: each name as it is or
    /// compressed.
    static func logFiles(in folder: URL, kept: Bool = false) -> [(name: String, bytes: Int64)] {
        var found: [(String, Int64)] = []
        // Plain paths: `status` measures every kept folder, and a URL costs more than the lstat.
        let path = folder.path + "/"
        for base in logNames {
            for name in [base, base + ".1"] {
                for stored in kept ? [name + compressedSuffix, name] : [name] {
                    var info = stat()
                    if lstat(path + stored, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0 {
                        found.append((stored, Int64(info.st_size)))
                    }
                }
            }
        }
        return found
    }

    /// Takes the logs out of a box's folder, which is about to be removed; the caller holds the
    /// box's lock. Returns where they are now, or nil when the box logged nothing or this store
    /// keeps no logs. `record` is the box's, when it could be read.
    func keep(box name: String, folder: URL, record: BoxRecord?, now: Date = Date()) throws -> URL? {
        guard holdDays > 0 else {
            return nil
        }
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
        // Read before the log is compressed away from where its reader finds it.
        var sessions: [String] = []
        for record in ExecLog(url: folder.appendingPathComponent(BoxStore.execLogName)).records() {
            if let session = record.session, !sessions.contains(session) {
                sessions.append(session)
            }
        }
        let kept = directory.appendingPathComponent(id, isDirectory: true)
        var moved = 0
        var logBytes: Int64 = 0
        var failure: AgentVMError?
        for file in files {
            let source = folder.appendingPathComponent(file.name).path
            let destination = kept.appendingPathComponent(file.name).path
            do {
                // Compressed when that works; as it is otherwise, so nothing is lost to it.
                do {
                    try Self.compress(source, to: destination + Self.compressedSuffix)
                } catch {
                    try FileSystem.rename(source, to: destination)
                }
                moved += 1
                logBytes += file.bytes
            } catch let error as AgentVMError {
                failure = failure ?? error
            }
        }
        guard moved > 0 else {
            _ = rmdir(kept.path)
            throw failure ?? AgentVMError.system(operation: "move the logs of box \(name)", code: EIO)
        }
        let entry = Record(id: id, box: name, formerNames: record?.formerNames, image: record?.image, guest: record?.effectiveGuest, disposable: record?.disposable,
                           boxCreatedAt: record?.createdAt, keptAt: now, logBytes: logBytes, sessions: sessions.isEmpty ? nil : sessions)
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

    // MARK: - Compression

    static let chunkSize = 256 << 10

    /// Writes `source` to a new file `destination` in gzip format (what `gunzip` and Finder
    /// expand). Neither path is followed when it is a link, and a file that is there is never
    /// replaced. On failure nothing is left at `destination`.
    static func compress(_ source: String, to destination: String) throws {
        let input = open(source, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard input >= 0 else {
            throw AgentVMError.system(operation: "read \(source)", code: errno)
        }
        defer { close(input) }
        let output = open(destination, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard output >= 0 else {
            throw AgentVMError.system(operation: "create \(destination)", code: errno)
        }
        // gzdopen takes the descriptor over: gzclose closes it.
        guard let file = gzdopen(output, "wb6") else {
            close(output)
            _ = unlink(destination)
            throw AgentVMError.system(operation: "compress \(source)", code: ENOMEM)
        }
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var code: Int32 = 0
        while code == 0 {
            let count = read(input, &buffer, buffer.count)
            if count == 0 {
                break
            }
            if count < 0 {
                code = errno == EINTR ? 0 : errno
                continue
            }
            if gzwrite(file, buffer, UInt32(count)) != Int32(count) {
                code = EIO
            }
        }
        // On the disk before the box's folder, the only other copy, is removed.
        if code == 0, gzflush(file, Z_FINISH) != Z_OK || fsync(output) != 0 {
            code = EIO
        }
        if gzclose(file) != Z_OK, code == 0 {
            code = EIO
        }
        guard code == 0 else {
            _ = unlink(destination)
            throw AgentVMError.system(operation: "compress \(source)", code: code)
        }
    }

    /// Writes what the gzip file `source` holds to a new file `destination`; more than `limit`
    /// bytes is refused. On failure nothing is left at `destination`.
    static func expand(_ source: String, to destination: String, limit: Int64 = KeptLogs.expandLimit) throws {
        let input = open(source, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard input >= 0 else {
            throw AgentVMError.system(operation: "read \(source)", code: errno)
        }
        guard let file = gzdopen(input, "rb") else {
            close(input)
            throw AgentVMError.system(operation: "expand \(source)", code: ENOMEM)
        }
        let output = open(destination, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard output >= 0 else {
            let code = errno
            _ = gzclose(file)
            throw AgentVMError.system(operation: "create \(destination)", code: code)
        }
        defer { close(output) }
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var written: Int64 = 0
        var code: Int32 = 0
        while code == 0 {
            let count = gzread(file, &buffer, UInt32(buffer.count))
            if count == 0 {
                break
            }
            written += Int64(max(count, 0))
            if count < 0 || written > limit {
                code = count < 0 ? EIO : EFBIG
                continue
            }
            do {
                try FrameChannel.writeAll(output, Array(buffer[0..<Int(count)]))
            } catch {
                code = EIO
            }
        }
        // A file cut short reads as far as it goes without an error: closing it is what tells.
        if gzclose(file) != Z_OK, code == 0 {
            code = EIO
        }
        guard code == 0 else {
            _ = unlink(destination)
            throw AgentVMError.system(operation: "expand \(source)", code: code)
        }
    }

    /// One deleted box's logs where they can be read as a box's are: its folder when the files
    /// are as they were, else a new private folder in `temporary` with every log expanded, which
    /// the caller removes when done (`temporary` is true then).
    public func readable(_ id: String, temporary parent: URL = FileManager.default.temporaryDirectory) throws -> (folder: URL, temporary: Bool) {
        let kept = try folder(of: id)
        let files = Self.logFiles(in: kept, kept: true)
        guard files.contains(where: { $0.name.hasSuffix(Self.compressedSuffix) }) else {
            return (kept, false)
        }
        var template = Array(parent.appendingPathComponent("agent-vm-kept-XXXXXX").path.utf8CString)
        guard mkdtemp(&template) != nil else {
            throw AgentVMError.system(operation: "create a folder in \(parent.path)", code: errno)
        }
        let folder = URL(fileURLWithPath: String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self), isDirectory: true)
        do {
            for file in files {
                let source = kept.appendingPathComponent(file.name).path
                if file.name.hasSuffix(Self.compressedSuffix) {
                    try Self.expand(source, to: folder.appendingPathComponent(String(file.name.dropLast(Self.compressedSuffix.count))).path)
                } else if !FileSystem.exists(folder.appendingPathComponent(file.name).path) {
                    // A clone when the store is on this volume, a copy when it is not.
                    do {
                        try BoxStore.cloneFile(URL(fileURLWithPath: source), to: folder.appendingPathComponent(file.name))
                    } catch {
                        try FileManager.default.copyItem(atPath: source, toPath: folder.appendingPathComponent(file.name).path)
                    }
                }
            }
        } catch {
            try? FileSystem.removeTree(folder.path)
            throw error
        }
        return (folder, true)
    }

    // MARK: - Listing and removing

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
            let files = Self.logFiles(in: folder, kept: true)
            entries.append(Entry(logs: record, path: folder.path, files: files.map(\.name), bytes: files.reduce(0) { $0 + $1.bytes }))
        }
        return entries.sorted { ($0.logs.keptAt, $0.logs.id) > ($1.logs.keptAt, $1.logs.id) }
    }

    /// How many are kept and what they take, without reading a record: every folder counts.
    public func totals() -> Totals {
        var count = 0
        var bytes: Int64 = 0
        for id in folders() {
            let folder = directory.appendingPathComponent(id, isDirectory: true)
            var info = stat()
            guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                continue
            }
            count += 1
            bytes += Self.logFiles(in: folder, kept: true).reduce(0) { $0 + $1.bytes }
        }
        return Totals(directory: directory.path, holdDays: holdDays, count: count, bytes: bytes)
    }

    /// Whether Logs/ has a folder of that name: one `list` shows, or one without a readable
    /// record, which `remove` takes too.
    public func exists(_ id: String) -> Bool {
        // Listed as it is: the disk ignores case, and a path made from "B0-..." opens "b0-...".
        return Self.isValidID(id) && (try? StoreName.isListed(id, in: directory)) == true
    }

    /// The folder of one deleted box's logs.
    public func folder(of id: String) throws -> URL {
        guard exists(id) else {
            throw AgentVMError.keptLogsNotFound(id)
        }
        return directory.appendingPathComponent(id, isDirectory: true)
    }

    /// Removes one deleted box's logs.
    public func remove(_ id: String) throws {
        let folder = directory.appendingPathComponent(id, isDirectory: true)
        guard exists(id) else {
            throw AgentVMError.keptLogsNotFound(id)
        }
        try FileSystem.removeTree(folder.path)
    }

    /// Whether one of `sessions` is still there to report on: not discarded.
    private func hasLiveSession(_ sessions: [String]?) -> Bool {
        guard let sessions, !sessions.isEmpty else {
            return false
        }
        let store = SessionStore(root: root)
        return sessions.contains { id in
            guard let session = try? store.session(id: id) else {
                // A record that cannot be read (damaged, or a newer agent-vm's) is not known
                // to be discarded: its logs stay. No folder at all is no session.
                return SessionStore.isValidID(id) && FileSystem.exists(store.sessionsDirectory.appendingPathComponent(id).path)
            }
            return session.record.state != .discarded
        }
    }

    /// Removes the logs of boxes deleted `days` or more days ago (nil: this store's
    /// `holdDays`); returns their ids, and what could not be removed. A folder without a
    /// readable record is as old as its last change. With `keepingSessions`, the logs of a
    /// session that is not discarded stay, whatever their age, unless this store keeps none.
    public func removeOlder(thanDays days: Int? = nil, keepingSessions: Bool = false, now: Date = Date()) -> (removed: [String], problems: [String]) {
        let hold = holdDays
        let days = days ?? hold
        var removed: [String] = []
        var problems: [String] = []
        for id in folders() {
            let folder = directory.appendingPathComponent(id, isDirectory: true)
            let record = record(of: id)
            var keptAt = record?.keptAt
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
            if keepingSessions, hold > 0, hasLiveSession(record?.sessions) {
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
