// Sources/AgentVMKit/FileSystem/DiskUsage.swift
//
// How much space an image or box folder takes, and how much of it only that folder holds.
// Images, their boxes and derived images are APFS clones of one another: a box's disk file
// may have 35 GB allocated while nearly all of it is shared with its image. APFS reports per
// file the bytes no clone shares (ATTR_CMNEXT_PRIVATESIZE), which is what deleting the file
// frees: for a box, what it wrote, plus the image's blocks the image rewrote after the box
// was cloned. About 0.1 s for a 64 GB disk file (measured).

import Darwin
import Foundation

public struct DiskUsage: Equatable, Sendable, Encodable {
    /// Bytes allocated to the folder's files, shared or not (what `du` counts).
    public var bytes: Int64
    /// Bytes only these files hold, which deleting them frees; nil when the volume does not
    /// report it (only APFS does).
    public var unsharedBytes: Int64?

    public init(bytes: Int64, unsharedBytes: Int64?) {
        self.bytes = bytes
        self.unsharedBytes = unsharedBytes
    }

    /// The usage of the regular files in `folder` and below; symbolic links are not followed,
    /// and files that vanish meanwhile are left out.
    public static func of(_ folder: URL) -> DiskUsage {
        var usage = DiskUsage(bytes: 0, unsharedBytes: 0)
        let paths = FileManager.default.enumerator(atPath: folder.path)
        while let relative = paths?.nextObject() as? String {
            let path = folder.appendingPathComponent(relative).path
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                continue
            }
            let unshared = unsharedBytes(ofFile: path)
            // Gone since lstat (a record saved atomically replaces its temporary file): left
            // out, rather than read as a volume that does not report unshared bytes.
            var after = stat()
            if unshared == nil && lstat(path, &after) != 0 {
                continue
            }
            usage.bytes += Int64(info.st_blocks) * 512
            if let total = usage.unsharedBytes {
                usage.unsharedBytes = unshared.map { total + $0 }
            }
        }
        return usage
    }

    /// The bytes of one file that no clone shares, or nil when the volume does not say.
    static func unsharedBytes(ofFile path: String) -> Int64? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        // The reply: its length (4 bytes), the attributes returned (attribute_set_t, 20 bytes),
        // then the size as an off_t.
        var reply = [UInt8](repeating: 0, count: 64)
        let status = reply.withUnsafeMutableBytes { buffer in
            getattrlist(path, &request, buffer.baseAddress, buffer.count, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW))
        }
        guard status == 0 else {
            return nil
        }
        return reply.withUnsafeBytes { buffer -> Int64? in
            let returned = buffer.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self)
            guard returned.forkattr & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0 else {
                return nil
            }
            return buffer.loadUnaligned(fromByteOffset: 4 + MemoryLayout<attribute_set_t>.size, as: off_t.self)
        }
    }

    // MARK: - Added over a base

    /// The bytes of `file`'s data in blocks `base` does not use: what a derived image's disk
    /// added over the disk it was cloned from, since clones share physical blocks until one
    /// side writes. Unlike `unsharedBytes`, it does not change when other clones come and go,
    /// so it traces each layer's growth. Nil when either file cannot be mapped. About 0.3 s
    /// for two 40 GB disks with 100,000 to 250,000 extents each (measured).
    public static func addedBytes(_ file: URL, over base: URL) -> Int64? {
        guard let mine = physicalExtents(file.path), let theirs = physicalExtents(base.path) else {
            return nil
        }
        return uncovered(mine, by: theirs)
    }

    /// Where a file's data lies on its volume: (device offset, length) of each extent, sorted
    /// by offset. Holes are skipped (SEEK_DATA, SEEK_HOLE); F_LOG2PHYS_EXT maps the rest. Data
    /// written but not yet flushed has no blocks yet, and its device offset is -1 (measured).
    static func physicalExtents(_ path: String) -> [(start: Int64, length: Int64)]? {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            return nil
        }
        defer { close(descriptor) }
        var extents: [(start: Int64, length: Int64)] = []
        var offset: off_t = 0
        while true {
            let data = lseek(descriptor, offset, SEEK_DATA)
            guard data >= 0 else {
                // ENXIO: no data past `offset`.
                if errno == ENXIO {
                    break
                }
                return nil
            }
            let hole = lseek(descriptor, data, SEEK_HOLE)
            guard hole > data else {
                return nil
            }
            var position = data
            while position < hole {
                var mapping = log2phys()
                mapping.l2p_contigbytes = hole - position
                mapping.l2p_devoffset = position
                guard fcntl(descriptor, F_LOG2PHYS_EXT, &mapping) == 0, mapping.l2p_contigbytes > 0 else {
                    return nil
                }
                extents.append((Int64(mapping.l2p_devoffset), Int64(mapping.l2p_contigbytes)))
                position += mapping.l2p_contigbytes
            }
            offset = hole
        }
        return extents.sorted { $0.start < $1.start }
    }

    /// The bytes of `ranges` that no range of `others` covers; both sorted by start. A range
    /// with a negative start (data not yet given blocks) is uncovered, and covers nothing.
    static func uncovered(_ ranges: [(start: Int64, length: Int64)], by others: [(start: Int64, length: Int64)]) -> Int64 {
        // `others` as disjoint (start, end) intervals.
        var covered: [(start: Int64, end: Int64)] = []
        for other in others where other.length > 0 && other.start >= 0 {
            if let last = covered.last, other.start <= last.end {
                covered[covered.count - 1].end = max(last.end, other.start + other.length)
            } else {
                covered.append((other.start, other.start + other.length))
            }
        }
        var total: Int64 = 0
        var first = 0
        for range in ranges where range.length > 0 {
            if range.start < 0 {
                total += range.length
                continue
            }
            var start = range.start
            let end = range.start + range.length
            while first < covered.count && covered[first].end <= start {
                first += 1
            }
            var index = first
            while start < end {
                guard index < covered.count, covered[index].start < end else {
                    total += end - start
                    break
                }
                if covered[index].start > start {
                    total += covered[index].start - start
                }
                start = max(start, covered[index].end)
                index += 1
            }
        }
        return total
    }
}
