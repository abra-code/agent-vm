// Tests/AgentVMKitTests/HostCheckTests.swift
//
// Doctor's rules, judged on made-up facts so they do not depend on this Mac or on how the test
// runner is signed.

import Foundation
import Testing
import Virtualization
@testable import AgentVMKit

@Suite struct HostCheckTests {
    static func goodFacts() -> HostFacts {
        return HostFacts(
            osVersion: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0),
            isAppleSilicon: true,
            virtualizationSupported: true,
            hasVirtualizationEntitlement: true,
            signature: HostFacts.Signature(isAdHoc: false, teamIdentifier: "TEAM123456", hardenedRuntime: true),
            cpuCount: 10,
            memoryBytes: 24 << 30,
            storeRoot: "/Users/someone/Library/Application Support/agent-vm",
            storeFreeBytes: 100 << 30,
            runningVirtualMachines: 0,
            store: StoreRoot.State(isFolder: true, ownedByUser: true, mode: 0o700, ignoresOwnership: false)
        )
    }

    func status(_ report: HostReport, _ name: String) -> HostCheck.Status? {
        return report.checks.first { $0.name == name }?.status
    }

    @Test func goodHostPassesEveryCheck() {
        let report = HostReport.evaluate(Self.goodFacts())
        #expect(report.canRunBoxes)
        // The last line is about Linux guests, and is never more than a note.
        #expect(report.checks.dropLast().allSatisfy { $0.status == .ok })
        #expect(report.checks.last?.status == .info)
        #expect(report.checks.map(\.name) == ["macOS", "virtualization", "entitlement", "signature", "disk space", "store folder", "account passwords", "running VMs",
                                             "linux guest daemon"])
    }

    @Test func theLinuxDaemonLineIsNeverAFailure() throws {
        func check(_ daemon: LocalGuestDaemon?) -> HostCheck? {
            var facts = Self.goodFacts()
            facts.linuxGuestDaemon = daemon
            let report = HostReport.evaluate(facts)
            #expect(report.canRunBoxes)
            return report.checks.first { $0.name == "linux guest daemon" }
        }
        // Nobody looked, or it is not there: a note that says how to get it.
        #expect(check(nil)?.status == .info)
        #expect(check(nil)?.detail.contains("not built") == true)
        let missing = LocalGuestDaemon.inspectLinux(URL(fileURLWithPath: "/no/such/linux/agent-vm-guest"))
        #expect(check(missing)?.status == .info)
        #expect(check(missing)?.detail.contains("Scripts/build.sh") == true)
        // There, and good: its digest, shortened.
        var good = LocalGuestDaemon(path: "/somewhere/linux/agent-vm-guest")
        good.digest = String(repeating: "ab", count: 32)
        #expect(check(good)?.status == .info)
        #expect(check(good)?.detail == "next to agent-vm (SHA-256 abababababab...)")
        // There, and not a Linux program: a warning that names the file.
        let scratch = try Scratch()
        let wrong = scratch.root.appendingPathComponent("agent-vm-guest")
        try Data("#!/bin/sh\n".utf8).write(to: wrong)
        chmod(wrong.path, 0o755)
        let found = check(LocalGuestDaemon.inspectLinux(wrong))
        #expect(found?.status == .warning)
        #expect(found?.detail.contains(wrong.path) == true)
    }

    @Test func theStoreFolderMustBeYourOwnAndPrivate() {
        func check(_ state: StoreRoot.State?) -> (HostCheck.Status?, Bool) {
            var facts = Self.goodFacts()
            facts.store = state
            let report = HostReport.evaluate(facts)
            return (status(report, "store folder"), report.canRunBoxes)
        }
        #expect(check(nil) == (.info, true))
        #expect(check(StoreRoot.State(isFolder: true, ownedByUser: true, mode: 0o755, ignoresOwnership: false)) == (.warning, true))
        #expect(check(StoreRoot.State(isFolder: true, ownedByUser: true, mode: 0o700, ignoresOwnership: true)) == (.warning, true))
        #expect(check(StoreRoot.State(isFolder: true, ownedByUser: false, mode: 0o700, ignoresOwnership: false)) == (.failure, false))
        #expect(check(StoreRoot.State(isFolder: false, ownedByUser: true, mode: 0o600, ignoresOwnership: false)) == (.failure, false))
    }

    @Test func passwordsStillInFilesAreMentioned() {
        func check(files: Int?, keychain: Bool) -> HostCheck? {
            var facts = Self.goodFacts()
            facts.passwordFiles = files
            facts.keepsPasswordsInKeychain = keychain
            let report = HostReport.evaluate(facts)
            #expect(report.canRunBoxes)
            return report.checks.first { $0.name == "account passwords" }
        }
        #expect(check(files: 0, keychain: true)?.status == .ok)
        #expect(check(files: 3, keychain: true)?.status == .info)
        #expect(check(files: 3, keychain: true)?.detail.contains("agent-vm store secure-passwords") == true)
        #expect(check(files: 1, keychain: true)?.detail.hasPrefix("1 image or box keeps its") == true)
        // An ad hoc build cannot move them, so it does not say to.
        #expect(check(files: 3, keychain: false)?.detail.contains("secure-passwords") == false)
        #expect(check(files: nil, keychain: true)?.status == .info)
    }

    /// A store folder made before agent-vm set the mode, or by hand, or by someone else.
    @Test func aStoreFolderIsMadePrivateOrRefusedBeforeAnythingIsWritten() throws {
        let scratch = try Scratch()
        let root = scratch.root.appendingPathComponent("old-store", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        chmod(root.path, 0o755)
        #expect(StoreRoot.state(root)?.mode == 0o755)
        _ = try SessionStore(root: root).start(project: scratch.project.path)
        #expect(StoreRoot.state(root) == StoreRoot.State(isFolder: true, ownedByUser: true, mode: 0o700, ignoresOwnership: false))

        // Missing: created private, with what is above it.
        let fresh = scratch.root.appendingPathComponent("a/b/store", isDirectory: true)
        #expect(StoreRoot.state(fresh) == nil)
        try StoreRoot.prepare(fresh)
        #expect(StoreRoot.state(fresh)?.mode == 0o700)

        // Given as a link to a folder: that folder, as the stores take it.
        let link = scratch.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        try StoreRoot.prepare(link)
        #expect(StoreRoot.state(link) == StoreRoot.state(root))

        // Not a folder, and a folder of another user (root's).
        let file = scratch.root.appendingPathComponent("file")
        try Data().write(to: file)
        for (bad, reason) in [(file, "not a folder"), (URL(fileURLWithPath: "/private/var/empty"), "another user")] {
            do {
                try StoreRoot.prepare(bad)
                Issue.record("\(bad.path) was accepted as a store")
            } catch let AgentVMError.unsuitableStore(_, text) {
                #expect(text.contains(reason), "\(text)")
            }
            #expect(throws: AgentVMError.self) { try JobStore(root: bad).start(executable: "/usr/bin/true", arguments: [], targets: [], directory: "/", runner: ["/usr/bin/true"]) }
        }
    }

    @Test func missingEntitlementFailsAndPointsAtTheBuildScript() {
        var facts = Self.goodFacts()
        facts.hasVirtualizationEntitlement = false
        let report = HostReport.evaluate(facts)
        #expect(!report.canRunBoxes)
        let check = report.checks.first { $0.name == "entitlement" }
        #expect(check?.status == .failure)
        #expect(check?.detail.contains("Scripts/build.sh") == true)
    }

    @Test func unreadableFactsWarnInsteadOfFailing() {
        var facts = Self.goodFacts()
        facts.hasVirtualizationEntitlement = nil
        facts.signature = nil
        facts.storeFreeBytes = nil
        facts.runningVirtualMachines = nil
        let report = HostReport.evaluate(facts)
        #expect(report.canRunBoxes)
        #expect(status(report, "entitlement") == .warning)
        #expect(status(report, "signature") == .warning)
        #expect(status(report, "disk space") == .warning)
        #expect(status(report, "running VMs") == .info)
    }

    @Test func oldMacOSAndIntelFail() {
        var facts = Self.goodFacts()
        facts.osVersion = OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 0)
        #expect(status(HostReport.evaluate(facts), "macOS") == .failure)

        facts = Self.goodFacts()
        facts.isAppleSilicon = false
        #expect(status(HostReport.evaluate(facts), "virtualization") == .failure)

        facts = Self.goodFacts()
        facts.virtualizationSupported = false
        #expect(status(HostReport.evaluate(facts), "virtualization") == .failure)
    }

    @Test func signatureKinds() {
        var facts = Self.goodFacts()
        facts.signature = HostFacts.Signature(isAdHoc: true, teamIdentifier: nil, hardenedRuntime: true)
        #expect(status(HostReport.evaluate(facts), "signature") == .info)

        facts.signature = HostFacts.Signature(isAdHoc: false, teamIdentifier: "TEAM123456", hardenedRuntime: false)
        #expect(status(HostReport.evaluate(facts), "signature") == .warning)
        #expect(HostReport.evaluate(facts).canRunBoxes)
    }

    @Test func lowSpaceAndTheTwoGuestLimitWarn() {
        var facts = Self.goodFacts()
        facts.storeFreeBytes = HostReport.lowSpaceBytes - 1
        #expect(status(HostReport.evaluate(facts), "disk space") == .warning)
        facts.storeFreeBytes = HostReport.lowSpaceBytes
        #expect(status(HostReport.evaluate(facts), "disk space") == .ok)

        facts = Self.goodFacts()
        facts.runningVirtualMachines = 1
        #expect(status(HostReport.evaluate(facts), "running VMs") == .ok)
        facts.runningVirtualMachines = HostReport.macOSGuestLimit
        let report = HostReport.evaluate(facts)
        #expect(status(report, "running VMs") == .warning)
        #expect(report.canRunBoxes)
    }

    /// The count and the limit as data, for a program that checks before it starts a VM.
    @Test func runningVMsAreCountedAsData() throws {
        var facts = Self.goodFacts()
        facts.runningVirtualMachines = 1
        var check = try #require(HostReport.evaluate(facts).checks.first { $0.name == "running VMs" })
        #expect(check.count == 1 && check.limit == 2)
        let json = String(decoding: try JSONEncoder().encode(check), as: UTF8.self)
        #expect(json.contains("\"count\":1") && json.contains("\"limit\":2"))
        facts.runningVirtualMachines = nil
        check = try #require(HostReport.evaluate(facts).checks.first { $0.name == "running VMs" })
        #expect(check.count == nil && check.limit == 2)
        // Only that check carries them.
        let others = HostReport.evaluate(facts).checks.filter { $0.name != "running VMs" }
        #expect(others.allSatisfy { $0.count == nil && $0.limit == nil })
    }

    /// The limit is on macOS guests: agent-vm's own running Linux boxes are counted, and named,
    /// apart.
    @Test func linuxBoxesDoNotCountAgainstTheLimit() throws {
        func check(_ running: Int?, linux: Int) throws -> HostCheck {
            var facts = Self.goodFacts()
            facts.runningVirtualMachines = running
            facts.runningLinuxBoxes = linux
            return try #require(HostReport.evaluate(facts).checks.first { $0.name == "running VMs" })
        }
        // Two processes, one of them a Linux box: a macOS box still has a place.
        var found = try check(2, linux: 1)
        #expect(found.status == .ok && found.count == 2 && found.limit == 2 && found.linuxBoxes == 1)
        #expect(found.detail == "2 virtual machines running on this Mac (any application), 1 of them a Linux box of yours")
        // Three, one Linux: the other two may be macOS guests.
        found = try check(3, linux: 1)
        #expect(found.status == .warning && found.linuxBoxes == 1)
        #expect(found.detail == "3 virtual machines running on this Mac (any application), 1 of them a Linux box of yours; macOS runs at most 2 macOS guests at once, so a macOS box will not start while the other 2 are macOS guests")
        // Linux boxes alone never warn.
        found = try check(5, linux: 5)
        #expect(found.status == .ok && found.detail == "5 virtual machines running on this Mac (any application), 5 of them Linux boxes of yours")
        // Without Linux boxes the words are the ones there always were.
        found = try check(2, linux: 0)
        #expect(found.detail == "2 virtual machines running on this Mac (any application); macOS runs at most 2 macOS guests at once, so a box will not start while those are macOS guests")
        #expect(found.linuxBoxes == 0)
        #expect(String(decoding: try JSONEncoder().encode(found), as: UTF8.self).contains("\"linuxBoxes\":0"))
        // More boxes than processes (a supervisor whose machine is gone) is never a negative count.
        found = try check(1, linux: 3)
        #expect(found.status == .ok && found.linuxBoxes == 1)
        // When the processes cannot be listed, nothing is claimed.
        found = try check(nil, linux: 1)
        #expect(found.count == nil && found.linuxBoxes == nil)
    }

    /// A Linux image being built or updated runs a Linux guest too, and takes no place either.
    @Test func linuxImagesAtWorkDoNotCountAgainstTheLimit() throws {
        func check(_ running: Int?, boxes: Int, images: Int) throws -> HostCheck {
            var facts = Self.goodFacts()
            facts.runningVirtualMachines = running
            facts.runningLinuxBoxes = boxes
            facts.runningLinuxImages = images
            return try #require(HostReport.evaluate(facts).checks.first { $0.name == "running VMs" })
        }
        // One macOS guest and one Linux image being built: a macOS box still has a place.
        var found = try check(2, boxes: 0, images: 1)
        #expect(found.status == .ok && found.linuxBoxes == 0 && found.linuxImages == 1)
        #expect(found.detail == "2 virtual machines running on this Mac (any application), 1 of them a Linux image being built or updated")
        // With a Linux box as well.
        found = try check(4, boxes: 1, images: 2)
        #expect(found.status == .ok && found.linuxBoxes == 1 && found.linuxImages == 2)
        #expect(found.detail == "4 virtual machines running on this Mac (any application), 1 of them a Linux box of yours, 2 Linux images being built or updated")
        // Two that may be macOS guests still warn.
        found = try check(3, boxes: 0, images: 1)
        #expect(found.status == .warning)
        #expect(found.detail.hasSuffix("so a macOS box will not start while the other 2 are macOS guests"))
        // Never more Linux guests than machines, boxes first.
        found = try check(2, boxes: 1, images: 3)
        #expect(found.linuxBoxes == 1 && found.linuxImages == 1)
        found = try check(1, boxes: 2, images: 1)
        #expect(found.linuxBoxes == 1 && found.linuxImages == 0)
        #expect(String(decoding: try JSONEncoder().encode(found), as: UTF8.self).contains("\"linuxImages\":0"))
        found = try check(nil, boxes: 0, images: 1)
        #expect(found.linuxImages == nil)
    }

    /// Virtualization's refusal to run another VM becomes its own error, with a stable phrase
    /// and exit status; its other errors stay as they were.
    @Test func theVMLimitIsItsOwnRefusal() {
        let limit = NSError(domain: VZErrorDomain, code: VZError.Code.virtualMachineLimitExceeded.rawValue)
        let refusal = AgentVMError.virtualMachine(operation: "start the guest", error: limit)
        #expect(refusal == .noFreeVMSlot(operation: "start the guest"))
        #expect(refusal.description.hasPrefix("no free VM slot: cannot start the guest"))
        #expect(AgentVMError.noFreeVMSlotStatus == 75)
        // As the installer reports it: wrapped in its own installation error (measured).
        let wrapped = NSError(domain: VZErrorDomain, code: VZError.Code.installationFailed.rawValue, userInfo: [NSUnderlyingErrorKey: limit])
        #expect(AgentVMError.virtualMachine(operation: "install macOS", error: wrapped) == .noFreeVMSlot(operation: "install macOS"))
        let other = NSError(domain: VZErrorDomain, code: VZError.Code.internalError.rawValue, userInfo: [NSLocalizedDescriptionKey: "it broke"])
        #expect(AgentVMError.virtualMachine(operation: "start the guest", error: other) == .virtualMachine(operation: "start the guest", message: "it broke"))
    }

    /// The live facts are gathered without crashing, whatever the test runner's signature.
    @Test func currentFactsAreReadable() {
        let facts = HostFacts.current(storeRoot: URL(fileURLWithPath: NSTemporaryDirectory()))
        #expect(facts.osVersion.majorVersion >= 27)
        #expect(facts.cpuCount > 0)
        _ = HostReport.evaluate(facts)
    }
}
