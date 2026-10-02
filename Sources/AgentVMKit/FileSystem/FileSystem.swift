// Sources/AgentVMKit/FileSystem/FileSystem.swift
//
// Thin Swift wrappers over the Darwin file-system calls the session code depends on:
// realpath, lstat, renamex_np with RENAME_SWAP (atomic exchange of two directory entries),
// flock, and opening up entries an agent locked with permissions, flags or access control
// lists. Cloning and deleting whole trees are in TreeWalk.swift. Nothing here follows symlinks
// inside a tree: the trees handled are agent-controlled.

import Darwin
import Foundation

enum FileSystem {
    /// The canonical absolute path: symlinks and `..` resolved. Throws if the path does not exist.
    static func canonicalPath(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else {
            throw AgentVMError.system(operation: "resolve \(path)", code: errno)
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// A store root in canonical form (for example /var -> /private/var), so every printed and
    /// recorded path matches realpath(3); a root that does not exist yet is resolved through its
    /// parent.
    static func canonicalRoot(_ root: URL) -> URL {
        let given = root.standardizedFileURL
        if let resolved = try? canonicalPath(given.path) {
            return URL(fileURLWithPath: resolved, isDirectory: true)
        }
        if let parent = try? canonicalPath(given.deletingLastPathComponent().path) {
            return URL(fileURLWithPath: parent, isDirectory: true).appendingPathComponent(given.lastPathComponent, isDirectory: true)
        }
        return given
    }

    /// Device and inode of `path`, symlinks followed; nil when it cannot be examined. Compares
    /// folders by identity: realpath keeps other names for the same folder
    /// (/System/Volumes/Data/Users/..., /.nofollow/Users/...), which path prefixes miss.
    static func identity(_ path: String) -> [UInt64]? {
        var info = stat()
        guard stat(path, &info) == 0 else {
            return nil
        }
        return [UInt64(UInt32(bitPattern: info.st_dev)), info.st_ino]
    }

    /// `lstat` of a path (a symlink is described, not followed).
    static func status(_ path: String) throws -> stat {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw AgentVMError.system(operation: "stat \(path)", code: errno)
        }
        return info
    }

    static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    static func isDirectory(_ info: stat) -> Bool {
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// Atomically exchanges the directory entries `first` and `second` (same volume).
    ///
    /// Moving a folder to another parent needs write permission on the folder itself, no
    /// immutable or append-only flag on it, and no ACL entry denying its deletion, so an agent
    /// could block undo with `chmod 555 .`, `chflags uchg .` or `chmod +a "everyone deny delete" .`,
    /// and a project that was read-only at start could never be restored. Each folder is opened
    /// up just for the exchange and gets its own mode, flags and ACL back afterwards, at its new
    /// place (an ACL that denies reading itself cannot be saved, and stays removed).
    static func swapEntries(_ first: String, _ second: String) throws {
        let firstSaved = try unlockEntry(first)
        defer { firstSaved.free() }
        let secondSaved = try unlockEntry(second)
        defer { secondSaved.free() }
        guard renamex_np(first, second, UInt32(RENAME_SWAP)) == 0 else {
            let code = errno
            restoreEntry(first, firstSaved)
            restoreEntry(second, secondSaved)
            throw AgentVMError.system(operation: "swap \(first) with \(second)", code: code)
        }
        restoreEntry(second, firstSaved)
        restoreEntry(first, secondSaved)
    }

    static let userLockFlags = UInt32(UF_IMMUTABLE | UF_APPEND)

    /// The file flags a session compares and puts back: the ones a person or a program sets
    /// on purpose, which a clone carries (measured: hidden and nodump are on the snapshot's
    /// copy). The rest of the user flags are the system's bookkeeping: UF_TRACKED (document
    /// tracking; a clone does not get it, so an untouched file would differ from its snapshot
    /// from the start), UF_COMPRESSED and UF_DATAVAULT.
    static let comparedFlags = UInt32(UF_NODUMP | UF_IMMUTABLE | UF_APPEND | UF_OPAQUE | UF_HIDDEN)

    /// What `unlockEntry` changed on one entry, to put back afterwards.
    struct SavedEntry {
        let info: stat
        let acl: acl_t?

        func free() {
            if let acl {
                acl_free(UnsafeMutableRawPointer(acl))
            }
        }
    }

    /// `lstat` that first removes an ACL denying "readsecurity" (which makes lstat itself fail
    /// with EACCES), without following a symlink.
    static func statusRemovingUnreadableACL(_ path: String) throws -> stat {
        var info = stat()
        if lstat(path, &info) != 0, errno == EACCES, !removeACL(path) {
            // A locked entry keeps its ACL. Its flags cannot be read to be saved either, so
            // the lock is gone with the ACL.
            _ = lchflags(path, 0)
            _ = removeACL(path)
        }
        return try status(path)
    }

    /// Removes the ACL, clears the user lock flags and makes a folder writable by its owner (no
    /// symlink following); only what is in the way is changed.
    static func unlockEntry(_ path: String) throws -> SavedEntry {
        let info = try statusRemovingUnreadableACL(path)
        if info.st_flags & userLockFlags != 0 {
            _ = lchflags(path, info.st_flags & ~userLockFlags)
        }
        let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED)
        if acl != nil {
            _ = removeACL(path)
        }
        if isDirectory(info), info.st_mode & S_IRWXU != S_IRWXU {
            _ = fchmodat(AT_FDCWD, path, (info.st_mode & 0o7777) | S_IRWXU, AT_SYMLINK_NOFOLLOW)
        }
        return SavedEntry(info: info, acl: acl)
    }

    /// Puts back what `unlockEntry` or `openFolder` changed: mode, then ACL, then flags (an
    /// immutable entry accepts no other change).
    static func restoreEntry(_ path: String, _ saved: SavedEntry) {
        let info = saved.info
        if isDirectory(info), info.st_mode & S_IRWXU != S_IRWXU {
            _ = fchmodat(AT_FDCWD, path, info.st_mode & 0o7777, AT_SYMLINK_NOFOLLOW)
        }
        if let acl = saved.acl {
            _ = acl_set_link_np(path, ACL_TYPE_EXTENDED, acl)
        }
        if info.st_flags & userLockFlags != 0 {
            _ = lchflags(path, info.st_flags)
        }
    }

    // MARK: - By descriptor
    //
    // The same operations on an open descriptor, for trees an agent may still be changing: a
    // path is looked up again at every call, so a folder checked a moment ago can be a symlink
    // by the time it is used. A descriptor stays on the entry it was opened on.

    /// Opens the folder `name` in the folder `parent` without following a symlink: a link (or
    /// anything else that is not a folder) fails with ENOTDIR or ELOOP. `O_EVTONLY` needs no
    /// read permission, and the descriptor still serves fstat, fchmod and the `*at` calls.
    static func openFolder(at parent: Int32, _ name: String) -> Int32 {
        return openat(parent, name, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }

    /// Opens the entry `name` in the folder `parent`, a symlink as itself; -1 when it cannot be
    /// opened (an ACL that denies listing a folder refuses even this). `O_NONBLOCK` is for a
    /// FIFO, which even this kind of open would wait on until something writes to it.
    static func openEntry(at parent: Int32, _ name: String) -> Int32 {
        return openat(parent, name, O_SYMLINK | O_EVTONLY | O_NONBLOCK | O_CLOEXEC)
    }

    /// `fstat` that first removes an ACL denying "readsecurity".
    static func statusRemovingUnreadableACL(descriptor: Int32, name: String) throws -> stat {
        var info = stat()
        if fstat(descriptor, &info) != 0, errno == EACCES {
            _ = removeACL(descriptor: descriptor)
        }
        guard fstat(descriptor, &info) == 0 else {
            throw AgentVMError.system(operation: "stat \(name)", code: errno)
        }
        return info
    }

    /// `unlockEntry` for an open entry.
    static func unlockEntry(descriptor: Int32, name: String) throws -> SavedEntry {
        let info = try statusRemovingUnreadableACL(descriptor: descriptor, name: name)
        if info.st_flags & userLockFlags != 0 {
            _ = fchflags(descriptor, info.st_flags & ~userLockFlags)
        }
        let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED)
        if acl != nil {
            _ = removeACL(descriptor: descriptor)
        }
        if isDirectory(info), info.st_mode & S_IRWXU != S_IRWXU {
            _ = fchmod(descriptor, (info.st_mode & 0o7777) | S_IRWXU)
        }
        return SavedEntry(info: info, acl: acl)
    }

    /// `restoreEntry` for an open entry.
    static func restoreEntry(descriptor: Int32, _ saved: SavedEntry) {
        let info = saved.info
        if isDirectory(info), info.st_mode & S_IRWXU != S_IRWXU {
            _ = fchmod(descriptor, info.st_mode & 0o7777)
        }
        if let acl = saved.acl {
            _ = acl_set_fd_np(descriptor, acl, ACL_TYPE_EXTENDED)
        }
        if info.st_flags & userLockFlags != 0 {
            _ = fchflags(descriptor, info.st_flags)
        }
    }

    private static func removeACL(descriptor: Int32) -> Bool {
        guard let security = filesec_init() else {
            return false
        }
        defer { filesec_free(security) }
        // _FILESEC_REMOVE_ACL, a C macro Swift does not import: ((void *)1).
        guard filesec_set_property(security, FILESEC_ACL, UnsafeRawPointer(bitPattern: 1)) == 0 else {
            return false
        }
        return fchmodx_np(descriptor, security) == 0
    }

    /// The POSIX error code behind a Foundation error, for `AgentVMError.system`. Foundation
    /// reports its own codes (for example 513, "no write permission"), which strerror does not know.
    static func posixCode(_ error: Error) -> Int32 {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return Int32(nsError.code)
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return Int32(underlying.code)
        }
        return EIO
    }

