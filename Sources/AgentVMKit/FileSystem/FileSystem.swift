// Sources/AgentVMKit/FileSystem/FileSystem.swift
//
// Thin Swift wrappers over the Darwin file-system calls the session code depends on:
// realpath, lstat, copyfile (whole-tree copy-on-write clone on APFS), renamex_np with
// RENAME_SWAP (atomic exchange of two directory entries), flock, and a tree removal that an
// agent cannot block with read-only folders, locked files or access control lists. Nothing
// here follows symlinks inside a tree: the trees handled are agent-controlled.

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

    /// Clones `source` (a file or a whole directory tree) to `destination`, which must not exist.
    /// Uses `copyfile` with `COPYFILE_CLONE | COPYFILE_RECURSIVE`, as clonefile(2) asks ("the use
    /// of clonefile(2) to clone directory hierarchies is strongly discouraged"): every entry is
    /// cloned copy-on-write on APFS, and an entry that cannot be cloned is copied instead.
    /// Symlinks are cloned as symlinks, never followed. Hard links become separate files.
    /// `COPYFILE_ACL` is needed too: a clone alone drops access control lists.
    ///
    /// A callback closes the gaps of plain `copyfile`:
    /// - A folder gets its mode, flags and ACL when it is created, and gets them again when its
    ///   own entries are done, yet symlinks are created only after the whole walk. So a read-only
    ///   or ACL-protected folder could receive neither its children nor its symlinks. Every such
    ///   folder is kept open for its owner while copyfile runs and locked again at the end.
    /// - Sockets, FIFOs and device nodes cannot be cloned (ENOTSUP), so they are skipped: they
    ///   hold no content (git's fsmonitor leaves a socket in `.git`).
    static func cloneTree(_ source: String, to destination: String) throws {
        let flags = copyfile_flags_t(COPYFILE_CLONE | COPYFILE_ACL | COPYFILE_RECURSIVE)
        let lockedFolders = LockedFolders()
        defer { lockedFolders.free() }
        let callback: copyfile_callback_t = { what, stage, _, source, destination, context in
            if stage == COPYFILE_ERR {
                return COPYFILE_QUIT
            }
            guard let source, let destination else {
                return COPYFILE_CONTINUE
            }
            if what == COPYFILE_RECURSE_FILE, stage == COPYFILE_START {
                var info = stat()
                if lstat(source, &info) == 0 {
                    let type = info.st_mode & S_IFMT
                    if type == S_IFSOCK || type == S_IFIFO || type == S_IFCHR || type == S_IFBLK {
                        return COPYFILE_SKIP
                    }
                }
            } else if what == COPYFILE_RECURSE_DIR, stage == COPYFILE_FINISH {
                // Opened for its children now; the state to restore is recorded at cleanup.
                FileSystem.openFolder(destination, copiedFrom: source)?.free()
            } else if what == COPYFILE_RECURSE_DIR_CLEANUP, stage == COPYFILE_FINISH, let context {
                if let saved = FileSystem.openFolder(destination, copiedFrom: source) {
                    let folders = Unmanaged<LockedFolders>.fromOpaque(context).takeUnretainedValue()
                    folders.entries.append((String(cString: destination), saved))
                }
            }
            return COPYFILE_CONTINUE
        }
        guard let state = copyfile_state_alloc() else {
            throw AgentVMError.system(operation: "clone \(source) to \(destination)", code: ENOMEM)
        }
        defer { copyfile_state_free(state) }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(lockedFolders).toOpaque())
        let result = withExtendedLifetime(lockedFolders) {
            copyfile(source, destination, state, flags)
        }
        guard result == 0 else {
            let code = errno == 0 ? EIO : errno
            // A failed directory clone may leave a partial destination behind; EEXIST means the
            // destination was never ours, so it is left alone.
            if code != EEXIST, exists(destination) {
                try? removeTree(destination)
            }
            throw AgentVMError.system(operation: "clone \(source) to \(destination)", code: code)
        }
        // Recorded as each folder finished, so children are locked before their parents.
        for (path, saved) in lockedFolders.entries {
            restoreEntry(path, saved)
        }
    }

    /// Folders `cloneTree` holds open during the copy, with the state to put back.
    private final class LockedFolders {
        var entries: [(path: String, saved: SavedEntry)] = []

        func free() {
            for entry in entries {
                entry.saved.free()
            }
        }
    }

    /// Opens a freshly created folder for its owner while copyfile fills it: removes its ACL,
    /// clears the user lock flags and adds u+rwx. Returns the state to put back (the ACL is
    /// taken from `source`, because copyfile applies it only when it creates the folder), or nil
    /// when nothing was in the way.
    private static func openFolder(_ path: UnsafePointer<CChar>, copiedFrom source: UnsafePointer<CChar>) -> SavedEntry? {
        var info = stat()
        guard lstat(path, &info) == 0, isDirectory(info) else {
            return nil
        }
        let acl = acl_get_link_np(source, ACL_TYPE_EXTENDED)
        let locked = info.st_flags & userLockFlags != 0
        guard acl != nil || locked || info.st_mode & S_IRWXU != S_IRWXU else {
            return nil
        }
        if locked {
            _ = lchflags(path, info.st_flags & ~userLockFlags)
        }
        if acl != nil {
            _ = removeACL(path)
        }
        if info.st_mode & S_IRWXU != S_IRWXU {
            _ = fchmodat(AT_FDCWD, path, (info.st_mode & 0o7777) | S_IRWXU, AT_SYMLINK_NOFOLLOW)
        }
        return SavedEntry(info: info, acl: acl)
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

    private static let userLockFlags = UInt32(UF_IMMUTABLE | UF_APPEND)

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
        if lstat(path, &info) != 0, errno == EACCES {
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

    /// Deletes a whole tree even if an agent made folders read-only or set the user
    /// "immutable"/"append-only" flags on entries: those are cleared first. Never follows
    /// symlinks and never crosses into another mounted volume.
    static func removeTree(_ path: String) throws {
        // Only a truly missing path is done: an ACL denying "readsecurity" makes lstat fail
        // with EACCES on a tree that is still there.
        // fts does not descend into a root it could not examine at first, so the root's ACL is
        // removed before the walk.
        var info = stat()
        if lstat(path, &info) != 0 {
            if errno == ENOENT {
                return
            }
            _ = removeACL(path)
        }
        try unlockTree(path)
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            throw AgentVMError.system(operation: "delete \(path)", code: FileSystem.posixCode(error))
        }
    }

    /// Makes every directory in the tree writable and searchable by its owner, clears the
    /// user immutable and append-only flags, and removes access control lists (an agent can add
    /// "deny delete" or "deny list" entries that override the mode), so the entries can be deleted.
    private static func unlockTree(_ path: String) throws {
        guard let rootCopy = strdup(path) else {
            throw AgentVMError.system(operation: "walk \(path)", code: ENOMEM)
        }
        defer { free(rootCopy) }
        var roots: [UnsafeMutablePointer<CChar>?] = [rootCopy, nil]
        guard let tree = fts_open(&roots, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            throw AgentVMError.system(operation: "walk \(path)", code: errno)
        }
        defer { fts_close(tree) }

        // Entries whose ACL was removed after they could not even be examined, revisited once.
        var revisited = Set<String>()
        while let entry = fts_read(tree) {
            let info = Int32(entry.pointee.fts_info)
            let entryPath = entry.pointee.fts_path!
            if info == FTS_NS {
                // A "deny readsecurity" entry makes even lstat fail. Remove the ACL, then have
                // fts examine the entry again so a folder is still opened up and walked.
                let key = String(cString: entryPath)
                if !revisited.contains(key), removeACL(entryPath) {
                    revisited.insert(key)
                    fts_set(tree, entry, FTS_AGAIN)
                }
                continue
            }
            let flags = entry.pointee.fts_statp?.pointee.st_flags ?? 0
            if flags & userLockFlags != 0 {
                _ = lchflags(entryPath, flags & ~userLockFlags)
            }
            // No ACL reads as ENOENT; any other failure still means there is one to remove.
            let acl = acl_get_link_np(entryPath, ACL_TYPE_EXTENDED)
            let hasACL = acl != nil || errno != ENOENT
            if let acl {
                acl_free(UnsafeMutableRawPointer(acl))
            }
            if hasACL {
                _ = removeACL(entryPath)
            }
            // A directory is returned before its children are read, so opening it up here lets
            // the walk descend into folders the agent made unreadable. AT_SYMLINK_NOFOLLOW: an
            // agent still running in the tree could swap the folder for a symlink meanwhile.
            if info == FTS_D || info == FTS_DNR {
                let mode = entry.pointee.fts_statp?.pointee.st_mode ?? 0
                _ = fchmodat(AT_FDCWD, entryPath, (mode & 0o7777) | S_IRWXU, AT_SYMLINK_NOFOLLOW)
            }
        }
    }

    /// Removes the extended access control list of one entry without following a symlink.
    /// `O_SYMLINK | O_EVTONLY` opens the entry itself and needs no read access; a folder whose
    /// ACL denies listing refuses even that, and is then changed by path once `readlink`
    /// (EINVAL) has shown it is not a symlink.
    private static func removeACL(_ path: UnsafePointer<CChar>) -> Bool {
        guard let security = filesec_init() else {
            return false
        }
        defer { filesec_free(security) }
        // _FILESEC_REMOVE_ACL, a C macro Swift does not import: ((void *)1).
        guard filesec_set_property(security, FILESEC_ACL, UnsafeRawPointer(bitPattern: 1)) == 0 else {
            return false
        }
        let descriptor = open(path, O_SYMLINK | O_EVTONLY | O_CLOEXEC)
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
