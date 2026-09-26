// Tests/AgentVMKitTests/BoxStatusTests.swift
//
// Box status without side effects (a stopped box from its folder, a running one from its
// supervisor's answer), what an image needs, and how agent-vm describes a guest daemon file.

import Darwin
import Foundation
import Testing
@testable import AgentVMKit

/// A control handler that answers status with a fixed response and refuses everything else.
final class StatusHandler: ControlHandler, @unchecked Sendable {
    let response: ControlResponse

    init(_ response: ControlResponse) {
        self.response = response
    }

    func controlStatus() -> ControlResponse { response }
    func controlOpenGuest(project: String?, readOnly: Bool) throws -> LentConnection { throw AgentVMError.guestRefused("not in tests") }
    func controlStop() {}
    func controlReload() throws {}
    func controlShare(path: String, readOnly: Bool) throws {}
    func controlView(interactive: Bool) throws {}
    func controlType(text: String?) throws {}
    func controlSyncClock() throws -> Double { throw AgentVMError.guestRefused("not in tests") }
}

@Suite struct BoxStatusTests {
    /// A box whose folder is short enough for a control socket.
    func shortBox(_ folder: ShortFolder) throws -> (Box, BoxScratch) {
        let fixture = try BoxScratch()
        let created = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images)
        return (Box(record: created.record, directory: URL(fileURLWithPath: folder.path, isDirectory: true)), fixture)
    }

    @Test func aStoppedBoxIsReadFromItsFolder() throws {
        let folder = try ShortFolder()
        let (box, _) = try shortBox(folder)
        #expect(BoxStatus.of(box) == .stopped)
    }

    @Test func aRunningBoxIsAskedThroughItsSupervisor() throws {
        let folder = try ShortFolder()
        let (box, _) = try shortBox(folder)
        let lock = try #require(try FolderLock.tryAcquire(box.lockPath))
        defer { lock.release() }
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let server = try ControlServer(path: box.controlSocketPath, handler: StatusHandler(ControlResponse(
            ok: true, state: .ready, guestVersion: "0.1.6", pid: 4242, project: "/Users/me/src/app", projectReadOnly: true,
            guestFeatures: ["terminal"], supervisorVersion: "0.1.6", supervisorPath: "/opt/agent-vm", startedAt: started, activeExecs: 2)))
        defer { server.close() }
        #expect(BoxStatus.of(box) == BoxStatus(state: .ready, pid: 4242, supervisorVersion: "0.1.6", supervisorPath: "/opt/agent-vm",
                                               startedAt: started, project: "/Users/me/src/app", projectReadOnly: true, activeExecs: 2,
                                               guestVersion: "0.1.6", guestFeatures: ["terminal"]))
    }

    /// Supervisors before 0.1.6 answer without the new fields; they stay empty.
    @Test func anOlderSupervisorLeavesTheNewFieldsEmpty() throws {
        let folder = try ShortFolder()
        let (box, _) = try shortBox(folder)
        let lock = try #require(try FolderLock.tryAcquire(box.lockPath))
        defer { lock.release() }
        let server = try ControlServer(path: box.controlSocketPath, handler: StatusHandler(ControlResponse(ok: true, state: .starting, pid: 7, guestFeatures: [])))
        defer { server.close() }
        let status = BoxStatus.of(box)
        #expect(status.state == .starting)
        #expect(status.pid == 7)
        #expect(status.supervisorVersion == nil && status.activeExecs == nil && status.startedAt == nil)
        // Features are the guest daemon's, known only once it answered.
        #expect(status.guestFeatures == nil)
    }

    /// Held but not answering: unresponsive, with the reason, after a short wait for a socket
    /// that a starting supervisor may not have bound yet.
    @Test func aHeldBoxWithoutASupervisorIsUnresponsive() throws {
        let folder = try ShortFolder()
        let (box, _) = try shortBox(folder)
        let lock = try #require(try FolderLock.tryAcquire(box.lockPath))
        defer { lock.release() }
        let clock = ContinuousClock()
        let began = clock.now
        let status = BoxStatus.of(box, connectWait: .milliseconds(300))
        #expect(clock.now - began >= .milliseconds(300))
        #expect(status.state == .unresponsive)
        #expect(status.statusError?.contains("control.sock") == true)
    }

    @Test func aRefusalIsUnresponsive() {
        let status = BoxStatus.from(ControlResponse(ok: false, error: "control protocol 2 is not supported"))
        #expect(status == BoxStatus(state: .unresponsive, statusError: "control protocol 2 is not supported"))
    }

    /// The status fields sit next to the record's in `box list --json`; dates as ISO 8601.
    @Test func statusEncodesOnlyWhatIsKnown() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        #expect(String(decoding: try encoder.encode(BoxStatus.stopped), as: UTF8.self) == #"{"state":"stopped"}"#)
        let running = BoxStatus(state: .ready, pid: 1, startedAt: Date(timeIntervalSince1970: 1_800_000_000), activeExecs: 0)
        #expect(String(decoding: try encoder.encode(running), as: UTF8.self) == #"{"activeExecs":0,"pid":1,"startedAt":"2027-01-15T08:00:00Z","state":"ready"}"#)
    }

    @Test func supervisorStateCountsLentConnections() {
        let state = SupervisorState()
        #expect(state.activeExecs == 0)
        state.execOpened()
        state.execOpened()
        state.execClosed()
        #expect(state.activeExecs == 1)
        state.execClosed()
        state.execClosed()
        #expect(state.activeExecs == 0)
    }
}

