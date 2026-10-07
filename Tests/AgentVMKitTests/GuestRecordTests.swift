// Tests/AgentVMKitTests/GuestRecordTests.swift
//
// Image and box records that say which guest they are: a record from before the field is a
// macOS one and reads as ever; a Linux record has its own format number, which an agent-vm
// that cannot run Linux guests refuses; lists name each record's system; and what has no
// meaning for a Linux guest is not asked of one.

import Foundation
import Testing
@testable import AgentVMKit

@Suite struct GuestRecordTests {
    static let debian = LinuxSystem(distribution: "debian", version: "13", name: "Debian GNU/Linux 13 (trixie)", kernel: "6.12.48+deb13-cloud-arm64")
    static let threeFeatures = [GuestFeature.terminal, GuestFeature.timeSync, GuestFeature.terminalPixels]

    /// A ready Linux image's record, as a build would write it.
    static func linuxRecord(_ name: String = "deb", features: [String]? = threeFeatures) -> ImageRecord {
        var record = ImageRecord(formatVersion: ImageRecord.formatVersion(passwordID: nil, guest: .linux), name: name, state: .ready, failure: nil,
                                 createdAt: Date(timeIntervalSince1970: 1_800_000_000), createdBy: AgentVM.version,
                                 macOSVersion: nil, macOSBuild: nil, cpuCount: 4, memoryBytes: 4 << 30,
                                 diskBytes: 32 << 30, macAddress: "da:51:72:d4:e5:73", userName: "agent")
        record.guest = .linux
        record.linux = debian
        record.base = ImageRecord.BaseSource(release: "debian-13", file: "debian-13-genericcloud-arm64.tar.xz",
                                             url: "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-arm64.tar.xz",
                                             sha512: String(repeating: "ab", count: 64))
        record.guestProtocol = 1
        record.guestVersion = AgentVM.version
        record.guestFeatures = features
        return record
    }

    // MARK: - Reading and writing

    @Test func aRecordWithoutGuestIsMacOS() throws {
        let json = #"{"formatVersion":1,"name":"dev","state":"ready","createdAt":"2026-09-23T10:00:00Z","createdBy":"0.0.1","macOSVersion":"27.0","macOSBuild":"26A428","cpuCount":4,"memoryBytes":8589934592,"diskBytes":68719476736,"macAddress":"da:51:72:d4:e5:72","userName":"agent"}"#
        let record = try SessionStore.decoder.decode(ImageRecord.self, from: Data(json.utf8))
        #expect(record.guest == nil)
        #expect(record.effectiveGuest == .macOS)
        #expect(record.linux == nil && record.base == nil)
        #expect(record.macOSVersion == "27.0" && record.macOSBuild == "26A428")
        // Written again, it gains no key an older agent-vm would have to know.
        let written = String(decoding: try SessionStore.encoder.encode(record), as: UTF8.self)
        #expect(!written.contains("\"guest\""))
        #expect(!written.contains("\"linux\""))

        let box = #"{"formatVersion":1,"name":"b1","image":"dev","macOSVersion":"27.0","macOSBuild":"26A428","createdAt":"2026-09-23T10:00:00Z","cpuCount":4,"memoryBytes":8589934592,"macAddress":"da:51:72:d4:e5:72","userName":"agent"}"#
        let boxRecord = try SessionStore.decoder.decode(BoxRecord.self, from: Data(box.utf8))
        #expect(boxRecord.effectiveGuest == .macOS)
        #expect(boxRecord.systemDescription == "macOS 27.0 (26A428)")
    }

    @Test func aLinuxRecordRoundTrips() throws {
        let record = Self.linuxRecord()
        let data = try SessionStore.encoder.encode(record)
        let text = String(decoding: data, as: UTF8.self)
        // No macOS key at all, not an empty one.
        #expect(!text.contains("macOSVersion") && !text.contains("macOSBuild"))
        let read = try SessionStore.decoder.decode(ImageRecord.self, from: data)
        #expect(read == record)
        #expect(read.effectiveGuest == .linux)
        #expect(read.linux == Self.debian)
        #expect(read.base?.release == "debian-13")

        // Through the store, as a real image's is.
        let scratch = try Scratch()
        let store = ImageStore(root: scratch.root.appendingPathComponent("store", isDirectory: true))
        var building = record
        building.state = .installing
        let (image, lock) = try store.create(building)
        lock.release()
        #expect(try store.image(named: "deb").record == building)
        #expect(image.efiVariableStoreURL.lastPathComponent == "EFIVariableStore")
        #expect(image.consoleLogURL.lastPathComponent == "console.log")
    }

