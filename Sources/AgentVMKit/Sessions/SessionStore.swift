// Sources/AgentVMKit/Sessions/SessionStore.swift
//
// Creates and manages Live-mode sessions. Layout under the store root
// (`$AGENT_VM_HOME`, default `~/Library/Application Support/agent-vm`):
//
//   Sessions/.lock                 flock serializing every state change
//   Sessions/<id>/session.json     the SessionRecord
//   Sessions/<id>/snapshot/        APFS clone of the project taken at start
//   Sessions/<id>/replaced-<ts>/   the tree `undo` swapped out (kept for recovery)
//
// The snapshot is a copy-on-write clone, so it costs almost no space until the agent changes
// files. Undo clones the snapshot again and swaps the clone with the project folder in one
// atomic rename, so the snapshot survives and the project is never half-restored.

import Darwin
import Foundation

public struct SessionStore: Sendable {
    static let snapshotName = "snapshot"
    static let recordName = "session.json"
    static let replacedPrefix = "replaced-"

    /// Root of all agent-vm state.
    public let root: URL

    public init(root: URL) {
        // Canonical path (for example /var -> /private/var) so every printed and recorded path
        // matches realpath(3); a root that does not exist yet is resolved through its parent.
        let given = root.standardizedFileURL
        if let resolved = try? FileSystem.canonicalPath(given.path) {
            self.root = URL(fileURLWithPath: resolved, isDirectory: true)
        } else if let parent = try? FileSystem.canonicalPath(given.deletingLastPathComponent().path) {
            self.root = URL(fileURLWithPath: parent, isDirectory: true).appendingPathComponent(given.lastPathComponent, isDirectory: true)
        } else {
            self.root = given
        }
    }

