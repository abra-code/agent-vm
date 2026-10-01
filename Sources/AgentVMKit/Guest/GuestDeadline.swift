// Sources/AgentVMKit/Guest/GuestDeadline.swift
//
// A time limit for a whole exchange with the guest. A socket's receive timeout bounds one read,
// so a guest that answers one byte at a time, each within the timeout, holds a caller for as
// long as it likes; so does a guest that stops reading while the host writes. For the requests
// the host makes for itself (hello, the clock, shutdown, short commands) the answer is a few
// lines and a slow one is a broken or hostile guest: when the limit passes, both directions of
// the connection are shut down, which ends a read waiting in poll and a blocked write, and the
// call fails.

import Darwin
import Foundation

enum GuestDeadline {
    /// Runs `body`, which talks to the guest on `descriptor` with blocking calls. When it has
    /// not returned after `limit`, the connection is shut down and the call throws
    /// `guestUnreachable`. The descriptor stays the caller's to close.
    static func run<T>(_ descriptor: Int32, within limit: Duration, what: String, _ body: () throws -> T) throws -> T {
        let watch = Watch(descriptor)
        let timer = DispatchWorkItem { watch.expire() }
        let (seconds, attoseconds) = limit.components
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(Int(seconds)) + .nanoseconds(Int(attoseconds / 1_000_000_000)), execute: timer)
        let result: Result<T, Error>
        do {
            result = .success(try body())
        } catch {
            result = .failure(error)
        }
        timer.cancel()
        // After this the timer no longer touches the descriptor, so the caller may close it.
        guard !watch.finish() else {
            throw AgentVMError.guestUnreachable("the guest did not finish \(what) within \(limit)")
        }
        return try result.get()
    }

    /// Whether the limit passed, decided under one lock with the shutdown: the descriptor is
    /// never shut down after `finish` returned (its number may belong to something else then).
    private final class Watch: @unchecked Sendable {
        private let lock = NSLock()
        private let descriptor: Int32
        private var finished = false
        private var expired = false

        init(_ descriptor: Int32) {
            self.descriptor = descriptor
        }

        func expire() {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else {
                return
            }
            expired = true
            _ = shutdown(descriptor, SHUT_RDWR)
        }

        /// True when the limit passed before the body returned.
        func finish() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            finished = true
            return expired
        }
    }
}
