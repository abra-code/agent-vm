// Sources/AgentVMKit/Connect/ConnectChoices.swift
//
// What `agent-vm connect` (avm) last chose for each project folder, in <store>/connect.json, so
// the pickers start at it, and which of the person's own agent entries they have agreed to
// run. A missing, unreadable or damaged file reads as no choices and no agreements, never an
// error: the pickers start at the top, and an agent is asked about again. Nothing secret is
// kept: folder paths, box and image names, what ran, agent ids and file digests.

import Darwin
import Foundation

/// What is snapshotted of a folder shared read-write before a session.
public enum SnapshotChoice: String, Codable, CaseIterable, Equatable, Sendable {
    /// Every file and folder.
    case whole
    /// Only the git folders (every `.git` under the folder).
    case git
    /// Nothing: no report and no undo afterwards.
    case none

    /// For a person: "snapshot: <words>".
    public var words: String {
        switch self {
        case .whole: return "whole folder"
        case .git: return "git folders only"
        case .none: return "none"
        }
    }

    /// What the choice means for the session, in a line.
    public var meaning: String {
        switch self {
        case .whole: return "every file: any change is reported and can be undone"
        case .git: return "every .git folder only: fast for a huge folder; working files are not covered"
        case .none: return "nothing: no report and no undo after the session"
        }
    }

    /// The avm option that asks for it.
    public var option: String {
        switch self {
        case .whole: return "--whole-snapshot"
        case .git: return "--git-snapshot"
        case .none: return "--no-snapshot"
        }
    }
}

public struct ConnectChoice: Codable, Equatable, Sendable {
    public enum Target: String, Codable, Sendable {
        /// An existing box (`box`).
        case box
        /// A temporary box from `image`.
        case temporary
    }

    public var target: Target
    public var box: String?
    public var image: String?
    /// What ran: "shell", or an agent's id.
    public var launch: String?
    public var readOnly: Bool?
    /// What was snapshotted of the folder; nil (a file of an earlier agent-vm, or a folder
    /// only ever shared read only): the whole folder.
    public var snapshot: SnapshotChoice?
    /// Whether the box was stopped after the session, when that was asked or named; nil: never
    /// yet.
    public var stop: Bool?
    public var at: Date

    public init(target: Target, box: String? = nil, image: String? = nil, launch: String? = nil, readOnly: Bool? = nil,
                snapshot: SnapshotChoice? = nil, stop: Bool? = nil, at: Date = Date()) {
        self.stop = stop
        self.target = target
        self.box = box
        self.image = image
        self.launch = launch
        self.readOnly = readOnly
        self.snapshot = snapshot
        self.at = at
    }

    /// A snapshot word this agent-vm does not know (a later one's) reads as none said, so the
    /// rest of the file is still read.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decode(Target.self, forKey: .target)
        box = try container.decodeIfPresent(String.self, forKey: .box)
        image = try container.decodeIfPresent(String.self, forKey: .image)
        launch = try container.decodeIfPresent(String.self, forKey: .launch)
        readOnly = try container.decodeIfPresent(Bool.self, forKey: .readOnly)
        snapshot = (try? container.decodeIfPresent(String.self, forKey: .snapshot)).flatMap { $0 }.flatMap(SnapshotChoice.init(rawValue:))
        stop = try container.decodeIfPresent(Bool.self, forKey: .stop)
        at = try container.decode(Date.self, forKey: .at)
    }
}

public struct ConnectChoices: Sendable {
    public static let fileName = "connect.json"
    /// Projects kept; the ones chosen longest ago go first.
    public static let limit = 200

    private struct File: Codable {
        var version: Int
        var projects: [String: ConnectChoice]
        /// The user's agent entries agreed to: id to the digest of the file agreed to.
        var agents: [String: String]?
        /// Whether the box was stopped after the last session without a folder where that was
        /// asked or named.
        var stop: Bool?
    }

    public let url: URL

    public init(store root: URL) {
        url = root.appendingPathComponent(Self.fileName)
    }

    /// The choice last made for `project` (a canonical path), if any.
    public func choice(for project: String) -> ConnectChoice? {
        return read().projects[project]
    }

