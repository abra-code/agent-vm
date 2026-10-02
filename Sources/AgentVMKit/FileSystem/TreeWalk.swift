// Sources/AgentVMKit/FileSystem/TreeWalk.swift
//
// Cloning and deleting a whole tree that an agent shaped. Both walk the tree by descriptor: a
// folder is opened from its open parent by name, never through a symlink, and its entries are
// reached by name from there. Nothing depends on an entry's full path, so a tree nested deeper
// than a path may be long (PATH_MAX, 1024 bytes) is handled like any other; copyfile(3), fts(3)
// with full paths and FileManager all stop there with "File name too long".
//
// Only the folder being worked on is held open. Its parent is opened again through ".." when
// the folder is done and must be the folder the walk came from, so the number of open
// descriptors does not grow with the depth either.
//
// An entry that refuses (no permission for its owner, a lock flag, an access control list) is
// opened up through a path that names it by its identity on its volume (/.vol/<volume>/<file>):
// the calls that change an ACL or a flag take a path or a descriptor, a descriptor cannot be
// had for an entry that refuses to be opened, and its own path may be too long. Such a path
// cannot be pointed elsewhere by exchanging the entry for a symlink.

import Darwin
import Foundation

extension FileSystem {
    // MARK: - Shared

    /// One name in a folder, as readdir(3) reports it.
    struct Listed {
        let name: String
        let inode: UInt64
    }

