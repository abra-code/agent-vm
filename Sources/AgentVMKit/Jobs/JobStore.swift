// Sources/AgentVMKit/Jobs/JobStore.swift
//
// Jobs: long agent-vm commands (an image build, a guest update, a box start, a download) run
// detached, so they outlive the terminal, the window or the application that started them,
// and record what happened where any later client reads it. One folder per job under the
// store root:
//
//   Jobs/<id>/job.json     what runs, for which images or boxes (JobRecord); written once,
//                          before the runner starts
//   Jobs/<id>/lock         held by the runner for its whole life: THE test of "still running"
//   Jobs/<id>/runner.json  the runner's process id, and the command's once it started
//   Jobs/<id>/log          the command's stderr: progress events, one JSON object per line
//                          (Docs/progress-events.md), then maybe "Error: ..."
//   Jobs/<id>/out          the command's stdout: its JSON result
//   Jobs/<id>/end.json     how it ended (JobEnd), written atomically as the runner's last act
//
// Why a lock and not a process id: a pid is reused once its process is gone, and a check of a
// reused pid is a guess. An flock is released by the kernel when its holder dies, however it
// dies, so "someone holds the lock" is exactly "the runner is alive", and while it is alive
// its pid cannot be reused, which makes signaling the recorded pid safe. `start` takes the
// lock itself and hands it to the runner it spawns, so a job counts as running from the
// moment its record exists. A runner that dies without writing end.json leaves a lost job.
//
// A job started `after` another waits, queued, until that one ends: it runs when the other
// ended with status 0, and ends canceled, with the reason, when it did not. So a chain
// (a base image, its Full Disk Access setup, the layers on top) runs by itself to the end,
// or stops at its first failure.
//
// Finished jobs are kept for a week; `list(prune: true)` and `start` remove older ones.

import Darwin
import Foundation

/// What a job runs, written to job.json when it is started. The format is read by every later
/// agent-vm version that shares the store, so fields are only ever added.
public struct JobRecord: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var id: String
    /// The program the runner starts: the agent-vm that started the job.
    public var executable: String
    /// Its arguments, `--json` included.
    public var arguments: [String]
    /// What the command works on: "image:<name>", "box:<name>", "ipsw".
    public var targets: [String]
    /// The folder the command runs in, so relative paths in its arguments (a recipe file)
    /// mean what they meant where it was started.
    public var directory: String
    public var createdAt: Date
    /// The agent-vm version that started the job.
    public var createdBy: String
    /// The job this one waits for: it runs once that one ended with status 0.
    public var after: String?

    public init(id: String, executable: String, arguments: [String], targets: [String], directory: String,
                after: String? = nil, createdAt: Date = Date(), createdBy: String = AgentVM.version) {
        self.formatVersion = Self.currentFormatVersion
        self.id = id
        self.executable = executable
        self.arguments = arguments
        self.targets = targets
        self.directory = directory
        self.createdAt = createdAt
        self.createdBy = createdBy
        self.after = after
    }
}

/// How a job ended, written by its runner as its last act.
public struct JobEnd: Codable, Equatable, Sendable {
    /// The command's exit status (128 + N when signal N ended it); nil when it never ran.
    public var status: Int32?
    /// Whether cancel (or SIGTERM) reached the runner while the command ran.
    public var canceled: Bool
    /// The signal that canceled it.
    public var signal: Int32?
    /// Why it was canceled without a signal: the job it waited for did not succeed.
    public var reason: String?
    public var endedAt: Date

    public init(status: Int32?, canceled: Bool, signal: Int32? = nil, reason: String? = nil, endedAt: Date = Date()) {
        self.status = status
        self.canceled = canceled
        self.signal = signal
        self.reason = reason
        self.endedAt = endedAt
    }
}

/// What the runner records about itself: its pid when it starts, and the command's pid and
/// start time once the command runs.
public struct JobRunnerInfo: Codable, Equatable, Sendable {
    public var pid: Int32
    public var commandPid: Int32?
    public var startedAt: Date?
}

public enum JobState: String, Codable, Sendable {
    /// Waiting for the job it was started after to end.
    case queued
    /// The runner holds the lock: the command runs (or is about to).
    case running
    /// Ended with status 0.
    case done
    /// Ended with another status, or could not be run.
    case failed
    /// Ended after a cancel, with a status other than 0, or never ran because the job it
    /// waited for did not succeed.
    case canceled
    /// The runner died without recording how the job ended.
    case lost

    public var isFinished: Bool {
        return self != .running && self != .queued
    }
}

