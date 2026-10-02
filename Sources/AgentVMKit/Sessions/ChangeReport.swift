// Sources/AgentVMKit/Sessions/ChangeReport.swift
//
// What changed in a project since its session snapshot. Both trees are walked without
// following symlinks; the status-change time (ctime) is the fast path: an entry whose ctime,
// and that of every folder above it up to the project folder, is earlier than the session start
// is unchanged, because a process cannot set ctime (APFS ignores attempts to backdate it). The
// folders matter because moving or renaming a folder gives the folder a new ctime but leaves
// the entries inside with their old one. Every other file is compared with its snapshot copy:
// equal when both are still clones of the same data (same APFS clone id), otherwise byte for
// byte, so a touched-but-identical file is not reported. Deletions and additions come from
// comparing the two trees, since a deleted file has no ctime.

import Darwin
import Foundation

public enum ChangeKind: String, Codable, Sendable {
    case added
    case deleted
    /// Content (or symlink target) differs.
    case modified
    /// A file became a folder, a symlink became a file, and so on.
    case typeChanged
    /// Same content, different permissions or file flags.
    case metadata
}

public enum EntryType: String, Codable, Sendable {
    case file, directory, symlink, other
}

public struct Change: Codable, Equatable, Sendable {
    /// Path relative to the project root.
    public let path: String
    public let kind: ChangeKind
    /// The entry's type now (for `deleted`: before).
    public let type: EntryType
    /// The type in the snapshot, when it differs (`typeChanged`).
    public let previousType: EntryType?
    public let size: Int64?
    public let previousSize: Int64?
    public let symlinkTarget: String?
    /// For an added, deleted or retyped folder: how many entries inside it are covered by this
    /// one change.
    public let entriesInside: Int?
    /// True when a change to an ancestor folder already covers this entry (it is listed only
    /// because it carries a flag). Undo skips it.
    public let coveredByAncestor: Bool
    public let flags: [RiskFlag]

    public var highestSeverity: RiskFlag.Severity? {
        return flags.map(\.severity).max()
    }
}

public struct ChangeReport: Codable, Sendable {
    public struct Summary: Codable, Equatable, Sendable {
        public var added = 0
        public var deleted = 0
        public var modified = 0
        public var typeChanged = 0
        public var metadata = 0
        public var flaggedHigh = 0
        public var flaggedMedium = 0
    }

    public let session: String
    public let project: String
    /// The snapshot folder: the project as it was when the session started, to compare with.
    public let snapshotPath: String?
    public let startedAt: Date
    public let generatedAt: Date
    public let summary: Summary
    /// Sorted by path.
    public let changes: [Change]
    /// Things the walk could not fully examine.
    public let warnings: [String]

    public var isEmpty: Bool { changes.isEmpty }
}

/// One entry found by a tree walk.
struct TreeEntryInfo {
    let type: EntryType
    let mode: UInt16
    let size: Int64
    let flags: UInt32
    let linkCount: UInt16
    let changeSeconds: Int64
    let changeNanoseconds: Int64
    /// The folder could not be read (the agent may have removed permissions), so its contents are unknown.
    var unreadable: Bool
}

/// Paths relative to the project root, split on "/" by Unicode scalar. The Character-based
/// String operations would miss a "/" followed by a combining mark (one grapheme cluster), and a
/// file name may start with one.
enum RelativePath {
    static func components(_ path: String) -> [Substring] {
        return path.unicodeScalars.split(separator: "/").map { Substring($0) }
    }

    /// The path without its last component, or nil for a top-level entry.
    static func parent(_ path: String) -> String? {
        guard let slash = path.unicodeScalars.lastIndex(of: "/") else {
            return nil
        }
        return String(path.unicodeScalars[..<slash])
    }

    /// True when `path` is `folder` itself or inside it.
    static func isWithin(_ path: String, _ folder: String) -> Bool {
        return path == folder || path.unicodeScalars.starts(with: (folder + "/").unicodeScalars)
    }

