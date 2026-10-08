// Tests/AgentVMKitTests/Qcow2ReaderTests.swift
//
// The qcow2 reader, on small files the tests write themselves: what it converts, and each
// thing it refuses.

import Darwin
import Foundation
import Testing
@testable import AgentVMKit

@Suite struct Qcow2ReaderTests {
    /// A qcow2 file as data: a header, a first table, the second tables, then the clusters.
    struct Image {
        enum Cluster {
            case plain(Data)
            /// Raw deflate data, as it is stored.
            case compressed(Data)
            /// Stored, and marked as reading zeros.
            case zeroFlag(Data)
        }

        var version: UInt32 = 3
        var clusterBits = 12
        var size: Int
        var clusters: [Int: Cluster] = [:]
        var backingOffset: UInt64 = 0
        var encryption: UInt32 = 0
        var features: UInt64 = 0
        var compressionType: UInt8 = 0
        /// Changes the finished file's bytes: a test's own damage.
        var damage: (inout Data) -> Void = { _ in }

        var clusterSize: Int {
            return 1 << clusterBits
        }

        static func big<T: FixedWidthInteger>(_ value: T) -> Data {
            return withUnsafeBytes(of: value.bigEndian) { Data($0) }
        }

        func data() -> Data {
            let perTable = clusterSize / 8
            let count = (size + clusterSize - 1) / clusterSize
            let tables = (count + perTable - 1) / perTable
            // Cluster 0: the header. Cluster 1: the first table. Then the second tables.
            var file = Data(count: clusterSize * (2 + tables))
            var entries = [UInt64](repeating: 0, count: tables * perTable)
            for (index, cluster) in clusters.sorted(by: { $0.key < $1.key }) {
                let start = UInt64(file.count)
                switch cluster {
                case let .plain(bytes):
                    file.append(bytes)
                    entries[index] = start | (1 << 63)
                case let .zeroFlag(bytes):
                    file.append(bytes)
                    entries[index] = start | 1
                case let .compressed(bytes):
                    file.append(bytes)
                    let sectors = UInt64((Int(start & 511) + bytes.count + 511) / 512 - 1)
                    entries[index] = (1 << 62) | (sectors << UInt64(62 - (clusterBits - 8))) | start
                }
                // The next cluster starts at a cluster boundary.
                file.append(Data(count: (clusterSize - file.count % clusterSize) % clusterSize))
            }
            for table in 0..<tables {
                let at = clusterSize * (2 + table)
                file.replaceSubrange((clusterSize + table * 8)..<(clusterSize + table * 8 + 8), with: Self.big(UInt64(at) | (1 << 63)))
                for index in 0..<perTable {
                    file.replaceSubrange((at + index * 8)..<(at + index * 8 + 8), with: Self.big(entries[table * perTable + index]))
                }
            }
            var header = Data([0x51, 0x46, 0x49, 0xFB])
            header.append(Self.big(version))
            header.append(Self.big(backingOffset))
            header.append(Self.big(UInt32(0)))
            header.append(Self.big(UInt32(clusterBits)))
            header.append(Self.big(UInt64(size)))
            header.append(Self.big(encryption))
            header.append(Self.big(UInt32(tables)))
            header.append(Self.big(UInt64(clusterSize)))
            // The reference count table, the snapshots: not read.
            header.append(Data(count: 24))
            if version == 3 {
                header.append(Self.big(features))
                header.append(Data(count: 16))
                header.append(Self.big(UInt32(4)))
                header.append(Self.big(UInt32(112)))
                header.append(Data([compressionType]))
                header.append(Data(count: 7))
            }
            file.replaceSubrange(0..<header.count, with: header)
            damage(&file)
            return file
        }
    }

    static func deflated(_ data: Data) throws -> Data {
        // Apple's "zlib" is raw deflate, which is what a qcow2 file stores.
        return try (data as NSData).compressed(using: .zlib) as Data
    }

