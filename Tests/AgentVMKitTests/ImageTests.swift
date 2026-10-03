// Tests/AgentVMKitTests/ImageTests.swift
//
// Image store, DHCP lease lookup, SSH invocation and the image builder's file helpers. The
// virtual machine steps themselves need the signed binary and a restore image; they are
// exercised by `agent-vm image create` (see the commit note's Verification section).

import Darwin
import Foundation
import Testing
@testable import AgentVMKit

@Suite struct ImageStoreTests {
    static func record(_ name: String, state: ImageRecord.State = .installing) -> ImageRecord {
        return ImageRecord(formatVersion: ImageRecord.currentFormatVersion, name: name, state: state, failure: nil,
                           createdAt: Date(timeIntervalSince1970: 1_800_000_000), createdBy: AgentVM.version,
                           macOSVersion: "27.0", macOSBuild: "26A428", cpuCount: 4, memoryBytes: 8 << 30,
                           diskBytes: 64 << 30, macAddress: "da:51:72:d4:e5:72", userName: "agent",
                           installSeconds: nil, provisionSeconds: nil)
    }

    func makeStore(_ scratch: Scratch) -> ImageStore {
        return ImageStore(root: scratch.root.appendingPathComponent("store", isDirectory: true))
    }

    @Test func namesAreRestricted() {
        for good in ["macos-dev", "a", "dev.27", "x_1"] {
            #expect(ImageStore.isValidName(good), "\(good)")
        }
        for bad in ["", ".", "..", ".hidden", "-x", "Upper", "a/b", "a b", String(repeating: "a", count: 64)] {
            #expect(!ImageStore.isValidName(bad), "\(bad)")
        }
    }

    @Test func createClaimsTheNameAndRecordsIt() throws {
        let scratch = try Scratch()
        let store = makeStore(scratch)
        let (image, lock) = try store.create(Self.record("dev"))
        defer { lock.release() }
        #expect(image.directory.lastPathComponent == "dev")
        #expect(try store.image(named: "dev").record == Self.record("dev"))

        #expect(throws: AgentVMError.imageExists(name: "dev", state: "installing")) {
            _ = try store.create(Self.record("dev"))
        }
        #expect(throws: AgentVMError.invalidImageName("../x")) {
            _ = try store.create(Self.record("../x"))
        }
    }

    @Test func updateRewritesTheRecord() throws {
        let scratch = try Scratch()
        let store = makeStore(scratch)
        let (image, lock) = try store.create(Self.record("dev"))
        defer { lock.release() }
        let updated = try store.update(image) { record in
            record.state = .ready
            record.installSeconds = 200
        }
        #expect(updated.record.state == .ready)
        #expect(try store.image(named: "dev").record.installSeconds == 200)
    }

    @Test func deleteIsRefusedWhileLockedAndWorksAfter() throws {
        let scratch = try Scratch()
        let store = makeStore(scratch)
        let (image, lock) = try store.create(Self.record("dev"))
        FileManager.default.createFile(atPath: image.diskURL.path, contents: Data(count: 16))
        // flock locks belong to the open file, so a second open in this process conflicts too.
        #expect(try store.tryLock(image) == nil)
        #expect(throws: AgentVMError.imageBusy("dev")) {
            try store.delete(named: "dev")
        }
        lock.release()
        try store.delete(named: "dev")
        #expect(!FileManager.default.fileExists(atPath: image.directory.path))
        #expect(throws: AgentVMError.imageNotFound("dev")) {
            try store.delete(named: "dev")
        }
    }

    @Test func aFolderWithoutARecordCanStillBeDeleted() throws {
        let scratch = try Scratch()
        let store = makeStore(scratch)
        let directory = store.imagesDirectory.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            _ = try store.image(named: "broken")
        }
        try store.delete(named: "broken")
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func listSortsAndReportsDamagedRecords() throws {
        let scratch = try Scratch()
        let store = makeStore(scratch)
        #expect(try store.list().images.isEmpty)
        for name in ["zeta", "alpha"] {
            let (_, lock) = try store.create(Self.record(name, state: .ready))
            lock.release()
        }
        let damaged = store.imagesDirectory.appendingPathComponent("damaged")
        try FileManager.default.createDirectory(at: damaged, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: damaged.appendingPathComponent("image.json"))
        // A record naming another image is damaged too (a copied folder).
        let copied = store.imagesDirectory.appendingPathComponent("copied")
        try FileManager.default.createDirectory(at: copied, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: store.imagesDirectory.appendingPathComponent("alpha/image.json"),
                                         to: copied.appendingPathComponent("image.json"))

        let (images, problems) = try store.list()
        #expect(images.map(\.name) == ["alpha", "zeta"])
        #expect(problems.count == 2)
    }
}

