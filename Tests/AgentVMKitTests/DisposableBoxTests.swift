// Tests/AgentVMKitTests/DisposableBoxTests.swift
//
// Disposable boxes and the owner lease: which stopped boxes `box gc` deletes (and never a
// running one, or one about to start), and the watch that stops a box when its owner exits.

import Darwin
import Foundation
import Testing
@testable import AgentVMKit

@Suite struct DisposableBoxTests {
    /// Owners are started and reaped with posix_spawn and waitpid, not Foundation's Process:
    /// its waitUntilExit in an async test once never returned although the child was reaped
    /// (the whole test run hung).
    static func spawn(_ argv: [String]) throws -> pid_t {
        // Default signal handling and no blocked signals: other tests ignore SIGTERM in this
        // process, which a spawned child would inherit (then SIGTERM would not end it).
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var all = sigset_t()
        sigfillset(&all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var pid: pid_t = 0
        let status = GuestServer.withCStrings(argv) { arguments in
            posix_spawn(&pid, argv[0], nil, &attributes, arguments, environ)
        }
        guard status == 0 else {
            throw AgentVMError.system(operation: "start \(argv[0])", code: status)
        }
        return pid
    }

    static func reap(_ pid: pid_t) {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    }

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
        let pid = try Self.spawn(["/bin/sleep", "30"])
        let fired = Flag()
        let watch = OwnerWatch(pid: pid, queue: .global()) { fired.set() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!fired.value)
        kill(pid, SIGTERM)
        Self.reap(pid)
        for _ in 0..<50 where !fired.value {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(fired.value)
        withExtendedLifetime(watch) {}
    }

    /// An owner already gone: the watch fires at once.
    @Test func anOwnerAlreadyGoneFiresAtOnce() async throws {
        let pid = try Self.spawn(["/usr/bin/true"])
        Self.reap(pid)
        let fired = Flag()
        let watch = OwnerWatch(pid: pid, queue: .global()) { fired.set() }
        for _ in 0..<50 where !fired.value {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(fired.value)
        withExtendedLifetime(watch) {}
    }

    /// A process number is given to another process once it is free. The watch is told when
    /// the owner started: a process with its number that started at another time is not it,
    /// and the watch fires as for an owner that is gone.
    @Test func aProcessThatTookTheOwnersNumberIsNotTheOwner() async throws {
        let pid = try Self.spawn(["/bin/sleep", "30"])
        defer {
            kill(pid, SIGTERM)
            Self.reap(pid)
        }
        let started = try #require(OwnerWatch.startTime(of: pid))
        #expect(started == OwnerWatch.startTime(of: pid))
        #expect(started != OwnerWatch.startTime(of: getpid()))
        #expect(OwnerWatch.startTime(of: 0) == nil && OwnerWatch.startTime(of: -1) == nil)

        // The same process: the watch waits.
        let same = Flag()
        let waiting = OwnerWatch(pid: pid, startedAt: started, queue: .global()) { same.set() }
        // Another start time for the number: fired at once, while the process still runs.
        let other = Flag()
        let fired = OwnerWatch(pid: pid, startedAt: "1.5", queue: .global()) { other.set() }
        for _ in 0..<50 where !other.value {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(other.value)
        #expect(!same.value)
        #expect(OwnerWatch.isAlive(pid))
        waiting.cancel()
        withExtendedLifetime(fired) {}
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
