// Sources/TerminalUI/CrashRestore.swift
//
// A crash while a widget has the terminal in raw mode (a trap in its own code) would leave the
// person's shell without echo or line editing. While raw mode is on, fault handlers put the
// saved settings back and show the cursor, then return: the fault happens again with the
// default action (SA_RESETHAND), so the crash report is the same as without them. The handler
// makes only async-signal-safe calls (tcsetattr, write) on memory prepared beforehand.

import Darwin

enum CrashRestore {
    /// SIGTRAP and SIGILL are what Swift's traps raise on Apple silicon and Intel.
    static let faults: [Int32] = [SIGTRAP, SIGILL, SIGABRT, SIGSEGV, SIGBUS, SIGFPE]

    /// Filled before the handlers are installed; read by the handler only.
    nonisolated(unsafe) private static let saved = UnsafeMutablePointer<termios>.allocate(capacity: 1)
    nonisolated(unsafe) private static var input: Int32 = -1
    nonisolated(unsafe) private static var output: Int32 = -1
    /// Attributes off, the cursor shown, on a line of its own; no allocation to write it.
    private static let restoreBytes: StaticString = "\r\n\u{1B}[0m\u{1B}[?25h"
    /// How much of `restoreBytes` the handler writes: only the line end without cursor control
    /// (TERM=dumb gets no escape sequences).
    nonisolated(unsafe) private static var restoreCount = 0
    nonisolated(unsafe) private static var previous: [(Int32, sigaction)] = []

    /// Installs the fault handlers for `settings` on `input`. Callers are the widgets, which
    /// run one at a time.
    static func install(input: Int32, output: Int32, settings: termios, cursorControl: Bool) {
        guard previous.isEmpty else {
            return
        }
        saved.pointee = settings
        Self.input = input
        Self.output = output
        // Touched now, so the handler's reads are of initialized globals.
        Self.restoreCount = cursorControl ? restoreBytes.utf8CodeUnitCount : 2
        var action = sigaction()
        action.__sigaction_u.__sa_handler = { _ in
            _ = tcsetattr(CrashRestore.input, TCSANOW, CrashRestore.saved)
            _ = write(CrashRestore.output, CrashRestore.restoreBytes.utf8Start, CrashRestore.restoreCount)
        }
        action.sa_flags = SA_RESETHAND
        sigemptyset(&action.sa_mask)
        var installed: [(Int32, sigaction)] = []
        for fault in faults {
            var old = sigaction()
            if sigaction(fault, &action, &old) == 0 {
                installed.append((fault, old))
            }
        }
        previous = installed
    }

    /// Puts the actions from before `install` back.
    static func uninstall() {
        for (fault, action) in previous {
            var old = action
            _ = sigaction(fault, &old, nil)
        }
        previous = []
    }
}