    private struct Identity: Equatable {
        let device: dev_t
        let inode: UInt64

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
        }
    }

    private static let folderFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    /// The names in an open folder, without "." and "..".
    static func entries(of folder: Int32, name: String) throws -> [Listed] {
        // closedir closes the descriptor it was given, so it gets its own.
        let copy = fcntl(folder, F_DUPFD_CLOEXEC, 0)
        guard copy >= 0 else {
            throw AgentVMError.system(operation: "list \(name)", code: errno)
        }
        guard let stream = fdopendir(copy) else {
            let code = errno
            close(copy)
            throw AgentVMError.system(operation: "list \(name)", code: code)
        }
        defer { closedir(stream) }
        var result: [Listed] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else {
                    throw AgentVMError.system(operation: "list \(name)", code: errno)
                }
                return result
            }
            let entryName = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if entryName != "." && entryName != ".." {
                result.append(Listed(name: entryName, inode: entry.pointee.d_ino))
            }
        }
    }

    /// A path that names an entry by its identity on its volume, whatever its depth and
    /// whatever sits under its name by now.
    static func pathByIdentity(device: dev_t, inode: UInt64) -> String {
        return "/.vol/\(UInt32(bitPattern: device))/\(inode)"
    }

    /// Opens the folder a walk came from, through "..", and checks it is that folder: the tree
    /// may have been rearranged meanwhile, and the walk must not go on somewhere else.
    private static func openParent(of folder: Int32, expecting identity: Identity, name: String) throws -> Int32 {
        let parent = openat(folder, "..", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else {
            throw AgentVMError.system(operation: "leave \(name)", code: errno)
        }
        var info = stat()
        guard fstat(parent, &info) == 0, Identity(info) == identity else {
            close(parent)
            throw AgentVMError.system(operation: "leave \(name), which was moved meanwhile", code: EBUSY)
        }
        return parent
    }

    // MARK: - Clone

    /// Clones `source` (a file, a symlink or a whole directory tree) to `destination`, which
    /// must not exist. Every file and symlink is cloned copy-on-write with clonefileat(2), which
    /// keeps its permissions, flags, times, extended attributes and ACL; a symlink is cloned as
    /// a symlink, never followed; hard links become separate files. A folder is created, filled,
    /// and then given the source folder's permissions, flags, times, extended attributes and
    /// ACL, so a read-only or locked folder still receives its entries.
    ///
    /// - Sockets, FIFOs and device nodes are left out: they hold no content (git's fsmonitor
    ///   leaves a socket in `.git`).
    /// - A folder on another mounted volume is created empty.
    /// - An entry its owner cannot read (mode 000, an ACL that denies it) is opened up for the
    ///   clone and gets its permissions back, on both sides. An ACL that denies reading the ACL
    ///   itself cannot be saved and stays removed.
    /// - An entry that disappears while the tree is walked is left out.
    ///
    /// A failed clone leaves no destination behind.
    static func cloneTree(_ source: String, to destination: String) throws {
        guard !exists(destination) else {
            throw AgentVMError.system(operation: "clone \(source) to \(destination)", code: EEXIST)
        }
        do {
            try cloneNew(source, to: destination)
        } catch {
            try? removeTree(destination)
            guard case let AgentVMError.system(detail, code) = error else {
                throw error
            }
            throw AgentVMError.system(operation: "clone \(source) to \(destination) (\(detail))", code: code)
        }
    }

    private struct CloneFrame {
        /// Open only while this is the folder being worked on; -1 otherwise.
        var source: Int32
        var destination: Int32
        let sourceIdentity: Identity
        let destinationIdentity: Identity
        /// What was changed on the source folder to read it, put back when it is done.
        var saved: SavedEntry?
        let name: String
        let entries: [Listed]
        var index = 0
    }

    private static func cloneNew(_ source: String, to destination: String) throws {
        var info = stat()
        var saved: SavedEntry?
        if lstat(source, &info) != 0 {
            guard errno == EACCES else {
                throw AgentVMError.system(operation: "stat", code: errno)
            }
            let opened = try unlockEntry(source)
            info = opened.info
            saved = opened
        }
        guard isDirectory(info) else {
            try cloneEntry(at: AT_FDCWD, source, to: AT_FDCWD, destination, info: info, saved: saved)
            // Inside a tree an entry that is gone or holds no content is left out; here it is
            // all there was to clone, and the caller counts on the destination.
            guard exists(destination) else {
                throw AgentVMError.system(operation: "clone", code: ENOENT)
            }
            return
        }
        var frames: [CloneFrame] = []
        do {
            try enter(at: AT_FDCWD, source, to: AT_FDCWD, destination, info: info, saved: saved, list: true, frames: &frames)
            while let top = frames.indices.last {
                if frames[top].index < frames[top].entries.count {
                    let entry = frames[top].entries[frames[top].index]
                    frames[top].index += 1
                    try cloneChild(entry, device: info.st_dev, frames: &frames)
                    continue
                }
                // This folder is done. Its parent is opened first: once the folder has its own
                // permissions back, it may not let anyone through.
                if top > 0 {
                    let name = frames[top].name
                    frames[top - 1].source = try openParent(of: frames[top].source, expecting: frames[top - 1].sourceIdentity, name: name)
                    frames[top - 1].destination = try openParent(of: frames[top].destination, expecting: frames[top - 1].destinationIdentity, name: name)
                }
                try finish(&frames[top])
                close(frames[top].source)
                close(frames[top].destination)
                frames.removeLast()
            }
        } catch {
            abandon(&frames)
            throw error
        }
    }

    /// Creates the folder `name` in `destination`, opens it and its source, and makes the pair
    /// the folder being worked on. With `list` false the folder stays empty.
    private static func enter(at parent: Int32, _ name: String, to destinationParent: Int32, _ destinationName: String,
                              info: stat, saved: SavedEntry?, list: Bool, frames: inout [CloneFrame]) throws {
        var saved = saved
        var source: Int32 = -1
        var destination: Int32 = -1
        do {
            if saved == nil {
                (source, saved) = try openForReading(at: parent, name, info: info)
            } else {
                source = openat(parent, name, folderFlags)
                guard source >= 0 else {
                    throw AgentVMError.system(operation: "open \(name)", code: errno)
                }
            }
            guard mkdirat(destinationParent, destinationName, 0o700) == 0 else {
                throw AgentVMError.system(operation: "create folder \(name)", code: errno)
            }
            destination = openat(destinationParent, destinationName, folderFlags)
            var destinationInfo = stat()
            guard destination >= 0, fstat(destination, &destinationInfo) == 0 else {
                throw AgentVMError.system(operation: "open the copy of \(name)", code: errno)
            }
            // The folder as it is now, which may no longer be the one `info` described.
            var sourceInfo = stat()
            guard fstat(source, &sourceInfo) == 0 else {
                throw AgentVMError.system(operation: "stat \(name)", code: errno)
            }
            let listed = list ? try entries(of: source, name: name) : []
            if let top = frames.indices.last {
                close(frames[top].source)
                close(frames[top].destination)
                frames[top].source = -1
                frames[top].destination = -1
            }
            frames.append(CloneFrame(source: source, destination: destination, sourceIdentity: Identity(sourceInfo),
                                     destinationIdentity: Identity(destinationInfo), saved: saved, name: name, entries: listed))
        } catch {
            if let saved {
                if source >= 0 {
                    restoreEntry(descriptor: source, saved)
                } else {
                    restoreEntry(pathByIdentity(device: info.st_dev, inode: info.st_ino), saved)
                }
                saved.free()
            }
            if source >= 0 {
                close(source)
            }
            if destination >= 0 {
                close(destination)
            }
            throw error
        }
    }

    /// Opens a folder of the tree being cloned, to list it and to reach its entries. A folder
    /// that does not let its owner do that is opened up first; the returned state puts it back.
    private static func openForReading(at parent: Int32, _ name: String, info: stat) throws -> (Int32, SavedEntry?) {
        let descriptor = openat(parent, name, folderFlags)
        if descriptor >= 0 {
            // Permission to list was checked by the open; reaching the entries is another one.
            if faccessat(descriptor, ".", R_OK | X_OK, AT_EACCESS) == 0 {
                return (descriptor, nil)
            }
            close(descriptor)
        } else if errno != EACCES && errno != EPERM {
            throw AgentVMError.system(operation: "open \(name)", code: errno)
        }
        let identity = pathByIdentity(device: info.st_dev, inode: info.st_ino)
        let saved = try unlockEntry(identity)
        let opened = openat(parent, name, folderFlags)
        guard opened >= 0 else {
            let code = errno
            restoreEntry(identity, saved)
            saved.free()
            throw AgentVMError.system(operation: "open \(name)", code: code)
        }
        return (opened, saved)
    }

    private static func cloneChild(_ entry: Listed, device: dev_t, frames: inout [CloneFrame]) throws {
        let top = frames.count - 1
        let source = frames[top].source
        let destination = frames[top].destination
        var info = stat()
        var saved: SavedEntry?
        if fstatat(source, entry.name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT {
                return
            }
            guard errno == EACCES else {
                throw AgentVMError.system(operation: "stat \(entry.name)", code: errno)
            }
            // An ACL that denies even this. The entry's volume is its folder's, unless it is a
            // mount point, which no ACL of the tree can make unreadable this way.
            let opened = try unlockEntry(pathByIdentity(device: frames[top].sourceIdentity.device, inode: entry.inode))
            info = opened.info
            saved = opened
        }
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            try enter(at: source, entry.name, to: destination, entry.name, info: info, saved: saved,
                      list: info.st_dev == device, frames: &frames)
        case S_IFSOCK, S_IFIFO, S_IFCHR, S_IFBLK:
            saved?.free()
        default:
            try cloneEntry(at: source, entry.name, to: destination, entry.name, info: info, saved: saved)
        }
    }

    /// Clones one file or symlink. `saved` is what the caller already had to change on it.
    private static func cloneEntry(at parent: Int32, _ name: String, to destinationParent: Int32, _ destinationName: String,
                                   info: stat, saved: SavedEntry?) throws {
        var saved = saved
        defer { saved?.free() }
        if saved == nil {
            if clonefileat(parent, name, destinationParent, destinationName, UInt32(CLONE_NOFOLLOW | CLONE_ACL)) == 0 {
                return
            }
            switch errno {
            case ENOENT:
                return
            case ENOTSUP:
                try copyEntry(at: parent, name, to: destinationParent, destinationName, info: info)
                return
            case EACCES, EPERM:
                break
            default:
                throw AgentVMError.system(operation: "clone \(name)", code: errno)
            }
        }
        // Not readable by its owner: opened up for the clone, then both get the state back.
        let identity = pathByIdentity(device: info.st_dev, inode: info.st_ino)
        if saved == nil {
            saved = try unlockEntry(identity)
        }
        let mode = info.st_mode & 0o7777
        // A symlink has permissions of its own (chmod -h), and is read to be cloned too.
        let type = info.st_mode & S_IFMT
        let unreadable = (type == S_IFREG || type == S_IFLNK) && mode & S_IRUSR == 0
        if unreadable {
            _ = fchmodat(AT_FDCWD, identity, mode | S_IRUSR, AT_SYMLINK_NOFOLLOW)
        }
        let cloned = clonefileat(parent, name, destinationParent, destinationName, UInt32(CLONE_NOFOLLOW | CLONE_ACL)) == 0
        let code = errno
        var restored = [identity]
        // The copy, by identity too: its name may be past what a path can hold.
        var copy = stat()
        if cloned, fstatat(destinationParent, destinationName, &copy, AT_SYMLINK_NOFOLLOW) == 0 {
            restored.append(pathByIdentity(device: copy.st_dev, inode: copy.st_ino))
        }
        for path in restored {
            if unreadable {
                _ = fchmodat(AT_FDCWD, path, mode, AT_SYMLINK_NOFOLLOW)
            }
            if let saved {
                restoreEntry(path, saved)
            }
        }
        guard cloned || code == ENOENT else {
            throw AgentVMError.system(operation: "clone \(name)", code: code)
        }
    }

    /// For what clonefileat(2) refuses with ENOTSUP: a plain copy, with the same attributes.
    private static func copyEntry(at parent: Int32, _ name: String, to destinationParent: Int32, _ destinationName: String,
                                  info: stat) throws {
        switch info.st_mode & S_IFMT {
        case S_IFREG:
            // O_NONBLOCK: the file may have been exchanged for a FIFO since it was examined.
            let from = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard from >= 0 else {
                throw AgentVMError.system(operation: "open \(name)", code: errno)
            }
            defer { close(from) }
            let to = openat(destinationParent, destinationName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard to >= 0 else {
                throw AgentVMError.system(operation: "create \(name)", code: errno)
            }
            defer { close(to) }
            guard fcopyfile(from, to, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else {
                throw AgentVMError.system(operation: "copy \(name)", code: errno)
            }
        case S_IFLNK:
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let length = readlinkat(parent, name, &buffer, Int(PATH_MAX))
            guard length >= 0 else {
                throw AgentVMError.system(operation: "read the link \(name)", code: errno)
            }
            buffer[length] = 0
            guard symlinkat(buffer, destinationParent, destinationName) == 0 else {
                throw AgentVMError.system(operation: "create the link \(name)", code: errno)
            }
        default:
            return
        }
    }

    /// Gives the new folder what the source folder has, now that its entries are in, and puts
    /// back what was changed on the source to read it.
    private static func finish(_ frame: inout CloneFrame) throws {
        var code = copyFolderAttributes(from: frame.source, to: frame.destination)
        // An ACL that lets the folder be listed but not described.
        if (code == EACCES || code == EPERM), frame.saved == nil {
            frame.saved = try unlockEntry(descriptor: frame.source, name: frame.name)
            code = copyFolderAttributes(from: frame.source, to: frame.destination)
        }
        guard code == 0 else {
            throw AgentVMError.system(operation: "copy the attributes of \(frame.name)", code: code)
        }
        if let saved = frame.saved {
            // The copy was made from the opened-up folder, so it gets the same state back.
            restoreEntry(descriptor: frame.destination, saved)
            restoreEntry(descriptor: frame.source, saved)
            saved.free()
            frame.saved = nil
        }
    }

    /// Extended attributes, times, permissions, ACL and the flags a session compares, in the
    /// order that lets each be set (a locked folder takes nothing more). Returns errno, or 0.
    ///
    /// Not fcopyfile(3): far down a tree every call that changes an entry takes time in
    /// proportion to the depth (measured: 7 ms for one fchmod 3000 folders down), and
    /// fcopyfile makes several, whatever there is to copy. Here a plain folder costs two.
    private static func copyFolderAttributes(from source: Int32, to destination: Int32) -> Int32 {
        var info = stat()
        guard fstat(source, &info) == 0 else {
            return errno
        }
        let listLength = flistxattr(source, nil, 0, 0)
        guard listLength >= 0 else {
            return errno
        }
        if listLength > 0 {
            var names = [CChar](repeating: 0, count: listLength)
            let length = flistxattr(source, &names, names.count, 0)
            guard length >= 0 else {
                return errno
            }
            var start = 0
            while start < length {
                let end = names[start..<length].firstIndex(of: 0) ?? length
                let code: Int32 = names.withUnsafeBufferPointer { buffer in
                    let name = buffer.baseAddress! + start
                    let size = fgetxattr(source, name, nil, 0, 0, 0)
                    guard size >= 0 else {
                        return errno
                    }
                    var value = [UInt8](repeating: 0, count: max(size, 1))
                    let got = fgetxattr(source, name, &value, size, 0, 0)
                    guard got >= 0 else {
                        return errno
                    }
                    return fsetxattr(destination, name, value, got, 0, 0) == 0 ? 0 : errno
                }
                // One that went away meanwhile is not an error.
                guard code == 0 || code == ENOATTR else {
                    return code
                }
                start = end + 1
            }
        }
        var times = [info.st_atimespec, info.st_mtimespec]
        guard futimens(destination, &times) == 0 else {
            return errno
        }
        if info.st_mode & 0o7777 != 0o700 {
            guard fchmod(destination, info.st_mode & 0o7777) == 0 else {
                return errno
            }
        }
        // No ACL reads as ENOENT.
        if let acl = acl_get_fd_np(source, ACL_TYPE_EXTENDED) {
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            guard acl_set_fd_np(destination, acl, ACL_TYPE_EXTENDED) == 0 else {
                return errno
            }
        } else if errno != ENOENT {
            return errno
        }
        if info.st_flags & comparedFlags != 0 {
            guard fchflags(destination, info.st_flags & comparedFlags) == 0 else {
                return errno
            }
        }
        return 0
    }

    /// After a failure: puts back what was opened up on the way down, innermost first, each
    /// folder reached from the one below it, and closes what is open.
    private static func abandon(_ frames: inout [CloneFrame]) {
        var index = frames.count - 1
        while index >= 0 {
            let frame = frames[index]
            if index > 0, frame.source >= 0, frames[index - 1].source < 0 {
                frames[index - 1].source = (try? openParent(of: frame.source, expecting: frames[index - 1].sourceIdentity, name: frame.name)) ?? -1
            }
            if let saved = frame.saved {
                if frame.source >= 0 {
                    restoreEntry(descriptor: frame.source, saved)
                } else {
                    // Not reachable from below (a folder was moved): by its identity then.
                    restoreEntry(pathByIdentity(device: frame.sourceIdentity.device, inode: frame.sourceIdentity.inode), saved)
                }
                saved.free()
            }
            if frame.source >= 0 {
                close(frame.source)
            }
            if frame.destination >= 0 {
                close(frame.destination)
            }
            index -= 1
        }
        frames.removeAll()
    }

    // MARK: - Remove

    private struct RemoveFrame {
        /// Open only while this is the folder being emptied; -1 otherwise.
        var folder: Int32
        let identity: Identity
        let name: String
        let entries: [Listed]
        var index = 0
    }

    /// Deletes a whole tree even if an agent made folders read-only or unreadable, set the user
    /// "immutable" or "append-only" flags, or added access control lists (which override the
    /// mode): each is cleared where it is in the way. Never follows symlinks and never descends
    /// into another mounted volume. A missing path is done.
    static func removeTree(_ path: String) throws {
        var info = stat()
        if lstat(path, &info) != 0 {
            if errno == ENOENT {
                return
            }
            // An ACL denying "readsecurity" makes lstat fail on a tree that is still there.
            _ = removeACL(path)
            guard lstat(path, &info) == 0 else {
                throw AgentVMError.system(operation: "delete \(path)", code: errno)
            }
        }
        do {
            if isDirectory(info) {
                try emptyFolder(path, device: info.st_dev)
            }
            try removeEntry(at: AT_FDCWD, path, info: info)
        } catch let AgentVMError.system(detail, code) {
            throw AgentVMError.system(operation: "delete \(path) (\(detail))", code: code)
        }
    }

    private static func emptyFolder(_ path: String, device: dev_t) throws {
        var frames: [RemoveFrame] = []
        defer {
            for frame in frames where frame.folder >= 0 {
                close(frame.folder)
            }
        }
        frames.append(try openForRemoval(at: AT_FDCWD, path, identity: path))
        while let top = frames.indices.last {
            if frames[top].index < frames[top].entries.count {
                let entry = frames[top].entries[frames[top].index]
                frames[top].index += 1
                let folder = frames[top].folder
                var info = stat()
                if fstatat(folder, entry.name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                    if errno == ENOENT {
                        continue
                    }
                    guard errno == EACCES else {
                        throw AgentVMError.system(operation: "stat \(entry.name)", code: errno)
                    }
                    let opened = try unlockEntry(pathByIdentity(device: frames[top].identity.device, inode: entry.inode))
                    info = opened.info
                    opened.free()
                }
                guard isDirectory(info), info.st_dev == device else {
                    try removeEntry(at: folder, entry.name, info: info)
                    continue
                }
                let child = try openForRemoval(at: folder, entry.name, identity: pathByIdentity(device: info.st_dev, inode: info.st_ino))
                close(folder)
                frames[top].folder = -1
                frames.append(child)
                continue
            }
            // Empty now: back to its parent, which removes it.
            guard top > 0 else {
                return
            }
            let done = frames[top]
            let parent = try openParent(of: done.folder, expecting: frames[top - 1].identity, name: done.name)
            close(done.folder)
            frames.removeLast()
            frames[top - 1].folder = parent
            guard unlinkat(parent, done.name, AT_REMOVEDIR) == 0 || errno == ENOENT else {
                throw AgentVMError.system(operation: "delete \(done.name)", code: errno)
            }
        }
    }

    /// Opens a folder to delete everything in it: listable, searchable and writable by its
    /// owner, without lock flags or an ACL. Nothing is put back.
    private static func openForRemoval(at parent: Int32, _ name: String, identity: String) throws -> RemoveFrame {
        var folder = openat(parent, name, folderFlags)
        if folder < 0, errno == EACCES || errno == EPERM {
            try unlockEntry(identity).free()
            folder = openat(parent, name, folderFlags)
        }
        guard folder >= 0 else {
            throw AgentVMError.system(operation: "open \(name)", code: errno)
        }
        do {
            let saved = try unlockEntry(descriptor: folder, name: name)
            let identity = Identity(saved.info)
            saved.free()
            return RemoveFrame(folder: folder, identity: identity, name: name, entries: try entries(of: folder, name: name))
        } catch {
            close(folder)
            throw error
        }
    }

    /// Deletes one entry that is not a folder, or a folder that is empty.
    private static func removeEntry(at parent: Int32, _ name: String, info: stat) throws {
        let flag = isDirectory(info) ? AT_REMOVEDIR : 0
        if info.st_flags & userLockFlags == 0 {
            if unlinkat(parent, name, flag) == 0 || errno == ENOENT {
                return
            }
            guard errno == EACCES || errno == EPERM else {
                throw AgentVMError.system(operation: "delete \(name)", code: errno)
            }
        }
        // A lock flag, or an ACL that denies deleting it.
        (try? unlockEntry(pathByIdentity(device: info.st_dev, inode: info.st_ino)))?.free()
        guard unlinkat(parent, name, flag) == 0 || errno == ENOENT else {
            throw AgentVMError.system(operation: "delete \(name)", code: errno)
        }
    }
}
