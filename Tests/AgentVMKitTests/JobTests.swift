// Tests/AgentVMKitTests/JobTests.swift
//
// Jobs: the real runner (`agent-vm job run`, the binary this build produced) runs detached
// around a stand-in command, a shell script that writes progress events a tenth of a second
// apart and stops on SIGINT or SIGTERM as agent-vm does. What is pinned: a start returns at once
// while the job goes on in its own session; progress, results and errors in the listing;
// cancel; a runner that dies leaves a lost job, not one running forever; a runner started by
// hand does nothing; forget; pruning; job ids cannot name a path; a queue (--after) that runs
// on success and is canceled, with the reason, down the chain on a failure.

import Darwin
import Foundation
import Testing
@testable import AgentVMKit

/// A private store, the stand-in command, and the built agent-vm as the runner.
final class JobScratch {
    let root: URL
    let store: JobStore
    let command: String
    let runner: [String]

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("agent-vm-jobs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: try FileSystem.canonicalPath(base.path), isDirectory: true)
        store = JobStore(root: root.appendingPathComponent("store", isDirectory: true))
        command = root.appendingPathComponent("fake-command").path
        try Data(Self.script.utf8).write(to: URL(fileURLWithPath: command))
        chmod(command, 0o755)
        runner = [try ConnectScratch.builtAgentVM(), "job", "run"]
    }

    deinit {
        // A job a failed test left running is canceled, and its command killed if that is not
        // enough: while the runner holds the lock it has not reaped the command, so the pids it
        // recorded are still theirs.
        for id in (try? store.ids()) ?? [] where !store.state(id).state.isFinished {
            try? store.cancel(id)
            let deadline = Date().addingTimeInterval(2)
            while store.runnerHoldsLock(id) && Date() < deadline {
                usleep(50_000)
            }
            if store.runnerHoldsLock(id), let command = store.runnerInfo(id)?.commandPid {
                kill(command, SIGKILL)
            }
        }
        try? FileSystem.removeTree(root.path)
    }

    /// events N: N progress events, a notice, a result on stdout, status 0. fail: an event,
    /// then a two-line error, status 1. wait: events until a signal; SIGINT or SIGTERM end it
    /// with 130 or 143 and agent-vm's message. where: the folder and the store it runs with.
    static let script = """
        #!/bin/sh
        trap 'printf "Error: canceled by SIGINT\\n" >&2; exit 130' INT
        trap 'printf "Error: canceled by SIGTERM\\n" >&2; exit 143' TERM
        printf '{"event":"progress","message":"starting","step":"starting"}\\n' >&2
        case "$1" in
            events)
                i=1
                while [ "$i" -le "$2" ]; do
                    /bin/sleep 0.1
                    printf '{"event":"progress","fraction":%s,"message":"step %s","step":"install"}\\n' "0.$i" "$i" >&2
                    i=$((i + 1))
                done
                printf '{"event":"notice","message":"look at this"}\\n' >&2
                printf '{"ok":true}\\n'
                exit 0
                ;;
            fail)
                printf 'warning: something odd\\n' >&2
                printf 'Error: the guest did not answer\\nsee the log\\n' >&2
                exit 1
                ;;
            wait)
                while :; do
                    printf '{"event":"progress","message":"waiting","step":"wait"}\\n' >&2
                    /bin/sleep 0.1
                done
                ;;
            where)
                /bin/pwd
                printf '%s\\n' "$AGENT_VM_HOME"
                exit 0
                ;;
        esac
        exit 3
        """

    func start(_ arguments: [String], directory: String = "/", after: String? = nil, runner: [String]? = nil) throws -> String {
        return try store.start(executable: command, arguments: arguments, targets: ["box:b1"], directory: directory, after: after,
                               runner: runner ?? self.runner).id
    }

    /// The job once it is in `state`; fails the test after `seconds`.
    func wait(_ id: String, for state: JobState, seconds: Double = 10) throws -> Job {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            let job = try store.job(id)
            if job.state == state || Date() > deadline {
                #expect(job.state == state)
                return job
            }
            usleep(50_000)
        }
    }

    /// Waits until the job's log has `text`.
    func waitForLog(_ id: String, _ text: String, seconds: Double = 10) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let log = (try? String(contentsOfFile: store.path(id, JobStore.logName), encoding: .utf8)) ?? ""
            if log.contains(text) {
                return true
            }
            usleep(50_000)
        }
        return false
    }
}

