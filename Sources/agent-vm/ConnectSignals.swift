// Sources/agent-vm/ConnectSignals.swift
//
// Steps connect must not stop halfway (taking a snapshot, reporting on it, the undo, ending the
// session) run with SIGINT, SIGQUIT, SIGTERM and SIGHUP held off: a Control-C or a closed
// terminal then waits for the step, and connect acts on it afterwards (it ends the session,
// keeping it for undo, and exits as the signal says). The signals are watched with a kqueue,
// as TerminalUI does: registering is immediate, so none is lost, and no code runs in a signal
// handler. The dispositions are SIG_IGN meanwhile; kqueue records a signal even then.

import Darwin

final class SignalHold {
    private static let held: [Int32] = [SIGINT, SIGQUIT, SIGTERM, SIGHUP]

    private let queue: Int32
    private var previous: [(Int32, sigaction)] = []
    private var released = false

    /// Holds the signals off until `release`. Without a kqueue nothing is held, and the signals
    /// keep their actions.
    init() {
        queue = kqueue()
        guard queue >= 0 else {
            return
        }
        _ = fcntl(queue, F_SETFD, FD_CLOEXEC)
        // Watched first, ignored second: a signal in between is recorded rather than lost.
        var changes = Self.held.map {
            kevent(ident: UInt($0), filter: Int16(EVFILT_SIGNAL), flags: UInt16(EV_ADD), fflags: 0, data: 0, udata: nil)
        }
        _ = kevent(queue, &changes, Int32(changes.count), nil, 0, nil)
        var ignore = sigaction()
        ignore.__sigaction_u.__sa_handler = SIG_IGN
        sigemptyset(&ignore.sa_mask)
        for signalNumber in Self.held {
            var old = sigaction()
            if sigaction(signalNumber, &ignore, &old) == 0 {
                previous.append((signalNumber, old))
            }
        }
    }

    deinit {
        _ = release()
    }

    /// Puts the actions back and returns the first signal that arrived meanwhile, if any; one
    /// that was ignored before the hold stays ignored. Called once; later calls return nil.
    func release() -> Int32? {
        guard !released, queue >= 0 else {
            return nil
        }
        released = true
        // Actions back first, queue read second: a signal in between is recorded by the queue
        // or acted on under the action put back, never ignored unseen.
        for (signalNumber, action) in previous {
            var old = action
            _ = sigaction(signalNumber, &old, nil)
        }
        let empty = kevent(ident: 0, filter: 0, flags: 0, fflags: 0, data: 0, udata: nil)
        var events = Array(repeating: empty, count: Self.held.count)
        var zero = timespec(tv_sec: 0, tv_nsec: 0)
        let count = kevent(queue, nil, 0, &events, Int32(events.count), &zero)
        close(queue)
        guard count > 0 else {
            return nil
        }
        // SIGTERM and SIGHUP first: they say the person is gone, which decides what follows.
        let arrived = Set(events[0..<Int(count)].map { Int32($0.ident) })
        for signalNumber in [SIGTERM, SIGHUP, SIGINT, SIGQUIT] where arrived.contains(signalNumber) {
            if let action = previous.first(where: { $0.0 == signalNumber })?.1, !Self.ignores(action) {
                return signalNumber
            }
        }
        return nil
    }

    /// Runs `body` with the signals held; the signal that arrived meanwhile comes back with its
    /// result, whether it returned or threw.
    static func around<T>(_ body: () throws -> T) -> (result: Result<T, Error>, signal: Int32?) {
        let hold = SignalHold()
        let result = Result { try body() }
        return (result, hold.release())
    }

    private static func ignores(_ action: sigaction) -> Bool {
        return unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self) == unsafeBitCast(SIG_IGN, to: Int.self)
    }
}