    /// `$AGENT_VM_HOME` if set and non-empty, otherwise `~/Library/Application Support/agent-vm`.
    public static func defaultRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["AGENT_VM_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Application Support/agent-vm", isDirectory: true)
    }

    public var sessionsDirectory: URL {
        return root.appendingPathComponent("Sessions", isDirectory: true)
    }

    // MARK: - Operations

    /// Takes a snapshot of `projectPath` and records a new active session.
    @discardableResult
    public func start(project projectPath: String) throws -> Session {
        try FileSystem.makeDirectories(sessionsDirectory.path)
        let project = try validatedProject(projectPath)
        let projectInfo = try FileSystem.status(project)
        let storeInfo = try FileSystem.status(sessionsDirectory.path)
        guard projectInfo.st_dev == storeInfo.st_dev else {
            throw AgentVMError.differentVolume(project: project, store: sessionsDirectory.path)
        }

        return try withLock {
            if let active = try list().first(where: { $0.record.state == .active && $0.record.project == project }) {
                throw AgentVMError.sessionAlreadyActive(project: project, id: active.id)
            }
            let id = Self.newID()
            let directory = sessionsDirectory.appendingPathComponent(id, isDirectory: true)
            try FileSystem.makeDirectory(directory.path)

            // Taken BEFORE the clone: anything that changes from here on has a later ctime.
            let start = FileSystem.now()
            do {
                try FileSystem.cloneTree(project, to: directory.appendingPathComponent(Self.snapshotName).path)
            } catch {
                try? FileSystem.removeTree(directory.path)
                throw error
            }

            let record = SessionRecord(
                formatVersion: SessionRecord.currentFormatVersion,
                id: id,
                project: project,
                projectDevice: Int64(projectInfo.st_dev),
                startSeconds: Int64(start.tv_sec),
                startNanoseconds: Int64(start.tv_nsec),
                state: .active,
                endedAt: nil,
                undoneAt: nil,
                replacedTree: nil)
            let session = Session(record: record, directory: directory)
            do {
                try save(session)
            } catch {
                try? FileSystem.removeTree(directory.path)
                throw error
            }
            return session
        }
    }

    /// Loads one session by id.
    public func session(id: String) throws -> Session {
        guard Self.isValidID(id) else {
            throw AgentVMError.invalidSessionID(id)
        }
        let directory = sessionsDirectory.appendingPathComponent(id, isDirectory: true)
        let recordPath = directory.appendingPathComponent(Self.recordName).path
        guard FileSystem.exists(recordPath) else {
            throw AgentVMError.sessionNotFound(id)
        }
        return Session(record: try loadRecord(at: recordPath, expectedID: id), directory: directory)
    }

    /// All sessions, oldest first. Folders that are not sessions are ignored, and so are sessions
    /// whose record cannot be read (see `listWithProblems` for those).
    public func list() throws -> [Session] {
        return try listWithProblems().sessions
    }

    /// All readable sessions, oldest first, plus one message per session record that could not
    /// be read. One damaged record must not block every other session.
    public func listWithProblems() throws -> (sessions: [Session], problems: [String]) {
        guard FileSystem.exists(sessionsDirectory.path) else {
            return ([], [])
        }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: sessionsDirectory.path)
        } catch {
            throw AgentVMError.system(operation: "list \(sessionsDirectory.path)", code: FileSystem.posixCode(error))
        }
        var sessions: [Session] = []
        var problems: [String] = []
        for id in names.filter(Self.isValidID) {
            let directory = sessionsDirectory.appendingPathComponent(id, isDirectory: true)
            let recordPath = directory.appendingPathComponent(Self.recordName).path
            guard FileSystem.exists(recordPath) else {
                continue
            }
            do {
                sessions.append(Session(record: try loadRecord(at: recordPath, expectedID: id), directory: directory))
            } catch {
                problems.append("\(error)")
            }
        }
        // By recorded start time (nanoseconds), then id: ids alone only have one-second resolution.
        sessions.sort {
            ($0.record.startSeconds, $0.record.startNanoseconds, $0.id) < ($1.record.startSeconds, $1.record.startNanoseconds, $1.id)
        }
        return (sessions, problems)
    }

    /// Marks an active session as ended. The snapshot is kept.
    @discardableResult
    public func end(id: String) throws -> Session {
        return try withLock {
            let current = try session(id: id)
            guard current.record.state == .active else {
                throw AgentVMError.wrongSessionState(id: id, state: current.record.state.rawValue, operation: "end")
            }
            var record = current.record
            record.state = .ended
            record.endedAt = Date()
            let updated = Session(record: record, directory: current.directory)
            try save(updated)
            return updated
        }
    }

    /// Restores the project folder to its state at session start. The replaced tree is moved
    /// into the session folder (not deleted) and the snapshot stays, so nothing is lost.
    ///
    /// Programs that still have the project open (an editor, a shell, an agent) keep seeing the
    /// replaced tree, because the swap exchanges folder identities; stop the agent first.
    @discardableResult
    public func undo(id: String) throws -> Session {
        return try withLock {
            let current = try session(id: id)
            let state = current.record.state
            guard state == .active || state == .ended else {
                throw AgentVMError.wrongSessionState(id: id, state: state.rawValue, operation: "undo")
            }
            let project = current.record.project
            guard let projectInfo = try? FileSystem.statusRemovingUnreadableACL(project),
                  FileSystem.isDirectory(projectInfo),
                  Int64(projectInfo.st_dev) == current.record.projectDevice else {
                throw AgentVMError.projectMissing(path: project)
            }
            guard FileSystem.exists(current.snapshotPath) else {
                throw AgentVMError.corruptSessionRecord(path: current.directory.path, reason: "the snapshot folder is missing")
            }

            // Clone the snapshot under its final "replaced" name, then swap it with the project:
            // afterwards the project holds the snapshot's content and this name holds what the
            // agent left behind.
            let replacedName = Self.replacedPrefix + Self.timestamp(Date())
            let replacedPath = current.directory.appendingPathComponent(replacedName).path
            guard !FileSystem.exists(replacedPath) else {
                throw AgentVMError.system(operation: "prepare \(replacedPath)", code: EEXIST)
            }
            try FileSystem.cloneTree(current.snapshotPath, to: replacedPath)
            do {
                try FileSystem.swapEntries(replacedPath, project)
            } catch {
                try? FileSystem.removeTree(replacedPath)
                throw error
            }

            var record = current.record
            record.state = .undone
            record.undoneAt = Date()
            if record.endedAt == nil {
                record.endedAt = record.undoneAt
            }
            record.replacedTree = replacedName
            let updated = Session(record: record, directory: current.directory)
            do {
                try save(updated)
            } catch {
                // Keep disk and record consistent: without the record, the replaced tree would be
                // orphaned (discard would never delete it). Swap back and drop the restored copy.
                if (try? FileSystem.swapEntries(replacedPath, project)) != nil {
                    try? FileSystem.removeTree(replacedPath)
                }
                throw error
            }
            return updated
        }
    }

    /// Deletes the snapshot and any replaced tree. The record stays, marked discarded, so the
    /// history of what ran remains visible.
    @discardableResult
    public func discard(id: String) throws -> Session {
        return try withLock {
            let current = try session(id: id)
            guard current.record.state != .discarded else {
                throw AgentVMError.wrongSessionState(id: id, state: current.record.state.rawValue, operation: "discard")
            }
            try FileSystem.removeTree(current.snapshotPath)
            if let replaced = current.record.replacedTree {
                // The name comes from the record; only ever delete a direct child of the session
                // folder that this tool could have created.
                guard replaced.hasPrefix(Self.replacedPrefix), !replaced.contains("/"), replaced != ".." else {
                    throw AgentVMError.corruptSessionRecord(
                        path: current.directory.path, reason: "unexpected replaced-tree name \(replaced)")
                }
                try FileSystem.removeTree(current.directory.appendingPathComponent(replaced).path)
            }
            var record = current.record
            record.state = .discarded
            if record.endedAt == nil {
                record.endedAt = Date()
            }
            let updated = Session(record: record, directory: current.directory)
            try save(updated)
            return updated
        }
    }

    // MARK: - Validation

    /// Resolves and checks a project path: an existing folder, not `/`, not the home folder or
    /// one of its ancestors, and not overlapping the session store.
    func validatedProject(_ path: String) throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let project: String
        do {
            project = try FileSystem.canonicalPath(expanded)
        } catch {
            throw AgentVMError.unsuitableProject(path: path, reason: "it does not exist")
        }
        guard FileSystem.isDirectory(try FileSystem.status(project)) else {
            throw AgentVMError.unsuitableProject(path: project, reason: "it is not a folder")
        }
        guard project != "/" else {
            throw AgentVMError.unsuitableProject(path: project, reason: "the whole disk cannot be a project")
        }
        let home = (try? FileSystem.canonicalPath(NSHomeDirectory())) ?? NSHomeDirectory()
        if project == home || Self.isInside(home, project) {
            throw AgentVMError.unsuitableProject(path: project, reason: "it is your home folder or contains it; choose the project folder itself")
        }
        let store = (try? FileSystem.canonicalPath(root.path)) ?? root.path
        if project == store || Self.isInside(store, project) || Self.isInside(project, store) {
            throw AgentVMError.unsuitableProject(path: project, reason: "it overlaps the agent-vm store \(store)")
        }
        return project
    }

    /// True when `path` is strictly inside `folder` (both canonical).
    static func isInside(_ path: String, _ folder: String) -> Bool {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return path.hasPrefix(prefix)
    }

    // MARK: - Ids

    /// `YYYYMMDD-HHMMSS-xxxx`: sortable by start time, unique enough with the random suffix and
    /// the exclusive `mkdir` that creates the folder.
    static func newID(now: Date = Date()) -> String {
        let suffix = String(format: "%04x", UInt16.random(in: 0...UInt16.max))
        return timestamp(now) + "-" + suffix
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// Ids are used as folder names, so only the exact generated shape is accepted.
    static func isValidID(_ id: String) -> Bool {
        return id.range(of: #"^[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$"#, options: .regularExpression) != nil
    }

    // MARK: - Persistence

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileSystem.makeDirectories(sessionsDirectory.path)
        return try FileSystem.withExclusiveLock(at: sessionsDirectory.appendingPathComponent(".lock").path, body)
    }

    private func save(_ session: Session) throws {
        let path = session.directory.appendingPathComponent(Self.recordName)
        do {
            try Self.encoder.encode(session.record).write(to: path, options: .atomic)
        } catch {
            throw AgentVMError.corruptSessionRecord(path: path.path, reason: "cannot write: \(error.localizedDescription)")
        }
    }

    private func loadRecord(at path: String, expectedID: String) throws -> SessionRecord {
        let record: SessionRecord
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            record = try Self.decoder.decode(SessionRecord.self, from: data)
        } catch {
            throw AgentVMError.corruptSessionRecord(path: path, reason: error.localizedDescription)
        }
        guard record.id == expectedID else {
            throw AgentVMError.corruptSessionRecord(path: path, reason: "it names session \(record.id)")
        }
        guard record.formatVersion <= SessionRecord.currentFormatVersion else {
            throw AgentVMError.corruptSessionRecord(path: path, reason: "written by a newer agent-vm (format \(record.formatVersion))")
        }
        return record
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