/// A job as `job list --json` shows it: the record, its state and what its log says so far.
public struct Job: Encodable, Sendable {
    public var id: String
    /// What runs: agent-vm's arguments, `--json` included.
    public var command: [String]
    public var targets: [String]
    /// The job this one waits for, when it was started with --after.
    public var after: String?
    public var state: JobState
    /// The command's exit status once it ended.
    public var status: Int32?
    public var createdAt: Date
    public var startedAt: Date?
    public var endedAt: Date?
    /// The last progress event, and the text of the last notice.
    public var progress: ProgressEvent?
    public var notice: String?
    /// A failed, canceled or lost job's error, as agent-vm wrote it (possibly several lines),
    /// or why a queued job was canceled.
    public var error: String?
    /// The store folder that holds the job's files.
    public var path: String

    enum CodingKeys: String, CodingKey {
        case id, command, targets, after, state, status, createdAt, startedAt, endedAt, progress, notice, error, path
    }
}

public struct JobStore: Sendable {
    static let recordName = "job.json"
    static let lockName = "lock"
    static let runnerName = "runner.json"
    static let logName = "log"
    static let outputName = "out"
    static let endName = "end.json"

    /// Finished jobs are removed this long after they ended.
    public static let keepSeconds: TimeInterval = 7 * 24 * 3600
    /// A folder without job.json (a start that died half way) is removed after this long.
    static let abandonedSeconds: TimeInterval = 3600
    /// The descriptor on which the runner receives the job's lock.
    public static let runnerLockDescriptor: Int32 = 3

    static let lostError = "the job ended without recording a result: its runner was stopped"

    public let root: URL

    public init(root: URL) {
        self.root = FileSystem.canonicalRoot(root)
    }

    public var jobsDirectory: URL {
        return root.appendingPathComponent("Jobs", isDirectory: true)
    }

    public func directory(of id: String) -> URL {
        return jobsDirectory.appendingPathComponent(id, isDirectory: true)
    }

    func path(_ id: String, _ name: String) -> String {
        return directory(of: id).appendingPathComponent(name).path
    }

    /// A job id: the UTC time it was started and six random hex digits, "20260929-101500-a1b2c3".
    public static func isValidID(_ id: String) -> Bool {
        return id.range(of: #"^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$"#, options: .regularExpression) != nil
    }

    /// job.json, runner.json and end.json keep fractions of a second: jobs started in one
    /// second (a chain) are listed in the order they were started. The full ISO 8601 form, time
    /// zone included ("2026-09-29T10:15:00.123Z"): picking fields (.year().month()...) drops it.
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
        return encoder
    }