@Suite struct GuestNetworkTests {
    static let leases = """
        {
        \tname=old
        \tip_address=192.168.64.5
        \thw_address=1,da:51:72:d4:e5:72
        \tidentifier=1,da:51:72:d4:e5:72
        \tlease=0x6ab40000
        }
        {
        \tname=agent
        \tip_address=192.168.64.9
        \thw_address=1,da:51:72:d4:e5:72
        \tidentifier=1,da:51:72:d4:e5:72
        \tlease=0x6ab4112a
        }
        {
        \tname=other
        \tip_address=192.168.64.3
        \thw_address=1,2:a:b:c:d:e
        \tidentifier=1,2:a:b:c:d:e
        \tlease=0x6ab41200
        }
        """

    @Test func macAddressesAreComparedInBootpdForm() {
        #expect(GuestNetwork.normalizedMAC("02:0A:0B:0C:0D:0E") == "2:a:b:c:d:e")
        #expect(GuestNetwork.normalizedMAC("00:00:5e:00:53:01") == "0:0:5e:0:53:1")
    }

    @Test func theNewestLeaseForTheMACWins() {
        #expect(GuestNetwork.parseLeases(Self.leases).count == 3)
        #expect(GuestNetwork.address(forMAC: "da:51:72:d4:e5:72", leases: Self.leases) == "192.168.64.9")
        #expect(GuestNetwork.address(forMAC: "02:0a:0b:0c:0d:0e", leases: Self.leases) == "192.168.64.3")
        #expect(GuestNetwork.address(forMAC: "02:0a:0b:0c:0d:0f", leases: Self.leases) == nil)
        #expect(GuestNetwork.address(forMAC: "da:51:72:d4:e5:72", leases: "") == nil)
    }

    @Test func anIncompleteEntryIsIgnored() {
        let text = "{\n\tip_address=192.168.64.4\n\tlease=0x1\n}\n{\n\tip_address=192.168.64.7\n\thw_address=1,2:a:b:c:d:e\n"
        #expect(GuestNetwork.parseLeases(text).isEmpty)
    }

    /// The `name=` value is the host name a guest sent. Field text inside it, on its line or
    /// after anything but a line feed, is part of the name and names no lease.
    @Test func aHostNameCannotForgeALease() {
        let mac = "da:51:72:d4:e5:72"
        func leases(name: String) -> String {
            return "{\n\tname=\(name)\n\tip_address=192.168.64.9\n\thw_address=1,\(mac)\n\tlease=0x10\n}\n"
        }
        let forged = "ip_address=192.168.64.66 hw_address=1,\(mac) lease=0xffffffff"
        #expect(GuestNetwork.address(forMAC: mac, leases: leases(name: "x \(forged)")) == "192.168.64.9")
        #expect(GuestNetwork.address(forMAC: mac, leases: leases(name: "x } { \(forged) }")) == "192.168.64.9")
        // Line ends other than the line feed the file is written with.
        for end in ["\r", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"] {
            // A whole lease of its own, closed before the real fields follow: read as lines, it would
            // be the newer lease for this address.
            let block = ["x", "ip_address=192.168.64.66", "hw_address=1,\(mac)", "lease=0xffffffff", "}", "{"].joined(separator: end)
            let text = leases(name: block)
            #expect(GuestNetwork.parseLeases(text).count == 1, "\(end.unicodeScalars.map(\.value))")
            #expect(GuestNetwork.address(forMAC: mac, leases: text) == "192.168.64.9")
        }
    }

