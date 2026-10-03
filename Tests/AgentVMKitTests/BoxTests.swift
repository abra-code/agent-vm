// Tests/AgentVMKitTests/BoxTests.swift
//
// Box store, folder locks and the supervisor's control socket. Running a box needs the signed
// binary and a real image; that is covered end to end (see the commit note's Verification).

import Darwin
import Foundation
import Testing
@testable import AgentVMKit
import Virtualization

/// A scratch store with a fake "ready" image (small files standing in for the disk).
final class BoxScratch {
    let scratch: Scratch
    var images: ImageStore
    var boxes: BoxStore
    var image: GoldenImage

    init(state: ImageRecord.State = .ready) throws {
        scratch = try Scratch()
        let root = scratch.root.appendingPathComponent("store", isDirectory: true)
        images = ImageStore(root: root)
        boxes = BoxStore(root: root, builtInPacks: TestPacks.repository)
        let (created, lock) = try images.create(ImageStoreTests.record("dev", state: state))
        lock.release()
        for (url, text) in [(created.diskURL, "disk"), (created.auxiliaryStorageURL, "aux"),
                            (created.hardwareModelURL, "hw"), (created.machineIdentifierURL, "id")] {
            try Data(text.utf8).write(to: url)
        }
        try ImageBuilder.writePassword("secret", to: created.passwordURL)
        image = created
    }
}

