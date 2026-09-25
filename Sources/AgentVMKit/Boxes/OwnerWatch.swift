// Sources/AgentVMKit/Boxes/OwnerWatch.swift
//
// A box's owner lease: `box start --owner-pid N` makes the supervisor watch process N and stop
// the box when it exits, so an application that crashes (or is killed) never keeps VM slots
// taken: macOS runs at most two macOS guests at once. kqueue reports the exit (EVFILT_PROC,
// NOTE_EXIT) the moment it happens; nothing polls.

import Darwin
import Foundation

public final class OwnerWatch: @unchecked Sendable {
    public let pid: Int32
    private let source: DispatchSourceProcess
    private let lock = NSLock()
    private var fired = false
    private let onExit: @Sendable () -> Void

    /// Watches `pid` and calls `onExit` once, on `queue`, when it exits; at once when it is not
    /// running (or exited while the watch was being set up).
    public init(pid: Int32, queue: DispatchQueue, onExit: @escaping @Sendable () -> Void) {
        self.pid = pid
        self.onExit = onExit
        source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in
            self?.fire()
        }
        source.resume()
        // libdispatch reports a process already gone (or a zombie) as exited at once (measured);
        // this check, after the registration, is a second safeguard that does not depend on it.
        // fire() runs onExit only once either way.
        if !Self.isAlive(pid) {
            queue.async { [weak self] in
                self?.fire()
            }
        }
    }

    /// Stops watching; a call already queued does nothing.
    public func cancel() {
        lock.lock()
        fired = true
        lock.unlock()
        source.cancel()
    }

    deinit {
        source.cancel()
    }

    private func fire() {
        lock.lock()
        let first = !fired
        fired = true
        lock.unlock()
        if first {
            onExit()
        }
    }

    /// Whether a process with this id runs (as any user: EPERM means it exists).
    public static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else {
            return false
        }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// Whether `pid` can own a box: a running process of this user, and not process 1.
    public static func isUsableOwner(_ pid: Int32) -> Bool {
        return pid > 1 && kill(pid, 0) == 0
    }
}
