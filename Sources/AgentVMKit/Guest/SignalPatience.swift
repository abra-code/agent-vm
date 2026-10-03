// Sources/AgentVMKit/Guest/SignalPatience.swift
//
// `agent-vm exec` forwards signals and ends when the program in the box does. A program that
// ignores SIGINT and SIGTERM would leave a client that only SIGKILL ends, and a person at a
// terminal pressing Control-C with nothing happening. So the second signal that asks a program
// to end gives up on it: exec closes the connection (the guest daemon then hangs the program's
// group up and kills it 3 s later) and exits.
//
// Not any second signal: callers deliver one signal twice within milliseconds (a terminal
// signals the whole foreground group, and a parent that forwards it signals again), and that
// must stay one request. The second counts only after `minimumGap`.
//
// And not a signal long after the first: a program may answer SIGINT without ending (it
// cancels what it was doing), and the next SIGINT an hour later is a new request, not a second
// one. After `window` the count starts again.

import Foundation

public final class SignalPatience: @unchecked Sendable {
    /// The signals that ask a program to end.
    public static let endingSignals: Set<Int32> = [SIGINT, SIGTERM, SIGHUP, SIGQUIT]
    public static let minimumGap: Duration = .seconds(1)
    public static let window: Duration = .seconds(30)

    private let lock = NSLock()
    private var first: ContinuousClock.Instant?

    public init() {}

    /// Whether `signal`, arriving at `now`, is the one to give up on: an ending signal at
    /// least `minimumGap` and at most `window` after the ending signal that began the count.
    /// Signal handlers run on any thread.
    public func givesUp(on signal: Int32, at now: ContinuousClock.Instant = .now) -> Bool {
        guard Self.endingSignals.contains(signal) else {
            return false
        }
        lock.lock()
        defer { lock.unlock() }
        guard let first, now - first <= Self.window else {
            self.first = now
            return false
        }
        return now - first >= Self.minimumGap
    }
}