@Suite struct BoxStoreTests {
    @Test func createClonesTheImageWithANewIdentity() throws {
        let fixture = try BoxScratch()
        let box = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images)
        #expect(box.record.image == "dev")
        #expect(box.record.userName == "agent")
        #expect(box.record.cpuCount == 4)
        #expect(box.record.macAddress != fixture.image.record.macAddress)
        #expect(try String(contentsOf: box.diskURL, encoding: .utf8) == "disk")
        #expect(try String(contentsOf: box.auxiliaryStorageURL, encoding: .utf8) == "aux")
        #expect(try Data(contentsOf: box.machineIdentifierURL) != Data("id".utf8))
        #expect(try FileSystem.status(box.passwordURL.path).st_mode & 0o777 == 0o600)
        #expect(try fixture.boxes.box(named: "b1").record == box.record)
        #expect(!box.isRunning)
    }

    /// A record's sizes are added to and rounded all over; one no machine could have is a
    /// damaged record, not a number to do sums with.
    @Test func recordsWithImpossibleNumbersAreDamagedRecords() throws {
        let fixture = try BoxScratch()
        let box = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images)
        func rewrite(_ url: URL, _ key: String, _ value: String) throws {
            let text = try String(contentsOf: url, encoding: .utf8)
            let changed = text.replacingOccurrences(of: #""\#(key)" : [0-9]+"#, with: "\"\(key)\" : \(value)", options: .regularExpression)
            #expect(changed != text)
            try Data(changed.utf8).write(to: url)
        }
        let boxRecord = box.directory.appendingPathComponent(BoxStore.recordName)
        let imageRecord = fixture.image.directory.appendingPathComponent(ImageStore.recordName)
        let good = (try Data(contentsOf: boxRecord), try Data(contentsOf: imageRecord))
        for (key, value) in [("memoryBytes", "18446744073709551615"), ("memoryBytes", "0"), ("cpuCount", "0"), ("cpuCount", "100000")] {
            try rewrite(boxRecord, key, value)
            try rewrite(imageRecord, key, value)
            #expect(throws: AgentVMError.self) { try fixture.boxes.box(named: "b1") }
            #expect(throws: AgentVMError.self) { try fixture.images.image(named: "dev") }
            try good.0.write(to: boxRecord)
            try good.1.write(to: imageRecord)
        }
        try rewrite(imageRecord, "diskBytes", "18446744073709551615")
        #expect(throws: AgentVMError.self) { try fixture.images.image(named: "dev") }
        try good.1.write(to: imageRecord)
        // The image's revision is counted up and its durations are shown as whole seconds.
        for extra in [#""revision" : 9223372036854775807"#, #""revision" : -1"#, #""updateSeconds" : 1e300"#, #""installSeconds" : -1"#] {
            let text = try #require(String(data: good.1, encoding: .utf8))
            let changed = text.replacingOccurrences(of: #""cpuCount" :"#, with: "\(extra),\n  \"cpuCount\" :")
            #expect(changed != text)
            try Data(changed.utf8).write(to: imageRecord)
            #expect(throws: AgentVMError.self) { try fixture.images.image(named: "dev") }
        }
        try Data(try #require(String(data: good.1, encoding: .utf8)).replacingOccurrences(of: #""cpuCount" :"#, with: "\"revision\" : 3,\n  \"updateSeconds\" : 41.5,\n  \"cpuCount\" :").utf8).write(to: imageRecord)
        #expect(try fixture.images.image(named: "dev").record.revision == 3)
        try good.1.write(to: imageRecord)
        #expect(try fixture.boxes.box(named: "b1").record == box.record)
        #expect(BoxStore.createCommand(name: "b1", image: "dev", record: box.record, network: BoxNetwork(mode: .off, allow: [])).contains("--memory-gb 8"))
    }

    @Test func resourcesCanBeOverridden() throws {
        let fixture = try BoxScratch()
        let box = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images, cpuCount: 2, memoryBytes: 4 << 30)
        #expect(box.record.cpuCount == 2)
        #expect(box.record.memoryBytes == 4 << 30)
    }

    @Test func onlyReadyAndIdleImagesAreCloned() throws {
        let unfinished = try BoxScratch(state: .provisioning)
        #expect(throws: AgentVMError.wrongImageState(name: "dev", state: "provisioning", operation: "create a box from")) {
            _ = try unfinished.boxes.create(name: "b1", from: unfinished.image, imageStore: unfinished.images)
        }

        let fixture = try BoxScratch()
        let lock = try #require(try fixture.images.tryLock(fixture.image))
        #expect(throws: AgentVMError.imageBusy("dev")) {
            _ = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images)
        }
        lock.release()
        _ = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images)
        #expect(throws: AgentVMError.boxExists("b1")) {
            _ = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images)
        }
        #expect(throws: AgentVMError.invalidBoxName("../b")) {
            _ = try fixture.boxes.create(name: "../b", from: fixture.image, imageStore: fixture.images)
        }
    }

    @Test func aRunningBoxCannotBeDeleted() throws {
        let fixture = try BoxScratch()
        let box = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images)
        let lock = try #require(try FolderLock.tryAcquire(box.lockPath))
        #expect(box.isRunning)
        #expect(throws: AgentVMError.boxRunning("b1")) {
            try fixture.boxes.delete(named: "b1")
        }
        lock.release()
        #expect(!box.isRunning)
        try fixture.boxes.delete(named: "b1")
        #expect(throws: AgentVMError.boxNotFound("b1")) {
            _ = try fixture.boxes.box(named: "b1")
        }
        // The image is untouched.
        #expect(try String(contentsOf: fixture.image.diskURL, encoding: .utf8) == "disk")
    }

    @Test func listSortsAndReportsDamagedRecords() throws {
        let fixture = try BoxScratch()
        #expect(try fixture.boxes.list().boxes.isEmpty)
        for name in ["zz", "aa"] {
            _ = try fixture.boxes.create(name: name, from: fixture.image, imageStore: fixture.images)
        }
        let damaged = fixture.boxes.boxesDirectory.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: damaged, withIntermediateDirectories: true)
        let (boxes, problems) = try fixture.boxes.list()
        #expect(boxes.map(\.name) == ["aa", "zz"])
        #expect(problems.count == 1)
    }

    /// box recreate: a fresh clone and identity with the box's own settings; the log goes.
    @Test func recreateKeepsTheSettingsAndStartsAfresh() throws {
        let fixture = try BoxScratch()
        let network = BoxNetwork(mode: .allowlist, allow: ["*.example.com", "pack:github"])
        let old = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images, cpuCount: 2,
                                           memoryBytes: 3 << 30, network: network, disposable: true)
        try Data("written in the box".utf8).write(to: old.diskURL)
        try Data("{}\n".utf8).write(to: old.execLogURL)
        let identity = try Data(contentsOf: old.machineIdentifierURL)
        let box = try fixture.boxes.recreate(name: "b1", from: fixture.image, imageStore: fixture.images)
        #expect(box.record.cpuCount == 2 && box.record.memoryBytes == 3 << 30)
        #expect(box.record.network == network && box.record.disposable == true)
        #expect(box.record.macAddress != old.record.macAddress)
        #expect(try Data(contentsOf: box.machineIdentifierURL) != identity)
        #expect(try String(contentsOf: box.diskURL, encoding: .utf8) == "disk")
        #expect(!FileManager.default.fileExists(atPath: box.execLogURL.path))
        #expect(try fixture.boxes.box(named: "b1").record == box.record)
    }

    /// box set: a stopped box takes other CPUs and memory and keeps everything else; a running
    /// one is refused and unchanged.
    @Test func aStoppedBoxTakesAnotherSize() throws {
        let fixture = try BoxScratch()
        let made = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images, cpuCount: 2, memoryBytes: 3 << 30)
        try Data("written in the box".utf8).write(to: made.diskURL)
        var box = try fixture.boxes.resize(named: "b1", memoryBytes: 5 << 30)
        #expect(box.record.cpuCount == 2 && box.record.memoryBytes == 5 << 30)
        box = try fixture.boxes.resize(named: "b1", cpuCount: 1)
        #expect(box.record.cpuCount == 1 && box.record.memoryBytes == 5 << 30)
        var expected = made.record
        expected.cpuCount = 1
        expected.memoryBytes = 5 << 30
        #expect(try fixture.boxes.box(named: "b1").record == expected)
        #expect(try String(contentsOf: box.diskURL, encoding: .utf8) == "written in the box")
        // What a supervisor does once it holds the lock: a box read before the change is read again.
        #expect(try BoxStore.reread(made).record == expected)
        // Nothing asked: nothing changed.
        #expect(try fixture.boxes.resize(named: "b1").record == expected)

        let lock = try #require(try FolderLock.tryAcquire(box.lockPath))
        #expect(throws: AgentVMError.boxRunning("b1")) {
            _ = try fixture.boxes.resize(named: "b1", memoryBytes: 2 << 30)
        }
        lock.release()
        #expect(try fixture.boxes.box(named: "b1").record == expected)
        #expect(throws: AgentVMError.boxNotFound("nope")) {
            _ = try fixture.boxes.resize(named: "nope", cpuCount: 2)
        }
    }

    /// More than this Mac can give a machine is refused when it is asked for, by create and by
    /// set, and nothing is made or changed.
    @Test func aSizeThisMacCannotRunIsRefused() throws {
        let fixture = try BoxScratch()
        let tooMuch = VZVirtualMachineConfiguration.maximumAllowedMemorySize + (1 << 30)
        #expect(throws: AgentVMError.self) {
            _ = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images, memoryBytes: tooMuch)
        }
        #expect(throws: AgentVMError.boxNotFound("b1")) {
            _ = try fixture.boxes.box(named: "b1")
        }
        let box = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images)
        #expect(throws: AgentVMError.self) {
            _ = try fixture.boxes.resize(named: "b1", memoryBytes: tooMuch)
        }
        #expect(throws: AgentVMError.self) {
            _ = try fixture.boxes.resize(named: "b1", cpuCount: VZVirtualMachineConfiguration.maximumAllowedCPUCount + 1)
        }
        #expect(try fixture.boxes.box(named: "b1").record == box.record)

        #expect(MachineSize.problem(cpuCount: nil, memoryBytes: nil, maximumCPUs: 8, maximumMemoryBytes: 16 << 30) == nil)
        #expect(MachineSize.problem(cpuCount: 8, memoryBytes: 16 << 30, maximumCPUs: 8, maximumMemoryBytes: 16 << 30) == nil)
        #expect(MachineSize.problem(cpuCount: 9, memoryBytes: nil, maximumCPUs: 8, maximumMemoryBytes: 16 << 30)?.contains("9 CPUs") == true)
        #expect(MachineSize.problem(cpuCount: nil, memoryBytes: 17 << 30, maximumCPUs: 8, maximumMemoryBytes: 16 << 30)?.contains("17 GB") == true)
    }

    /// The start's warning: said when the boxes that run together leave the Mac less than its
    /// reserve, with the numbers; not before.
    @Test func boxesThatLeaveTheMacTooLittleMemoryAreSaid() throws {
        let host: UInt64 = 24 << 30
        #expect(MachineSize.memoryWarning(starting: 8 << 30, running: [], hostBytes: host) == nil)
        #expect(MachineSize.memoryWarning(starting: 8 << 30, running: [8 << 30], hostBytes: host) == nil)
        #expect(MachineSize.memoryWarning(starting: 18 << 30, running: [], hostBytes: host) == nil)
        let alone = try #require(MachineSize.memoryWarning(starting: 20 << 30, running: [], hostBytes: host))
        #expect(alone.hasPrefix("this box has 20 GB of this Mac's 24 GB"))
        let beside = try #require(MachineSize.memoryWarning(starting: 12 << 30, running: [8 << 30], hostBytes: host))
        #expect(beside.hasPrefix("with this box (12 GB) and 1 already running, boxes have 20 GB of this Mac's 24 GB"))
        // A Mac smaller than the reserve, and sums that do not fit a number.
        #expect(MachineSize.memoryWarning(starting: 4 << 30, running: [], hostBytes: 4 << 30) != nil)
        #expect(MachineSize.memoryWarning(starting: UInt64.max, running: [UInt64.max], hostBytes: host) != nil)
        #expect(MachineSize.gigabytes(3 << 30) == 3 && MachineSize.gigabytes((3 << 30) + 1) == 4)

        // What a start adds to: the boxes whose lock is held, without the one that starts.
        let fixture = try BoxScratch()
        let first = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images, memoryBytes: 3 << 30)
        _ = try fixture.boxes.create(name: "b2", from: fixture.image, imageStore: fixture.images, memoryBytes: 2 << 30)
        #expect(fixture.boxes.runningMemory(except: "b2").isEmpty)
        let lock = try #require(try FolderLock.tryAcquire(first.lockPath))
        #expect(fixture.boxes.runningMemory(except: "b2") == [3 << 30])
        #expect(fixture.boxes.runningMemory(except: "b1").isEmpty)
        lock.release()
    }

    /// Refusals come before the delete and leave the box as it was.
    @Test func recreateRefusesBeforeDeleting() throws {
        let fixture = try BoxScratch()
        let box = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images)
        let lock = try #require(try FolderLock.tryAcquire(box.lockPath))
        #expect(throws: AgentVMError.boxRunning("b1")) {
            _ = try fixture.boxes.recreate(name: "b1", from: fixture.image, imageStore: fixture.images)
        }
        lock.release()
        let busy = try #require(try fixture.images.tryLock(fixture.image))
        #expect(throws: AgentVMError.imageBusy("dev")) {
            _ = try fixture.boxes.recreate(name: "b1", from: fixture.image, imageStore: fixture.images)
        }
        busy.release()
        let unfinished = try fixture.images.update(fixture.image) { $0.state = .provisioning }
        #expect(throws: AgentVMError.self) {
            _ = try fixture.boxes.recreate(name: "b1", from: unfinished, imageStore: fixture.images)
        }
        #expect(try fixture.boxes.box(named: "b1").record == box.record)
    }

    /// A disposable box is not recreated while a collection runs: it could take the new box
    /// for the old one's garbage.
    @Test func recreateWaitsForACollection() throws {
        let fixture = try BoxScratch()
        let box = try fixture.boxes.create(name: "d1", from: fixture.image, imageStore: fixture.images, disposable: true)
        let collecting = try #require(try FolderLock.tryAcquire(fixture.boxes.boxesDirectory.appendingPathComponent(BoxStore.gcLockName).path))
        #expect(throws: AgentVMError.self) {
            _ = try fixture.boxes.recreate(name: "d1", from: fixture.image, imageStore: fixture.images, collectionPatience: .milliseconds(100))
        }
        #expect(try fixture.boxes.box(named: "d1").record == box.record)
        collecting.release()
        let recreated = try fixture.boxes.recreate(name: "d1", from: fixture.image, imageStore: fixture.images)
        #expect(recreated.record.disposable == true)
    }

    /// A box records when its image was built and how often it was updated; once `image
    /// update` changed the image, or another was built under its name, the box needs
    /// recreating. A box from before that was recorded says nothing.
    @Test func aBoxNeedsRecreatingAfterItsImageWasUpdatedOrRebuilt() throws {
        let fixture = try BoxScratch()
        let box = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images)
        #expect(box.record.imageCreatedAt == fixture.image.record.createdAt)
        #expect(box.record.imageRevision == 0)
        #expect(box.record.needs(image: fixture.image.record).isEmpty)

        let updated = try fixture.images.update(fixture.image) {
            $0.revision = 1
            $0.macOSBuild = "26A434"
        }
        #expect(box.record.needs(image: updated.record) == [BoxNeed(kind: .recreate, reason: .imageUpdated, macOSBuild: "26A434")])
        let recreated = try fixture.boxes.recreate(name: "b1", from: updated, imageStore: fixture.images)
        #expect(recreated.record.imageRevision == 1)
        #expect(recreated.record.needs(image: updated.record).isEmpty)

        var rebuilt = updated.record
        rebuilt.createdAt = rebuilt.createdAt.addingTimeInterval(60)
        rebuilt.revision = nil
        #expect(recreated.record.needs(image: rebuilt) == [BoxNeed(kind: .recreate, reason: .imageRebuilt, macOSBuild: "26A434")])

        var old = recreated.record
        old.imageCreatedAt = nil
        old.imageRevision = nil
        #expect(old.needs(image: rebuilt).isEmpty)
        // Its JSON says why.
        let json = String(decoding: try SessionStore.encoder.encode(box.record.needs(image: updated.record)), as: UTF8.self)
        #expect(json.contains("\"reason\" : \"image-updated\""))
    }

    /// A box records the image's guest daemon; once the image's changes (image update-guest),
    /// the box needs recreating, and recreating it takes the new one.
    @Test func aBoxNeedsRecreatingAfterItsImagesGuestChanged() throws {
        let fixture = try BoxScratch()
        let image = try fixture.images.update(fixture.image) {
            $0.guestVersion = "0.4.2"
            $0.guestDigest = "aaaa"
        }
        let box = try fixture.boxes.create(name: "b1", from: image, imageStore: fixture.images)
        #expect(box.record.guestVersion == "0.4.2")
        #expect(box.record.guestDigest == "aaaa")
        #expect(box.record.needs(image: image.record).isEmpty)

        let updated = try fixture.images.update(image) {
            $0.guestVersion = "0.4.3"
            $0.guestDigest = "bbbb"
        }
        #expect(box.record.needs(image: updated.record) == [BoxNeed(kind: .recreate, guestVersion: "0.4.3", reason: .guestUpdate)])
        // Nothing to compare: the image is gone, or not ready, or either digest unknown.
        #expect(box.record.needs(image: nil).isEmpty)
        var building = updated.record
        building.state = .provisioning
        #expect(box.record.needs(image: building).isEmpty)
        var unknown = box.record
        unknown.guestDigest = nil
        #expect(unknown.needs(image: updated.record).isEmpty)

        let recreated = try fixture.boxes.recreate(name: "b1", from: updated, imageStore: fixture.images)
        #expect(recreated.record.guestDigest == "bbbb")
        #expect(recreated.record.needs(image: updated.record).isEmpty)

        // Given the image as it was before an update that ended since, create records the
        // image as it is under its lock, which is what it clones.
        let stale = try fixture.boxes.create(name: "b2", from: image, imageStore: fixture.images)
        #expect(stale.record.guestDigest == "bbbb")
    }

    /// The command given when the box was deleted but could not be created again.
    @Test func theCreateCommandReadsBackInAShell() {
        let record = BoxRecord(formatVersion: 1, name: "b1", image: "dev", macOSVersion: "27.0", macOSBuild: "26A428", guestProtocol: 1,
                               createdAt: Date(), cpuCount: 4, memoryBytes: 8 << 30, macAddress: "", userName: "agent",
                               network: nil, disposable: true)
        let network = BoxNetwork(mode: .allowlist, allow: ["*.example.com", "github.com:22", "it's"])
        #expect(BoxStore.createCommand(name: "b1", image: "dev", record: record, network: network)
                == "agent-vm box create b1 --image dev --cpus 4 --memory-gb 8 --net allowlist --allow '*.example.com' --allow github.com:22 --allow 'it'\\''s' --disposable")
    }

    /// A damaged box.json is named as a box record, not an image record.
    @Test func aDamagedRecordIsABoxRecord() throws {
        let fixture = try BoxScratch()
        let box = try fixture.boxes.create(name: "dmg", from: fixture.image, imageStore: fixture.images)
        try Data("{".utf8).write(to: box.directory.appendingPathComponent(BoxStore.recordName))
        do {
            _ = try fixture.boxes.box(named: "dmg")
            Issue.record("a damaged record was read")
        } catch {
            #expect("\(error)".hasPrefix("box record "), "\(error)")
            #expect("\(error)".contains("box.json is unusable"), "\(error)")
        }
    }
}