    @Test func portProbe() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        #expect(listener >= 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Bool in
                bind(listener, pointer, length) == 0 && listen(listener, 1) == 0 && getsockname(listener, pointer, &length) == 0
            }
        }
        #expect(bound)
        let port = UInt16(bigEndian: address.sin_port)
        #expect(GuestNetwork.isPortOpen("127.0.0.1", port: port))
        close(listener)
        // Closed: a port held bound but not listening. A port just closed is free, and another
        // test's server was given it once before the check below ran.
        let held = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(held) }
        var closed = sockaddr_in()
        closed.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        closed.sin_family = sa_family_t(AF_INET)
        closed.sin_addr.s_addr = inet_addr("127.0.0.1")
        var closedLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let reserved = withUnsafeMutablePointer(to: &closed) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Bool in
                bind(held, pointer, closedLength) == 0 && getsockname(held, pointer, &closedLength) == 0
            }
        }
        #expect(reserved)
        #expect(!GuestNetwork.isPortOpen("127.0.0.1", port: UInt16(bigEndian: closed.sin_port)))
        #expect(!GuestNetwork.isPortOpen("not an address", port: 22))
    }
}

@Suite struct GuestSSHTests {
    let ssh = GuestSSH(host: "192.168.64.9", user: "agent",
                       password: .file(URL(fileURLWithPath: "/store/Images/dev/Password")),
                       knownHostsFile: URL(fileURLWithPath: "/store/Images/dev/known_hosts"),
                       askpassProgram: "/usr/local/bin/agent-vm")

    @Test func theUsersSSHSetupIsNeverUsed() throws {
        let arguments = try ssh.arguments("id -un")
        #expect(Array(arguments.prefix(2)) == ["-F", "/dev/null"])
        for option in ["PubkeyAuthentication=no", "IdentityAgent=none", "ForwardAgent=no", "ClearAllForwardings=yes",
                       "UserKnownHostsFile=\"/store/Images/dev/known_hosts\"", "GlobalKnownHostsFile=/dev/null",
                       "StrictHostKeyChecking=accept-new"] {
            #expect(arguments.contains(option), "\(option)")
        }
        #expect(Array(arguments.suffix(3)) == ["192.168.64.9", "--", "id -un"])

        let environment = ssh.environment(base: ["PATH": "/usr/bin", "SSH_AUTH_SOCK": "/tmp/agent", "DISPLAY": ":0", "HOME": "/Users/x"])
        #expect(environment["SSH_AUTH_SOCK"] == nil)
        #expect(environment["DISPLAY"] == nil)
        #expect(environment["PATH"] == "/usr/bin")
        #expect(environment["SSH_ASKPASS"] == "/usr/local/bin/agent-vm")
        #expect(environment["SSH_ASKPASS_REQUIRE"] == "force")
        #expect(environment[GuestSSH.askpassFileVariable] == "/store/Images/dev/Password")
        #expect(environment[GuestSSH.askpassItemVariable] == nil)

        // A password in the Keychain: ssh's environment names the item, never a file, whatever
        // the caller's environment held.
        var keyed = ssh
        keyed.password = .item("0b1c2d3e-0000-4000-8000-000000000001")
        let named = keyed.environment(base: [GuestSSH.askpassFileVariable: "/tmp/planted", "PATH": "/usr/bin"])
        #expect(named[GuestSSH.askpassItemVariable] == "0b1c2d3e-0000-4000-8000-000000000001")
        #expect(named[GuestSSH.askpassFileVariable] == nil)
    }

    @Test func knownHostsPathIsNotExpandedBySSH() throws {
        func sshWith(_ path: String) -> GuestSSH {
            return GuestSSH(host: "192.168.64.9", user: "agent", password: .file(URL(fileURLWithPath: "/store/Password")),
                            knownHostsFile: URL(fileURLWithPath: path), askpassProgram: "/usr/local/bin/agent-vm")
        }
        #expect(try sshWith("/a b/100%d/known_hosts").arguments("true").contains("UserKnownHostsFile=\"/a b/100%%d/known_hosts\""))
        #expect(throws: (any Error).self) { _ = try sshWith("/a/${HOME}/known_hosts").arguments("true") }
        #expect(throws: (any Error).self) { _ = try sshWith("/a/\"q/known_hosts").arguments("true") }
    }

