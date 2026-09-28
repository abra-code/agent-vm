// Tests/AgentVMKitTests/GuestSendTests.swift
//
// Sending files into the guest's Downloads folder, end to end on this Mac: the real GuestServer
// runs the receiving script as this test's account, with HOME in a scratch folder.

import Darwin
import Foundation
import Testing
@testable import AgentVMKit

@Suite struct GuestSendTests {
    /// A scratch folder with `source/` for what is sent and `home/` for the guest's HOME.
    struct Setup {
        let scratch: Scratch
        var source: URL { scratch.root.appendingPathComponent("source") }
        var downloads: URL { scratch.root.appendingPathComponent("home/Downloads") }
        var caches: URL { scratch.root.appendingPathComponent("home/Library/Caches/agent-vm-receiving") }

        init() throws {
            scratch = try Scratch()
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: scratch.root.appendingPathComponent("home"), withIntermediateDirectories: true)
        }

        func send(_ url: URL, cancelWhen: (@Sendable (GuestSend.Event, GuestSend) -> Bool)? = nil) throws -> String {
            let pair = try GuestPair()
            let sender = GuestSend(source: url)
            sender.environment = ["HOME": scratch.root.appendingPathComponent("home").path]
            return try sender.run(descriptor: pair.client) { event in
                if let cancelWhen, cancelWhen(event, sender) {
                    sender.cancel()
                }
            }
        }

        /// What Downloads holds, hidden entries included.
        func downloadsNames() throws -> [String] {
            return try FileManager.default.contentsOfDirectory(atPath: downloads.path).sorted()
        }

        /// Waits up to 5 seconds for the guest to remove its staging folder.
        func stagingIsGone() throws -> Bool {
            for _ in 0..<50 {
                if try FileManager.default.contentsOfDirectory(atPath: caches.path).isEmpty {
                    return true
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            return false
        }
    }

    @Test func nameParts() {
        #expect(GuestSend.nameParts("Setup.pkg") == ("Setup", ".pkg"))
        #expect(GuestSend.nameParts("Xcode.app") == ("Xcode", ".app"))
        #expect(GuestSend.nameParts("archive.tar.gz") == ("archive.tar", ".gz"))
        #expect(GuestSend.nameParts("v1.2") == ("v1.2", ""))
        #expect(GuestSend.nameParts(".profile") == (".profile", ""))
        #expect(GuestSend.nameParts("Folder") == ("Folder", ""))
        #expect(GuestSend.nameParts("notes.a b") == ("notes.a b", ""))
    }

    @Test func archiveArguments() {
        #expect(GuestSend.archiveArguments("/a/Folder", isDirectory: true) == ["-c", "--keepParent", "/a/Folder", "-"])
        #expect(GuestSend.archiveArguments("/a/file.txt", isDirectory: false) == ["-c", "/a/file.txt", "-"])
    }

    /// A file arrives with its content and extended attributes; a folder with its tree and links.
    @Test func filesAndFoldersArrive() throws {
        let setup = try Setup()
        let file = setup.source.appendingPathComponent("Read me.txt")
        try Data("hello".utf8).write(to: file)
        #expect(setxattr(file.path, "com.example.test", "yes", 3, 0, 0) == 0)
        #expect(try setup.send(file) == "Read me.txt")
        let arrived = setup.downloads.appendingPathComponent("Read me.txt")
        #expect(try Data(contentsOf: arrived) == Data("hello".utf8))
        var value = [UInt8](repeating: 0, count: 8)
        #expect(getxattr(arrived.path, "com.example.test", &value, value.count, 0, 0) == 3)

        let folder = setup.source.appendingPathComponent("Tool.app")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: folder.appendingPathComponent("Contents/MacOS/tool"))
        #expect(chmod(folder.appendingPathComponent("Contents/MacOS/tool").path, 0o755) == 0)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("Contents/link").path, withDestinationPath: "MacOS/tool")
        #expect(try setup.send(folder) == "Tool.app")
        let tool = setup.downloads.appendingPathComponent("Tool.app/Contents/MacOS/tool")
        #expect(FileManager.default.isExecutableFile(atPath: tool.path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: setup.downloads.appendingPathComponent("Tool.app/Contents/link").path) == "MacOS/tool")
        #expect(try setup.downloadsNames() == ["Read me.txt", "Tool.app"])
    }

    /// What Downloads holds already stays; the new item gets the next free name.
    @Test func nothingIsOverwritten() throws {
        let setup = try Setup()
        try FileManager.default.createDirectory(at: setup.downloads, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: setup.downloads.appendingPathComponent("Setup.pkg"))
        try Data("old 2".utf8).write(to: setup.downloads.appendingPathComponent("Setup 2.pkg"))
        let file = setup.source.appendingPathComponent("Setup.pkg")
        try Data("new".utf8).write(to: file)
        #expect(try setup.send(file) == "Setup 3.pkg")
        #expect(try Data(contentsOf: setup.downloads.appendingPathComponent("Setup.pkg")) == Data("old".utf8))
        #expect(try Data(contentsOf: setup.downloads.appendingPathComponent("Setup 3.pkg")) == Data("new".utf8))
        #expect(try setup.downloadsNames() == ["Setup 2.pkg", "Setup 3.pkg", "Setup.pkg"])
    }

