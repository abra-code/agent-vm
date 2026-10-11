// Sources/AgentVMKit/FileSystem/GitFolders.swift
//
// The git folders of a project: every entry named `.git` under it. A session that snapshots
// only these is fast for a huge tree (a folder of many repositories), because the files of the
// working trees are neither cloned nor examined: the search reads folder listings only.
//
// Found by walking, never through a symlink and never into another mounted volume. A `.git`
// may be a folder (a repository), a file (a worktree or a submodule, which names its git folder
// elsewhere) or a symlink; each is taken as it is. The search does not go into a `.git`: what is
// in it belongs to it.

import Darwin
import Foundation

extension FileSystem {
    struct GitEntries {
        /// Paths relative to the searched folder, sorted.
        var found: [String] = []
        /// Folders that could not be listed (no permission, or too deep for a path), relative
        /// too; "." is the searched folder itself. Git folders inside them are not found.
        var unsearched: [String] = []
        /// How many entries the search listed.
        var listed = 0
    }

    /// True for the name git gives its folder, in any case: on the default (case-insensitive)
    /// macOS volume `.GIT` is the same entry.
    static func isGitName<Name: StringProtocol>(_ name: Name) -> Bool {
        return name.utf8.count == 4 && name.lowercased() == ".git"
    }

    /// Every entry named `.git` under `root`. `progress` is called now and then with the number
    /// of entries listed so far; what it throws stops the search.
    static func gitEntries(under root: String, progress: ((Int) throws -> Void)? = nil) throws -> GitEntries {
        var result = GitEntries()
        var rootInfo = stat()
        guard lstat(root, &rootInfo) == 0 else {
            throw AgentVMError.system(operation: "stat \(root)", code: errno)
        }
        // Folders still to list, relative to the root ("" is the root).
        var pending = [""]
        while let folder = pending.popLast() {
            let path = folder.isEmpty ? root : root + "/" + folder
            let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else {
                switch errno {
                case ENOENT, ENOTDIR, ELOOP:
                    // Gone, or no longer a folder, since its parent was listed.
                    continue
                case EACCES, EPERM, ENAMETOOLONG:
                    result.unsearched.append(folder.isEmpty ? "." : folder)
                    continue
                default:
                    throw AgentVMError.system(operation: "open \(path)", code: errno)
                }
            }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_dev == rootInfo.st_dev, let stream = fdopendir(descriptor) else {
                close(descriptor)
                continue
            }
            defer { closedir(stream) }
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else {
                        throw AgentVMError.system(operation: "list \(path)", code: errno)
                    }
                    break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." {
                    continue
                }
                result.listed += 1
                if let progress, result.listed % 4096 == 0 {
                    try progress(result.listed)
                }
                var type = Int32(entry.pointee.d_type)
                let relative = folder.isEmpty ? name : folder + "/" + name
                if type == DT_UNKNOWN {
                    var entryInfo = stat()
                    guard fstatat(dirfd(stream), name, &entryInfo, AT_SYMLINK_NOFOLLOW) == 0 else {
                        continue
                    }
                    switch entryInfo.st_mode & S_IFMT {
                    case S_IFDIR: type = DT_DIR
                    case S_IFREG: type = DT_REG
                    case S_IFLNK: type = DT_LNK
                    default: type = DT_FIFO
                    }
                }
                if isGitName(name) {
                    // A socket, FIFO or device holds no content, as in a whole snapshot.
                    if type == DT_DIR || type == DT_REG || type == DT_LNK {
                        result.found.append(relative)
                    }
                } else if type == DT_DIR {
                    pending.append(relative)
                }
            }
        }
        result.found.sort()
        result.unsearched.sort()
        return result
    }

    /// Clones every git folder under `source` to the same place under `destination`, which
    /// must not exist: `destination` then holds those entries and the plain folders above
    /// them, nothing else. Each is cloned as `cloneTree` clones. Returns what was found; a
    /// git folder too deep for a path is among the unsearched. A failed clone leaves no
    /// destination behind.
    ///
    /// `progress` is called now and then with the number of entries listed and cloned so far.
    /// What it throws stops the clone, which then leaves no destination either.
    static func cloneGitFolders(_ source: String, to destination: String, progress: ((Int) throws -> Void)? = nil) throws -> GitEntries {
        guard !exists(destination) else {
            throw AgentVMError.system(operation: "clone \(source) to \(destination)", code: EEXIST)
        }
        var entries = try gitEntries(under: source, progress: progress)
        try makeDirectory(destination)
        do {
            var kept: [String] = []
            var met = entries.listed
            for relative in entries.found {
                var folder = destination
                for component in RelativePath.components(relative).dropLast() {
                    folder += "/" + component
                    if mkdir(folder, 0o700) != 0, errno != EEXIST {
                        throw AgentVMError.system(operation: "create folder \(folder)", code: errno)
                    }
                }
                var metHere = 0
                do {
                    try cloneTree(source + "/" + relative, to: destination + "/" + relative) { count in
                        metHere = count
                        try progress?(met + count)
                    }
                } catch AgentVMError.system(_, ENAMETOOLONG) {
                    entries.unsearched.append(relative)
                    continue
                } catch let error as AgentVMError {
                    guard case .system(_, ENOENT) = error else {
                        throw error
                    }
                    // Left out only when it is gone since it was found: a git folder missing
                    // from the snapshot for another reason would later read as added.
                    var info = stat()
                    guard lstat(source + "/" + relative, &info) != 0, errno == ENOENT else {
                        throw error
                    }
                    continue
                }
                met += metHere + 1
                kept.append(relative)
            }
            entries.found = kept
            entries.unsearched.sort()
        } catch {
            try? removeTree(destination)
            throw error
        }
        return entries
    }
}