    @Test func askpassAnswersOnlyPasswordPrompts() throws {
        let scratch = try Scratch()
        let file = scratch.root.appendingPathComponent("Password")
        try Data("s3cret".utf8).write(to: file)
        let environment = [GuestSSH.askpassFileVariable: file.path]

        #expect(GuestSSH.askpassAnswer(arguments: ["agent-vm", "image", "list"], environment: [:]) == .notAskpass)
        #expect(GuestSSH.askpassAnswer(arguments: ["agent-vm", "(agent@192.168.64.9) Password:"], environment: environment) == .password("s3cret"))
        #expect(GuestSSH.askpassAnswer(arguments: ["agent-vm", "Are you sure you want to continue connecting (yes/no)?"], environment: environment) == .refuse)
        #expect(GuestSSH.askpassAnswer(arguments: ["agent-vm", "Password:"], environment: [GuestSSH.askpassFileVariable: "/nonexistent"]) == .refuse)
    }
}

@Suite struct ImageBuilderFileTests {
    @Test func passwordsAreLongRandomAndPlain() throws {
        let first = try ImageBuilder.newPassword()
        let second = try ImageBuilder.newPassword()
        #expect(first.count == 24)
        #expect(first != second)
        #expect(first.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }

    @Test func passwordFileIsPrivateAndNeverOverwritten() throws {
        let scratch = try Scratch()
        let file = scratch.root.appendingPathComponent("Password")
        try ImageBuilder.writePassword("abc", to: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "abc")
        #expect(try FileSystem.status(file.path).st_mode & 0o777 == 0o600)
        #expect(throws: AgentVMError.system(operation: "create \(file.path)", code: EEXIST)) {
            try ImageBuilder.writePassword("xyz", to: file)
        }
    }

    @Test func diskIsSparse() throws {
        let scratch = try Scratch()
        let disk = scratch.root.appendingPathComponent("Disk.img")
        try ImageBuilder.createSparseDisk(at: disk, bytes: 64 << 30)
        let info = try FileSystem.status(disk.path)
        #expect(info.st_size == 64 << 30)
        #expect(Int64(info.st_blocks) * 512 < 1 << 20)
    }

    @MainActor
    @Test func hostIsCheckedBeforeAnythingIsWritten() throws {
        try ImageBuilder.checkHost(HostCheckTests.goodFacts())

        var facts = HostCheckTests.goodFacts()
        facts.hasVirtualizationEntitlement = false
        #expect(throws: (any Error).self) { try ImageBuilder.checkHost(facts) }

        facts = HostCheckTests.goodFacts()
        facts.storeFreeBytes = ImageBuilder.minimumFreeBytes - 1
        #expect(throws: (any Error).self) { try ImageBuilder.checkHost(facts) }

        // Unknown facts do not block a build.
        facts = HostCheckTests.goodFacts()
        facts.hasVirtualizationEntitlement = nil
        facts.storeFreeBytes = nil
        try ImageBuilder.checkHost(facts)
    }

    @Test func accountNames() {
        #expect(ImageBuildOptions.isValidUserName("agent"))
        #expect(ImageBuildOptions.isValidUserName("dev_2"))
        for bad in ["", "root", "Agent", "2x", "a-b", "a b"] {
            #expect(!ImageBuildOptions.isValidUserName(bad), "\(bad)")
        }
    }
}

@Suite struct CommandLineToolsTests {
    @Test func theNewestToolsLabelIsChosen() {
        let output = """
            Software Update Tool

            Finding available software
            Software Update found the following new or updated software:
            * Label: Command Line Tools for Xcode 26.4-26.4
            \tTitle: Command Line Tools for Xcode 26.4, Version: 26.4, Size: 512000KiB, Recommended: YES,
            * Label: macOS Tahoe 27.0.1-26A500
            \tTitle: macOS 27.0.1, Version: 27.0.1, Size: 3000000KiB, Recommended: YES, Action: restart,
            * Label: Command Line Tools for Xcode 27.0-27.0
            \tTitle: Command Line Tools for Xcode 27.0, Version: 27.0, Size: 519460KiB, Recommended: YES,
            """
        #expect(CommandLineTools.label(fromListOutput: output) == "Command Line Tools for Xcode 27.0-27.0")
        #expect(CommandLineTools.label(fromListOutput: "Software Update Tool\n\nFinding available software\nNo new software available.\n") == nil)
        #expect(CommandLineTools.version(of: "Command Line Tools for Xcode 27.0-27.0") == [27, 0, 27, 0])
        let withBeta = output + "\n* Label: Command Line Tools beta 3 for Xcode 27.1-27.1\n"
        #expect(CommandLineTools.label(fromListOutput: withBeta) == "Command Line Tools for Xcode 27.0-27.0")
        #expect(CommandLineTools.label(fromListOutput: "* Label: Command Line Tools beta 3 for Xcode 27.1-27.1\n") == "Command Line Tools beta 3 for Xcode 27.1-27.1")
    }

