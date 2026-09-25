// Tests/AgentVMKitTests/DisposableBoxTests.swift
//
// Disposable boxes and the owner lease: which stopped boxes `box gc` deletes (and never a
// running one, or one about to start), and the watch that stops a box when its owner exits.

import Darwin
import Foundation
import Testing
@testable import AgentVMKit

@Suite struct DisposableBoxTests {
    @Test func theRecordSaysDisposable() throws {
        let fixture = try BoxScratch()
        let kept = try fixture.boxes.create(name: "kept", from: fixture.image, imageStore: fixture.images)
        let once = try fixture.boxes.create(name: "once", from: fixture.image, imageStore: fixture.images, disposable: true)
        #expect(kept.record.disposable == nil)
        // A tombstone counts only in a disposable box.
        try Data("stopped\n".utf8).write(to: kept.tombstoneURL)
        #expect(!kept.isTombstoned)
        #expect(try fixture.boxes.box(named: "once").record.disposable == true)
        #expect(BoxStatus.of(once).disposable == true)
        #expect(BoxStatus.of(kept).disposable == nil)
    }

    @Test func gcDeletesStoppedDisposableBoxesOnly() throws {
        let fixture = try BoxScratch()
        let stopped = try fixture.boxes.create(name: "stopped", from: fixture.image, imageStore: fixture.images, disposable: true)
        try Data("stopped\n".utf8).write(to: stopped.tombstoneURL)
        _ = try fixture.boxes.create(name: "fresh", from: fixture.image, imageStore: fixture.images, disposable: true)
        let kept = try fixture.boxes.create(name: "kept", from: fixture.image, imageStore: fixture.images)
        // A tombstone in a box that is not disposable means nothing.
        try Data("stopped\n".utf8).write(to: kept.tombstoneURL)
        let running = try fixture.boxes.create(name: "running", from: fixture.image, imageStore: fixture.images, disposable: true)
        try Data("stopped\n".utf8).write(to: running.tombstoneURL)
        let lock = try #require(try FolderLock.tryAcquire(running.lockPath))
        defer { lock.release() }

        let (deleted, problems) = fixture.boxes.collectGarbage()
        #expect(deleted == ["stopped"])
        #expect(problems.isEmpty)
        #expect(try fixture.boxes.list().boxes.map(\.name) == ["fresh", "kept", "running"])
    }

    /// A disposable box never started (or whose supervisor died) goes once it is old enough;
    /// a younger one may be about to start, and `except` spares the one being started.
    @Test func oldDisposableBoxesWithoutATombstoneGoToo() throws {
        let fixture = try BoxScratch()
        _ = try fixture.boxes.create(name: "a", from: fixture.image, imageStore: fixture.images, disposable: true)
        _ = try fixture.boxes.create(name: "b", from: fixture.image, imageStore: fixture.images, disposable: true)
        #expect(fixture.boxes.collectGarbage().deleted.isEmpty)
        let later = Date().addingTimeInterval(BoxStore.unstartedDisposableAge + 1)
        #expect(fixture.boxes.collectGarbage(now: later, except: "b").deleted == ["a"])
        #expect(fixture.boxes.collectGarbage(now: later).deleted == ["b"])
    }

    @Test func theOwnerWatchFiresWhenTheOwnerExits() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        let fired = Flag()
        let watch = OwnerWatch(pid: process.processIdentifier, queue: .global()) { fired.set() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!fired.value)
        process.terminate()
        process.waitUntilExit()
        for _ in 0..<50 where !fired.value {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(fired.value)
        withExtendedLifetime(watch) {}
    }

    /// An owner already gone: the watch fires at once.
    @Test func anOwnerAlreadyGoneFiresAtOnce() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        let fired = Flag()
        let watch = OwnerWatch(pid: process.processIdentifier, queue: .global()) { fired.set() }
        for _ in 0..<50 where !fired.value {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(fired.value)
        withExtendedLifetime(watch) {}
    }

    @Test func onlyOwnRunningProcessesCanOwnABox() {
        #expect(OwnerWatch.isUsableOwner(getpid()))
        #expect(!OwnerWatch.isUsableOwner(1))
        #expect(!OwnerWatch.isUsableOwner(0))
        #expect(!OwnerWatch.isUsableOwner(-5))
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    func set() {
        lock.lock()
        isSet = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isSet
    }
}