    static func depth(_ path: String) -> Int {
        return components(path).count
    }
}

enum ChangeScanner {
    /// Compares `snapshot` with `project` and produces the report for `session`.
    static func report(session: Session, now: Date = Date()) throws -> ChangeReport {
        let record = session.record
        var warnings: [String] = []
        let before = try walk(session.snapshotPath, warnings: &warnings)
        let after = try walk(record.project, warnings: &warnings)
        let repositories = repositories(in: after)
        let nowSeconds = Int64(now.timeIntervalSince1970)

        var changes: [Change] = []
        // Paths whose whole subtree one change already covers, with the count of entries inside.
        var coveringRoots: [String: Int] = [:]

        func coveringAncestor(of path: String) -> String? {
            var current = path
            while let parent = RelativePath.parent(current) {
                current = parent
                if coveringRoots[current] != nil {
                    return current
                }
            }
            return nil
        }

        // An old ctime proves nothing for an entry inside a folder that changed during the
        // session: the folder may have been moved in with everything inside it. That includes
        // the project folder itself, which could have been swapped for another folder.
        func changedSinceStart(_ seconds: Int64, _ nanoseconds: Int64) -> Bool {
            return (seconds, nanoseconds) >= (record.startSeconds, record.startNanoseconds)
        }
        let rootNow = try? FileSystem.statusRemovingUnreadableACL(record.project)
        let rootChanged = rootNow.map {
            changedSinceStart(Int64($0.st_ctimespec.tv_sec), Int64($0.st_ctimespec.tv_nsec))
        } ?? true
        func insideChangedFolder(_ path: String) -> Bool {
            if rootChanged {
                return true
            }
            var current = path
            while let parent = RelativePath.parent(current) {
                current = parent
                if let folder = after[current], changedSinceStart(folder.changeSeconds, folder.changeNanoseconds) {
                    return true
                }
            }
            return false
        }

        func symlinkTarget(_ root: String, _ relative: String) -> String? {
            return try? FileManager.default.destinationOfSymbolicLink(atPath: root + "/" + relative)
        }

        // Entries present now: added, retyped, modified, metadata changes.
        for path in after.keys.sorted() {
            let new = after[path]!
            if let root = coveringAncestor(of: path) {
                coveringRoots[root, default: 0] += 1
                // Still surface flagged entries inside an added or replaced folder.
                let target = new.type == .symlink ? symlinkTarget(record.project, path) : nil
                let flags = RiskRules.flags(for: path, kind: .added, type: new.type, mode: new.mode, previousMode: nil,
                                            symlinkTarget: target, linkCount: new.linkCount, repositories: repositories)
                if flags.contains(where: { $0.severity != .info }) {
                    changes.append(Change(path: path, kind: .added, type: new.type, previousType: nil, size: new.size,
                                          previousSize: nil, symlinkTarget: target, entriesInside: nil,
                                          coveredByAncestor: true, flags: flags))
                }
                continue
            }

            if new.changeSeconds > nowSeconds + 1 {
                warnings.append("\(path) has a status-change time in the future; the clock may have been changed")
            }

            guard let old = before[path] else {
                let target = new.type == .symlink ? symlinkTarget(record.project, path) : nil
                if new.type == .directory {
                    coveringRoots[path] = 0
                }
                changes.append(makeChange(repositories, path, .added, new: new, old: nil, target: target))
                continue
            }

            if old.type != new.type || new.unreadable || old.unreadable {
                let target = new.type == .symlink ? symlinkTarget(record.project, path) : nil
                if new.type == .directory || old.type == .directory {
                    coveringRoots[path] = 0
                }
                if new.unreadable || old.unreadable {
                    warnings.append("\(path) is a folder that cannot be read; undo replaces it as a whole")
                }
                changes.append(makeChange(repositories, path, old.type != new.type ? .typeChanged : .modified, new: new, old: old, target: target))
                continue
            }

            // Same type from here on.
            let changedDuringSession = changedSinceStart(new.changeSeconds, new.changeNanoseconds) || insideChangedFolder(path)
            if !changedDuringSession {
                continue
            }
            let metadataDiffers = new.mode != old.mode || (new.flags & FileSystem.comparedFlags) != (old.flags & FileSystem.comparedFlags)
            switch new.type {
            case .directory:
                if metadataDiffers {
                    changes.append(makeChange(repositories, path, .metadata, new: new, old: old, target: nil))
                }
            case .symlink:
                let newTarget = symlinkTarget(record.project, path)
                if newTarget != symlinkTarget(session.snapshotPath, path) {
                    changes.append(makeChange(repositories, path, .modified, new: new, old: old, target: newTarget))
                }
            case .other:
                // FIFOs and devices have no content to compare (and opening a FIFO blocks).
                if metadataDiffers {
                    changes.append(makeChange(repositories, path, .metadata, new: new, old: old, target: nil))
                }
            case .file:
                let snapshotFile = session.snapshotPath + "/" + path
                let projectFile = record.project + "/" + path
                var contentDiffers = new.size != old.size
                if !contentDiffers && !sameClone(snapshotFile, projectFile) {
                    contentDiffers = try !sameContents(snapshotFile, projectFile)
                }
                if contentDiffers {
                    changes.append(makeChange(repositories, path, .modified, new: new, old: old, target: nil))
                } else if metadataDiffers {
                    changes.append(makeChange(repositories, path, .metadata, new: new, old: old, target: nil))
                }
            }
        }

        // Entries gone now: deletions (a deleted folder covers its contents).
        var deletedRoots: [String: Int] = [:]
        for path in before.keys.sorted() where after[path] == nil {
            if coveringAncestor(of: path) != nil {
                continue // inside a folder that was replaced by something else
            }
            if let root = deletedRoots.keys.first(where: { RelativePath.isWithin(path, $0) }) {
                deletedRoots[root, default: 0] += 1
                continue
            }
            let old = before[path]!
            if old.type == .directory {
                deletedRoots[path] = 0
            }
            changes.append(makeChange(repositories, path, .deleted, new: nil, old: old, target: nil))
        }

        // The project folder itself (the walks skip their roots): permissions or flags the agent
        // changed on it are reported as ".", which undo puts back.
        if let rootBefore = try? FileSystem.status(session.snapshotPath),
           let rootAfter = rootNow,
           rootBefore.st_mode & 0o7777 != rootAfter.st_mode & 0o7777
            || (rootBefore.st_flags & FileSystem.comparedFlags) != (rootAfter.st_flags & FileSystem.comparedFlags) {
            changes.append(Change(path: ".", kind: .metadata, type: .directory, previousType: nil, size: nil,
                                  previousSize: nil, symlinkTarget: nil, entriesInside: nil, coveredByAncestor: false,
                                  flags: [RiskFlag(rule: "project-folder", severity: .medium,
                                                   reason: "permissions or flags of the project folder itself changed")]))
        }

        // Fill in how many entries each covering change stands for.
        changes = changes.map { change in
            let count = coveringRoots[change.path] ?? deletedRoots[change.path]
            guard let count, !change.coveredByAncestor else {
                return change
            }
            return Change(path: change.path, kind: change.kind, type: change.type, previousType: change.previousType,
                          size: change.size, previousSize: change.previousSize, symlinkTarget: change.symlinkTarget,
                          entriesInside: count, coveredByAncestor: false, flags: change.flags)
        }.sorted { $0.path < $1.path }

        var summary = ChangeReport.Summary()
        for change in changes where !change.coveredByAncestor {
            switch change.kind {
            case .added: summary.added += 1
            case .deleted: summary.deleted += 1
            case .modified: summary.modified += 1
            case .typeChanged: summary.typeChanged += 1
            case .metadata: summary.metadata += 1
            }
        }
        for change in changes {
            switch change.highestSeverity {
            case .high?: summary.flaggedHigh += 1
            case .medium?: summary.flaggedMedium += 1
            default: break
            }
        }

        return ChangeReport(session: record.id, project: record.project, snapshotPath: session.snapshotPath, startedAt: record.startedAt, generatedAt: now,
                            summary: summary, changes: changes, warnings: warnings)
    }