@Suite struct FolderLockTests {
    @Test func oneHolderAtATime() throws {
        let scratch = try Scratch()
        let path = scratch.root.appendingPathComponent(".lock").path
        #expect(!FolderLock.isHeld(path))
        let first = try #require(try FolderLock.tryAcquire(path))
        #expect(try FolderLock.tryAcquire(path) == nil)
        #expect(FolderLock.isHeld(path))
        first.release()
        #expect(!FolderLock.isHeld(path))
    }

    /// A holder that lets go within the patience (an isHeld test) does not make a taker fail.
    @Test func patienceOutlastsABriefHolder() throws {
        let scratch = try Scratch()
        let path = scratch.root.appendingPathComponent(".lock").path
        let brief = try #require(try FolderLock.tryAcquire(path))
        // A thread of its own: under a full parallel test run, a global queue can be kept
        // busy for longer than the patience.
        Thread.detachNewThread {
            usleep(50_000)
            brief.release()
        }
        let taken = try #require(try FolderLock.tryAcquire(path, patience: .seconds(2)))
        let clock = ContinuousClock()
        let began = clock.now
        #expect(try FolderLock.tryAcquire(path, patience: .milliseconds(100)) == nil)
        #expect(clock.now - began >= .milliseconds(100))
        taken.release()
    }
}