@Suite struct ImageNeedTests {
    func record(features: [String]?, access: ImageRecord.FullDiskAccess?, digest: String? = "d1") -> ImageRecord {
        var record = ImageStoreTests.record("dev", state: .ready)
        record.guestFeatures = features
        record.guestDigest = digest
        record.fullDiskAccess = access
        return record
    }

    @Test func aCompleteImageNeedsNothing() {
        let access = ImageRecord.FullDiskAccess(granted: true, guestDigest: "d1", checkedAt: Date())
        #expect(record(features: GuestFeature.all, access: access).needs == [])
    }

    @Test func missingFeaturesAskForAGuestUpdate() {
        let access = ImageRecord.FullDiskAccess(granted: true, guestDigest: "d1", checkedAt: Date())
        #expect(record(features: ["terminal"], access: access).needs == [ImageNeed(kind: .guestUpdate, missing: ["prompt-notices", "wallpaper", "time-sync", "user-session", "terminal-pixels"])])
        #expect(record(features: nil, access: access).needs == [ImageNeed(kind: .guestUpdate, missing: GuestFeature.all)])
    }

    @Test func fullDiskAccessIsNeededWhenRefusedOrUnchecked() {
        let refused = ImageRecord.FullDiskAccess(granted: false, guestDigest: "d1", checkedAt: Date())
        #expect(record(features: GuestFeature.all, access: refused).needs == [ImageNeed(kind: .fullDiskAccess, reason: .notGranted)])
        #expect(record(features: GuestFeature.all, access: nil).needs == [ImageNeed(kind: .fullDiskAccess, reason: .notChecked)])
        // Granted to a daemon since replaced: not known for the current one.
        let stale = ImageRecord.FullDiskAccess(granted: true, guestDigest: "d0", checkedAt: Date())
        #expect(record(features: GuestFeature.all, access: stale).needs == [ImageNeed(kind: .fullDiskAccess, reason: .notChecked)])
    }

    static let developerID = #"identifier "com.abracode.agent-vm-guest" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = T9NM2ZLDTY"#

    /// A grant recorded for another build carries over when both name the same signer (a
    /// Developer ID), never for ad hoc builds, whose requirement is one build's hash.
    @Test func fullDiskAccessCarriesOverBetweenBuildsOfOneSigner() {
        var image = record(features: GuestFeature.all, access: ImageRecord.FullDiskAccess(granted: true, guestDigest: "d0", guestRequirement: Self.developerID, checkedAt: Date()))
        image.guestRequirement = Self.developerID
        #expect(image.hasFullDiskAccess == true)
        #expect(image.needs == [])
        image.fullDiskAccess?.granted = false
        #expect(image.hasFullDiskAccess == false)

        image.fullDiskAccess?.granted = true
        image.guestRequirement = Self.developerID.replacingOccurrences(of: "T9NM2ZLDTY", with: "OTHERTEAM1")
        #expect(image.hasFullDiskAccess == nil)
        image.guestRequirement = nil
        #expect(image.hasFullDiskAccess == nil)

        let adHoc = #"cdhash H"fad47e2c930b7246cffa3aac62fda48c459ef597""#
        image.guestRequirement = adHoc
        image.fullDiskAccess?.guestRequirement = adHoc
        #expect(image.hasFullDiskAccess == nil)
        // The same executable: known whatever its signature.
        image.guestDigest = "d0"
        #expect(image.hasFullDiskAccess == true)
    }