    @Test func requestsRunWhereTheyMust() {
        #expect(CommandLineTools.listRequest.user == "root")
        #expect(CommandLineTools.installRequest(label: "Command Line Tools for Xcode 27.0-27.0").argv
                == ["/usr/sbin/softwareupdate", "--install", "Command Line Tools for Xcode 27.0-27.0", "--agree-to-license"])
        #expect(CommandLineTools.cleanupRequest.argv == ["/bin/rm", "-f", CommandLineTools.onDemandFlag])
        // Checked as the box user: that is who will use the tools.
        #expect(CommandLineTools.verifyRequest.user == nil)
    }
}

@Suite struct DerivedImageTests {
    @MainActor
    @Test func onlyReadyBasesWithTheCurrentDaemonAreUsed() async throws {
        let scratch = try Scratch()
        let store = ImageStore(root: scratch.root.appendingPathComponent("store", isDirectory: true))
        var ready = ImageStoreTests.record("base", state: .ready)
        ready.guestProtocol = AgentVM.guestProtocolVersion
        _ = try store.create(ready).1.release()
        var old = ImageStoreTests.record("old", state: .ready)
        old.guestProtocol = nil
        _ = try store.create(old).1.release()
        _ = try store.create(ImageStoreTests.record("half", state: .provisioning)).1.release()

        let builder = ImageBuilder(store: store) { (_: ProgressEvent) in }
        func refusal(_ base: String, name: String = "new") async -> AgentVMError? {
            do {
                _ = try await builder.derive(ImageDeriveOptions(name: name, base: base, commandLineTools: false))
                return nil
            } catch {
                return error as? AgentVMError
            }
        }
        #expect(await refusal("half") == .wrongImageState(name: "half", state: "provisioning", operation: "build an image from"))
        if case .wrongImageState(name: "old", _, _)? = await refusal("old") {} else {
            Issue.record("an image without the current guest daemon must be refused")
        }
        #expect(await refusal("missing") == .imageNotFound("missing"))
        #expect(await refusal("base", name: "base") == .imageExists(name: "base", state: "ready"))
        #expect(await refusal("base", name: "Bad") == .invalidImageName("Bad"))
        // Nothing was created by the refusals.
        #expect(try store.list().images.map(\.name) == ["base", "half", "old"])
    }

    @Test func recordsFromBeforeDerivedImagesStillRead() throws {
        let json = #"{"formatVersion":1,"name":"dev","state":"ready","createdAt":"2026-09-23T10:00:00Z","createdBy":"0.0.1","macOSVersion":"27.0","macOSBuild":"26A428","cpuCount":4,"memoryBytes":8589934592,"diskBytes":68719476736,"macAddress":"da:51:72:d4:e5:72","userName":"agent"}"#
        let record = try SessionStore.decoder.decode(ImageRecord.self, from: Data(json.utf8))
        #expect(record.derivedFrom == nil)
        #expect(record.recipe == nil)
        #expect(record.recipes == nil)
    }

    @Test func recordsFromBeforeRecipeListsStillRead() throws {
        let json = #"{"formatVersion":1,"name":"dev-node","state":"ready","createdAt":"2026-09-23T10:00:00Z","createdBy":"0.0.1","macOSVersion":"27.0","macOSBuild":"26A428","cpuCount":4,"memoryBytes":8589934592,"diskBytes":68719476736,"macAddress":"da:51:72:d4:e5:72","userName":"agent","recipe":{"description":"Homebrew and Node","digest":"edef"}}"#
        let record = try SessionStore.decoder.decode(ImageRecord.self, from: Data(json.utf8))
        #expect(record.recipe == ImageRecord.RecipeInfo(description: "Homebrew and Node", digest: "edef"))
        #expect(record.recipes == nil)
    }
}
