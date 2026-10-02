// Sources/AgentVMKit/Sessions/ProjectRestorer.swift
//
// File-by-file undo: only the entries the change report lists are touched, so the project
// folder keeps its identity (editors, shells and watchers that have it open stay attached) and
// nothing the agent did not change is rewritten. The agent's version of every changed entry is
// moved into the session's `replaced-<ts>/` folder, mirroring its path, before the snapshot's
// version is cloned back; nothing is deleted.
//
// The project is agent-controlled, and the agent may still be running while it is restored:
// - nothing in the project is reached by its path. The project folder is opened once, each
//   parent folder of a change is opened from there one name at a time, never through a symlink,
//   and the entry is then moved by name inside that open folder. A folder the agent exchanges
//   for a link to somewhere else during the undo is either refused (it is not a folder) or
//   irrelevant (the open folder is still the project's own). A folder the agent replaced with
//   a link earlier is itself a listed change, restored as a whole before anything inside it;
// - nothing in the project is opened for its content. The snapshot's version is cloned into
//   the session folder first and then moved into place, so what sits at the destination (a
//   FIFO would block an open forever) is never opened: it is moved aside like the rest;
// - a parent the agent made read-only, locked or denied with an ACL is opened up just for the
//   one operation and gets its state back (its own permission change, if any, is a listed
//   change restored at the end).

import Darwin
import Foundation

public struct RestoreResult: Codable, Equatable, Sendable {
    /// Entries put back to their snapshot state, by path relative to the project.
    public var restored: [String] = []
    /// Entries that could not be restored, with the reason.
    public var failed: [String: String] = [:]
    /// Changes still reported after the restore; 0 when the project matches the snapshot. For
    /// `undo --path`, only those at or under the paths given.
    public var remaining: Int = 0
}