    static func rename(_ source: String, to destination: String) throws {
        guard Darwin.rename(source, destination) == 0 else {
            throw AgentVMError.system(operation: "rename \(source) to \(destination)", code: errno)
        }
    }

    static func makeDirectory(_ path: String, mode: mode_t = 0o700) throws {
        guard mkdir(path, mode) == 0 else {
            throw AgentVMError.system(operation: "create folder \(path)", code: errno)
        }
    }

    /// Creates the directory and its missing parents; succeeds if it already exists.
    static func makeDirectories(_ path: String, mode: mode_t = 0o700) throws {
        do {
            try FileManager.default.createDirectory(
                atPath: path, withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: mode)])
        } catch {
            throw AgentVMError.system(operation: "create folder \(path)", code: FileSystem.posixCode(error))
        }
    }

    /// The current wall-clock time with nanosecond resolution.
    static func now() -> timespec {
        var time = timespec()
        clock_gettime(CLOCK_REALTIME, &time)
        return time
    }

    /// Runs `body` while holding an exclusive `flock` on `lockPath` (created if missing).
    static func withExclusiveLock<T>(at lockPath: String, _ body: () throws -> T) throws -> T {
        let descriptor = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw AgentVMError.system(operation: "open lock \(lockPath)", code: errno)
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw AgentVMError.system(operation: "lock \(lockPath)", code: errno)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// Removes the extended access control list of one entry without following a symlink.
    /// `O_SYMLINK | O_EVTONLY` opens the entry itself and needs no read access; a folder whose
    /// ACL denies listing refuses even that, and is then changed by path once `readlink`
    /// (EINVAL) has shown it is not a symlink. `O_NONBLOCK` is for a FIFO, as in `openEntry`.
    static func removeACL(_ path: UnsafePointer<CChar>) -> Bool {
        guard let security = filesec_init() else {
            return false
        }
        defer { filesec_free(security) }
        // _FILESEC_REMOVE_ACL, a C macro Swift does not import: ((void *)1).
        guard filesec_set_property(security, FILESEC_ACL, UnsafeRawPointer(bitPattern: 1)) == 0 else {
            return false
        }
        let descriptor = open(path, O_SYMLINK | O_EVTONLY | O_NONBLOCK | O_CLOEXEC)
        if descriptor >= 0 {
            defer { close(descriptor) }
            return fchmodx_np(descriptor, security) == 0
        }
        var byte: CChar = 0
        guard readlink(path, &byte, 1) == -1, errno == EINVAL else {
            return false
        }
        return chmodx_np(path, security) == 0
    }
}