    @Test func requirementsNamingASigner() throws {
        #expect(CodeSignature.namesASigner(Self.developerID))
        #expect(!CodeSignature.namesASigner(#"cdhash H"fad47e2c930b7246cffa3aac62fda48c459ef597""#))
        #expect(CodeSignature.namesASigner(#"identifier "com.example.tool" and certificate root = H"0123456789abcdef0123456789abcdef01234567""#))
        // Apple's own tools name a signer; a script names none.
        let ls = try #require(CodeSignature.designatedRequirement(of: URL(fileURLWithPath: "/bin/ls")))
        #expect(CodeSignature.namesASigner(ls), "\(ls)")
        let scratch = try Scratch()
        let script = scratch.root.appendingPathComponent("tool")
        try Data("#!/bin/sh\n".utf8).write(to: script)
        #expect(CodeSignature.designatedRequirement(of: script) == nil)
    }

    /// Records written before the requirement was recorded still read.
    @Test func recordsWithoutARequirementStillRead() throws {
        let json = #"{"granted":true,"guestDigest":"d1","checkedAt":"2026-09-01T00:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let access = try decoder.decode(ImageRecord.FullDiskAccess.self, from: Data(json.utf8))
        #expect(access.guestRequirement == nil)
        #expect(access.applies(toDigest: "d1", requirement: Self.developerID))
        #expect(!access.applies(toDigest: "d2", requirement: Self.developerID))
    }

    @Test func onlyReadyImagesNeedAnything() {
        var failed = record(features: nil, access: nil)
        failed.state = .failed
        #expect(failed.needs == [])
    }

    @Test func needsEncodeAsTheBriefSays() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let needs = [ImageNeed(kind: .guestUpdate, missing: ["wallpaper"]), ImageNeed(kind: .fullDiskAccess, reason: .notChecked)]
        #expect(String(decoding: try encoder.encode(needs), as: UTF8.self)
            == #"[{"kind":"guest-update","missing":["wallpaper"]},{"kind":"full-disk-access","reason":"not-checked"}]"#)
    }
}

@Suite struct GuestDaemonInfoTests {
    @Test func parsesJSONAndTheOlderTextLine() {
        #expect(GuestDaemonInfo.parse(#"{"features":["terminal"],"protocol":1,"version":"0.1.6"}"#)
            == GuestDaemonInfo(version: "0.1.6", protocol: 1, features: ["terminal"]))
        #expect(GuestDaemonInfo.parse("agent-vm-guest 0.1.5 (protocol 1)\n") == GuestDaemonInfo(version: "0.1.5", protocol: 1, features: nil))
        #expect(GuestDaemonInfo.parse("something else 1.0") == nil)
        #expect(GuestDaemonInfo.parse("{not json") == nil)
    }

    @Test func inspectsAnExecutable() throws {
        let scratch = try Scratch()
        let url = scratch.root.appendingPathComponent("agent-vm-guest")
        try Data("#!/bin/sh\necho 'agent-vm-guest 0.1.5 (protocol 1)'\n".utf8).write(to: url)
        chmod(url.path, 0o755)
        let daemon = LocalGuestDaemon.inspect(url)
        #expect(daemon.error == nil)
        #expect(daemon.version == "0.1.5")
        #expect(daemon.protocol == 1)
        #expect(daemon.features == nil)
        #expect(daemon.digest == (try ImageBuilder.sha256(of: url)))
        #expect(daemon.requirement == nil)
    }

    @Test func reportsAMissingOrSilentDaemon() throws {
        let scratch = try Scratch()
        let missing = LocalGuestDaemon.inspect(scratch.root.appendingPathComponent("nothing"))
        #expect(missing.error?.contains("no agent-vm-guest executable") == true)
        #expect(missing.digest == nil)

        let url = scratch.root.appendingPathComponent("agent-vm-guest")
        try Data("#!/bin/sh\nexit 3\n".utf8).write(to: url)
        chmod(url.path, 0o755)
        let silent = LocalGuestDaemon.inspect(url)
        #expect(silent.error?.contains("status 3") == true)
        #expect(silent.digest != nil)
        #expect(silent.version == nil)
    }
}