    private static func makeChange(_ repositories: Set<String>, _ path: String, _ kind: ChangeKind, new: TreeEntryInfo?,
                                   old: TreeEntryInfo?, target: String?) -> Change {
        let type = (new ?? old)!.type
        let flags = RiskRules.flags(for: path, kind: kind, type: type, mode: new?.mode ?? old?.mode,
                                    previousMode: old?.mode, symlinkTarget: target, linkCount: new?.linkCount,
                                    repositories: repositories)
        return Change(path: path, kind: kind, type: type,
                      previousType: kind == .typeChanged ? old?.type : nil,
                      size: new?.size, previousSize: old?.size, symlinkTarget: target,
                      entriesInside: nil, coveredByAncestor: false, flags: flags)
    }

    /// The folders that hold a git repository without being named `.git`: a bare repository, or
    /// one made with `--separate-git-dir`. Recognized the way git recognizes one, by `HEAD` next
    /// to `objects/` and `refs/`; its hooks and configuration run like any other repository's.
    /// Paths are folded (`RiskRules.folded`); the project folder itself is "".
    static func repositories(in entries: [String: TreeEntryInfo]) -> Set<String> {
        var result = Set<String>()
        // Only when a candidate turns up: every folder of the tree, folded.
        var folders: Set<String>?
        for (path, info) in entries where info.type != .directory {
            let components = RelativePath.components(path)
            guard let last = components.last, last.utf8.count == 4, last.lowercased() == "head" else {
                continue
            }
            let folder = RiskRules.folded(components.dropLast().joined(separator: "/"))
            // Inside a `.git` folder the rules apply already.
            guard !RelativePath.components(folder).contains(".git") else {
                continue
            }
            if folders == nil {
                folders = Set(entries.filter { $0.value.type == .directory }.keys.map(RiskRules.folded))
            }
            let prefix = folder.isEmpty ? "" : folder + "/"
            if folders!.contains(prefix + "objects"), folders!.contains(prefix + "refs") {
                result.insert(folder)
            }
        }
        return result
    }

