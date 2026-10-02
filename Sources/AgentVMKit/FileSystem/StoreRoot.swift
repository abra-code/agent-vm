// Sources/AgentVMKit/FileSystem/StoreRoot.swift
//
// The store's own folder. Everything under it is created private (folders 0700, the files
// that matter 0600), but that is worth only as much as the folder above: one that another
// user owns can have its entries moved aside and replaced (agent definitions and network packs
// are read from it), and one that others may list shows the names of images and boxes. So the
// folder is looked at before a store writes into it, and `agent-vm doctor` reports it.

import Darwin
import Foundation

public enum StoreRoot {
    /// What the folder is, for doctor.
    public struct State: Sendable, Equatable {
        public var isFolder: Bool
        public var ownedByUser: Bool
        /// Permission bits (0o700 when private).
        public var mode: UInt16
        /// The volume is mounted with ownership ignored (the default for external volumes):
        /// every file on it reads as owned by whoever asks, so no mode keeps anyone out.
        public var ignoresOwnership: Bool

        public init(isFolder: Bool, ownedByUser: Bool, mode: UInt16, ignoresOwnership: Bool) {
            self.isFolder = isFolder
            self.ownedByUser = ownedByUser
            self.mode = mode
            self.ignoresOwnership = ignoresOwnership
        }
    }

    /// The folder as it is; nil when it does not exist yet or cannot be examined.
    public static func state(_ root: URL) -> State? {
        // A root given as a link to a folder is that folder, as the stores take it.
        let root = FileSystem.canonicalRoot(root)
        var info = stat()
        guard lstat(root.path, &info) == 0 else {
            return nil
        }
        var volume = statfs()
        let ignoresOwnership = statfs(root.path, &volume) == 0 && volume.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) != 0
        return State(isFolder: FileSystem.isDirectory(info), ownedByUser: info.st_uid == geteuid(),
                     mode: UInt16(info.st_mode & 0o7777), ignoresOwnership: ignoresOwnership)
    }

    /// Before a store writes: creates the folder, private, when it is missing; refuses one that
    /// is not a folder of this user's own; and takes away what group and others may do in one
    /// made before agent-vm set the mode (or by hand).
    static func prepare(_ root: URL) throws {
        // A root given as a link to a folder is that folder, as the stores take it.
        let root = FileSystem.canonicalRoot(root)
        var info = stat()
        if lstat(root.path, &info) != 0 {
            guard errno == ENOENT else {
                throw AgentVMError.system(operation: "examine \(root.path)", code: errno)
            }
            try FileSystem.makeDirectories(root.path)
            // Looked at once more: "created" also means somebody else made it meanwhile.
            guard lstat(root.path, &info) == 0 else {
                throw AgentVMError.system(operation: "examine \(root.path)", code: errno)
            }
        }
        guard FileSystem.isDirectory(info) else {
            throw AgentVMError.unsuitableStore(path: root.path, reason: "it is not a folder")
        }
        guard info.st_uid == geteuid() else {
            throw AgentVMError.unsuitableStore(path: root.path, reason: "it belongs to another user (uid \(info.st_uid)), who could replace what agent-vm keeps there")
        }
        if info.st_mode & 0o077 != 0 {
            guard chmod(root.path, info.st_mode & 0o7700) == 0 else {
                throw AgentVMError.system(operation: "make \(root.path) private", code: errno)
            }
        }
    }
}
