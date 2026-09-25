// Sources/AgentVMKit/Sessions/Session.swift
//
// A session is one agent run against one project folder in Live mode: the agent edits the real
// folder, and a copy-on-write snapshot taken at the start makes the whole run inspectable and
// undoable. The record below is what `session.json` holds; the snapshot itself is the folder
// `snapshot` next to it.

import Foundation

public struct SessionRecord: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        /// Snapshot taken; the agent may still be working on the project.
        case active
        /// The run is over; the snapshot is kept for reports and undo.
        case ended
        /// The project was restored from the snapshot; the replaced tree is kept for recovery.
        case undone
        /// Snapshot and replaced tree deleted; only this record remains.
        case discarded
    }

    /// Bumped on incompatible changes to this record.
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var id: String
    /// Canonical absolute path of the project folder.
    public var project: String
    /// `st_dev` of the project folder at start; undo refuses if the folder moved volumes.
    public var projectDevice: Int64
    /// Host wall-clock time taken just before the snapshot, to the nanosecond. Anything in the
    /// project whose status-change time (ctime) is not earlier than this changed during the session.
    public var startSeconds: Int64
    public var startNanoseconds: Int64
    public var state: State
    public var endedAt: Date?
    public var undoneAt: Date?
    /// Name (inside the session folder) of the tree that `undo` replaced, if any.
    public var replacedTree: String?

    public var startedAt: Date {
        return Date(timeIntervalSince1970: Double(startSeconds) + Double(startNanoseconds) / 1_000_000_000)
    }
}

public struct Session: Sendable {
    public let record: SessionRecord
    /// The session's folder in the store.
    public let directory: URL

    public var id: String { record.id }

    public var snapshotPath: String {
        return directory.appendingPathComponent(SessionStore.snapshotName).path
    }

    public var replacedTreePath: String? {
        return record.replacedTree.map { directory.appendingPathComponent($0).path }
    }
}

/// A session as the command line prints it: the record's fields, plus `snapshotPath` while the
/// snapshot exists. The path is not saved in session.json, where it would go stale if the store
/// moved.
public struct SessionOutput: Encodable, Sendable {
    public let record: SessionRecord
    public let snapshotPath: String?

    public init(_ session: Session) {
        record = session.record
        snapshotPath = session.record.state == .discarded ? nil : session.snapshotPath
    }

    enum Keys: String, CodingKey {
        case snapshotPath
    }

    public func encode(to encoder: Encoder) throws {
        try record.encode(to: encoder)
        var container = encoder.container(keyedBy: Keys.self)
        try container.encodeIfPresent(snapshotPath, forKey: .snapshotPath)
    }
}
