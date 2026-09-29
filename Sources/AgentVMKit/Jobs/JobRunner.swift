// Sources/AgentVMKit/Jobs/JobRunner.swift
//
// `agent-vm job run <id>`: the detached process that runs one job's command and records how it
// ended. JobStore.start spawns it in its own session, with nothing of the caller's open and the
// job's lock on descriptor 3; it holds that lock until it exits, which is how every client
// tells that the job still runs. The command's stdout goes to the job's `out`, its stderr (the
// progress events) to its `log`, and the command runs in the folder it was started from.
//
// A job started after another waits for it first, looking every half second: it runs once
// that one ended with status 0, and otherwise ends canceled with the reason, which ends every
// job queued after it in turn.
//
// Cancel (SIGINT from `job cancel`) and SIGTERM (a logout or shutdown) are passed on to the
// command, which stops at its next safe point; the runner keeps waiting, to record the result.
// SIGHUP is ignored. Signals and the command's exit arrive through one kqueue, so no code runs
// in a signal handler; the dispositions are SIG_IGN meanwhile (kqueue records a signal even
// then), and the command starts with them at their defaults.

import Darwin
import Foundation

public enum JobRunner {
    /// Signals a runner and its command start with at their defaults, whatever the process
    /// that spawned them ignored or blocked.
    static let defaultedSignals: [Int32] = [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGPIPE, SIGCHLD, SIGALRM, SIGUSR1, SIGUSR2]
    /// Passed on to the command as a cancel.
    static let cancelSignals: [Int32] = [SIGINT, SIGTERM]

