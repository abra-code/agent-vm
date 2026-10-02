// Sources/AgentVMKit/Network/Splice.swift
//
// Copies two connected stream sockets into each other until both directions end: when one side
// finishes sending, the other side's write half is shut down (a half-close, which vsock
// supports - measured), so request/response protocols that close one way still complete.

import Darwin
import Foundation

public enum Splice {
    /// The bytes a running splice has copied so far, readable from any thread, and the way to
    /// end it from outside.
    public final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private var values = [0, 0]
        private var cutReason: String?
        private var descriptors: (Int32, Int32)?
        private var over = false

        public init() {}

        /// Bytes copied from the first socket to the second, and the other way.
        public var counts: (aToB: Int, bToA: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (values[0], values[1])
        }

        /// Why the splice was ended by `cut`, if it was.
        public var reason: String? {
            lock.lock()
            defer { lock.unlock() }
            return cutReason
        }

        /// Ends the splice: both sockets are shut down both ways, which wakes a copier waiting
        /// to read or asleep in a write (measured for both on AF_UNIX and TCP sockets). A splice that
        /// has not started yet is cut as it starts. Nothing happens once it is over, so a
        /// descriptor closed since, and its number given to another file, is never touched.
        public func cut(reason: String) {
            lock.lock()
            defer { lock.unlock() }
            guard !over else {
                return
            }
            if cutReason == nil {
                cutReason = reason
            }
            if let (a, b) = descriptors {
                Self.shutBothWays(a)
                Self.shutBothWays(b)
            }
        }

        /// Each way by itself: on macOS SHUT_RDWR is refused, and does nothing, on a socket
        /// whose peer has finished sending (measured on AF_UNIX and TCP: ENOTCONN, a writer
        /// stays asleep and the peer sees no end of file).
        private static func shutBothWays(_ descriptor: Int32) {
            _ = shutdown(descriptor, SHUT_RD)
            _ = shutdown(descriptor, SHUT_WR)
        }

        fileprivate func add(_ index: Int, _ count: Int) {
            lock.lock()
            values[index] += count
            lock.unlock()
        }

        fileprivate func attach(_ a: Int32, _ b: Int32) {
            lock.lock()
            descriptors = (a, b)
            if cutReason != nil {
                Self.shutBothWays(a)
                Self.shutBothWays(b)
            }
            lock.unlock()
        }

        fileprivate func detach() {
            lock.lock()
            descriptors = nil
            over = true
            lock.unlock()
        }
    }

    /// Blocks until both directions are done; returns the bytes copied each way. Closes
    /// neither descriptor. Writes never raise SIGPIPE (SO_NOSIGPIPE is set on both).
    ///
    /// `progress` gets the counts as they grow and can end the splice. With `silenceLimit`,
    /// once `a` has finished sending, `b` may stay silent that long at most; then both are shut
    /// down. Without it a peer of `b` that never answers a half-close keeps the splice, its
    /// threads and its descriptors for good.
    @discardableResult
    public static func run(_ a: Int32, _ b: Int32, progress: Progress? = nil, silenceLimit: Duration? = nil) -> (aToB: Int, bToA: Int) {
        var one: Int32 = 1
        _ = setsockopt(a, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(b, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let progress = progress ?? Progress()
        progress.attach(a, b)
        // Before the caller can close either descriptor.
        defer { progress.detach() }
        let forwardEnded = Ended()
        let done = DispatchGroup()
        for (index, (from, to)) in [(a, b), (b, a)].enumerated() {
            done.enter()
            Thread.detachNewThread {
                var giveUp: (() -> Bool)?
                if index == 1, let silenceLimit {
                    giveUp = { forwardEnded.since.map { ContinuousClock.now - $0 > silenceLimit } ?? false }
                }
                let silent = copy(from, to, giveUp: giveUp) { count in
                    progress.add(index, count)
                    if index == 1 {
                        // Data from `b`: its silence starts over.
                        forwardEnded.restart()
                    }
                }
                if silent {
                    progress.cut(reason: "nothing from the server for \(silenceLimit.map { "\($0.components.seconds) s" } ?? "too long") after the box closed its side")
                }
                if index == 0 {
                    forwardEnded.mark()
                }
                // Tell the far side this direction is over; a failed write ends both.
                _ = shutdown(to, SHUT_WR)
                done.leave()
            }
        }
        done.wait()
        return progress.counts
    }

    /// Copies until end of file or an error, reporting each chunk written to `copied`. Returns
    /// true when it stopped because `giveUp` said so (asked about once a second while nothing
    /// arrives).
    static func copy(_ from: Int32, _ to: Int32, giveUp: (() -> Bool)? = nil, copied: (Int) -> Void) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 65536)
        // Noted here, not read from errno: the socket's own ETIMEDOUT (a server that stopped
        // answering, found by keepalive) is an error like any other, not `giveUp`'s answer.
        var gaveUp = false
        let ask = giveUp.map { giveUp in
            return { () -> Bool in
                gaveUp = giveUp()
                return gaveUp
            }
        }
        while true {
            // Not read(2): a thread asleep in it can miss the guest's shutdown (SocketRead).
            let count = buffer.withUnsafeMutableBytes { SocketRead.read(from, $0.baseAddress!, $0.count, giveUp: ask) }
            if count <= 0 {
                return gaveUp
            }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes { write(to, $0.baseAddress! + offset, count - offset) }
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    // The receiver is gone: stop reading too, so the sender sees it.
                    _ = shutdown(from, SHUT_RD)
                    return false
                }
                offset += written
            }
            copied(count)
        }
    }

    /// When the first direction ended, moved forward by each chunk of the second.
    private final class Ended: @unchecked Sendable {
        private let lock = NSLock()
        private var instant: ContinuousClock.Instant?

        var since: ContinuousClock.Instant? {
            lock.lock()
            defer { lock.unlock() }
            return instant
        }

        func mark() {
            lock.lock()
            instant = ContinuousClock.now
            lock.unlock()
        }

        func restart() {
            lock.lock()
            if instant != nil {
                instant = ContinuousClock.now
            }
            lock.unlock()
        }
    }
}
