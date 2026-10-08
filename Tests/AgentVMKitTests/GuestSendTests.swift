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
        var caches: URL {
            return scratch.root.appendingPathComponent(guest == .linux ? "home/.cache/agent-vm-receiving" : "home/Library/Caches/agent-vm-receiving")
        }
        /// The guest the send is for. The Linux script names its tools by paths this Mac has
        /// too, and the Mac's tar takes the options the guest's does, so it runs here.
        var guest = GuestKind.macOS

        init(guest: GuestKind = .macOS) throws {
            self.guest = guest
            scratch = try Scratch()
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: scratch.root.appendingPathComponent("home"), withIntermediateDirectories: true)
        }

        func send(_ url: URL, cancelWhen: (@Sendable (GuestSend.Event, GuestSend) -> Bool)? = nil) throws -> String {
            let pair = try GuestPair()
            let sender = GuestSend(source: url, guest: guest)
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

    /// For a Linux box the Mac's tar packs the one item from its parent folder, under a name
    /// that cannot be read as an option or as an archive to include, and leaves out what only
    /// a Mac has.
    @Test func theLinuxArchiveArgumentsNameOneItem() {
        let expected = ["-c", "--no-mac-metadata", "--no-xattrs", "--no-acls", "--no-fflags", "-f", "-", "-C"]
        #expect(GuestSend.archiveArguments("/a/Folder", isDirectory: true, guest: .linux) == expected + ["/a", "./Folder"])
        #expect(GuestSend.archiveArguments("/a/b/file.txt", isDirectory: false, guest: .linux) == expected + ["/a/b", "./file.txt"])
        #expect(GuestSend.archiveArguments("/-rf", isDirectory: false, guest: .linux) == expected + ["/", "./-rf"])
        #expect(GuestSend.archiveArguments("/a/@list", isDirectory: false, guest: .linux) == expected + ["/a", "./@list"])
        // The macOS form is the one it was.
        #expect(GuestSend.archiveArguments("/a/Folder", isDirectory: true, guest: .macOS) == GuestSend.archiveArguments("/a/Folder", isDirectory: true))
        #expect(GuestSend.packer(for: .linux).path == "/usr/bin/tar" && GuestSend.packer(for: .macOS).path == "/usr/bin/ditto")
    }

    /// A Linux daemon sends no notices and a Linux box has no prompt to wait on: the request
    /// does not ask for them, and runs the Linux script. The macOS request is unchanged.
    @Test func theNoticeFeatureIsNotAskedOfALinuxGuest() {
        let url = URL(fileURLWithPath: "/tmp/Setup.pkg")
        let linux = GuestSend(source: url, guest: .linux).request(name: "Setup.pkg")
        #expect(linux.notices == nil)
        #expect(linux.argv == ["/bin/sh", "-c", GuestSend.linuxReceiveScript, "sh", "Setup.pkg", "Setup", ".pkg", GuestSend.completeMark])
        // The words that say the archive is whole fit in what the script reads back, and
        // hold nothing a shell would change.
        #expect(GuestSend.completeMark.utf8.count <= 32 && !GuestSend.completeMark.contains("\n"))
        #expect(GuestSend.linuxReceiveScript.contains(#"mark="$(/bin/cat | /usr/bin/tail -c 32)""#))
        #expect(linux.user == nil)
        let mac = GuestSend(source: url).request(name: "Setup.pkg")
        #expect(mac.notices == true)
        #expect(mac.argv == ["/bin/sh", "-c", GuestSend.receiveScript, "sh", "Setup.pkg", "Setup", ".pkg"])
        // The Linux script: tar as the account, no owner from the archive, a folder under
        // ~/.cache, and nothing a Linux system lacks.
        let script = GuestSend.linuxReceiveScript
        #expect(script.contains(#"/usr/bin/tar -x -f - -C "$staging" --no-same-owner"#))
        #expect(script.contains(#"caches="$HOME/.cache/agent-vm-receiving""#))
        #expect(!script.contains("ditto") && !script.contains("Library"))
        #expect(script.contains("the archive held more than $1"))
    }

    /// The Linux script, run here: a file arrives under a free name, without the extended
    /// attribute it had on the Mac and without a "._" file beside it.
    @Test func theLinuxScriptUnpacksAFileUnderAFreeName() throws {
        let setup = try Setup(guest: .linux)
        try FileManager.default.createDirectory(at: setup.downloads, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: setup.downloads.appendingPathComponent("Read me.txt"))
        let file = setup.source.appendingPathComponent("Read me.txt")
        try Data("hello".utf8).write(to: file)
        #expect(setxattr(file.path, "com.example.test", "yes", 3, 0, 0) == 0)
        #expect(try setup.send(file) == "Read me 2.txt")
        let arrived = setup.downloads.appendingPathComponent("Read me 2.txt")
        #expect(try Data(contentsOf: arrived) == Data("hello".utf8))
        #expect(try Data(contentsOf: setup.downloads.appendingPathComponent("Read me.txt")) == Data("old".utf8))
        var value = [UInt8](repeating: 0, count: 8)
        #expect(getxattr(arrived.path, "com.example.test", &value, value.count, 0, 0) == -1)
        #expect(try setup.downloadsNames() == ["Read me 2.txt", "Read me.txt"])
        #expect(try setup.stagingIsGone())
        // A name spelled the Mac's other way (a letter and its accent as two characters) gets
        // the spelling Linux tools write, in the answer and on disk.
        let composed = "caf\u{E9}.txt"
        let decomposed = setup.source.appendingPathComponent("cafe\u{301}.txt")
        try Data("x".utf8).write(to: decomposed)
        let answered = try setup.send(decomposed)
        #expect(Array(answered.unicodeScalars) == Array(composed.unicodeScalars))
        #expect(try setup.downloadsNames().contains { Array($0.unicodeScalars) == Array(composed.unicodeScalars) })
        #expect(Array(GuestSend.guestName("cafe\u{301}", guest: .linux).unicodeScalars) == Array("caf\u{E9}".unicodeScalars))
        #expect(Array(GuestSend.guestName("cafe\u{301}", guest: .macOS).unicodeScalars) == Array("cafe\u{301}".unicodeScalars))
        // Names a shell or tar could misread arrive as they are.
        for name in ["-rf", "@list", "a $(x) 'b'.txt", "za\u{17C}\u{F3}\u{142}\u{107}.txt"] {
            let odd = setup.source.appendingPathComponent(name)
            try Data(name.utf8).write(to: odd)
            #expect(try setup.send(odd) == name, "\(name)")
            #expect(try Data(contentsOf: setup.downloads.appendingPathComponent(name)) == Data(name.utf8), "\(name)")
        }
    }

    /// A name with a line end is refused on the Mac, for both guests, before anything is sent:
    /// the box's answer is a name on a line, and such an item would arrive and be called lost.
    @Test func aNameWithALineEndIsRefusedBeforeItIsSent() throws {
        for guest in [GuestKind.macOS, .linux] {
            let setup = try Setup(guest: guest)
            let file = setup.source.appendingPathComponent("two\nlines.txt")
            try Data("x".utf8).write(to: file)
            #expect(throws: GuestSend.Failure(message: "cannot send two?lines.txt: its name has a line end or another control character; rename it first")) {
                _ = try setup.send(file)
            }
            #expect(!FileManager.default.fileExists(atPath: setup.downloads.path))
        }
    }

    /// A folder arrives whole: its tree, an executable file still executable, a link still a
    /// link, and no "._" file anywhere in it.
    @Test func theLinuxScriptUnpacksAFolder() throws {
        let setup = try Setup(guest: .linux)
        let folder = setup.source.appendingPathComponent("project v1.2")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("bin/empty"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: folder.appendingPathComponent("bin/tool"))
        #expect(chmod(folder.appendingPathComponent("bin/tool").path, 0o755) == 0)
        #expect(setxattr(folder.appendingPathComponent("bin/tool").path, "com.apple.quarantine", "0081;0;x;", 9, 0, 0) == 0)
        try Data("notes".utf8).write(to: folder.appendingPathComponent(".hidden"))
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("link").path, withDestinationPath: "bin/tool")
        #expect(try setup.send(folder) == "project v1.2")
        let arrived = setup.downloads.appendingPathComponent("project v1.2")
        #expect(FileManager.default.isExecutableFile(atPath: arrived.appendingPathComponent("bin/tool").path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: arrived.appendingPathComponent("link").path) == "bin/tool")
        #expect(try Data(contentsOf: arrived.appendingPathComponent(".hidden")) == Data("notes".utf8))
        var isFolder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: arrived.appendingPathComponent("bin/empty").path, isDirectory: &isFolder) && isFolder.boolValue)
        let names = try FileManager.default.subpathsOfDirectory(atPath: arrived.path).sorted()
        #expect(names == [".hidden", "bin", "bin/empty", "bin/tool", "link"])
        // A second one gets the next name; ".2" is no extension.
        #expect(try setup.send(folder) == "project v1.2 2")
        #expect(try setup.stagingIsGone())
    }

    /// A send to a Linux box that is stopped while the guest unpacks leaves nothing in
    /// Downloads and no staging folder.
    @Test func aSendCutShortLeavesNothingInDownloads() throws {
        let setup = try Setup(guest: .linux)
        try FileManager.default.createDirectory(at: setup.downloads, withIntermediateDirectories: true)
        // Real bytes, 1 GB of them: tar packs a file with holes as its few data blocks, and the
        // send would be over before it could be stopped.
        let file = setup.source.appendingPathComponent("big.img")
        #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        let block = Data(repeating: 0x5A, count: 16 << 20)
        for _ in 0..<64 {
            try handle.write(contentsOf: block)
        }
        try handle.close()
        let caches = setup.caches.path
        #expect(throws: GuestSend.Failure(message: "stopped")) {
            // Once the guest's staging folder is there, so the script's own cleanup is what runs.
            _ = try setup.send(file) { event, _ in
                guard case let .progress(sent, _) = event, sent > 0 else {
                    return false
                }
                return !((try? FileManager.default.contentsOfDirectory(atPath: caches)) ?? []).isEmpty
            }
        }
        #expect(try setup.stagingIsGone())
        #expect(try setup.downloadsNames().isEmpty)
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

    /// The same for a Linux box. The Mac's tar stops at the file it cannot read and still ends
    /// the archive well, so the guest's tar unpacks what there is without an error: the script
    /// must not move that into Downloads before the Mac says the archive was whole.
    @Test(arguments: 0..<5) func anUnreadableFileFailsTheSendToALinuxBox(_ attempt: Int) throws {
        let setup = try Setup(guest: .linux)
        // The Mac's tar may fail before the guest makes its folders.
        try FileManager.default.createDirectory(at: setup.downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: setup.caches, withIntermediateDirectories: true)
        let folder = setup.source.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["a.txt", "b.txt", "c.txt", "d.txt"] {
            try Data(name.utf8).write(to: folder.appendingPathComponent(name))
        }
        #expect(chmod(folder.appendingPathComponent("b.txt").path, 0) == 0)
        defer { _ = chmod(folder.appendingPathComponent("b.txt").path, 0o644) }
        do {
            _ = try setup.send(folder)
            Issue.record("the send succeeded")
        } catch let failure as GuestSend.Failure {
            #expect(failure.message.hasPrefix("cannot read Folder on this Mac:"), "\(failure)")
            #expect(failure.message.contains("Permission denied"), "\(failure)")
        }
        // The script has ended either way by the time its folder is gone or was never made.
        Thread.sleep(forTimeInterval: 0.5)
        #expect(try setup.downloadsNames().isEmpty)
        #expect(try setup.stagingIsGone())
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