    /// Every entry under `root` keyed by path relative to it. Symlinks are not followed and the
    /// walk does not enter other mounted volumes.
    static func walk(_ root: String, warnings: inout [String]) throws -> [String: TreeEntryInfo] {
        var entries: [String: TreeEntryInfo] = [:]
        guard let rootCopy = strdup(root) else {
            throw AgentVMError.system(operation: "walk \(root)", code: ENOMEM)
        }
        defer { free(rootCopy) }
        var roots: [UnsafeMutablePointer<CChar>?] = [rootCopy, nil]
        guard let tree = fts_open(&roots, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            throw AgentVMError.system(operation: "walk \(root)", code: errno)
        }
        defer { fts_close(tree) }

        // In bytes: a Character count would swallow a combining mark at the start of a name
        // together with the "/" before it.
        let prefixLength = root.utf8.count + (root.hasSuffix("/") ? 0 : 1)
        while let entry = fts_read(tree) {
            let info = Int32(entry.pointee.fts_info)
            if entry.pointee.fts_level == 0 || info == FTS_DP {
                continue
            }
            let relative = String(cString: entry.pointee.fts_path + prefixLength)
            guard info != FTS_NS, info != FTS_ERR, let status = entry.pointee.fts_statp?.pointee else {
                warnings.append("\(relative) could not be examined: \(String(cString: strerror(entry.pointee.fts_errno)))")
                // A folder that lists its entries but does not let them be examined (no search
                // permission) is replaced as a whole, like an unreadable one; otherwise its
                // entries would look deleted.
                if let parent = entry.pointee.fts_parent, parent.pointee.fts_level > 0,
                   let parentRelative = RelativePath.parent(relative) {
                    entries[parentRelative]?.unreadable = true
                }
                continue
            }
            let type: EntryType
            switch status.st_mode & S_IFMT {
            case S_IFREG: type = .file
            case S_IFDIR: type = .directory
            case S_IFLNK: type = .symlink
            case S_IFSOCK, S_IFIFO, S_IFCHR, S_IFBLK:
                // Left out of the snapshot (they hold no content), so left out here too: a live
                // socket such as git's fsmonitor must not show up as added, or be moved by undo.
                continue
            default: type = .other
            }
            entries[relative] = TreeEntryInfo(
                type: type,
                mode: UInt16(status.st_mode & 0o7777),
                size: Int64(status.st_size),
                flags: status.st_flags,
                linkCount: UInt16(truncatingIfNeeded: status.st_nlink),
                changeSeconds: Int64(status.st_ctimespec.tv_sec),
                changeNanoseconds: Int64(status.st_ctimespec.tv_nsec),
                unreadable: info == FTS_DNR)
        }
        return entries
    }