    /// A send stopped while the guest unpacks leaves nothing behind.
    @Test func aStoppedSendLeavesNothing() throws {
        let setup = try Setup()
        try FileManager.default.createDirectory(at: setup.downloads, withIntermediateDirectories: true)
        let file = setup.source.appendingPathComponent("big.dmg")
        #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        #expect(truncate(file.path, 4 << 30) == 0)
        let caches = setup.caches.path
        #expect(throws: GuestSend.Failure(message: "stopped")) {
            try setup.send(file) { event, _ in
                guard case let .progress(sent, _) = event, sent > 0 else {
                    return false
                }
                return !((try? FileManager.default.contentsOfDirectory(atPath: caches)) ?? []).isEmpty
            }
        }
        #expect(try setup.stagingIsGone())
        #expect(try setup.downloadsNames().isEmpty)
    }

    /// A file ditto cannot read on the Mac fails the send, and the guest discards the rest.
    @Test func anUnreadableFileFailsTheSend() throws {
        let setup = try Setup()
        // The Mac's ditto may fail before the guest makes its folders.
        try FileManager.default.createDirectory(at: setup.downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: setup.caches, withIntermediateDirectories: true)
        let folder = setup.source.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: folder.appendingPathComponent("a.txt"))
        try Data("b".utf8).write(to: folder.appendingPathComponent("b.txt"))
        #expect(chmod(folder.appendingPathComponent("b.txt").path, 0) == 0)
        defer { _ = chmod(folder.appendingPathComponent("b.txt").path, 0o644) }
        do {
            _ = try setup.send(folder)
            Issue.record("the send succeeded")
        } catch let failure as GuestSend.Failure {
            #expect(failure.message.hasPrefix("cannot read Folder on this Mac:"), "\(failure)")
            #expect(failure.message.contains("Permission denied"), "\(failure)")
        }
        #expect(try setup.stagingIsGone())
        #expect(try setup.downloadsNames().isEmpty)
    }

    /// What a stopped send left is removed once an hour old; a newer folder (another send
    /// under way) stays.
    @Test func oldLeftoversAreRemoved() throws {
        let setup = try Setup()
        let old = setup.caches.appendingPathComponent("OLD123")
        let recent = setup.caches.appendingPathComponent("NEW123")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recent, withIntermediateDirectories: true)
        let twoHoursAgo = Date().addingTimeInterval(-7200)
        try FileManager.default.setAttributes([.modificationDate: twoHoursAgo], ofItemAtPath: old.path)
        let file = setup.source.appendingPathComponent("x.txt")
        try Data("x".utf8).write(to: file)
        #expect(try setup.send(file) == "x.txt")
        #expect(try FileManager.default.contentsOfDirectory(atPath: setup.caches.path) == ["NEW123"])
    }

    /// The guest's own failure is reported with what it said.
    @Test func aGuestFailureIsReported() throws {
        let setup = try Setup()
        // Downloads is a file: the guest cannot make its folder there.
        try Data().write(to: setup.downloads)
        let file = setup.source.appendingPathComponent("x.txt")
        try Data("x".utf8).write(to: file)
        do {
            _ = try setup.send(file)
            Issue.record("the send succeeded")
        } catch let failure as GuestSend.Failure {
            #expect(failure.message.hasPrefix("the box could not unpack x.txt:"), "\(failure)")
        }
    }

    /// A link is sent as what it points to, under that item's name (ditto names the archive's
    /// top item after the link's target).
    @Test func aLinkIsSentAsItsTarget() throws {
        let setup = try Setup()
        let folder = setup.source.appendingPathComponent("Real Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("in".utf8).write(to: folder.appendingPathComponent("inside.txt"))
        let file = setup.source.appendingPathComponent("real.txt")
        try Data("real".utf8).write(to: file)
        let folderLink = setup.source.appendingPathComponent("folder link")
        let fileLink = setup.source.appendingPathComponent("file link")
        try FileManager.default.createSymbolicLink(atPath: folderLink.path, withDestinationPath: "Real Folder")
        try FileManager.default.createSymbolicLink(atPath: fileLink.path, withDestinationPath: "real.txt")
        #expect(try setup.send(folderLink) == "Real Folder")
        #expect(try setup.send(fileLink) == "real.txt")
        #expect(try Data(contentsOf: setup.downloads.appendingPathComponent("Real Folder/inside.txt")) == Data("in".utf8))
        #expect(try Data(contentsOf: setup.downloads.appendingPathComponent("real.txt")) == Data("real".utf8))
    }

    /// A guest that fails while the Mac still sends is reported as the guest's failure, not as
    /// the Mac's ditto (which the send ends then).
    @Test(arguments: 0..<5) func aGuestFailureWhileSendingIsReported(_ attempt: Int) throws {
        let setup = try Setup()
        try Data().write(to: setup.downloads)
        let file = setup.source.appendingPathComponent("big.dmg")
        #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        #expect(truncate(file.path, 4 << 30) == 0)
        do {
            _ = try setup.send(file)
            Issue.record("the send succeeded")
        } catch let failure as GuestSend.Failure {
            #expect(failure.message.hasPrefix("the box could not unpack big.dmg:"), "\(failure)")
        }
    }

    @Test func theStartupDiskIsRefusedBeforeConnecting() throws {
        let sender = GuestSend(source: URL(fileURLWithPath: "/"))
        #expect(throws: GuestSend.Failure(message: "the startup disk cannot be sent; choose the files or folders on it")) {
            _ = try sender.run(descriptor: -1) { _ in }
        }
    }

    @Test func aMissingSourceIsRefusedBeforeConnecting() throws {
        let setup = try Setup()
        let sender = GuestSend(source: setup.source.appendingPathComponent("gone"))
        #expect(throws: GuestSend.Failure.self) {
            _ = try sender.run(descriptor: -1) { _ in }
        }
    }
}