enum ProjectRestorer {
    /// Restores `changes`: none of them may be inside another one that covers it (see
    /// `SessionStore.undoSelection`; for a whole undo, the changes not covered by an ancestor).
    static func restore(session: Session, changes: [Change], replacedPath: String) throws -> RestoreResult {
        let project = session.record.project
        let snapshot = session.snapshotPath
        var result = RestoreResult()
        let root = open(project, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else {
            throw AgentVMError.system(operation: "open \(project)", code: errno)
        }
        defer { close(root) }
        try FileSystem.makeDirectory(replacedPath)
        // Where the snapshot's entries are cloned before they are moved into the project; a
        // killed undo's leftover is removed first.
        let staging = session.directory.appendingPathComponent(stagingName).path
        try FileSystem.removeTree(staging)
        try FileSystem.makeDirectory(staging)
        defer { try? FileSystem.removeTree(staging) }
        let folderMetadata: (Change) -> Bool = { $0.kind == .metadata && $0.type == .directory }

        // Phase 1, deepest first: move the agent's version aside (not for deletions, which have
        // nothing to move, nor for folder permission changes, which are fixed in place).
        let toMove = changes.filter { $0.kind != .deleted && !folderMetadata($0) }
            .sorted { depth($0.path) > depth($1.path) }
        for change in toMove {
            do {
                let place = try Place(root: root, project: project, path: change.path)
                defer { place.close() }
                try makeReplacedParent(replacedPath, of: change.path)
                try moveAside(place, to: replacedPath + "/" + change.path)
            } catch {
                result.failed[change.path] = "\(error)"
            }
        }

        // Phase 2, shallowest first: bring back the snapshot's version of everything that existed
        // at session start. Folder permission changes come last, so no parent is re-locked
        // before its children are back.
        let toRestore = changes.filter { $0.kind != .added && !folderMetadata($0) && result.failed[$0.path] == nil }
            .sorted { depth($0.path) < depth($1.path) }
        for (index, change) in toRestore.enumerated() {
            do {
                let place = try Place(root: root, project: project, path: change.path)
                defer { place.close() }
                let staged = staging + "/\(index)"
                try cloneEntry(snapshot + "/" + change.path, to: staged)
                do {
                    try moveIn(staged, to: place, replacedPath: replacedPath)
                } catch {
                    try? FileSystem.removeTree(staged)
                    throw error
                }
                result.restored.append(change.path)
            } catch {
                result.failed[change.path] = "\(error)"
            }
        }
        for change in changes.filter(folderMetadata).sorted(by: { depth($0.path) > depth($1.path) }) {
            do {
                let folder = try openFolder(root: root, project: project, path: change.path)
                defer { close(folder) }
                try restoreFolderMetadata(from: snapshot + "/" + change.path, to: folder, name: change.path)
                result.restored.append(change.path)
            } catch {
                result.failed[change.path] = "\(error)"
            }
        }

        // Added entries were moved aside in phase 1: removing them is their restore.
        for change in changes where change.kind == .added && result.failed[change.path] == nil {
            result.restored.append(change.path)
        }
        result.restored.sort()
        return result
    }

    /// In the session folder, next to the snapshot.
    static let stagingName = "restore-staging"

    /// One entry of the project, as its open parent folder and its name there.
    private struct Place {
        let parent: Int32
        let name: String
        /// Relative to the project, for messages.
        let path: String

        /// Opens the parent of `path` from the project's open folder `root`, one name at a
        /// time. Throws when a name on the way is not a real folder (a symlink included).
        init(root: Int32, project: String, path: String) throws {
            let components = RelativePath.components(path).map(String.init)
            guard let name = components.last, components.allSatisfy({ $0 != "." && $0 != ".." }) else {
                throw AgentVMError.unsuitableProject(path: project + "/" + path, reason: "not an entry inside the project")
            }
            var current = dup(root)
            guard current >= 0 else {
                throw AgentVMError.system(operation: "open \(project)", code: errno)
            }
            var reached = project
            for component in components.dropLast() {
                reached += "/" + component
                let next = FileSystem.openFolder(at: current, component)
                let code = errno
                Darwin.close(current)
                guard next >= 0 else {
                    guard code == ENOTDIR || code == ELOOP else {
                        throw AgentVMError.system(operation: "open \(reached)", code: code)
                    }
                    throw AgentVMError.unsuitableProject(path: reached, reason: "a parent of \(path) is no longer a real folder")
                }
                current = next
            }
            self.parent = current
            self.name = name
            self.path = path
        }

        func close() {
            Darwin.close(parent)
        }
    }

    /// Opens the folder `path` of the project itself ("." is the project folder).
    private static func openFolder(root: Int32, project: String, path: String) throws -> Int32 {
        if path == "." {
            let copy = dup(root)
            guard copy >= 0 else {
                throw AgentVMError.system(operation: "open \(project)", code: errno)
            }
            return copy
        }
        let place = try Place(root: root, project: project, path: path)
        defer { place.close() }
        let folder = FileSystem.openFolder(at: place.parent, place.name)
        guard folder >= 0 else {
            let code = errno
            guard code == ENOTDIR || code == ELOOP else {
                throw AgentVMError.system(operation: "open \(project)/\(path)", code: code)
            }
            throw AgentVMError.unsuitableProject(path: project + "/" + path, reason: "no longer a real folder")
        }
        return folder
    }

    /// Renames the entry into the replaced tree. When the agent locked the way (a read-only or
    /// immutable parent, a deny ACL, or a folder that refuses to be moved), the parent and the
    /// entry are opened up and the rename retried; the parent gets its state back afterwards.
    private static func moveAside(_ place: Place, to target: String) throws {
        if renameat(place.parent, place.name, AT_FDCWD, target) == 0 {
            return
        }
        let firstError = errno
        guard firstError == EACCES || firstError == EPERM else {
            throw AgentVMError.system(operation: "move \(place.path) aside", code: firstError)
        }
        let parentSaved = try FileSystem.unlockEntry(descriptor: place.parent, name: "the folder of \(place.path)")
        defer {
            FileSystem.restoreEntry(descriptor: place.parent, parentSaved)
            parentSaved.free()
        }
        // The entry itself keeps whatever the agent set, but must be movable. Its descriptor
        // follows it to the replaced tree.
        var entry = FileSystem.openEntry(at: place.parent, place.name)
        // A folder without any permission cannot even be opened: its owner gets access by name
        // (inside the open parent, never through a link), and the mode it had is put back.
        var modeBefore: mode_t?
        if entry < 0 {
            var info = stat()
            if fstatat(place.parent, place.name, &info, AT_SYMLINK_NOFOLLOW) == 0, FileSystem.isDirectory(info),
               fchmodat(place.parent, place.name, (info.st_mode & 0o7777) | S_IRWXU, AT_SYMLINK_NOFOLLOW) == 0 {
                modeBefore = info.st_mode
                entry = FileSystem.openEntry(at: place.parent, place.name)
            }
        }
        defer {
            if entry >= 0 {
                close(entry)
            }
        }
        var entrySaved = entry >= 0 ? try FileSystem.unlockEntry(descriptor: entry, name: place.path) : nil
        if let saved = entrySaved, let modeBefore {
            var info = saved.info
            info.st_mode = modeBefore
            entrySaved = FileSystem.SavedEntry(info: info, acl: saved.acl)
        }
        defer { entrySaved?.free() }
        let moved = renameat(place.parent, place.name, AT_FDCWD, target) == 0
        let code = errno
        if let entrySaved {
            FileSystem.restoreEntry(descriptor: entry, entrySaved)
        }
        guard moved else {
            throw AgentVMError.system(operation: "move \(place.path) aside", code: code)
        }
    }

    /// Moves the staged clone of a snapshot entry into the project, opening up a parent folder
    /// the agent locked if the first attempt is refused.
    private static func moveIn(_ staged: String, to place: Place, replacedPath: String) throws {
        var code = try put(staged, at: place, replacedPath: replacedPath)
        guard code != 0 else {
            return
        }
        guard code == EACCES || code == EPERM else {
            throw AgentVMError.system(operation: "restore \(place.path)", code: code)
        }
        let parentSaved = try FileSystem.unlockEntry(descriptor: place.parent, name: "the folder of \(place.path)")
        defer {
            FileSystem.restoreEntry(descriptor: place.parent, parentSaved)
            parentSaved.free()
        }
        // A folder that is read-only or locked cannot change parents: the clone is opened up
        // for the move and gets the snapshot's state back where it lands. It is named by its
        // identity for that (a folder without any permission cannot be opened, and its path
        // in the project may not be used).
        let entrySaved = try FileSystem.unlockEntry(staged)
        defer { entrySaved.free() }
        code = try put(staged, at: place, replacedPath: replacedPath)
        FileSystem.restoreEntry(FileSystem.pathByIdentity(device: entrySaved.info.st_dev, inode: entrySaved.info.st_ino), entrySaved)
        guard code == 0 else {
            throw AgentVMError.system(operation: "restore \(place.path)", code: code)
        }
    }

    /// One attempt to move the staged clone to its place, which must be free; returns errno.
    /// Something at the destination was not in the report: a FIFO, socket or device (reports
    /// leave them out), or what a still-running agent put there since. It is moved into the
    /// replaced tree without being opened for its content (locked, it is opened up as in
    /// phase 1), and the move tried once more.
    private static func put(_ staged: String, at place: Place, replacedPath: String) throws -> Int32 {
        if renameatx_np(AT_FDCWD, staged, place.parent, place.name, UInt32(RENAME_EXCL)) == 0 {
            return 0
        }
        guard errno == EEXIST else {
            return errno
        }
        try makeReplacedParent(replacedPath, of: place.path)
        var target = replacedPath + "/" + place.path
        var attempt = 1
        while FileSystem.exists(target) {
            attempt += 1
            target = replacedPath + "/" + place.path + ".unlisted-\(attempt)"
        }
        try moveAside(place, to: target)
        return renameatx_np(AT_FDCWD, staged, place.parent, place.name, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
    }

    /// Creates the folders above `relative` in the replaced tree. The tree is in the session
    /// folder, but what was moved into it is the agent's and can be a symlink: each folder on
    /// the way must be a real one, or a move through it would land where the link points.
    private static func makeReplacedParent(_ replacedPath: String, of relative: String) throws {
        var current = replacedPath
        for component in RelativePath.components(relative).dropLast() {
            current += "/" + component
            if mkdir(current, 0o700) == 0 {
                continue
            }
            let code = errno
            var info = stat()
            guard code == EEXIST, lstat(current, &info) == 0 else {
                throw AgentVMError.system(operation: "create folder \(current)", code: code)
            }
            guard FileSystem.isDirectory(info) else {
                throw AgentVMError.system(operation: "create folder \(current)", code: ENOTDIR)
            }
        }
    }

    /// Clones one snapshot entry (a file, a symlink as itself, or a folder with everything in
    /// it) to `target`, a path in the session folder.
    private static func cloneEntry(_ source: String, to target: String) throws {
        try FileSystem.cloneTree(source, to: target)
    }

    /// Gives a folder the snapshot's permissions and user flags. An immutable folder accepts no
    /// chmod, so the lock flags are cleared first and the snapshot's flags applied last.
    private static func restoreFolderMetadata(from snapshotFolder: String, to folder: Int32, name: String) throws {
        let wanted = try FileSystem.status(snapshotFolder)
        let current = try FileSystem.statusRemovingUnreadableACL(descriptor: folder, name: name)
        let userLockFlags = UInt32(UF_IMMUTABLE | UF_APPEND)
        if current.st_flags & userLockFlags != 0 {
            _ = fchflags(folder, current.st_flags & ~userLockFlags)
        }
        guard fchmod(folder, wanted.st_mode & 0o7777) == 0 else {
            throw AgentVMError.system(operation: "restore permissions of \(name)", code: errno)
        }
        // The flags a session compares come from the snapshot; the others are left as they
        // are (the snapshot's copy never had the folder's document-tracking flag).
        let flags = (current.st_flags & ~FileSystem.comparedFlags) | (wanted.st_flags & FileSystem.comparedFlags)
        guard fchflags(folder, flags) == 0 else {
            throw AgentVMError.system(operation: "restore flags of \(name)", code: errno)
        }
    }

    private static func depth(_ path: String) -> Int {
        return RelativePath.depth(path)
    }
}
