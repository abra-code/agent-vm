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
        self.root = FileSystem.canonicalRoot(root)
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
        try StoreRoot.prepare(root)
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

    /// What changed in the project since the session's snapshot.
    public func report(id: String) throws -> ChangeReport {
        let current = try session(id: id)
        guard current.record.state != .discarded else {
            throw AgentVMError.wrongSessionState(id: id, state: current.record.state.rawValue, operation: "report on")
        }
        try requireProject(of: current)
        return try ChangeScanner.report(session: current)
    }

    public enum UndoMode: String, Sendable {
        /// Restore only the entries the change report lists; the project folder keeps its identity.
        case changedFiles
        /// Swap the whole project folder with a copy of the snapshot in one atomic step.
        case wholeTree
    }

    public struct UndoOutcome: Sendable {
        public let session: Session
        /// Details of a file-by-file undo (nil for a whole-tree undo).
        public let restore: RestoreResult?

        /// True when the project now matches the snapshot.
        public var isComplete: Bool {
            return restore.map { $0.failed.isEmpty && $0.remaining == 0 } ?? true
        }
    }

    /// Restores the project folder to its state at session start. What the agent left is moved
    /// into the session folder (`replaced-<ts>/`, never deleted) and the snapshot stays.
    ///
    /// - `changedFiles` (default) touches only what changed, so editors and shells with the
    ///   project open stay attached. If some entry cannot be restored, the session stays
    ///   undoable: retry, or use `wholeTree`.
    /// - `wholeTree` swaps folder identities: programs that still have the project open keep
    ///   seeing the replaced tree until they reopen it.
    ///
    /// `paths` (changed files only) restores just those entries of the change report and what
    /// is under them, relative to the project or absolute inside it; the rest of the session
    /// stays undoable. The session becomes `undone` only once nothing changed remains.
    ///
    /// Stop the agent first either way.
    @discardableResult
    public func undo(id: String, mode: UndoMode = .changedFiles, paths: [String]? = nil) throws -> UndoOutcome {
        return try withLock {
            let current = try session(id: id)
            let state = current.record.state
            guard state == .active || state == .ended else {
                throw AgentVMError.wrongSessionState(id: id, state: state.rawValue, operation: "undo")
            }
            try requireProject(of: current)
            guard FileSystem.exists(current.snapshotPath) else {
                throw AgentVMError.corruptSessionRecord(path: current.directory.path, reason: "the snapshot folder is missing")
            }
            if mode == .wholeTree, let paths {
                throw AgentVMError.invalidUndoPath(paths.first ?? "", reason: "a whole-tree undo restores everything")
            }
            // An empty selection is a caller's mistake, not "everything".
            if let paths, paths.isEmpty {
                throw AgentVMError.invalidUndoPath("", reason: "no paths given; undo without paths restores everything")
            }
            let report = mode == .changedFiles ? try ChangeScanner.report(session: current) : nil
            // Paths are checked before anything moves.
            let selected = try paths.map { try Self.undoSelection($0.map { try relativeUndoPath($0, project: current.record.project) }, in: report?.changes ?? []) }
            let replacedName = try unusedReplacedName(in: current.directory)
            let replacedPath = current.directory.appendingPathComponent(replacedName).path
            switch mode {
            case .wholeTree:
                return UndoOutcome(session: try swapWholeTree(current, replacedName: replacedName, replacedPath: replacedPath),
                                   restore: nil)
            case .changedFiles:
                let changes = selected?.changes ?? report!.changes.filter { !$0.coveredByAncestor }
                var restore = try ProjectRestorer.restore(session: current, changes: changes, replacedPath: replacedPath)
                // The project has already changed: a failed check must not abort before the
                // record (and the replaced folder's name) is saved.
                var nothingLeft = false
                do {
                    let left = try ChangeScanner.report(session: current).changes.filter { !$0.coveredByAncestor }
                    nothingLeft = left.isEmpty
                    // For a selection, what is left of it.
                    restore.remaining = selected.map { selection in left.filter { selection.includes($0.path) }.count } ?? left.count
                } catch {
                    restore.failed["."] = "could not verify the result: \(error)"
                }
                var record = current.record
                record.replacedTree = replacedName
                if restore.failed.isEmpty && nothingLeft {
                    record.state = .undone
                    record.undoneAt = Date()
                    if record.endedAt == nil {
                        record.endedAt = record.undoneAt
                    }
                }
                let updated = Session(record: record, directory: current.directory)
                try save(updated)
                return UndoOutcome(session: updated, restore: restore)
            }
        }
    }

    /// The entries `session undo --path` restores.
    struct UndoSelection {
        /// The paths asked for, relative to the project.
        let paths: [String]
        /// The changes to restore, none inside another one of them that covers it.
        let changes: [Change]

        func includes(_ path: String) -> Bool {
            return paths.contains { RelativePath.isWithin(path, $0) }
        }
    }

    /// The listed changes at or under `paths`. A path must be a change or hold changes. An
    /// entry inside a folder the agent deleted or replaced cannot come back without that
    /// folder, so it is refused, naming the folder; inside a folder the agent added, an entry
    /// the report lists (it carries a flag) is moved aside on its own.
    static func undoSelection(_ paths: [String], in changes: [Change]) throws -> UndoSelection {
        var chosen: [Change] = []
        for path in paths {
            let under = changes.filter { RelativePath.isWithin($0.path, path) }
            // The nearest change that covers `path` as a whole: an added, deleted or retyped folder.
            let enclosing = changes.filter { $0.path != path && RelativePath.isWithin(path, $0.path) && !$0.coveredByAncestor && $0.entriesInside != nil }
                .max { RelativePath.depth($0.path) < RelativePath.depth($1.path) }
            if let enclosing, enclosing.kind != .added {
                throw AgentVMError.invalidUndoPath(path, reason: "it is inside \(enclosing.path), which the agent \(enclosing.kind == .deleted ? "deleted" : "replaced") as a whole; undo --path \(enclosing.path)")
            }
            // Inside an added folder, only what the report lists: an unlisted folder there would
            // lose only its flagged entries and look undone.
            guard !under.isEmpty, enclosing == nil || under.contains(where: { $0.path == path }) else {
                let reason = enclosing.map { "it is inside \($0.path), which the agent added as a whole; undo --path \($0.path) to remove it all" }
                    ?? "it did not change in this session (`agent-vm session report` lists what did)"
                throw AgentVMError.invalidUndoPath(path, reason: reason)
            }
            for change in under where !chosen.contains(where: { $0.path == change.path }) {
                chosen.append(change)
            }
        }
        // A covered entry goes only when no folder holding it is restored too: neither the
        // change covering it nor a listed added folder above it (moved aside as one).
        let covering = chosen.filter { $0.entriesInside != nil || ($0.kind == .added && $0.type == .directory) }
        let changes = chosen.filter { change in
            !change.coveredByAncestor || !covering.contains { $0.path != change.path && RelativePath.isWithin(change.path, $0.path) }
        }
        return UndoSelection(paths: paths, changes: changes.sorted { $0.path < $1.path })
    }

    /// `path` relative to the project: given relative, or absolute inside the project. No "."
    /// or ".." components; "." alone (or the project's path) is the project folder's own
    /// permissions and flags, as the report lists them.
    func relativeUndoPath(_ path: String, project: String) throws -> String {
        var relative = path
        if path == "." || path == project || path == project + "/" {
            return "."
        }
        if path.hasPrefix("/") {
            let prefix = project + "/"
            guard path.unicodeScalars.starts(with: prefix.unicodeScalars) else {
                throw AgentVMError.invalidUndoPath(path, reason: "it is not inside the project \(project)")
            }
            relative = String(path.unicodeScalars.dropFirst(prefix.unicodeScalars.count))
        }
        // "./README.md", as shell completion writes it.
        while relative.hasPrefix("./") {
            relative = String(relative.unicodeScalars.dropFirst(2))
        }
        let components = RelativePath.components(relative)
        guard !components.isEmpty else {
            throw AgentVMError.invalidUndoPath(path, reason: "it names no entry")
        }
        guard !components.contains(where: { $0 == "." || $0 == ".." }) else {
            throw AgentVMError.invalidUndoPath(path, reason: "use a path without . or .. components, as `session report` lists them")
        }
        return components.joined(separator: "/")
    }

    /// Throws unless the recorded project folder is still there, a folder, on the same volume.
    private func requireProject(of session: Session) throws {
        let project = session.record.project
        guard let projectInfo = try? FileSystem.statusRemovingUnreadableACL(project),
              FileSystem.isDirectory(projectInfo),
              Int64(projectInfo.st_dev) == session.record.projectDevice else {
            throw AgentVMError.projectMissing(path: project)
        }
    }

    /// `replaced-<timestamp>`, with a counter if an earlier undo attempt used the same second.
    private func unusedReplacedName(in directory: URL) throws -> String {
        let base = Self.replacedPrefix + Self.timestamp(Date())
        var name = base
        var counter = 1
        while FileSystem.exists(directory.appendingPathComponent(name).path) {
            counter += 1
            guard counter < 100 else {
                throw AgentVMError.system(operation: "prepare \(directory.appendingPathComponent(base).path)", code: EEXIST)
            }
            name = base + "-\(counter)"
        }
        return name
    }

    private func swapWholeTree(_ current: Session, replacedName: String, replacedPath: String) throws -> Session {
        let project = current.record.project
        do {
            // Clone the snapshot under its final "replaced" name, then swap it with the project:
            // afterwards the project holds the snapshot's content and this name holds what the
            // agent left behind.
            try FileSystem.cloneTree(current.snapshotPath, to: replacedPath)
            do {
                try FileSystem.swapEntries(replacedPath, project)
            } catch {
                try? FileSystem.removeTree(replacedPath)
                throw error
            }
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
            // Keep disk and record consistent: swap back and drop the restored copy.
            if (try? FileSystem.swapEntries(replacedPath, project)) != nil {
                try? FileSystem.removeTree(replacedPath)
            }
            throw error
        }
        return updated
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
            // Every replaced tree, including those of undo attempts that did not complete: only
            // direct children of the session folder named the way this tool names them.
            let children: [String]
            do {
                children = try FileManager.default.contentsOfDirectory(atPath: current.directory.path)
            } catch {
                throw AgentVMError.system(operation: "list \(current.directory.path)", code: FileSystem.posixCode(error))
            }
            for name in children where name.hasPrefix(Self.replacedPrefix) && !name.contains("/") {
                try FileSystem.removeTree(current.directory.appendingPathComponent(name).path)
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

    /// Discards every ended or undone session that ended at least `age` seconds before `now`
    /// (sessions from before `endedAt` existed count from their start). Active sessions are
    /// left alone, however old: an agent may still be working. One failure does not stop the
    /// others; each is returned with its reason. `unreadable` are the records that could not be
    /// read, as `listWithProblems` reports them.
    public func discard(olderThan age: TimeInterval, now: Date = Date()) throws -> (discarded: [Session], failures: [String], unreadable: [String]) {
        let cutoff = now.addingTimeInterval(-age)
        let (sessions, unreadable) = try listWithProblems()
        var discarded: [Session] = []
        var failures: [String] = []
        for session in sessions {
            let record = session.record
            guard record.state == .ended || record.state == .undone, (record.endedAt ?? record.startedAt) <= cutoff else {
                continue
            }
            do {
                discarded.append(try discard(id: session.id))
            } catch AgentVMError.wrongSessionState {
                // Discarded meanwhile by another agent-vm.
                continue
            } catch {
                failures.append("\(session.id): \(error)")
            }
        }
        return (discarded, failures, unreadable)
    }

    // MARK: - Validation

    /// Resolves and checks a project path: an existing folder, not `/`, not the home folder or
    /// one of its ancestors, and not overlapping the session store.
    /// The canonical project folder for `path`, or why it cannot be one: it must exist, be a
    /// folder, and be neither the whole disk, the home folder or a folder containing it, nor
    /// overlap the agent-vm store.
    public func validatedProject(_ path: String) throws -> String {
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
        // By identity, walking up from the home folder: an alias path for the home folder or a
        // folder above it (/System/Volumes/Data/Users/<me>) must not pass.
        let home = (try? FileSystem.canonicalPath(NSHomeDirectory())) ?? NSHomeDirectory()
        guard let projectID = FileSystem.identity(project) else {
            throw AgentVMError.unsuitableProject(path: project, reason: "it cannot be examined")
        }
        var ancestor = home
        while true {
            if FileSystem.identity(ancestor) == projectID {
                throw AgentVMError.unsuitableProject(path: project, reason: "it is your home folder or contains it; choose the project folder itself")
            }
            if ancestor == "/" {
                break
            }
            ancestor = (ancestor as NSString).deletingLastPathComponent
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
        try StoreRoot.prepare(root)
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