    /// Reads times with or without fractions of a second.
    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
                return date
            }
            return try Date(text, strategy: .iso8601)
        }
        return decoder
    }

    static func newID(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date) + "-" + String(format: "%06x", UInt32.random(in: 0...0xffffff))
    }

    // MARK: - Reading

    /// The job's record; throws when the id is not a job id or there is no such job.
    public func record(_ id: String) throws -> JobRecord {
        guard Self.isValidID(id) else {
            throw AgentVMError.invalidJobID(id)
        }
        let url = directory(of: id).appendingPathComponent(Self.recordName)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let code = FileSystem.posixCode(error)
            if code == ENOENT || (error as NSError).code == NSFileReadNoSuchFileError {
                throw AgentVMError.jobNotFound(id)
            }
            throw AgentVMError.system(operation: "read \(url.path)", code: code)
        }
        do {
            return try Self.decoder.decode(JobRecord.self, from: data)
        } catch {
            throw AgentVMError.corruptJobRecord(path: url.path, reason: "\(error)")
        }
    }

    func end(_ id: String) -> JobEnd? {
        guard let data = FileManager.default.contents(atPath: path(id, Self.endName)) else {
            return nil
        }
        return try? Self.decoder.decode(JobEnd.self, from: data)
    }

    func runnerInfo(_ id: String) -> JobRunnerInfo? {
        guard let data = FileManager.default.contents(atPath: path(id, Self.runnerName)) else {
            return nil
        }
        // A process id below 2 is no runner's: signaled, 0 and -1 mean "every process of
        // this user", so a damaged file counts as none.
        guard let info = try? Self.decoder.decode(JobRunnerInfo.self, from: data), info.pid > 1, info.commandPid.map({ $0 > 1 }) ?? true else {
            return nil
        }
        return info
    }

    /// Whether the job's runner is alive: something holds an exclusive lock on its lock file.
    /// The probe asks for a SHARED lock, which only an exclusive one refuses, so two probes at
    /// once (a list during a cancel) never take each other for a live runner.
    func runnerHoldsLock(_ id: String) -> Bool {
        var descriptor: Int32
        repeat {
            descriptor = open(path(id, Self.lockName), O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        } while descriptor < 0 && errno == EINTR
        guard descriptor >= 0 else {
            return false
        }
        defer { close(descriptor) }
        var locked: Int32
        repeat {
            locked = flock(descriptor, LOCK_SH | LOCK_NB)
        } while locked != 0 && errno == EINTR
        return locked != 0 && errno == EWOULDBLOCK
    }

    /// The job's state, its exit status, and when it ended (nil while it runs).
    func state(_ id: String) -> (state: JobState, end: JobEnd?, endedAt: Date?) {
        if let end = end(id) {
            return (Self.state(of: end), end, end.endedAt)
        }
        if runnerHoldsLock(id) {
            // Queued until its command starts, for a job that waits for another.
            if runnerInfo(id)?.startedAt == nil, (try? record(id))?.after != nil {
                return (.queued, nil, nil)
            }
            return (.running, nil, nil)
        }
        // The runner may have written end.json and exited between the two looks.
        if let end = end(id) {
            return (Self.state(of: end), end, end.endedAt)
        }
        return (.lost, nil, newestChange(id))
    }

    /// For a job queued after `id`: nil while that one runs or waits, "" once it is done, and
    /// otherwise why the queued job does not run.
    func blockingReason(after id: String) -> String? {
        do {
            _ = try record(id)
        } catch AgentVMError.jobNotFound {
            return "job \(id), which it waited for, was removed"
        } catch {
            return "job \(id), which it waited for, cannot be read: \(error)"
        }
        let (state, end, _) = state(id)
        switch state {
        case .queued, .running:
            return nil
        case .done:
            return ""
        case .failed:
            return "job \(id), which it waited for, failed\(end?.status.map { " (status \($0))" } ?? "")"
        case .canceled:
            return "job \(id), which it waited for, was canceled"
        case .lost:
            return "job \(id), which it waited for, was lost"
        }
    }

    static func state(of end: JobEnd) -> JobState {
        if end.status == 0 {
            return .done
        }
        return end.canceled ? .canceled : .failed
    }

    /// When a lost job last showed a sign of life: its newest file.
    private func newestChange(_ id: String) -> Date {
        let changes = [Self.recordName, Self.runnerName, Self.logName, Self.outputName].compactMap { Self.modificationDate(path(id, $0)) }
        return changes.max() ?? Date()
    }

    static func modificationDate(_ path: String) -> Date? {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
    }

    /// The job as `job list` shows it. `logLimit` bounds how much of the log's end is read.
    public func job(_ id: String, logLimit: Int = JobLog.tailBytes) throws -> Job {
        let record = try record(id)
        return job(record, logLimit: logLimit)
    }

    func job(_ record: JobRecord, logLimit: Int = JobLog.tailBytes) -> Job {
        return job(record, state(record.id), logLimit: logLimit)
    }

    private func job(_ record: JobRecord, _ looked: (state: JobState, end: JobEnd?, endedAt: Date?), logLimit: Int = JobLog.tailBytes) -> Job {
        let id = record.id
        let (state, end, endedAt) = looked
        let log = JobLog.read(path(id, Self.logName), limit: logLimit)
        let error: String?
        switch state {
        case .failed:
            error = log.error ?? end?.status.map { "agent-vm exited with status \($0) and gave no reason" }
        case .canceled:
            error = log.error ?? end?.reason ?? end?.signal.map { AgentVMError.canceled(signal: $0).description }
        case .lost:
            error = log.error ?? Self.lostError
        case .queued, .running, .done:
            error = nil
        }
        return Job(id: id, command: record.arguments, targets: record.targets, after: record.after, state: state, status: end?.status,
                   createdAt: record.createdAt, startedAt: runnerInfo(id)?.startedAt, endedAt: endedAt,
                   progress: log.lastProgress, notice: log.lastNotice, error: error, path: directory(of: id).path)
    }

    /// The job's whole log.
    public func log(_ id: String) -> JobLog {
        return JobLog.read(logPath(id))
    }

    /// Where the job's command writes its progress events and error.
    public func logPath(_ id: String) -> String {
        return path(id, Self.logName)
    }

    /// The ids of every job folder, oldest first.
    func ids() throws -> [String] {
        // No job was ever started in this store.
        guard FileSystem.exists(jobsDirectory.path) else {
            return []
        }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: jobsDirectory.path)
        } catch {
            throw AgentVMError.system(operation: "list \(jobsDirectory.path)", code: FileSystem.posixCode(error))
        }
        return names.filter(Self.isValidID).sorted()
    }

    /// Every job, oldest first, with problems (an unreadable record) as warnings. With
    /// `prune`, finished jobs that ended over a week ago, and folders a start left behind half
    /// made, are removed first.
    ///
    /// `endedWithin`: only the jobs that have not ended, and those that ended that many seconds
    /// ago or less (`status`, which runs often, reads no older job's log).
    public func list(prune: Bool = false, endedWithin: TimeInterval? = nil) throws -> (jobs: [Job], problems: [String]) {
        var jobs: [Job] = []
        var problems: [String] = []
        let now = Date()
        for id in try ids() {
            let record: JobRecord
            do {
                record = try self.record(id)
            } catch AgentVMError.jobNotFound {
                // A start that died between making the folder and writing job.json: never
                // listed, and removed once it is clearly not a start still under way.
                if prune, let made = Self.modificationDate(directory(of: id).path),
                   now.timeIntervalSince(made) > Self.abandonedSeconds {
                    try? FileSystem.removeTree(directory(of: id).path)
                }
                continue
            } catch {
                problems.append("\(error)")
                continue
            }
            let looked = state(id)
            if let ended = looked.endedAt {
                if prune, now.timeIntervalSince(ended) > Self.keepSeconds {
                    try? FileSystem.removeTree(directory(of: id).path)
                    continue
                }
                if let endedWithin, now.timeIntervalSince(ended) > endedWithin {
                    continue
                }
            }
            jobs.append(job(record, looked))
        }
        jobs.sort { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        return (jobs, problems)
    }

    // MARK: - Changing

    /// Asks a running job to stop: SIGINT to its runner, which passes it to the command. agent-vm
    /// stops at its next safe point and exits 130; the job then ends canceled. A queued job ends
    /// canceled at once, and so does every job queued after it.
    public func cancel(_ id: String) throws {
        _ = try record(id)
        guard !state(id).state.isFinished else {
            throw AgentVMError.jobNotRunning(id)
        }
        // The runner writes its pid first thing; a job started a moment ago may not have yet.
        var info = runnerInfo(id)
        let deadline = ContinuousClock.now + .seconds(2)
        while info == nil && ContinuousClock.now < deadline && runnerHoldsLock(id) {
            usleep(20_000)
            info = runnerInfo(id)
        }
        guard let info else {
            throw state(id).state.isFinished ? AgentVMError.jobNotRunning(id) : AgentVMError.jobNotStarted(id)
        }
        // Checked once more right before the signal: while the runner holds the lock it is
        // alive, so the pid is still its own.
        guard runnerHoldsLock(id) else {
            throw AgentVMError.jobNotRunning(id)
        }
        guard kill(info.pid, SIGINT) == 0 else {
            throw AgentVMError.system(operation: "signal the runner of job \(id)", code: errno)
        }
    }

    /// Removes a job that no longer runs, with its log; also one whose record cannot be read
    /// (damaged, or from a newer format), once nothing holds its lock.
    public func forget(_ id: String) throws {
        do {
            _ = try record(id)
        } catch AgentVMError.corruptJobRecord {
            guard !runnerHoldsLock(id) else {
                throw AgentVMError.jobRunning(id)
            }
            try FileSystem.removeTree(directory(of: id).path)
            return
        }
        guard state(id).state.isFinished else {
            throw AgentVMError.jobRunning(id)
        }
        // A job queued after this one looks for its record to learn that it succeeded: removed
        // first, the queue behind it would end canceled (a client that forgets each job as
        // soon as it is done).
        for other in try ids() where other != id {
            if let waiting = try? record(other), waiting.after == id, state(other).state == .queued {
                throw AgentVMError.jobAwaited(id, by: other)
            }
        }
        try FileSystem.removeTree(directory(of: id).path)
    }

    /// Records a job and starts its runner, detached: `runner` plus the job's id is the
    /// runner's command line (`agent-vm job run`), and it receives the job's lock on
    /// descriptor `runnerLockDescriptor`. Of `environment` the runner (and so the command)
    /// gets what a detached process needs (`DetachedEnvironment`), with AGENT_VM_HOME set to
    /// this store, so the command works on the store that holds its record. With `after`, the job waits for that one and runs only when it
    /// ended with status 0; one that already ended otherwise is refused here. Returns the
    /// record once the runner is started.
    public func start(executable: String, arguments: [String], targets: [String], directory: String, after: String? = nil,
                      runner: [String], environment: [String: String] = ProcessInfo.processInfo.environment) throws -> JobRecord {
        guard executable.hasPrefix("/"), let runnerPath = runner.first, runnerPath.hasPrefix("/") else {
            throw AgentVMError.system(operation: "start a job: the command and the runner need absolute paths", code: EINVAL)
        }
        try StoreRoot.prepare(root)
        try FileSystem.makeDirectories(jobsDirectory.path)
        _ = try? list(prune: true)
        // Looked at after the pruning, which could otherwise remove it under the new job.
        if let after {
            _ = try record(after)
            let predecessor = state(after).state
            if predecessor != .done, predecessor.isFinished {
                throw AgentVMError.jobWouldNeverRun(after: after, state: predecessor.rawValue)
            }
        }

        var id = Self.newID()
        while mkdir(self.directory(of: id).path, 0o700) != 0 {
            let code = errno
            guard code == EEXIST else {
                throw AgentVMError.system(operation: "create folder \(self.directory(of: id).path)", code: code)
            }
            id = Self.newID()
        }
        do {
            let record = JobRecord(id: id, executable: executable, arguments: arguments, targets: targets, directory: directory, after: after)
            try spawnRunner(record, runner: runner, environment: environment)
            return record
        } catch {
            try? FileSystem.removeTree(self.directory(of: id).path)
            throw error
        }
    }

    private func spawnRunner(_ record: JobRecord, runner: [String], environment: [String: String]) throws {
        let id = record.id
        // Taken before job.json exists, so no list ever sees a record without a live lock.
        let opened = open(path(id, Self.lockName), O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard opened >= 0 else {
            throw AgentVMError.system(operation: "create \(path(id, Self.lockName))", code: errno)
        }
        // Above the descriptor the runner receives it on: dup2 onto itself would keep its
        // close-on-exec flag, and the runner would start without the lock.
        let lock = fcntl(opened, F_DUPFD_CLOEXEC, 10)
        let dupError = errno
        close(opened)
        guard lock >= 0 else {
            throw AgentVMError.system(operation: "open \(path(id, Self.lockName))", code: dupError)
        }
        // Closed without LOCK_UN: an unlock would release the runner's copy too (one open file).
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw AgentVMError.system(operation: "lock \(path(id, Self.lockName))", code: errno)
        }
        do {
            try Self.encoder.encode(record).write(to: directory(of: id).appendingPathComponent(Self.recordName), options: .atomic)
        } catch {
            throw AgentVMError.system(operation: "write \(path(id, Self.recordName))", code: FileSystem.posixCode(error))
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // Nothing of the caller's: a handler reading `job start` through $( ) waits until every
        // copy of its pipe is closed, and the terminal may go away.
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, lock, Self.runnerLockDescriptor)
        posix_spawn_file_actions_addchdir(&actions, "/")
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own session, away from the terminal; every other descriptor closed; signals as
        // a fresh process has them, whatever the caller ignored (a shell's `&` ignores SIGINT).
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var defaulted = sigset_t()
        sigemptyset(&defaulted)
        for signalNumber in JobRunner.defaultedSignals {
            sigaddset(&defaulted, signalNumber)
        }
        posix_spawnattr_setsigdefault(&attributes, &defaulted)
        var empty = sigset_t()
        sigemptyset(&empty)
        posix_spawnattr_setsigmask(&attributes, &empty)

        // Not the caller's whole environment: a job's commands take nothing from it.
        var runnerEnvironment = environment
        runnerEnvironment["AGENT_VM_HOME"] = root.path
        let environmentList = DetachedEnvironment.list(runnerEnvironment)
        let argv = runner + [id]
        var pid: pid_t = 0
        let status = GuestServer.withCStrings(argv) { argvPointer in
            GuestServer.withCStrings(environmentList) { envp in
                posix_spawn(&pid, argv[0], &actions, &attributes, argvPointer, envp)
            }
        }
        guard status == 0 else {
            throw AgentVMError.system(operation: "start the job runner \(argv[0])", code: status)
        }
        // Reaped when it ends, for a caller that lives on (a test); agent-vm job start exits
        // at once and leaves it to launchd.
        let runnerPid = pid
        DispatchQueue.global(qos: .utility).async {
            var waitStatus: Int32 = 0
            while waitpid(runnerPid, &waitStatus, 0) < 0 && errno == EINTR {}
        }
    }
}
