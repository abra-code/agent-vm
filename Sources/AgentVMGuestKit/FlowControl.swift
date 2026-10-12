// Sources/AgentVMGuestKit/FlowControl.swift
//
// Flow control for an exec (feature `flow-control`). Each side says how many bytes of frames it
// lets the other have on the way to it and not yet taken (its window), and the other sends no
// more than that until an acknowledgment frame says some were taken.
//
// Why: a connection the Mac opened to a guest must be read promptly on the Mac. With output
// left unread there (measured on macOS 27: 64 KiB is enough for a Linux guest, a macOS guest
// takes more), no vsock connection of that guest moves any more: a new exec gets no answer and
// a running one goes silent, until the reader reads. `agent-vm exec` wrote output on as it
// read it, and whatever it writes to can stop: a pager, a paused terminal, a slow pipe. Now it
// reads the connection at once, into memory (ExecSession.run), and the window is what bounds
// that memory: the program in the box waits, as it would on a full pipe.
//
// Input needs a window too, or the two would lock each other: a guest that waits to send
// output must still read what the host sends (the acknowledgments are there), so it cannot
// wait on a program that does not read its input; it keeps at most a window of input in
// memory instead.

import Dispatch

public enum GuestFlow {
    /// What each side lets the other have sent and not yet acknowledged, and so what each
    /// holds in memory at most for one exec.
    public static let window = 64 * 1024

    /// The windows a peer may ask for; anything else is taken as none (no flow control).
    static let windows = 4096...(1024 * 1024)

    /// A frame's bytes on the connection, which is what a window counts.
    public static func cost(payload count: Int) -> Int {
        return count + 5
    }

    /// The largest payload sent under `window`: a frame costs at most a quarter of it, so a
    /// receiver that acknowledges at every quarter never leaves a sender waiting for good.
    public static func chunk(for window: Int) -> Int {
        return max(1, window / 4 - 5)
    }

    /// How many taken bytes a receiver lets add up before it acknowledges them.
    static func acknowledgeEvery(for window: Int) -> Int {
        return max(1, window / 4)
    }

    /// The window a peer named, when it is one this build works with.
    public static func accepted(_ window: Int?) -> Int? {
        guard let window, windows.contains(window) else {
            return nil
        }
        return window
    }

    /// An acknowledgment frame's payload: the number of bytes taken, 4 bytes, big-endian.
    public static func acknowledgment(_ count: Int) -> [UInt8] {
        let value = UInt32(clamping: count)
        return [UInt8(value >> 24), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }

    public static func acknowledged(_ payload: [UInt8]) -> Int? {
        guard payload.count == 4 else {
            return nil
        }
        return Int(payload[0]) << 24 | Int(payload[1]) << 16 | Int(payload[2]) << 8 | Int(payload[3])
    }
}

/// The sender's side of a window: how much it may still send. `take` waits for room, `add`
/// (an acknowledgment arrived) makes room, and `open` ends all waiting when the connection is
/// over.
public final class CreditGate: @unchecked Sendable {
    private let lock = PthreadLock()
    private let wake = DispatchSemaphore(value: 0)
    /// The window this gate keeps to; what is sent under it is cut by it (GuestFlow.chunk).
    public let window: Int
    private var available: Int
    private var waiting = 0
    private var isOpen = false

    public init(window: Int) {
        self.window = window
        available = window
    }

    /// Waits until `cost` bytes may be sent and counts them as sent. False when the gate was
    /// opened: the connection is over and nothing more need be sent.
    public func take(_ cost: Int) -> Bool {
        // Never more than the whole window, or the wait would not end.
        let needed = min(cost, window)
        lock.lock()
        while true {
            if isOpen {
                lock.unlock()
                return false
            }
            if available >= needed {
                available -= needed
                lock.unlock()
                return true
            }
            waiting += 1
            lock.unlock()
            // A wake-up meant for another waiter is used up by whoever gets it; the limit
            // makes the one it was meant for look again.
            _ = wake.wait(timeout: .now() + .milliseconds(200))
            lock.lock()
            waiting -= 1
        }
    }

    /// `count` bytes were taken at the other end.
    public func add(_ count: Int) {
        lock.lock()
        available = min(window, available + max(0, count))
        let waiters = waiting
        lock.unlock()
        for _ in 0..<waiters {
            wake.signal()
        }
    }

    /// Ends every wait, now and later, with false.
    public func open() {
        lock.lock()
        isOpen = true
        let waiters = waiting
        lock.unlock()
        for _ in 0..<waiters {
            wake.signal()
        }
    }

    /// How much may be sent now without waiting.
    public var room: Int {
        lock.lock()
        defer { lock.unlock() }
        return available
    }
}

/// The receiver's side of a window: adds up what was taken and says when to acknowledge it.
public struct AckTally: Sendable {
    private let every: Int
    private var pending = 0

    public init(window: Int) {
        every = GuestFlow.acknowledgeEvery(for: window)
    }

    /// A frame with `count` bytes of payload was taken. The number to acknowledge now, if any.
    public mutating func took(payload count: Int) -> Int? {
        pending += GuestFlow.cost(payload: count)
        guard pending >= every else {
            return nil
        }
        defer { pending = 0 }
        return pending
    }
}
