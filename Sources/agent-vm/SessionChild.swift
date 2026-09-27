// Sources/agent-vm/SessionChild.swift
//
// connect's session: `agent-vm exec --tty ...` run as a child on this terminal, and waited
// for. The child stays in connect's process group, the terminal's foreground job, so keys and
// the window size reach it; it starts with default signal actions and an empty mask whatever
// connect ignores. Meanwhile connect ignores SIGINT and SIGQUIT (keys belong to the box), and
// passes SIGTERM and SIGHUP on to the child, which ends the session as for ssh; the first one
// is recorded, so connect then exits as that signal says. The terminal's settings are saved
// before and put back after, in case the child was killed while its terminal was raw.

import AgentVMKit
import Darwin
import Foundation

enum SessionChild {
    struct Outcome {
        /// ExitReport(waitStatus:).shellStatus.
        var status: Int32
        /// SIGTERM or SIGHUP that connect received meanwhile.
        var signal: Int32?
    }

    /// Signals whose actions the child gets back to their defaults.
    private static let defaulted: [Int32] = [SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGPIPE, SIGWINCH, SIGTSTP, SIGTTIN, SIGTTOU, SIGCHLD]

    /// Shared with the signal handler: [0] the child to pass signals on to (0 before the spawn),
    /// [1] the first signal passed. Raw memory, allocated once: a Swift variable's access
    /// tracking (exclusivity checks) is not safe to run in a signal handler.
    nonisolated(unsafe) private static let state: UnsafeMutablePointer<Int32> = {
        let pointer = UnsafeMutablePointer<Int32>.allocate(capacity: 2)
        pointer.initialize(repeating: 0, count: 2)
        return pointer
    }()

    /// `arguments` follow the executable (they start with "exec"). argv[0] is `executable`, the
    /// resolved path, so the child never takes itself for avm.
    static func run(executable: String, arguments: [String]) throws -> Outcome {
        fflush(nil)
        var saved = termios()
        let haveSettings = tcgetattr(STDIN_FILENO, &saved) == 0

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // Only stdin, stdout and stderr go to the child.
        for descriptor: Int32 in [0, 1, 2] {
            posix_spawn_file_actions_addinherit_np(&actions, descriptor)
        }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signalNumber in defaulted {
            sigaddset(&defaults, signalNumber)
        }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var empty = sigset_t()
        sigemptyset(&empty)
        posix_spawnattr_setsigmask(&attributes, &empty)
        // No new session or process group: the child must stay the terminal's foreground job.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        // Before the spawn, so a Control-C typed before the child's terminal is raw cannot end
        // connect; put back if the spawn fails.
        let state = Self.state
        state[0] = 0
        state[1] = 0
        let previous = installHandlers()
        var pid: pid_t = 0
        let status = withCStrings([executable] + arguments) { argv in
            posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
        }
        guard status == 0 else {
            restoreHandlers(previous)
            throw AgentVMError.system(operation: "start agent-vm exec", code: status)
        }
        state[0] = pid
        // A SIGTERM or SIGHUP that came before the child existed.
        if state[1] != 0 {
            kill(pid, state[1])
        }

        var waitStatus: Int32 = 0
        while waitpid(pid, &waitStatus, 0) < 0 {
            guard errno == EINTR else {
                // Not ours to wait for (with SIGCHLD at its default, it cannot happen for a
                // child we spawned).
                waitStatus = ExecRunner.ownFailureStatus << 8
                break
            }
        }
        state[0] = 0
        restoreHandlers(previous)
        if haveSettings {
            _ = tcsetattr(STDIN_FILENO, TCSADRAIN, &saved)
        }
        let signalNumber = state[1]
        return Outcome(status: ExitReport(waitStatus: waitStatus).shellStatus, signal: signalNumber == 0 ? nil : signalNumber)
    }

    private static func withCStrings<T>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> T) -> T {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer {
            for pointer in pointers {
                free(pointer)
            }
        }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }

    private static func installHandlers() -> [(Int32, sigaction)] {
        var previous: [(Int32, sigaction)] = []
        var ignore = sigaction()
        ignore.__sigaction_u.__sa_handler = SIG_IGN
        sigemptyset(&ignore.sa_mask)
        // SIGCHLD ignored (inherited from whoever started connect) would reap the child
        // unseen, and waitpid would fail with ECHILD instead of giving its status.
        var byDefault = sigaction()
        byDefault.__sigaction_u.__sa_handler = SIG_DFL
        sigemptyset(&byDefault.sa_mask)
        var pass = sigaction()
        // Async-signal-safe: kill, and loads and stores in memory prepared beforehand (run
        // initializes `state` before it installs the handler).
        pass.__sigaction_u.__sa_handler = { signalNumber in
            let state = SessionChild.state
            if state[1] == 0 {
                state[1] = signalNumber
            }
            if state[0] > 0 {
                kill(state[0], signalNumber)
            }
        }
        sigemptyset(&pass.sa_mask)
        pass.sa_flags = SA_RESTART
        for (signalNumber, action) in [(SIGINT, ignore), (SIGQUIT, ignore), (SIGWINCH, ignore), (SIGCHLD, byDefault), (SIGTERM, pass), (SIGHUP, pass)] {
            var new = action
            var old = sigaction()
            if sigaction(signalNumber, &new, &old) == 0 {
                previous.append((signalNumber, old))
            }
        }
        return previous
    }

    private static func restoreHandlers(_ previous: [(Int32, sigaction)]) {
        for (signalNumber, action) in previous {
            var old = action
            _ = sigaction(signalNumber, &old, nil)
        }
    }
}