/// A stand-in supervisor: lends one end of a socket pair per open.
final class FakeHandler: ControlHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var releasedCount = 0
    private var stops = 0
    private var views: [Bool] = []
    private(set) var typed: [String] = []
    var ready = true
    /// The far ends of lent pairs, to check what the client received.
    private(set) var farEnds: [Int32] = []

    var released: Int {
        lock.lock()
        defer { lock.unlock() }
        return releasedCount
    }

    var stopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return stops
    }

    func controlStatus() -> ControlResponse {
        return ControlResponse(ok: true, state: ready ? .ready : .starting, guestVersion: "9.9.9", pid: getpid())
    }

    func controlOpenGuest(project: String?, readOnly: Bool) throws -> LentConnection {
        if let project {
            try controlShare(path: project, readOnly: readOnly)
        }
        guard ready else {
            throw AgentVMError.guestRefused("not ready")
        }
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw AgentVMError.system(operation: "socketpair", code: errno)
        }
        lock.lock()
        farEnds.append(pair[1])
        lock.unlock()
        let near = pair[0]
        return LentConnection(descriptor: near, release: { [self] in
            close(near)
            lock.lock()
            releasedCount += 1
            lock.unlock()
        })
    }

    func controlReload() throws {}

    private(set) var sharedPaths: [String] = []

    func controlShare(path: String, readOnly: Bool) throws {
        lock.lock()
        sharedPaths.append(path)
        lock.unlock()
    }

    var viewRequests: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return views
    }

    func controlView(interactive: Bool) throws {
        lock.lock()
        views.append(interactive)
        lock.unlock()
        throw AgentVMError.supervisorRefused("no screen in tests")
    }

    func controlSyncClock() throws -> Double {
        return 2.5
    }

    func controlType(text: String?) throws {
        lock.lock()
        typed.append(text ?? "<password>")
        lock.unlock()
        throw AgentVMError.supervisorRefused("no screen in tests")
    }

    func controlStop() {
        lock.lock()
        stops += 1
        lock.unlock()
    }
}

