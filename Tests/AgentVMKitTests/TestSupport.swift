// Tests/AgentVMKitTests/TestSupport.swift
//
// Temporary sandboxes for session tests: a scratch folder holding a project and a store, and a
// tree description used to compare folders by content, type, mode and symlink target.

import Darwin
import Foundation
import Testing
@testable import AgentVMKit

/// A scratch folder with `project/` and `store/` inside, deleted when the value is released.
final class Scratch {
    let root: URL
    let project: URL
    let store: SessionStore

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-vm-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Canonical path, so assertions compare against what the store records.
        root = URL(fileURLWithPath: try FileSystem.canonicalPath(base.path), isDirectory: true)
        project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        store = SessionStore(root: root.appendingPathComponent("store", isDirectory: true))
    }

    deinit {
        try? FileSystem.removeTree(root.path)
    }

    func write(_ relative: String, _ text: String) throws {
        let url = project.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ relative: String) throws -> String {
        return String(decoding: try Data(contentsOf: project.appendingPathComponent(relative)), as: UTF8.self)
    }

    func path(_ relative: String) -> String {
        return project.appendingPathComponent(relative).path
    }

    /// A small realistic project: sources, a nested folder, a git hook, an executable script,
    /// and a relative symlink.
    func populate() throws {
        try write("README.md", "hello\n")
        try write("Sources/App/main.swift", "print(\"hi\")\n")
        try write(".git/HEAD", "ref: refs/heads/main\n")
        try write(".git/hooks/pre-commit.sample", "#!/bin/sh\nexit 0\n")
        try write("build.sh", "#!/bin/sh\necho build\n")
        chmod(path("build.sh"), 0o755)
        symlink("README.md", path("link-to-readme"))
    }
}

/// One entry of a folder tree, for whole-tree equality checks.
struct TreeEntry: Equatable, CustomStringConvertible {
    enum Kind: Equatable { case file(Data), directory, symlink(String) }
    let path: String
    let kind: Kind
    let permissions: mode_t

    var description: String {
        switch kind {
        case .file(let data): return "\(path) file \(data.count)B \(String(permissions, radix: 8))"
        case .directory: return "\(path)/ \(String(permissions, radix: 8))"
        case .symlink(let target): return "\(path) -> \(target)"
        }
    }
}

/// Every entry under `root`, sorted by relative path. Symlinks are described, not followed.
func describeTree(_ root: String) throws -> [TreeEntry] {
    var entries: [TreeEntry] = []
    guard let enumerator = FileManager.default.enumerator(atPath: root) else {
        return entries
    }
    while let relative = enumerator.nextObject() as? String {
        let full = (root as NSString).appendingPathComponent(relative)
        let info = try FileSystem.status(full)
        let permissions = info.st_mode & 0o7777
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            entries.append(TreeEntry(path: relative, kind: .directory, permissions: permissions))
        case S_IFLNK:
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: full)
            entries.append(TreeEntry(path: relative, kind: .symlink(target), permissions: 0))
        default:
            entries.append(TreeEntry(path: relative, kind: .file(try Data(contentsOf: URL(fileURLWithPath: full))), permissions: permissions))
        }
    }
    return entries.sorted { $0.path < $1.path }
}

/// Adds an access control entry with `/bin/chmod +a` (for example "everyone deny delete"),
/// the way an agent would; `-h` changes a symlink itself.
func addACL(_ entry: String, to path: String) throws {
    let chmod = Process()
    chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
    chmod.arguments = ["-h", "+a", entry, path]
    try chmod.run()
    chmod.waitUntilExit()
    #expect(chmod.terminationStatus == 0, "chmod +a \(entry) \(path)")
}

/// True when the entry has an extended ACL; a "deny readsecurity" entry reads as EACCES, which
/// also means there is one.
func hasACL(_ path: String) -> Bool {
    let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED)
    if let acl {
        acl_free(UnsafeMutableRawPointer(acl))
        return true
    }
    return errno != ENOENT
}

/// A flag one thread sets and another polls, with a signal for when the poller is done.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    let finished = DispatchSemaphore(value: 0)

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