    @Test func aLinuxRecordIsFormat3AndAMacRecordIsNot() {
        #expect(ImageRecord.formatVersion(passwordID: nil, guest: .linux) == 3)
        #expect(ImageRecord.formatVersion(passwordID: "some-id", guest: .linux) == 3)
        // macOS records keep the formats agent-vm has always written for them: an older
        // agent-vm must go on reading them after a newer one saved them again.
        #expect(ImageRecord.formatVersion(passwordID: nil, guest: .macOS) == 1)
        #expect(ImageRecord.formatVersion(passwordID: nil, guest: nil) == 1)
        #expect(ImageRecord.formatVersion(passwordID: "some-id", guest: .macOS) == 2)
        #expect(ImageRecord.formatVersion(passwordID: "some-id", guest: nil) == 2)
        #expect(ImageRecord.currentFormatVersion == 3 && BoxRecord.currentFormatVersion == 3)
        #expect(Self.linuxRecord().formatVersion == 3)
    }

    @Test func aNewerFormatIsRefused() throws {
        let scratch = try Scratch()
        let store = ImageStore(root: scratch.root.appendingPathComponent("store", isDirectory: true))
        var record = Self.linuxRecord("future")
        record.formatVersion = 4
        let (_, lock) = try store.create(record)
        lock.release()
        do {
            _ = try store.image(named: "future")
            Issue.record("a format 4 record was read")
        } catch let AgentVMError.corruptImageRecord(_, reason) {
            #expect(reason == "written by a newer agent-vm (format 4)")
        }
        // Format 3, the newest this agent-vm knows, is read.
        record.name = "now"
        record.formatVersion = 3
        let (_, second) = try store.create(record)
        second.release()
        #expect(try store.image(named: "now").record.formatVersion == 3)
    }

    // MARK: - What a record needs, and what it is called

    @Test func linuxImagesNeverNeedFullDiskAccess() {
        let linux = Self.linuxRecord()
        #expect(linux.needs.isEmpty)
        // The same record as a macOS one has never been checked for it.
        var mac = ImageStoreTests.record("dev", state: .ready)
        mac.guestFeatures = GuestFeature.all(for: .macOS)
        #expect(mac.needs == [ImageNeed(kind: .fullDiskAccess, reason: .notChecked)])
    }

    @Test func linuxImagesNeedOnlyTheirOwnFeatures() {
        // Three of the six features are all a Linux daemon has: nothing is missing.
        #expect(Self.linuxRecord().needs.isEmpty)
        let older = Self.linuxRecord(features: [GuestFeature.terminal, GuestFeature.timeSync])
        #expect(older.needs == [ImageNeed(kind: .guestUpdate, missing: [GuestFeature.terminalPixels])])
        // A macOS image with those three lacks the other three.
        var mac = ImageStoreTests.record("dev", state: .ready)
        mac.guestFeatures = Self.threeFeatures
        #expect(mac.needs.first == ImageNeed(kind: .guestUpdate, missing: [GuestFeature.promptNotices, GuestFeature.wallpaper, GuestFeature.userSession]))
    }

    @Test func systemDescriptions() {
        let mac = ImageStoreTests.record("dev", state: .ready)
        #expect(mac.systemDescription == "macOS 27.0 (26A428)")
        #expect(mac.systemShort == "macOS 27.0")
        #expect(mac.systemBuild == "macOS 26A428")
        let linux = Self.linuxRecord()
        #expect(linux.systemDescription == "Debian GNU/Linux 13 (trixie)")
        #expect(linux.systemShort == "Debian 13")
        #expect(linux.systemBuild == "Debian 13")
        // What the names fall back to.
        #expect(LinuxSystem(distribution: "ubuntu", version: "26.04", name: "Ubuntu 26.04.1 LTS").shortName == "Ubuntu 26.04")
        #expect(LinuxSystem(distribution: "nixos", version: "", name: "").shortName == "Nixos")
        #expect(LinuxSystem(distribution: "", version: "", name: "").shortName == "Linux")
        var nameless = linux
        nameless.linux = LinuxSystem(distribution: "debian", version: "13", name: "")
        #expect(nameless.systemDescription == "Debian 13")
        nameless.linux = nil
        #expect(nameless.systemDescription == "Linux" && nameless.systemShort == "Linux")
        // A macOS record that lost a field says so in place of a made-up value.
        var odd = mac
        odd.macOSVersion = nil
        #expect(odd.systemDescription == "macOS ? (26A428)")
    }