@Suite struct JobTests {
    @Test func aJobRunsDetachedAndEndsDone() throws {
        let scratch = try JobScratch()
        let began = Date()
        let id = try scratch.start(["events", "5"])
        // Five events a tenth of a second apart: the start did not wait for them.
        #expect(Date().timeIntervalSince(began) < 0.4)
        #expect(JobStore.isValidID(id))
        let running = try scratch.store.job(id)
        #expect(running.state == .running)
        #expect(running.targets == ["box:b1"])
        #expect(running.command == ["events", "5"])
        #expect(running.status == nil && running.endedAt == nil)

        let job = try scratch.wait(id, for: .done)
        #expect(job.status == 0)
        #expect(job.progress?.step == "install")
        #expect(job.progress?.message == "step 5")
        #expect(job.progress?.fraction == 0.5)
        #expect(job.notice == "look at this")
        #expect(job.error == nil)
        #expect(job.startedAt != nil && job.endedAt != nil)
        let output = try String(contentsOfFile: scratch.store.path(id, JobStore.outputName), encoding: .utf8)
        #expect(output == "{\"ok\":true}\n")

        // The runner ran in its own session, away from the caller's terminal.
        let info = try #require(scratch.store.runnerInfo(id))
        #expect(info.commandPid != nil)
        #expect(info.pid != getpid())
    }

    @Test func theRunnerIsASessionLeaderAndHoldsTheLock() throws {
        let scratch = try JobScratch()
        let id = try scratch.start(["wait"])
        #expect(scratch.waitForLog(id, "waiting"))
        let info = try #require(scratch.store.runnerInfo(id))
        #expect(getsid(info.pid) == info.pid)
        #expect(scratch.store.runnerHoldsLock(id))
        // The command does not hold it: the lock tells the runner's life, nothing else's.
        #expect(getsid(try #require(info.commandPid)) == info.pid)
        try scratch.store.cancel(id)
        _ = try scratch.wait(id, for: .canceled)
        #expect(!scratch.store.runnerHoldsLock(id))
    }

    @Test func cancelPassesSIGINTAndEndsCanceled() throws {
        let scratch = try JobScratch()
        let id = try scratch.start(["wait"])
        #expect(scratch.waitForLog(id, "waiting"))
        try scratch.store.cancel(id)
        let job = try scratch.wait(id, for: .canceled)
        #expect(job.status == 130)
        #expect(job.error == "canceled by SIGINT")
        #expect(throws: AgentVMError.jobNotRunning(id)) { try scratch.store.cancel(id) }
    }

    /// A caller that ignores SIGINT (a shell's `&`) does not make the command deaf to cancel.
    @Test func theCommandGetsSIGINTEvenWhenTheCallerIgnoredIt() throws {
        let scratch = try JobScratch()
        let ignoring = ["/bin/sh", "-c", "trap '' INT; exec \"$0\" job run \"$1\"", scratch.runner[0]]
        let id = try scratch.start(["wait"], runner: ignoring)
        #expect(scratch.waitForLog(id, "waiting"))
        try scratch.store.cancel(id)
        let job = try scratch.wait(id, for: .canceled)
        #expect(job.status == 130)
    }

    @Test func aFailureKeepsAgentVMsMessage() throws {
        let scratch = try JobScratch()
        let id = try scratch.start(["fail"])
        let job = try scratch.wait(id, for: .failed)
        #expect(job.status == 1)
        #expect(job.error == "the guest did not answer\nsee the log")
        let log = scratch.store.log(id)
        #expect(log.otherLines == ["warning: something odd"])
        #expect(log.events.count == 1)
    }

    @Test func aCommandThatCannotRunFailsWithTheReason() throws {
        let scratch = try JobScratch()
        let id = try scratch.start(["events", "1"], directory: scratch.root.appendingPathComponent("gone").path)
        let job = try scratch.wait(id, for: .failed)
        #expect(job.status == 127)
        #expect(job.error?.contains("in \(scratch.root.path)/gone failed") == true)
    }

    @Test func theCommandRunsWhereItWasStartedAndOnTheJobsStore() throws {
        let scratch = try JobScratch()
        let id = try scratch.start(["where"], directory: scratch.root.path)
        _ = try scratch.wait(id, for: .done)
        let output = try String(contentsOfFile: scratch.store.path(id, JobStore.outputName), encoding: .utf8)
        #expect(output == "\(scratch.root.path)\n\(scratch.store.root.path)\n")
    }