/// A short folder for sockets: the temporary folder's path is too long for a Unix socket.
final class ShortFolder {
    let path: String

    init() throws {
        var template = Array("/private/tmp/avm-XXXXXX".utf8CString)
        guard let created = mkdtemp(&template) else {
            throw AgentVMError.system(operation: "mkdtemp", code: errno)
        }
        path = String(cString: created)
    }

    deinit {
        try? FileSystem.removeTree(path)
    }
}

@Suite struct ControlChannelTests {
    func socketPath(_ folder: ShortFolder) -> String {
        return folder.path + "/control.sock"
    }

    @Test func statusAndStop() throws {
        let scratch = try ShortFolder()
        let handler = FakeHandler()
        let server = try ControlServer(path: socketPath(scratch), handler: handler)
        defer { server.close() }
        let status = try ControlClient.request(.status, path: socketPath(scratch))
        #expect(status == ControlResponse(ok: true, state: .ready, guestVersion: "9.9.9", pid: getpid()))
        let stop = try ControlClient.request(.stop, path: socketPath(scratch))
        #expect(stop.state == .stopping)
        #expect(handler.stopCount == 1)
    }

    /// sync-clock answers with the status and how far the guest's clock was off.
    @Test func syncClockReturnsTheOffset() throws {
        let scratch = try ShortFolder()
        let server = try ControlServer(path: socketPath(scratch), handler: FakeHandler())
        defer { server.close() }
        let response = try ControlClient.request(ControlRequest(op: .syncClock), path: socketPath(scratch))
        #expect(response.ok)
        #expect(response.clockOffset == 2.5)
    }