    /// Whether to stop the box after a session, as last answered for `project`, or for
    /// sessions without a folder (nil); nil: never answered.
    public func stop(for project: String?) -> Bool? {
        let file = read()
        guard let project else {
            return file.stop
        }
        return file.projects[project]?.stop
    }

    /// Records the answer to whether the box is stopped after a session: with `project`'s
    /// choice (when one is recorded for it), or for sessions without a folder (nil).
    public func rememberStop(_ stop: Bool, for project: String?) throws {
        var file = read()
        if let project {
            guard var choice = file.projects[project] else {
                return
            }
            choice.stop = stop
            file.projects[project] = choice
        } else {
            file.stop = stop
        }
        try write(file)
    }

    /// Whether the person agreed to run the user's agent `id` as the file with `digest`.
    public func agreed(agent id: String, digest: String) -> Bool {
        return read().agents?[id] == digest
    }

    /// Records the agreement to agent `id` as the file with `digest`, replacing an earlier one.
    public func agree(agent id: String, digest: String) throws {
        var file = read()
        var agents = file.agents ?? [:]
        agents[id] = digest
        file.agents = agents
        try write(file)
    }

    /// Records `choice` for `project`, replacing a damaged file.
    public func remember(_ choice: ConnectChoice, for project: String) throws {
        var file = read()
        var projects = file.projects
        projects[project] = choice
        if projects.count > Self.limit {
            let oldest = projects.sorted { $0.value.at < $1.value.at }.prefix(projects.count - Self.limit)
            for (path, _) in oldest {
                projects.removeValue(forKey: path)
            }
        }
        file.projects = projects
        try write(file)
    }

    /// After `box rename`: the folders whose choice was box `old` now name `new`. Returns how
    /// many.
    @discardableResult
    public func rename(box old: String, to new: String) throws -> Int {
        return try rename { choice in
            guard choice.target == .box, choice.box == old else {
                return false
            }
            choice.box = new
            return true
        }
    }

    /// After `image rename`: the folders whose choice was a temporary box from image `old`
    /// now name `new`. Returns how many.
    @discardableResult
    public func rename(image old: String, to new: String) throws -> Int {
        return try rename { choice in
            guard choice.image == old else {
                return false
            }
            choice.image = new
            return true
        }
    }

    private func rename(_ change: (inout ConnectChoice) -> Bool) throws -> Int {
        var file = read()
        var count = 0
        for (project, var choice) in file.projects where change(&choice) {
            file.projects[project] = choice
            count += 1
        }
        if count > 0 {
            try write(file)
        }
        return count
    }

    private func write(_ file: File) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try write(try encoder.encode(file))
    }

    private func read() -> File {
        let empty = File(version: 1, projects: [:], agents: nil, stop: nil)
        guard let data = try? Data(contentsOf: url) else {
            return empty
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(File.self, from: data), file.version == 1 else {
            return empty
        }
        return file
    }

    /// Whole and private: a new file made with mode 0600 next to the old one, then renamed over
    /// it. Anything else in its place (a folder) is removed first.
    private func write(_ data: Data) throws {
        let directory = url.deletingLastPathComponent().path
        try StoreRoot.prepare(url.deletingLastPathComponent())
        var info = stat()
        if lstat(url.path, &info) == 0, info.st_mode & S_IFMT != S_IFREG {
            try FileSystem.removeTree(url.path)
        }
        let temporary = directory + "/.\(Self.fileName).\(getpid()).\(UInt32.random(in: 0...UInt32.max))"
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw AgentVMError.system(operation: "create \(temporary)", code: errno)
        }
        let written = data.withUnsafeBytes { buffer -> Int in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0 {
                    if errno == EINTR {
                        continue
                    }
                    return -1
                }
                offset += count
            }
            return offset
        }
        let code = errno
        close(descriptor)
        guard written == data.count else {
            unlink(temporary)
            throw AgentVMError.system(operation: "write \(temporary)", code: code)
        }
        guard Darwin.rename(temporary, url.path) == 0 else {
            let renameCode = errno
            unlink(temporary)
            throw AgentVMError.system(operation: "replace \(url.path)", code: renameCode)
        }
    }
}