    @Test func aRunnerThatDiesLeavesTheJobLost() throws {
        let scratch = try JobScratch()
        let id = try scratch.start(["wait"])
        #expect(scratch.waitForLog(id, "waiting"))
        let info = try #require(scratch.store.runnerInfo(id))
        // By the pid the job recorded, while the lock proves it is still this job's runner.
        #expect(scratch.store.runnerHoldsLock(id))
        kill(info.pid, SIGKILL)
        let job = try scratch.wait(id, for: .lost)
        #expect(job.error == JobStore.lostError)
        #expect(job.status == nil)
        #expect(job.endedAt != nil)
        if let command = info.commandPid {
            kill(command, SIGKILL)
        }
        // A lost job no longer runs: it can be forgotten.
        try scratch.store.forget(id)
        #expect(!FileSystem.exists(scratch.store.directory(of: id).path))
    }

    /// Runs `agent-vm job run <id>` by hand, as `sh -c` with `redirect` (such as "3<file");
    /// returns its exit status.
    func runByHand(_ scratch: JobScratch, _ id: String, redirect: String = "") throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exec \"$0\" job run \"$1\" \(redirect)", scratch.runner[0], id]
        process.environment = ["AGENT_VM_HOME": scratch.store.root.path, "PATH": "/usr/bin:/bin"]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// `agent-vm job run` started by hand, without the lock job start hands down, is not the
    /// job's runner: a lost job stays lost, nothing is run or written.
    @Test func aRunnerWithoutTheLockDoesNothing() throws {
        let scratch = try JobScratch()
        let id = try scratch.start(["wait"])
        #expect(scratch.waitForLog(id, "waiting"))
        let info = try #require(scratch.store.runnerInfo(id))
        kill(info.pid, SIGKILL)
        _ = try scratch.wait(id, for: .lost)
        if let command = info.commandPid {
            kill(command, SIGKILL)
        }
        // A short command in its record: a runner that wrongly ran it would end, and the test
        // fail, rather than wait on the endless one.
        var record = try scratch.store.record(id)
        record.arguments = ["events", "1"]
        try JobStore.encoder.encode(record).write(to: scratch.store.directory(of: id).appendingPathComponent(JobStore.recordName))
        #expect(try runByHand(scratch, id) == 2)
        #expect(try scratch.store.job(id).state == .lost)
        #expect(!FileSystem.exists(scratch.store.path(id, JobStore.endName)))
    }

    /// A job that has ended is never run again, even by a runner given its free lock file.
    @Test func anEndedJobIsNotRunAgain() throws {
        let scratch = try JobScratch()
        let id = try scratch.start(["events", "1"])
        _ = try scratch.wait(id, for: .done)
        let end = try Data(contentsOf: scratch.store.directory(of: id).appendingPathComponent(JobStore.endName))
        let lock = scratch.store.path(id, JobStore.lockName)
        #expect(try runByHand(scratch, id, redirect: "3<'\(lock)'") == 2)
        #expect(try Data(contentsOf: scratch.store.directory(of: id).appendingPathComponent(JobStore.endName)) == end)
        #expect(try String(contentsOfFile: scratch.store.path(id, JobStore.outputName), encoding: .utf8).count(where: { $0 == "\n" }) == 1)
    }

    @Test func anUnreadableRecordCanBeForgotten() throws {
        let scratch = try JobScratch()
        let id = try scratch.start(["events", "1"])
        _ = try scratch.wait(id, for: .done)
        try Data("{".utf8).write(to: scratch.store.directory(of: id).appendingPathComponent(JobStore.recordName))
        #expect(try scratch.store.list().problems.count == 1)
        try scratch.store.forget(id)
        #expect(!FileSystem.exists(scratch.store.directory(of: id).path))
    }

    @Test func forgetRefusesARunningJob() throws {
        let scratch = try JobScratch()
        let id = try scratch.start(["wait"])
        #expect(throws: AgentVMError.jobRunning(id)) { try scratch.store.forget(id) }
        #expect(FileSystem.exists(scratch.store.directory(of: id).path))
        try scratch.store.cancel(id)
        _ = try scratch.wait(id, for: .canceled)
        try scratch.store.forget(id)
        #expect(try scratch.store.list().jobs.isEmpty)
    }

    @Test func aQueuedJobRunsOnceTheOneBeforeItSucceeds() throws {
        let scratch = try JobScratch()
        let first = try scratch.start(["events", "5"])
        let second = try scratch.start(["where"], directory: scratch.root.path, after: first)
        let queued = try scratch.store.job(second)
        #expect(queued.state == .queued)
        #expect(queued.after == first)
        #expect(queued.startedAt == nil)
        let done = try scratch.wait(second, for: .done)
        let before = try scratch.store.job(first)
        #expect(before.state == .done)
        #expect(try #require(done.startedAt) >= (try #require(before.endedAt)))
    }

    @Test func aFailureCancelsTheQueueBehindIt() throws {
        let scratch = try JobScratch()
        let first = try scratch.start(["fail"])
        let second = try scratch.start(["events", "1"], after: first)
        let third = try scratch.start(["events", "1"], after: second)
        let canceled = try scratch.wait(third, for: .canceled)
        #expect(canceled.error == "job \(second), which it waited for, was canceled")
        let middle = try scratch.store.job(second)
        #expect(middle.state == .canceled)
        #expect(middle.error == "job \(first), which it waited for, failed (status 1)")
        #expect(middle.status == nil && middle.startedAt == nil)
        // It never ran: nothing in its output or log.
        #expect(try String(contentsOfFile: scratch.store.path(second, JobStore.outputName), encoding: .utf8).isEmpty)
        #expect(scratch.store.log(second).events.isEmpty)
    }

    @Test func aQueuedJobCanBeCanceled() throws {
        let scratch = try JobScratch()
        let first = try scratch.start(["wait"])
        let second = try scratch.start(["events", "1"], after: first)
        let third = try scratch.start(["events", "1"], after: second)
        _ = try scratch.wait(second, for: .queued)
        try scratch.store.cancel(second)
        let canceled = try scratch.wait(second, for: .canceled)
        #expect(canceled.error == "canceled by SIGINT")
        #expect(canceled.startedAt == nil)
        #expect(try scratch.wait(third, for: .canceled).error == "job \(second), which it waited for, was canceled")
        // The one it waited for goes on.
        #expect(try scratch.store.job(first).state == .running)
        try scratch.store.cancel(first)
        _ = try scratch.wait(first, for: .canceled)
    }

    /// Forgotten as soon as it is done (a client tidying up), the job would take with it the
    /// record its follower reads to learn that it succeeded.
    @Test func aJobAQueuedJobWaitsForIsNotForgotten() throws {
        let scratch = try JobScratch()
        let first = try scratch.start(["wait"])
        let second = try scratch.start(["events", "1"], after: first)
        _ = try scratch.wait(second, for: .queued)
        try scratch.store.cancel(first)
        _ = try scratch.wait(first, for: .canceled)
        _ = try scratch.wait(second, for: .canceled)
        // Once the follower has ended, the first can go.
        try scratch.store.forget(first)

        // A follower whose runner starts two seconds late is queued for that long, with the
        // first already done: the moment a tidying client would forget it.
        let third = try scratch.start(["events", "1"])
        _ = try scratch.wait(third, for: .done)
        let late = ["/bin/sh", "-c", "/bin/sleep 2; exec \"$0\" job run \"$1\"", scratch.runner[0]]
        let fourth = try scratch.start(["events", "1"], after: third, runner: late)
        #expect(try scratch.store.job(fourth).state == .queued)
        #expect(throws: AgentVMError.jobAwaited(third, by: fourth)) { try scratch.store.forget(third) }
        _ = try scratch.wait(fourth, for: .done)
        try scratch.store.forget(third)
    }

    @Test func aJobAfterOneThatDidNotSucceedIsRefused() throws {
        let scratch = try JobScratch()
        let failed = try scratch.start(["fail"])
        _ = try scratch.wait(failed, for: .failed)
        #expect(throws: AgentVMError.jobWouldNeverRun(after: failed, state: "failed")) {
            try scratch.start(["events", "1"], after: failed)
        }
        #expect(throws: AgentVMError.jobNotFound("20260101-000000-abcdef")) {
            try scratch.start(["events", "1"], after: "20260101-000000-abcdef")
        }
        #expect(try scratch.store.list().jobs.map(\.id) == [failed])
        // After one that is done already, it runs at once.
        let done = try scratch.start(["events", "1"])
        _ = try scratch.wait(done, for: .done)
        let next = try scratch.start(["events", "1"], after: done)
        _ = try scratch.wait(next, for: .done, seconds: 2)
        // One old enough to be pruned is pruned by this start before it is looked at: refused,
        // rather than accepted and then canceled as removed.
        try JobStore.encoder.encode(JobEnd(status: 0, canceled: false, endedAt: Date().addingTimeInterval(-8 * 24 * 3600)))
            .write(to: scratch.store.directory(of: done).appendingPathComponent(JobStore.endName))
        #expect(throws: AgentVMError.jobNotFound(done)) {
            try scratch.start(["events", "1"], after: done)
        }
    }

    @Test func jobIDsCannotNameAPath() throws {
        let scratch = try JobScratch()
        for id in ["../../Jobs", "..", "20260101-000000-ABCDEF", "20260101-000000-abcdef/x", ""] {
            #expect(throws: AgentVMError.invalidJobID(id)) { try scratch.store.cancel(id) }
            #expect(throws: AgentVMError.invalidJobID(id)) { try scratch.store.forget(id) }
        }
        #expect(throws: AgentVMError.jobNotFound("20260101-000000-abcdef")) { try scratch.store.job("20260101-000000-abcdef") }
    }

    @Test func oldFinishedJobsAndHalfMadeFoldersArePruned() throws {
        let scratch = try JobScratch()
        let old = try scratch.start(["events", "1"])
        // Start times keep milliseconds, and two starts in one process can fall in the same
        // one (measured 1 ms apart); the listing then orders them by their random id.
        usleep(5_000)
        let recent = try scratch.start(["events", "1"])
        _ = try scratch.wait(old, for: .done)
        _ = try scratch.wait(recent, for: .done)
        let eightDaysAgo = Date().addingTimeInterval(-8 * 24 * 3600)
        try JobStore.encoder.encode(JobEnd(status: 0, canceled: false, endedAt: eightDaysAgo))
            .write(to: scratch.store.directory(of: old).appendingPathComponent(JobStore.endName))
        // A start that died before writing job.json, two hours ago, and one under way now.
        let abandoned = scratch.store.directory(of: "20260101-000000-000001").path
        let underWay = scratch.store.directory(of: "20260101-000000-000002").path
        try FileSystem.makeDirectory(abandoned)
        try FileSystem.makeDirectory(underWay)
        var times = [timeval(tv_sec: time(nil) - 7200, tv_usec: 0), timeval(tv_sec: time(nil) - 7200, tv_usec: 0)]
        #expect(utimes(abandoned, &times) == 0)

        #expect(try scratch.store.list().jobs.map(\.id) == [old, recent])
        #expect(try scratch.store.list(prune: true).jobs.map(\.id) == [recent])
        #expect(!FileSystem.exists(scratch.store.directory(of: old).path))
        #expect(!FileSystem.exists(abandoned))
        #expect(FileSystem.exists(underWay))
    }

    /// Times in the job's files are full ISO 8601, zone included, with fractions of a second.
    @Test func timesKeepFractionsAndTheirTimeZone() throws {
        let moment = Date(timeIntervalSince1970: 1_790_000_000.25)
        let data = try JobStore.encoder.encode(JobEnd(status: 0, canceled: false, endedAt: moment))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""endedAt" : "2026-09-21T14:13:20.250Z""#))
        #expect(try JobStore.decoder.decode(JobEnd.self, from: data).endedAt == moment)
        let whole = Data(#"{"canceled":false,"endedAt":"2026-09-21T14:13:20Z"}"#.utf8)
        #expect(try JobStore.decoder.decode(JobEnd.self, from: whole).endedAt.timeIntervalSince1970 == 1_790_000_000)
    }

    @Test func aLogIsReadFromItsEnd() throws {
        let events = (1...5).map { #"{"event":"progress","message":"step \#($0)","step":"s"}"# }
        let text = (["plain line"] + events + ["Error: it broke", "  in two lines", ""]).joined(separator: "\n")
        let log = JobLog.parse(text)
        #expect(log.events.count == 5)
        #expect(log.lastProgress?.message == "step 5")
        #expect(log.lastNotice == nil)
        #expect(log.error == "it broke\n  in two lines")
        #expect(log.otherLines == ["plain line"])
        // Lines after the error are the error's, even ones that look like events.
        #expect(JobLog.parse("Error: a\n" + events[0]).events.isEmpty)
        // Without an "Error:" line, the last plain lines are the error.
        #expect(JobLog.parse("x\n" + events[0] + "\ny\n").error == "x\ny")

        let scratch = try JobScratch()
        let path = scratch.root.appendingPathComponent("log").path
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        // Cut inside the first event: that line is dropped, not misread.
        let tail = JobLog.read(path, limit: text.utf8.count - "plain line\n".utf8.count - 3)
        #expect(tail.events.count == 4)
        #expect(tail.otherLines.isEmpty)
        #expect(tail.error == "it broke\n  in two lines")
        #expect(JobLog.read(path + ".missing").events.isEmpty)
    }
}