    /// A view request reaches the handler with its mode; the handler's refusal comes back.
    @Test func viewRequestsReachTheHandler() throws {
        let scratch = try ShortFolder()
        let handler = FakeHandler()
        let server = try ControlServer(path: socketPath(scratch), handler: handler)
        defer { server.close() }
        let response = try ControlClient.request(ControlRequest(op: .view, interactive: true), path: socketPath(scratch))
        #expect(!response.ok)
        #expect(response.error?.contains("no screen in tests") == true)
        #expect(handler.viewRequests == [true])
    }

    @Test func theSocketIsPrivateAndRemovedOnClose() throws {
        let scratch = try ShortFolder()
        let server = try ControlServer(path: socketPath(scratch), handler: FakeHandler())
        #expect(try FileSystem.status(socketPath(scratch)).st_mode & 0o777 == 0o600)
        server.close()
        #expect(!FileSystem.exists(socketPath(scratch)))
        #expect(throws: (any Error).self) {
            _ = try ControlClient.request(.status, path: socketPath(scratch))
        }
    }

    @Test func openPassesAWorkingDescriptorUntilTheClientCloses() throws {
        let scratch = try ShortFolder()
        let handler = FakeHandler()
        let server = try ControlServer(path: socketPath(scratch), handler: handler)
        defer { server.close() }
        let (control, guest, _) = try ControlClient.openGuest(path: socketPath(scratch))
        // What the client writes on the passed descriptor arrives at the far end.
        #expect(write(guest, "ping", 4) == 4)
        var buffer = [UInt8](repeating: 0, count: 4)
        let far = try #require(handler.farEnds.first)
        #expect(read(far, &buffer, 4) == 4)
        #expect(String(decoding: buffer, as: UTF8.self) == "ping")
        #expect(handler.released == 0)
        close(guest)
        close(control)
        var released = false
        for _ in 0..<50 where !released {
            released = handler.released == 1
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(released)
        close(far)
    }

    @Test func openIsRefusedWhileStarting() throws {
        let scratch = try ShortFolder()
        let handler = FakeHandler()
        handler.ready = false
        let server = try ControlServer(path: socketPath(scratch), handler: handler)
        defer { server.close() }
        #expect(throws: AgentVMError.self) {
            _ = try ControlClient.openGuest(path: socketPath(scratch))
        }
    }

    @Test func anotherVersionIsRefused() throws {
        let scratch = try ShortFolder()
        let server = try ControlServer(path: socketPath(scratch), handler: FakeHandler())
        defer { server.close() }
        let socket = try ControlChannel.connect(socketPath(scratch))
        defer { close(socket) }
        struct Future: Encodable { var v = 7; var op = "status" }
        try ControlChannel.send(Future(), over: socket)
        let (response, _) = try #require(try ControlChannel.receive(ControlResponse.self, from: socket))
        #expect(!response.ok)
        #expect(response.error?.contains("7") == true)
    }

    /// What no agent-vm sends: a length below zero or past the limit, text that is not a
    /// request, nothing but nesting, two messages in one write. Each gets a refusal and its
    /// connection is closed; the server goes on answering.
    @Test(.timeLimit(.minutes(1)))
    func messagesOfTheWrongShapeAreRefusedAndTheServerGoesOn() throws {
        let scratch = try ShortFolder()
        let handler = FakeHandler()
        let server = try ControlServer(path: socketPath(scratch), handler: handler)
        defer { server.close() }
        func framed(_ text: String) -> [UInt8] {
            return Int32(text.utf8.count).bigEndianBytes + Array(text.utf8)
        }
        let status = "{\"v\":\(ControlChannel.version),\"op\":\"status\"}"
        let stop = "{\"v\":\(ControlChannel.version),\"op\":\"stop\"}"
        let cases: [(String, [UInt8])] = [
            ("a length below zero", Int32(-1).bigEndianBytes),
            ("the smallest length", Int32.min.bigEndianBytes),
            ("a length past the limit", Int32(ControlChannel.maxMessage + 1).bigEndianBytes),
            ("the largest length", Int32.max.bigEndianBytes),
            ("not JSON", framed("status")),
            ("no operation", framed("{\"v\":\(ControlChannel.version)}")),
            ("an unknown operation", framed("{\"v\":\(ControlChannel.version),\"op\":\"format\"}")),
            ("nothing but nesting", framed(String(repeating: "[", count: 60_000))),
            ("nested objects", framed(String(repeating: "{\"a\":", count: 12_000))),
            ("two messages in one write", framed(status) + framed(stop)),
        ]
        for (name, bytes) in cases {
            let socket = try ControlChannel.connect(socketPath(scratch))
            defer { close(socket) }
            let written = bytes.withUnsafeBytes { write(socket, $0.baseAddress, $0.count) }
            #expect(written == bytes.count, "\(name)")
            let (response, _) = try #require(try ControlChannel.receive(ControlResponse.self, from: socket), "\(name)")
            #expect(!response.ok, "\(name)")
            // Nothing more comes: the connection is closed, not served further.
            #expect(try ControlChannel.receive(ControlResponse.self, from: socket) == nil, "\(name)")
        }
        // The second message of the pair was not acted on.
        #expect(handler.stopCount == 0)
        #expect(try ControlClient.request(.status, path: socketPath(scratch)).ok)
    }

    /// Connections that say nothing, half a length, or half a message, and stay: each holds
    /// one thread of the server and nothing else, so a request beside them is answered.
    @Test(.timeLimit(.minutes(1)))
    func stalledConnectionsDoNotStopTheServer() throws {
        let scratch = try ShortFolder()
        let server = try ControlServer(path: socketPath(scratch), handler: FakeHandler())
        defer { server.close() }
        // 60, not hundreds: both ends of each are descriptors of this test process.
        var stalled: [Int32] = []
        defer { stalled.forEach { close($0) } }
        for index in 0..<60 {
            // The server's queue of connections not yet accepted is short: one made while it
            // is full is refused, and made again.
            var connected = try? ControlChannel.connect(socketPath(scratch))
            for _ in 0..<200 where connected == nil {
                usleep(10_000)
                connected = try? ControlChannel.connect(socketPath(scratch))
            }
            let socket = try #require(connected)
            stalled.append(socket)
            let bytes: [UInt8]
            switch index % 3 {
            case 0: bytes = []
            case 1: bytes = [0, 0]
            default: bytes = Int32(40).bigEndianBytes + Array("{\"v\":".utf8)
            }
            #expect(bytes.withUnsafeBytes { write(socket, $0.baseAddress, $0.count) } == bytes.count)
        }
        #expect(try ControlClient.request(.status, path: socketPath(scratch)).ok)
        // They are let go when their clients close, and the server still answers.
        stalled.forEach { close($0) }
        stalled = []
        #expect(try ControlClient.request(.status, path: socketPath(scratch)).ok)
    }

    /// The server serves only its own user. Another user cannot be played here, so the check
    /// is asked about a user this process is not.
    @Test func thePeerMustBeTheSameUser() throws {
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer {
            close(pair[0])
            close(pair[1])
        }
        #expect(ControlChannel.peerIsSameUser(pair[0]))
        #expect(ControlChannel.peerIsSameUser(pair[0], expected: geteuid()))
        #expect(!ControlChannel.peerIsSameUser(pair[0], expected: geteuid() + 1))
        #expect(!ControlChannel.peerIsSameUser(pair[0], expected: 0) || geteuid() == 0)
        // Not a socket at all: no peer, no service.
        let file = open("/dev/null", O_RDONLY)
        defer { close(file) }
        #expect(!ControlChannel.peerIsSameUser(file))
    }

    /// More descriptors than the receive buffer holds: the kernel still reports all of them in
    /// cmsg_len, so a count taken from it alone would read past the buffer and close whatever
    /// numbers it found there.
    @Test func tooManyPassedDescriptorsAreNotReadPastTheBuffer() throws {
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer {
            close(pair[0])
            close(pair[1])
        }
        let sentinel = open("/dev/null", O_RDONLY)
        defer { close(sentinel) }
        let passed = (0..<6).map { _ in open("/dev/null", O_RDONLY) }
        defer { passed.forEach { close($0) } }

        let json = try JSONEncoder().encode(ControlResponse(ok: true))
        var bytes = Int32(json.count).bigEndianBytes
        bytes.append(contentsOf: json)
        let controlLength = MemoryLayout<cmsghdr>.size + MemoryLayout<Int32>.size * passed.count
        let control = UnsafeMutableRawPointer.allocate(byteCount: controlLength, alignment: MemoryLayout<cmsghdr>.alignment)
        defer { control.deallocate() }
        let header = control.assumingMemoryBound(to: cmsghdr.self)
        header.pointee.cmsg_len = socklen_t(controlLength)
        header.pointee.cmsg_level = SOL_SOCKET
        header.pointee.cmsg_type = SCM_RIGHTS
        for (index, descriptor) in passed.enumerated() {
            (control + MemoryLayout<cmsghdr>.size + index * MemoryLayout<Int32>.size).storeBytes(of: descriptor, as: Int32.self)
        }
        let sent = bytes.withUnsafeMutableBytes { raw -> Int in
            var vector = iovec(iov_base: raw.baseAddress, iov_len: raw.count)
            return withUnsafeMutablePointer(to: &vector) { vectorPointer in
                var message = msghdr()
                message.msg_iov = vectorPointer
                message.msg_iovlen = 1
                message.msg_control = control
                message.msg_controllen = socklen_t(controlLength)
                return sendmsg(pair[0], &message, 0)
            }
        }
        #expect(sent == bytes.count)

        let (response, received) = try #require(try ControlChannel.receive(ControlResponse.self, from: pair[1]))
        #expect(response.ok)
        let descriptor = try #require(received)
        #expect(fcntl(descriptor, F_GETFD) >= 0)
        close(descriptor)
        #expect(fcntl(sentinel, F_GETFD) >= 0)
    }

    @Test func tooLongASocketPathIsExplained() throws {
        let path = "/tmp/" + String(repeating: "x", count: 120) + "/control.sock"
        #expect(throws: (any Error).self) {
            _ = try ControlChannel.listen(path)
        }
    }
}

