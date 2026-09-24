// Tests/AgentVMKitTests/DiskUsageTests.swift
//
// The space `image list` and `box list` report: everything allocated, and the part no APFS
// clone shares. The scratch folder is on the temporary folder's volume, APFS on macOS 27.

import Darwin
import Foundation
import Testing
@testable import AgentVMKit

@Suite struct DiskUsageTests {
    private static let megabyte = 1 << 20

    /// Writes `count` random bytes at `offset` and flushes them, so the blocks are allocated
    /// (APFS allocates written data lazily) and cannot be shared by chance.
    private func write(_ path: String, count: Int, at offset: UInt64 = 0) throws {
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: Data((0..<count).map { _ in UInt8.random(in: 0...255) }))
        try handle.synchronize()
    }

    @Test func aFileOfItsOwnIsUnshared() throws {
        let scratch = try Scratch()
        try write(scratch.path("disk"), count: Self.megabyte)
        let usage = DiskUsage.of(scratch.project)
        #expect(usage.bytes >= Int64(Self.megabyte))
        #expect(usage.unsharedBytes == usage.bytes)
    }

    @Test func aCloneSharesUntilItIsWritten() throws {
        let scratch = try Scratch()
        let image = scratch.project.appendingPathComponent("image")
        let box = scratch.project.appendingPathComponent("box")
        try FileManager.default.createDirectory(at: image, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        try write(image.appendingPathComponent("Disk.img").path, count: Self.megabyte)
        try BoxStore.cloneFile(image.appendingPathComponent("Disk.img"), to: box.appendingPathComponent("Disk.img"))

        let cloned = DiskUsage.of(box)
        #expect(cloned.bytes >= Int64(Self.megabyte))
        #expect(cloned.unsharedBytes == 0)
        #expect(DiskUsage.of(image).unsharedBytes == 0)

        try write(box.appendingPathComponent("Disk.img").path, count: Self.megabyte / 4)
        let written = try #require(DiskUsage.of(box).unsharedBytes)
        #expect(written >= Int64(Self.megabyte / 4))
        #expect(written < Int64(Self.megabyte))
        // The blocks the box replaced are now the image's alone.
        #expect(try #require(DiskUsage.of(image).unsharedBytes) >= Int64(Self.megabyte / 4))
    }

    @Test func subfoldersCountAndLinksDoNot() throws {
        let scratch = try Scratch()
        try FileManager.default.createDirectory(atPath: scratch.path("nested"), withIntermediateDirectories: true)
        try write(scratch.path("nested/log"), count: Self.megabyte)
        try write(scratch.root.appendingPathComponent("outside").path, count: 4 * Self.megabyte)
        try FileManager.default.createSymbolicLink(atPath: scratch.path("link"), withDestinationPath: scratch.root.appendingPathComponent("outside").path)
        let usage = DiskUsage.of(scratch.project)
        #expect(usage.bytes >= Int64(Self.megabyte))
        #expect(usage.bytes < Int64(2 * Self.megabyte))
    }
}
