// Sources/AgentVMKit/Connect/ConnectChoices.swift
//
// What `agent-vm connect` (avm) last chose for each project folder, in <store>/connect.json, so
// the pickers start at it, and which of the person's own agent entries they have agreed to
// run. A missing, unreadable or damaged file reads as no choices and no agreements, never an
// error: the pickers start at the top, and an agent is asked about again. Nothing secret is
// kept: folder paths, box and image names, what ran, agent ids and file digests.

import Darwin
import Foundation

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
    public var at: Date

    public init(target: Target, box: String? = nil, image: String? = nil, launch: String? = nil, readOnly: Bool? = nil, at: Date = Date()) {
        self.target = target
        self.box = box
        self.image = image
        self.launch = launch
        self.readOnly = readOnly
        self.at = at
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
    }

    public let url: URL

    public init(store root: URL) {
        url = root.appendingPathComponent(Self.fileName)
    }

    /// The choice last made for `project` (a canonical path), if any.
    public func choice(for project: String) -> ConnectChoice? {
        return read().projects[project]
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

    private func write(_ file: File) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try write(try encoder.encode(file))
    }

    private func read() -> File {
        let empty = File(version: 1, projects: [:], agents: nil)
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