    @Test func needsNameTheSystem() throws {
        let box = BoxRecord(formatVersion: 3, name: "b1", image: "deb", macOSVersion: nil, macOSBuild: nil, guest: .linux, linux: Self.debian,
                            guestProtocol: 1, createdAt: Date(), cpuCount: 4, memoryBytes: 4 << 30, macAddress: "", userName: "agent",
                            imageCreatedAt: Date(timeIntervalSince1970: 1_800_000_000), imageRevision: 0)
        #expect(box.effectiveGuest == .linux)
        #expect(box.systemBuild == "Debian 13")
        #expect(box.needs(image: Self.linuxRecord()).isEmpty)
        var updated = Self.linuxRecord()
        updated.revision = 1
        #expect(box.needs(image: updated) == [BoxNeed(kind: .recreate, reason: .imageUpdated, macOSBuild: nil, system: "Debian 13")])
        // A box's record round trips with its system, and without a macOS key.
        let data = try SessionStore.encoder.encode(box)
        #expect(!String(decoding: data, as: UTF8.self).contains("macOS"))
        #expect(try SessionStore.decoder.decode(BoxRecord.self, from: data).linux == Self.debian)
    }

    @Test func macOSUpdatesAreNotOfferedToALinuxImage() {
        let newest = NewestMacOS(version: "27.1", build: "26B100", checkedAt: Date())
        #expect(newest.update(for: Self.linuxRecord()) == nil)
        var mac = ImageStoreTests.record("dev", state: .ready)
        mac.macOSVersion = "27.0"
        #expect(newest.update(for: mac)?.build == "26B100")
    }

    // MARK: - What a Linux record is not asked

    @Test func aBoxIsNotMadeFromALinuxImageYet() throws {
        let scratch = try Scratch()
        let root = scratch.root.appendingPathComponent("store", isDirectory: true)
        let images = ImageStore(root: root)
        let boxes = BoxStore(root: root, builtInPacks: TestPacks.repository)
        let (image, lock) = try images.create(Self.linuxRecord())
        lock.release()
        try Data("disk".utf8).write(to: image.diskURL)
        #expect(throws: AgentVMError.notForThisGuest("image deb runs Linux, and this agent-vm cannot run Linux guests yet")) {
            _ = try boxes.create(name: "b1", from: image, imageStore: images)
        }
        // Nothing was claimed by the refusal.
        #expect(try boxes.list().boxes.isEmpty)
    }

    @Test func whatHasNoMeaningForLinuxSaysSo() {
        let box = BoxRecord(formatVersion: 3, name: "work", image: "deb", macOSVersion: nil, macOSBuild: nil, guest: .linux, linux: Self.debian,
                            guestProtocol: 1, createdAt: Date(), cpuCount: 4, memoryBytes: 4 << 30, macAddress: "", userName: "agent")
        #expect(throws: AgentVMError.notForThisGuest("box work runs Linux, which has no screen to show; open a shell with `agent-vm box shell <box>`")) {
            try box.requireScreen()
        }
        #expect(throws: AgentVMError.notForThisGuest("box send is not there for Linux boxes yet; put the file in the shared project folder, or pipe it: `agent-vm exec --box work -- sh -c 'cat > f' < f`")) {
            try box.requireSend()
        }
        // A macOS box is asked nothing.
        var mac = box
        mac.guest = nil
        #expect(throws: Never.self) {
            try mac.requireScreen()
            try mac.requireSend()
        }
        // The message is the whole text: no prefix that would be about something else.
        #expect("\(LinuxGuest.noFullDiskAccess(image: "deb"))" == "image deb runs Linux: there is no Full Disk Access to grant")
    }
}
