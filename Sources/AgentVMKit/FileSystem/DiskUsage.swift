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
}
