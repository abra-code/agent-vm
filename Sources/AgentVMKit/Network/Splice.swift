// Sources/AgentVMKit/Network/Splice.swift
//
// Copies two connected stream sockets into each other until both directions end: when one side
// finishes sending, the other side's write half is shut down (a half-close, which vsock
// supports - measured), so request/response protocols that close one way still complete.

import Darwin
import Foundation

public enum Splice {
    /// Blocks until both directions are done; returns the bytes copied each way. Closes
    /// neither descriptor. Writes never raise SIGPIPE (SO_NOSIGPIPE is set on both).
    @discardableResult
    public static func run(_ a: Int32, _ b: Int32) -> (aToB: Int, bToA: Int) {
        var one: Int32 = 1
        _ = setsockopt(a, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(b, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let counts = Counts()
        let done = DispatchGroup()
        for (index, (from, to)) in [(a, b), (b, a)].enumerated() {
            done.enter()
            Thread.detachNewThread {
                counts.set(index, copy(from, to))
                // Tell the far side this direction is over; a failed write ends both.
                _ = shutdown(to, SHUT_WR)
                done.leave()
            }
        }
        done.wait()
        return (counts.value(0), counts.value(1))
    }

    /// Copies until end of file or an error; returns the bytes copied.
    static func copy(_ from: Int32, _ to: Int32) -> Int {
        var buffer = [UInt8](repeating: 0, count: 65536)
        var total = 0
        while true {
            let count = read(from, &buffer, buffer.count)
            if count < 0 && errno == EINTR {
                continue
            }
            if count <= 0 {
                return total
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
                    return total
                }
                offset += written
            }
            total += count
        }
    }

    private final class Counts: @unchecked Sendable {
        private let lock = NSLock()
        private var values = [0, 0]

        func set(_ index: Int, _ value: Int) {
            lock.lock()
            values[index] = value
            lock.unlock()
        }

        func value(_ index: Int) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return values[index]
        }
    }
}