    /// Byte-for-byte comparison of two regular files, without following symlinks.
    static func sameContents(_ first: String, _ second: String) throws -> Bool {
        let a = open(first, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard a >= 0 else {
            // The snapshot keeps a file nobody can read as it was, unreadable.
            if errno == EACCES {
                return false
            }
            throw AgentVMError.system(operation: "open \(first)", code: errno)
        }
        defer { close(a) }
        // O_NONBLOCK: an agent still running could swap the file for a FIFO, whose open blocks.
        let b = open(second, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard b >= 0 else {
            // An unreadable file cannot be shown to be unchanged.
            return false
        }
        defer { close(b) }
        var info = stat()
        guard fstat(b, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            return false
        }

        let chunk = 1 << 20
        let bufferA = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
        let bufferB = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
        defer {
            bufferA.deallocate()
            bufferB.deallocate()
        }
        while true {
            let countA = readFully(a, bufferA, chunk)
            let countB = readFully(b, bufferB, chunk)
            if countA < 0 || countB < 0 {
                return false
            }
            if countA != countB || memcmp(bufferA, bufferB, countA) != 0 {
                return false
            }
            if countA == 0 {
                return true
            }
        }
    }

    /// True when both regular files are clones sharing the same data (the same APFS clone id):
    /// then their contents are equal without reading them. Writing to either clone gives it a
    /// new clone id.
    static func sameClone(_ first: String, _ second: String) -> Bool {
        guard let a = cloneID(first), let b = cloneID(second) else {
            return false
        }
        return a == b
    }

    private static func cloneID(_ path: String) -> UInt64? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        request.forkattr = attrgroup_t(ATTR_CMNEXT_CLONEID)
        // u_int32_t length, attribute_set_t returned (5 x u_int32_t), then the u_int64_t clone id.
        var buffer = (UInt64(0), UInt64(0), UInt64(0), UInt64(0))
        let status = withUnsafeMutableBytes(of: &buffer) { raw in
            getattrlist(path, &request, raw.baseAddress, raw.count, UInt32(FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED))
        }
        guard status == 0 else {
            return nil
        }
        return withUnsafeBytes(of: &buffer) { raw -> UInt64? in
            let returnedExtended = raw.loadUnaligned(fromByteOffset: 4 + 16, as: UInt32.self)
            guard returnedExtended & UInt32(ATTR_CMNEXT_CLONEID) != 0 else {
                return nil
            }
            return raw.loadUnaligned(fromByteOffset: 24, as: UInt64.self)
        }
    }

    /// Reads up to `count` bytes, retrying short reads; returns the byte count, 0 at end of file,
    /// or -1 on error.
    private static func readFully(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
        var total = 0
        while total < count {
            let got = read(descriptor, buffer + total, count - total)
            if got < 0 {
                if errno == EINTR {
                    continue
                }
                return -1
            }
            if got == 0 {
                break
            }
            total += got
        }
        return total
    }
}
