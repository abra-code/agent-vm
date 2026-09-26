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
    let images: ImageStore
    let boxes: BoxStore
    let image: GoldenImage

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