    /// Runs job `id` of `store` while holding the lock received on `lockDescriptor`. Returns
    /// the runner's own exit status: 0 once the job's end is recorded.
    public static func run(store: JobStore, id: String, lockDescriptor: Int32) -> Int32 {
        guard JobStore.isValidID(id) else {
            FileHandle.standardError.write(Data("Error: \(AgentVMError.invalidJobID(id))\n".utf8))
            return 2
        }
        // Started by hand, without the lock `job start` hands down: this is not the job's
        // runner, and must not write its end.
        guard holdsLock(store: store, id: id, descriptor: lockDescriptor) else {
            FileHandle.standardError.write(Data("Error: job \(id) is run by `agent-vm job start`, which hands its runner the job's lock\n".utf8))
            return 2
        }
        // A job that has ended is never run again, whoever holds its lock file.
        guard !FileSystem.exists(store.path(id, JobStore.endName)) else {
            FileHandle.standardError.write(Data("Error: job \(id) has already ended\n".utf8))
            return 2
        }
        let logPath = store.path(id, JobStore.logName)
        let log = open(logPath, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
        let output = open(store.path(id, JobStore.outputName), O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
        defer {
            if log >= 0 {
                close(log)
            }
            if output >= 0 {
                close(output)
            }
        }
        // What goes wrong before the command runs goes where `job log` and `job list` show it.
        func fail(_ message: String, status: Int32?) -> Int32 {
            if log >= 0 {
                let line = "Error: \(message)\n"
                _ = line.withCString { write(log, $0, strlen($0)) }
            }
            return recordEnd(store: store, id: id, JobEnd(status: status, canceled: false))
        }
        guard log >= 0, output >= 0 else {
            return fail("cannot open the job's log and output in \(store.directory(of: id).path): \(String(cString: strerror(errno)))", status: nil)
        }
        let record: JobRecord
        do {
            record = try store.record(id)
        } catch {
            return fail("\(error)", status: nil)
        }

        // Watched first, ignored second: a signal in between is recorded by the queue rather
        // than lost. The pid is written after both, so `job cancel` cannot signal a runner
        // that would still die of SIGINT.
        let queue = kqueue()
        guard queue >= 0 else {
            return fail("cannot watch signals: \(String(cString: strerror(errno)))", status: nil)
        }
        defer { close(queue) }
        var changes = cancelSignals.map {
            kevent(ident: UInt($0), filter: Int16(EVFILT_SIGNAL), flags: UInt16(EV_ADD), fflags: 0, data: 0, udata: nil)
        }
        guard kevent(queue, &changes, Int32(changes.count), nil, 0, nil) == 0 else {
            return fail("cannot watch signals: \(String(cString: strerror(errno)))", status: nil)
        }
        for signalNumber in cancelSignals + [SIGHUP] {
            signal(signalNumber, SIG_IGN)
        }
        let runnerPid = getpid()
        guard writeRunnerInfo(store: store, id: id, JobRunnerInfo(pid: runnerPid)) else {
            return fail("cannot write \(store.path(id, JobStore.runnerName))", status: nil)
        }
        // A cancel that came before the command exists ends the job here.
        if let signalNumber = pendingSignal(queue, milliseconds: 0) {
            return Self.recordEnd(store: store, id: id, JobEnd(status: nil, canceled: true, signal: signalNumber))
        }
        if let after = record.after {
            while true {
                if let reason = store.blockingReason(after: after) {
                    if reason.isEmpty {
                        break
                    }
                    return Self.recordEnd(store: store, id: id, JobEnd(status: nil, canceled: true, reason: reason))
                }
                if let signalNumber = pendingSignal(queue, milliseconds: 500) {
                    return Self.recordEnd(store: store, id: id, JobEnd(status: nil, canceled: true, signal: signalNumber))
                }
            }
        }

        let child: pid_t
        do {
            child = try spawn(record, stdout: output, stderr: log)
        } catch {
            return fail("\(error)", status: 127)
        }
        _ = writeRunnerInfo(store: store, id: id, JobRunnerInfo(pid: runnerPid, commandPid: child, startedAt: Date()))

        var canceledBy: Int32?
        var exitWatch = kevent(ident: UInt(child), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD), fflags: NOTE_EXIT, data: 0, udata: nil)
        // ESRCH: it has already exited; waitpid below collects it.
        if kevent(queue, &exitWatch, 1, nil, 0, nil) == 0 {
            while true {
                var event = kevent()
                let count = kevent(queue, nil, 0, &event, 1, nil)
                if count < 0 {
                    if errno == EINTR {
                        continue
                    }
                    break
                }
                if count == 0 {
                    continue
                }
                if event.filter == Int16(EVFILT_SIGNAL) {
                    let signalNumber = Int32(event.ident)
                    canceledBy = canceledBy ?? signalNumber
                    kill(child, signalNumber)
                    continue
                }
                if event.filter == Int16(EVFILT_PROC) {
                    break
                }
            }
        }
        var waitStatus: Int32 = 0
        while waitpid(child, &waitStatus, 0) < 0 {
            guard errno == EINTR else {
                return fail("cannot collect the command's exit status: \(String(cString: strerror(errno)))", status: nil)
            }
        }
        // A cancel that arrived as the command was ending still counts.
        if canceledBy == nil {
            canceledBy = pendingSignal(queue, milliseconds: 0)
        }
        let status = ExitReport(waitStatus: waitStatus).shellStatus
        return Self.recordEnd(store: store, id: id, JobEnd(status: status, canceled: canceledBy != nil, signal: canceledBy))
    }

    /// Whether `descriptor` is this job's lock file and holds its lock (a lock this process
    /// already holds is granted again; one held elsewhere is refused).
    static func holdsLock(store: JobStore, id: String, descriptor: Int32) -> Bool {
        var held = stat()
        var file = stat()
        guard fstat(descriptor, &held) == 0, lstat(store.path(id, JobStore.lockName), &file) == 0,
              held.st_dev == file.st_dev, held.st_ino == file.st_ino else {
            return false
        }
        // Kept across exec: set close-on-exec here, so the command never inherits it.
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        return flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }

    /// A cancel signal the queue has recorded, waiting up to `milliseconds` for one.
    static func pendingSignal(_ queue: Int32, milliseconds: Int) -> Int32? {
        var event = kevent()
        var wait = timespec(tv_sec: milliseconds / 1000, tv_nsec: (milliseconds % 1000) * 1_000_000)
        let count = kevent(queue, nil, 0, &event, 1, &wait)
        guard count > 0, event.filter == Int16(EVFILT_SIGNAL) else {
            return nil
        }
        return Int32(event.ident)
    }

    /// Starts the job's command: stdin from /dev/null, stdout and stderr to the job's files,
    /// in the job's folder, with the signals at their defaults and nothing else inherited.
    static func spawn(_ record: JobRecord, stdout: Int32, stderr: Int32) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)
        posix_spawn_file_actions_addchdir(&actions, record.directory)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var defaulted = sigset_t()
        sigemptyset(&defaulted)
        for signalNumber in defaultedSignals {
            sigaddset(&defaulted, signalNumber)
        }
        posix_spawnattr_setsigdefault(&attributes, &defaulted)
        var empty = sigset_t()
        sigemptyset(&empty)
        posix_spawnattr_setsigmask(&attributes, &empty)

        var pid: pid_t = 0
        let argv = [record.executable] + record.arguments
        let status = GuestServer.withCStrings(argv) { argvPointer in
            posix_spawn(&pid, record.executable, &actions, &attributes, argvPointer, environ)
        }
        guard status == 0 else {
            throw AgentVMError.system(operation: "run \(record.executable) in \(record.directory)", code: status)
        }
        return pid
    }

    static func writeRunnerInfo(store: JobStore, id: String, _ info: JobRunnerInfo) -> Bool {
        let url = store.directory(of: id).appendingPathComponent(JobStore.runnerName)
        return (try? JobStore.encoder.encode(info).write(to: url, options: .atomic)) != nil
    }

    /// Writes the job's end, atomically; 0 when written, 1 when not (the job is then lost).
    static func recordEnd(store: JobStore, id: String, _ end: JobEnd) -> Int32 {
        let url = store.directory(of: id).appendingPathComponent(JobStore.endName)
        return (try? JobStore.encoder.encode(end).write(to: url, options: .atomic)) != nil ? 0 : 1
    }
}
