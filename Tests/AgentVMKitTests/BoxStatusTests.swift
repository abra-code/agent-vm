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
        #expect(record(features: ["terminal"], access: access).needs == [ImageNeed(kind: .guestUpdate, missing: ["prompt-notices", "wallpaper", "time-sync"])])
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
