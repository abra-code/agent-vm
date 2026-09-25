// Sources/AgentVMKit/Sessions/ProjectRestorer.swift
//
// File-by-file undo: only the entries the change report lists are touched, so the project
// folder keeps its identity (editors, shells and watchers that have it open stay attached) and
// nothing the agent did not change is rewritten. The agent's version of every changed entry is
// moved into the session's `replaced-<ts>/` folder, mirroring its path, before the snapshot's
// version is cloned back; nothing is deleted.
//
// The project is agent-controlled:
// - every operation first checks that each parent of the target path is a real folder, not a
//   symlink (a folder the agent replaced with a link is itself a listed change, restored as a
//   whole before anything inside it is touched);
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
        try FileSystem.makeDirectory(replacedPath)
        let folderMetadata: (Change) -> Bool = { $0.kind == .metadata && $0.type == .directory }

        // Phase 1, deepest first: move the agent's version aside (not for deletions, which have
        // nothing to move, nor for folder permission changes, which are fixed in place).
        let toMove = changes.filter { $0.kind != .deleted && !folderMetadata($0) }
            .sorted { depth($0.path) > depth($1.path) }
        for change in toMove {
            do {
                try requireRealParents(project, change.path)
                let target = replacedPath + "/" + change.path
                try FileSystem.makeDirectories((target as NSString).deletingLastPathComponent)
                try moveAside(project + "/" + change.path, to: target)
            } catch {
                result.failed[change.path] = "\(error)"
            }
        }

        // Phase 2, shallowest first: bring back the snapshot's version of everything that existed
        // at session start. Folder permission changes come last, so no parent is re-locked
        // before its children are back.
        let toRestore = changes.filter { $0.kind != .added && !folderMetadata($0) && result.failed[$0.path] == nil }
            .sorted { depth($0.path) < depth($1.path) }
        for change in toRestore {
            do {
                try requireRealParents(project, change.path)
                try cloneBack(snapshot + "/" + change.path, to: project + "/" + change.path)
                result.restored.append(change.path)
            } catch {
                result.failed[change.path] = "\(error)"
            }
        }
        for change in changes.filter(folderMetadata).sorted(by: { depth($0.path) > depth($1.path) }) {
            do {
                try requireRealParents(project, change.path)
                try restoreFolderMetadata(from: snapshot + "/" + change.path, to: project + "/" + change.path)
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

    /// Renames `source` into the replaced tree. When the agent locked the way (a read-only or
    /// immutable parent, a deny ACL, or a folder that refuses to be moved), the parent and the
    /// entry are opened up and the rename retried; the parent gets its state back afterwards.
    private static func moveAside(_ source: String, to target: String) throws {
        if Darwin.rename(source, target) == 0 {
            return
        }
        let firstError = errno
        guard firstError == EACCES || firstError == EPERM else {
            throw AgentVMError.system(operation: "move \(source) aside", code: firstError)
        }
        let parent = (source as NSString).deletingLastPathComponent
        let parentSaved = try FileSystem.unlockEntry(parent)
        defer {
            FileSystem.restoreEntry(parent, parentSaved)
            parentSaved.free()
        }
        // The entry itself keeps whatever the agent set, but must be movable.
        let entrySaved = try FileSystem.unlockEntry(source)
        defer { entrySaved.free() }
        guard Darwin.rename(source, target) == 0 else {
            let code = errno
            FileSystem.restoreEntry(source, entrySaved)
            throw AgentVMError.system(operation: "move \(source) aside", code: code)
        }
        FileSystem.restoreEntry(target, entrySaved)
    }

    /// Clones the snapshot's entry back into the project, opening up a parent folder the agent
    /// locked if the first attempt is refused.
    private static func cloneBack(_ source: String, to target: String) throws {
        do {
            try cloneEntry(source, to: target)
            return
        } catch AgentVMError.system(_, let code) where code == EACCES || code == EPERM {
            let parent = (target as NSString).deletingLastPathComponent
            let parentSaved = try FileSystem.unlockEntry(parent)
            defer {
                FileSystem.restoreEntry(parent, parentSaved)
                parentSaved.free()
            }
            try cloneEntry(source, to: target)
        }
    }

    /// Clones one snapshot entry. A symlink is cloned with clonefile(2): copyfile's recursive
    /// mode looks at a symlink given as the root through the link, and fails (ENOENT) when the
    /// link dangles.
    private static func cloneEntry(_ source: String, to target: String) throws {
        let info = try FileSystem.status(source)
        guard info.st_mode & S_IFMT == S_IFLNK else {
            try FileSystem.cloneTree(source, to: target)
            return
        }
        guard clonefile(source, target, UInt32(CLONE_NOFOLLOW)) == 0 else {
            throw AgentVMError.system(operation: "clone \(source) to \(target)", code: errno)
        }
    }

    /// Gives a folder the snapshot's permissions and user flags. An immutable folder accepts no
    /// chmod, so the lock flags are cleared first and the snapshot's flags applied last.
    private static func restoreFolderMetadata(from snapshotFolder: String, to folder: String) throws {
        let wanted = try FileSystem.status(snapshotFolder)
        let current = try FileSystem.statusRemovingUnreadableACL(folder)
        let userLockFlags = UInt32(UF_IMMUTABLE | UF_APPEND)
        if current.st_flags & userLockFlags != 0 {
            _ = lchflags(folder, current.st_flags & ~userLockFlags)
        }
        guard fchmodat(AT_FDCWD, folder, wanted.st_mode & 0o7777, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw AgentVMError.system(operation: "restore permissions of \(folder)", code: errno)
        }
        // User flags (the low 16 bits) come from the snapshot; system flags are left alone.
        let flags = (current.st_flags & ~UInt32(0xFFFF)) | (wanted.st_flags & 0xFFFF)
        guard lchflags(folder, flags) == 0 else {
            throw AgentVMError.system(operation: "restore flags of \(folder)", code: errno)
        }
    }

    private static func depth(_ path: String) -> Int {
        return RelativePath.depth(path)
    }

    /// Throws unless every folder between `project` and `relative` is a real folder.
    static func requireRealParents(_ project: String, _ relative: String) throws {
        var current = project
        for component in RelativePath.components(relative).dropLast() {
            current += "/" + component
            let info = try FileSystem.statusRemovingUnreadableACL(current)
            guard FileSystem.isDirectory(info) else {
                throw AgentVMError.unsuitableProject(path: current, reason: "a parent of \(relative) is no longer a real folder")
            }
        }
    }
}