    static func pattern(_ count: Int, seed: UInt8) -> Data {
        return Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ Int(seed)) })
    }

    static func write(_ image: Image, in scratch: Scratch, name: String = "source.qcow2") throws -> URL {
        let file = scratch.root.appendingPathComponent(name)
        try image.data().write(to: file)
        return file
    }

    /// Converts, and expects the reader's refusal with this reason; nothing is left behind by
    /// the unpacker.
    static func expectRefusal(_ image: Image, _ reason: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let scratch = try Scratch()
        let file = try write(image, in: scratch)
        let output = scratch.root.appendingPathComponent("Disk.img")
        #expect(throws: Qcow2Reader.Problem(reason), sourceLocation: sourceLocation) {
            _ = try Qcow2Reader.convert(file, to: output)
        }
    }

    @Test func aPlainImageConvertsToTheSameBytes() throws {
        let scratch = try Scratch()
        // 5 MiB and 1000 bytes more... no: a disk is whole sectors. 5 MiB and one sector, so
        // the last cluster is cut.
        let size = (5 << 20) + 512
        var image = Image(size: size)
        var disk = Data(count: size)
        for index in [0, 1, 300, 511, 512, 700, 1280] {
            let bytes = Self.pattern(image.clusterSize, seed: UInt8(index % 251))
            image.clusters[index] = .plain(bytes)
            let end = min((index + 1) * image.clusterSize, size)
            disk.replaceSubrange((index * image.clusterSize)..<end, with: bytes.prefix(end - index * image.clusterSize))
        }
        let file = try Self.write(image, in: scratch)
        #expect(try Qcow2Reader.header(of: file) == Qcow2Reader.Header(version: 3, clusterBits: 12, size: Int64(size), tableEntries: 3, tableOffset: 4096))
        let output = scratch.root.appendingPathComponent("Disk.img")
        #expect(try Qcow2Reader.convert(file, to: output) == Int64(size))
        #expect(try Data(contentsOf: output) == disk)
        #expect(((try FileManager.default.attributesOfItem(atPath: output.path))[.posixPermissions] as? Int) == 0o600)
        // A file that is there is not written over.
        #expect(throws: AgentVMError.self) { _ = try Qcow2Reader.convert(file, to: output) }
    }

    @Test func aVersion2ImageConverts() throws {
        let scratch = try Scratch()
        var image = Image(version: 2, size: 1 << 20)
        let bytes = Self.pattern(image.clusterSize, seed: 9)
        image.clusters[3] = .plain(bytes)
        let output = scratch.root.appendingPathComponent("Disk.img")
        #expect(try Qcow2Reader.convert(try Self.write(image, in: scratch), to: output) == 1 << 20)
        var disk = Data(count: 1 << 20)
        disk.replaceSubrange((3 * 4096)..<(4 * 4096), with: bytes)
        #expect(try Data(contentsOf: output) == disk)
    }

    @Test func compressedClustersAreInflated() throws {
        let scratch = try Scratch()
        for bits in [9, 12, 16, 21] {
            let cluster = 1 << bits
            let size = cluster * 6
            var image = Image(clusterBits: bits, size: size)
            // Text compresses; the last one barely does.
            let first = Data(String(repeating: "agent-vm reads qcow2. ", count: cluster / 22 + 1).utf8.prefix(cluster))
            let second = Self.pattern(cluster, seed: 3)
            let plain = Self.pattern(cluster, seed: 77)
            image.clusters[0] = .compressed(try Self.deflated(first))
            image.clusters[1] = .compressed(try Self.deflated(second))
            image.clusters[4] = .plain(plain)
            image.clusters[5] = .compressed(try Self.deflated(first))
            var disk = Data(count: size)
            disk.replaceSubrange(0..<cluster, with: first)
            disk.replaceSubrange(cluster..<(2 * cluster), with: second)
            disk.replaceSubrange((4 * cluster)..<(5 * cluster), with: plain)
            disk.replaceSubrange((5 * cluster)..<(6 * cluster), with: first)
            let output = scratch.root.appendingPathComponent("Disk-\(bits).img")
            #expect(try Qcow2Reader.convert(try Self.write(image, in: scratch, name: "source-\(bits).qcow2"), to: output) == Int64(size), "cluster bits \(bits)")
            #expect(try Data(contentsOf: output) == disk, "cluster bits \(bits)")
        }
    }

    /// The last compressed cluster of a file names whole sectors, and the file may end before
    /// the last of them does.
    @Test func aCompressedClusterAtTheFilesEndIsRead() throws {
        let scratch = try Scratch()
        var image = Image(clusterBits: 16, size: 1 << 20)
        let bytes = Data(String(repeating: "the end. ", count: 8000).utf8.prefix(1 << 16))
        let packed = try Self.deflated(bytes)
        image.clusters[2] = .compressed(packed)
        // No padding after the data.
        image.damage = { $0 = $0.prefix(3 * 65536 + packed.count) }
        let output = scratch.root.appendingPathComponent("Disk.img")
        _ = try Qcow2Reader.convert(try Self.write(image, in: scratch), to: output)
        #expect(try Data(contentsOf: output).subdata(in: (2 << 16)..<(3 << 16)) == bytes)
    }

    @Test func unallocatedClustersBecomeHoles() throws {
        let scratch = try Scratch()
        let size = 64 << 20
        var image = Image(clusterBits: 16, size: size)
        let bytes = Self.pattern(1 << 16, seed: 5)
        image.clusters[0] = .plain(bytes)
        image.clusters[500] = .plain(bytes)
        // Stored and marked as zeros; stored zeros; compressed zeros.
        image.clusters[10] = .zeroFlag(bytes)
        image.clusters[11] = .plain(Data(count: 1 << 16))
        image.clusters[12] = .compressed(try Self.deflated(Data(count: 1 << 16)))
        let output = scratch.root.appendingPathComponent("Disk.img")
        #expect(try Qcow2Reader.convert(try Self.write(image, in: scratch), to: output) == Int64(size))
        var disk = Data(count: size)
        disk.replaceSubrange(0..<(1 << 16), with: bytes)
        disk.replaceSubrange((500 << 16)..<(501 << 16), with: bytes)
        #expect(try Data(contentsOf: output) == disk)
        // Two clusters hold data; the file system rounds each up to its own blocks.
        #expect(DiskUnpackTests.allocated(output) <= 1 << 20)
    }

    @Test func aBackingFileIsRefused() throws {
        try Self.expectRefusal(Image(size: 1 << 20, backingOffset: 200), "it needs a backing file")
    }

    @Test func anEncryptedImageIsRefused() throws {
        try Self.expectRefusal(Image(size: 1 << 20, encryption: 1), "it is encrypted")
        try Self.expectRefusal(Image(size: 1 << 20, encryption: 2), "it is encrypted")
    }

    @Test func anUnknownFeatureBitIsRefused() throws {
        try Self.expectRefusal(Image(size: 1 << 20, features: 1 << 0), "it was not closed properly (it is marked as in use)")
        try Self.expectRefusal(Image(size: 1 << 20, features: 1 << 1), "it is marked as damaged")
        try Self.expectRefusal(Image(size: 1 << 20, features: 1 << 2), "it needs an external data file")
        try Self.expectRefusal(Image(size: 1 << 20, features: 1 << 3), "its compression is not zlib")
        try Self.expectRefusal(Image(size: 1 << 20, compressionType: 1), "its compression is not zlib")
        try Self.expectRefusal(Image(size: 1 << 20, features: 1 << 4), "it has extended cluster tables")
        try Self.expectRefusal(Image(size: 1 << 20, features: 1 << 5), "it needs a feature this agent-vm does not know (feature bits 0x20)")
        try Self.expectRefusal(Image(size: 1 << 20, features: 1 << 63), "it needs a feature this agent-vm does not know (feature bits 0x8000000000000000)")
        // Version 2 has no feature bits: what is in their place is not read as such.
        let scratch = try Scratch()
        let output = scratch.root.appendingPathComponent("Disk.img")
        #expect(try Qcow2Reader.convert(try Self.write(Image(version: 2, size: 1 << 20), in: scratch), to: output) == 1 << 20)
    }

    @Test func otherVersionsAndClusterSizesAreRefused() throws {
        try Self.expectRefusal(Image(version: 1, size: 1 << 20), "it is qcow2 version 1, and versions 2 and 3 are read")
        try Self.expectRefusal(Image(version: 4, size: 1 << 20), "it is qcow2 version 4, and versions 2 and 3 are read")
        for bits: UInt32 in [0, 8, 22, 63, 64, UInt32.max] {
            var image = Image(size: 1 << 20)
            image.damage = { $0.replaceSubrange(20..<24, with: Image.big(bits)) }
            try Self.expectRefusal(image, "its cluster size is outside 512 bytes to 2 MiB")
        }
    }

    @Test func aHugeDeclaredSizeIsRefused() throws {
        for (size, reason) in [(UInt64(65) << 30, "it declares a disk of 65 GB, and more than 64 GB is not read"),
                               (UInt64.max - 511, "it declares a disk of 17179869183 GB, and more than 64 GB is not read"),
                               (UInt64(0), "it declares no disk"), (UInt64(1000), "it declares no disk")] {
            var image = Image(size: 1 << 20)
            image.damage = { $0.replaceSubrange(24..<32, with: Image.big(size)) }
            try Self.expectRefusal(image, reason)
        }
        // A size within the limit that the first table does not cover.
        var image = Image(size: 1 << 20)
        image.damage = { $0.replaceSubrange(24..<32, with: Image.big(UInt64(8) << 30)) }
        try Self.expectRefusal(image, "its cluster table is too short for its disk")
        // A first table larger than is read.
        image.damage = { $0.replaceSubrange(36..<40, with: Image.big(UInt32.max)) }
        try Self.expectRefusal(image, "its cluster table is larger than 32 MB")
    }

    @Test func anOffsetBeyondTheFileIsRefused() throws {
        // The first table.
        for offset in [UInt64(1) << 40, UInt64.max & ~4095, UInt64(0), UInt64(4096 + 512)] {
            var image = Image(size: 1 << 20)
            image.damage = { $0.replaceSubrange(40..<48, with: Image.big(offset)) }
            try Self.expectRefusal(image, "its cluster table lies beyond the file's end")
        }
        // A second table: beyond the end, and inside the last cluster.
        for offset in [UInt64(1) << 40, UInt64(0x00FF_FFFF_FFFF_F000)] {
            var image = Image(size: 1 << 20)
            image.damage = { $0.replaceSubrange(4096..<4104, with: Image.big(offset)) }
            try Self.expectRefusal(image, "a cluster table lies beyond the file's end")
        }
        var cut = Image(size: 1 << 20)
        cut.damage = { $0 = $0.prefix(3 * 4096 - 8) }
        try Self.expectRefusal(cut, "a cluster table lies beyond the file's end")
        // A plain cluster: beyond the end, cut short, and not at a cluster boundary.
        for offset in [UInt64(1) << 40, UInt64(3 * 4096 + 512)] {
            var image = Image(size: 1 << 20)
            image.clusters[0] = .plain(Self.pattern(4096, seed: 1))
            image.damage = { $0.replaceSubrange(8192..<8200, with: Image.big(offset)) }
            try Self.expectRefusal(image, "a cluster lies beyond the file's end")
        }
        var short = Image(size: 1 << 20)
        short.clusters[0] = .plain(Self.pattern(4096, seed: 1))
        short.damage = { $0 = $0.prefix($0.count - 1) }
        try Self.expectRefusal(short, "a cluster lies beyond the file's end")
        // A compressed cluster that starts beyond the end.
        var packed = Image(size: 1 << 20)
        packed.damage = { $0.replaceSubrange(8192..<8200, with: Image.big((UInt64(1) << 62) | (UInt64(1) << 40))) }
        try Self.expectRefusal(packed, "a cluster lies beyond the file's end")
    }

    @Test func aClusterThatInflatesTooLargeIsRefused() throws {
        let reason = "a compressed cluster does not hold exactly one cluster"
        var large = Image(size: 1 << 20)
        large.clusters[0] = .compressed(try Self.deflated(Data(count: 4097)))
        try Self.expectRefusal(large, reason)
        var huge = Image(size: 1 << 20)
        huge.clusters[0] = .compressed(try Self.deflated(Data(count: 4 << 20)))
        try Self.expectRefusal(huge, reason)
        var small = Image(size: 1 << 20)
        small.clusters[0] = .compressed(try Self.deflated(Data(count: 4095)))
        try Self.expectRefusal(small, reason)
        var noise = Image(size: 1 << 20)
        noise.clusters[0] = .compressed(Data(repeating: 0xFF, count: 700))
        try Self.expectRefusal(noise, reason)
    }

    @Test func aTruncatedHeaderIsRefused() throws {
        let whole = Image(size: 1 << 20).data()
        for count in [4, 50, 71, 72, 103] {
            var image = Image(size: 1 << 20)
            image.damage = { $0 = $0.prefix(count) }
            try Self.expectRefusal(image, "its header is cut short")
        }
        // A header that says it is shorter than a version 3 header is.
        var image = Image(size: 1 << 20)
        image.damage = { $0.replaceSubrange(100..<104, with: Image.big(UInt32(72))) }
        try Self.expectRefusal(image, "its header is cut short")
        #expect(throws: Qcow2Reader.Problem("it is not a qcow2 file")) {
            _ = try Qcow2Reader.header(Array(whole.dropFirst(1).prefix(112)), fileSize: Int64(whole.count))
        }
    }

    @Test func aCancelStopsTheReader() throws {
        let scratch = try Scratch()
        var image = Image(size: 1 << 20)
        image.clusters[0] = .plain(Self.pattern(4096, seed: 1))
        let cancellation = BuildCancellation()
        cancellation.cancel(signal: SIGTERM)
        #expect(throws: AgentVMError.canceled(signal: SIGTERM)) {
            _ = try Qcow2Reader.convert(try Self.write(image, in: scratch), to: scratch.root.appendingPathComponent("Disk.img"), cancellation: cancellation)
        }
    }

    /// Through the unpacker: recognized by its first bytes, limited to the image's disk, and a
    /// failure leaves no disk.
    @Test func theUnpackerReadsQcow2() throws {
        let scratch = try Scratch()
        var image = Image(clusterBits: 16, size: 4 << 20)
        let bytes = Self.pattern(1 << 16, seed: 21)
        image.clusters[7] = .compressed(try Self.deflated(bytes))
        // Named as Ubuntu names its image: the name tells nothing.
        let file = try Self.write(image, in: scratch, name: "cloudimg.img")
        #expect(try DiskUnpack.kind(of: file) == .qcow2)
        let output = scratch.root.appendingPathComponent("Disk.img")
        #expect(try DiskUnpack.unpack(file, member: "", to: output, limit: 8 << 20) == 4 << 20)
        #expect(try Data(contentsOf: output).subdata(in: (7 << 16)..<(8 << 16)) == bytes)

        let second = scratch.root.appendingPathComponent("Second.img")
        #expect(throws: AgentVMError.virtualMachine(operation: "unpack \(file.path)", message: "its disk is larger than the image's (0 GB); give a larger --disk-gb")) {
            _ = try DiskUnpack.unpack(file, member: "", to: second, limit: 2 << 20)
        }
        #expect(!FileSystem.exists(second.path))

        // What the header tells is refused when the file's kind is asked, before any image.
        let backed = try Self.write(Image(size: 1 << 20, backingOffset: 300), in: scratch, name: "backed.qcow2")
        #expect(throws: AgentVMError.virtualMachine(operation: "read \(backed.path)", message: "backed.qcow2 is not a disk image agent-vm can read: it needs a backing file")) {
            _ = try DiskUnpack.kind(of: backed)
        }
        // What only the reading tells fails the unpacking, and removes what was written.
        var broken = Image(size: 1 << 20)
        broken.clusters[0] = .plain(Self.pattern(4096, seed: 2))
        broken.clusters[1] = .compressed(Data(repeating: 0xFF, count: 100))
        let bad = try Self.write(broken, in: scratch, name: "broken.img")
        #expect(throws: AgentVMError.virtualMachine(operation: "unpack \(bad.path)", message: "broken.img is not a disk image agent-vm can read: a compressed cluster does not hold exactly one cluster")) {
            _ = try DiskUnpack.unpack(bad, member: "", to: second, limit: 8 << 20)
        }
        #expect(!FileSystem.exists(second.path))
    }

    /// A real image, when one is named: $AGENT_VM_TEST_QCOW2 is the file, and
    /// $AGENT_VM_TEST_QCOW2_SHA256 the SHA-256 of the raw disk another converter made of it.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENT_VM_TEST_QCOW2"] != nil))
    func aRealImageConvertsToTheSameDisk() async throws {
        let environment = ProcessInfo.processInfo.environment
        let source = URL(fileURLWithPath: environment["AGENT_VM_TEST_QCOW2"] ?? "")
        let scratch = try Scratch()
        let output = scratch.root.appendingPathComponent("Disk.img")
        let clock = ContinuousClock()
        let began = clock.now
        let size = try Qcow2Reader.convert(source, to: output)
        print("qcow2: \(size >> 20) MB disk in \(clock.now - began), \(DiskUnpackTests.allocated(output) >> 20) MB on disk")
        let digest = try await LinuxBaseCache.digests(of: output).sha256
        print("qcow2: SHA-256 \(digest)")
        if let expected = environment["AGENT_VM_TEST_QCOW2_SHA256"] {
            #expect(digest == expected)
        }
    }
}
