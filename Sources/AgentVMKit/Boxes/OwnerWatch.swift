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
    /// running (or exited while the watch was being set up). With `startedAt`, also at once
    /// when the process with this number is not the one that started then: the owner exited
    /// and its number went to another process before the watch was set up.
    public init(pid: Int32, startedAt: String? = nil, queue: DispatchQueue, onExit: @escaping @Sendable () -> Void) {
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
        // Only a start time that was read and differs: one that cannot be read says nothing.
        let now = startedAt == nil ? nil : Self.startTime(of: pid)
        if !Self.isAlive(pid) || (now != nil && now != startedAt) {
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

    /// When process `pid` started, as "seconds.microseconds" since 1970: with the number, it
    /// names one process for good, where the number alone is given to another once it is free.
    /// nil when there is no such process (or it is another user's and may not be asked about).
    public static func startTime(of pid: Int32) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return nil
        }
        return "\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)"
    }

    /// Whether `pid` can own a box: a running process of this user, and not process 1.
    public static func isUsableOwner(_ pid: Int32) -> Bool {
        return pid > 1 && kill(pid, 0) == 0
    }
}