@Suite struct ProjectShareTests {
    @Test func theAutomountTagIsApples() {
        #expect(ProjectShare.tag == VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
    }

    @Test func projectsAreMountedOnTheirParent() {
        let mount = ProjectShare.mountRequests("/Users/me/src/app")
        #expect(mount.map(\.argv) == [["/bin/mkdir", "-p", "/Users/me/src"], ["/sbin/mount_virtiofs", ProjectShare.tag, "/Users/me/src"]])
        #expect(mount.allSatisfy { $0.user == "root" })
        let unmount = ProjectShare.unmountRequest("/Users/me/src/app")
        #expect(unmount.argv?.first == "/bin/sh" && unmount.argv?.last == "/Users/me/src" && unmount.user == "root")
        #expect(ProjectShare.parentContentsRequest("/Users/me/src/app").argv?[1] == "/Users/me/src")
    }

    @Test func sessionsRefuseAliasesOfTheHomeFolder() throws {
        let scratch = try Scratch()
        let home = try FileSystem.canonicalPath(NSHomeDirectory())
        for alias in ["/System/Volumes/Data" + home, "/System/Volumes/Data" + (home as NSString).deletingLastPathComponent] where FileManager.default.fileExists(atPath: alias) {
            #expect(throws: AgentVMError.self, "\(alias)") {
                _ = try scratch.store.validatedProject(alias)
            }
        }
    }

    @Test func sensitiveFoldersAreNotShared() throws {
        let scratch = try Scratch()
        let store = scratch.root.appendingPathComponent("store")
        #expect(try ProjectShare.validated(scratch.project.path, storeRoot: store) == scratch.project.path)
        let home = NSHomeDirectory()
        for folder in ["\(home)/Library/Caches", "\(home)/.Trash", home, "/"] where FileManager.default.fileExists(atPath: folder) {
            #expect(throws: AgentVMError.self, "\(folder)") {
                _ = try ProjectShare.validated(folder, storeRoot: store)
            }
        }
        // Other names realpath keeps for the same folders are recognized too.
        for folder in ["/System/Volumes/Data\(home)/Library/Caches", "/System/Volumes/Data\(home)", "/.nofollow\(home)/Library"]
            where FileManager.default.fileExists(atPath: folder) {
            #expect(throws: AgentVMError.self, "\(folder)") {
                _ = try ProjectShare.validated(folder, storeRoot: store)
            }
        }
        // Directly in /: nothing to mount the share on.
        #expect(throws: AgentVMError.self) {
            _ = try ProjectShare.validated("/Applications", storeRoot: store)
        }
    }

    @Test func theControlSocketCarriesShareRequests() throws {
        let folder = try ShortFolder()
        let handler = FakeHandler()
        let server = try ControlServer(path: folder.path + "/control.sock", handler: handler)
        defer { server.close() }
        let response = try ControlClient.request(ControlRequest(op: .share, path: "/Users/me/src/app", readOnly: true), path: folder.path + "/control.sock")
        #expect(response.ok)
        #expect(handler.sharedPaths == ["/Users/me/src/app"])
        let missing = try ControlClient.request(ControlRequest(op: .share), path: folder.path + "/control.sock")
        #expect(!missing.ok)

        // An exec's project travels with its open request: one step on the supervisor.
        let (control, guest, _) = try ControlClient.openGuest(path: folder.path + "/control.sock", project: "/Users/me/src/other", readOnly: false)
        #expect(handler.sharedPaths == ["/Users/me/src/app", "/Users/me/src/other"])
        close(guest)
        close(control)
    }
}

@Suite struct LastBootTests {
    @Test func theLastReadyLineCounts() {
        let log = """
            2026-09-27T19:04:46Z Starting box b (4 CPUs, 4 GB, image dev, network allowlist)
            2026-09-27T19:05:12Z Ready in 26 s: agent-vm-guest 0.2.18
            2026-09-27T19:26:14Z Starting box b (4 CPUs, 4 GB, image dev, network allowlist)
            2026-09-27T19:26:43Z Ready in 29 s: agent-vm-guest 0.2.18
            2026-09-27T19:26:45Z Shared /Users/me/src/app
            """
        #expect(BoxLauncher.lastBootSeconds(inLog: log) == 29)
        #expect(BoxLauncher.lastBootSeconds(inLog: "2026-09-27T19:04:46Z Starting box b\n") == nil)
        #expect(BoxLauncher.lastBootSeconds(inLog: "") == nil)
        // Not a boot line: no number, or no " s" after it.
        #expect(BoxLauncher.lastBootSeconds(inLog: "Ready in no time\nReady in 12 minutes\n") == nil)
    }
}
