// Sources/agent-vm/JobCommand.swift
//
// `agent-vm job`: long commands (an image build, a guest update, Full Disk Access setup, a
// restore image download, a box start or stop) run detached, so closing the terminal, the
// window or the application that started them does not end them, and any client (another
// terminal, AgentVM.app, Cadabra) sees them in `job list`. JobStore keeps the records,
// JobRunner is the detached process (`job run`, hidden).

import AgentVMKit
import ArgumentParser
import Darwin
import Foundation

/// A command `job start` runs: all of them report with --json, and name what they work on.
protocol JobTask {
    var jobTargets: [String] { get }
}

extension ImageCommand.Create: JobTask {
    var jobTargets: [String] { ["image:\(name)"] }
}

extension ImageCommand.UpdateGuest: JobTask {
    var jobTargets: [String] { names.map { "image:\($0)" } }
}

extension ImageCommand.Setup: JobTask {
    var jobTargets: [String] { ["image:\(name)"] }
}

extension ImageCommand.FetchIPSW: JobTask {
    var jobTargets: [String] { ["ipsw"] }
}

extension BoxCommand.Start: JobTask {
    var jobTargets: [String] { ["box:\(name)"] }
}

extension BoxCommand.Stop: JobTask {
    var jobTargets: [String] { ["box:\(name)"] }
}

extension StoreOptions {
    var jobStore: JobStore {
        return JobStore(root: SessionStore.defaultRoot())
    }
}

struct JobCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "job",
        abstract: "Run long commands detached, and follow, cancel or forget them.",
        discussion: """
            A job is an agent-vm command (image create, image update-guest, image setup, image \
            fetch-ipsw, box start or box stop) run in the background, in its own session: \
            closing the terminal or the application that started it does not end it. Its \
            record, progress events and result are kept in the store's Jobs folder, where \
            `job list` and `job log` read them from any terminal or application; finished jobs \
            are kept for a week.
            """,
        subcommands: [Start.self, List.self, Log.self, Cancel.self, Forget.self, Run.self]
    )

    static let taskNames = "image create, image update-guest, image setup, image fetch-ipsw, box start and box stop"

    struct Start: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Start an agent-vm command as a job and print its id.",
            discussion: """
                The command follows --, as it would follow agent-vm: `agent-vm job start -- image \
                create dev --ipsw latest`. It runs with --json (added when missing), its \
                progress events going to the job's log and its result to the job's output, in \
                this folder, so relative paths mean what they mean here. It is checked before \
                the job starts: a mistyped command fails here, not in the background. With \
                --json: the job, as `job list --json` shows it.
                """)

        @OptionGroup var options: StoreOptions

        @Argument(parsing: .postTerminator, help: ArgumentHelp("The agent-vm command, after --.", valueName: "command"))
        var command: [String] = []

        /// What the job runs: the command, with --json.
        var arguments: [String] {
            return command.contains("--json") ? command : command + ["--json"]
        }

        /// The command as agent-vm parses it, when a job may run it.
        func task() throws -> JobTask {
            let parsed: ParsableCommand
            do {
                parsed = try AgentVMCommand.parseAsRoot(arguments)
            } catch {
                throw ValidationError("the job's command: \(AgentVMCommand.message(for: error))")
            }
            guard let task = parsed as? JobTask else {
                throw ValidationError("a job runs \(JobCommand.taskNames); not `\(Output.shellQuoted(command))`")
            }
            return task
        }

        func validate() throws {
            if command.isEmpty {
                throw ValidationError("give the command after --, for example: agent-vm job start -- image create dev --ipsw latest")
            }
            _ = try task()
        }

        func run() throws {
            let task = try task()
            let executable = try AskpassEntry.executablePath()
            let store = options.jobStore
            let record = try store.start(executable: executable, arguments: arguments, targets: task.jobTargets,
                                         directory: FileManager.default.currentDirectoryPath, runner: [executable, "job", "run"])
            if options.json {
                try Output.json(try store.job(record.id))
                return
            }
            print(record.id)
            // For a person; a script reading the id through $( ) gets the id alone.
            if isatty(STDOUT_FILENO) == 1 {
                print("  follow it with: agent-vm job log \(record.id) --follow")
            }
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List the jobs: those that run, and those that ended in the last week.",
            discussion: """
                One entry per job, oldest first: its id, state and command, then its last \
                progress (while it runs) or its error (after it failed). The states are \
                running, done, failed, canceled, and lost (its runner was stopped before it \
                could record the result). Finished jobs older than a week are removed. With \
                --json: an array of jobs, each with `id`, `command` (agent-vm's arguments), \
                `targets` ("image:<name>", "box:<name>", "ipsw"), `state`, `status` (the exit \
                status, once it ended), `createdAt`, `startedAt`, `endedAt`, `progress` (the \
                last progress event), `notice` (the last notice's text), `error` and `path`.
                """)

        @OptionGroup var options: StoreOptions

        func run() throws {
            let (jobs, problems) = try options.jobStore.list(prune: true)
            for problem in problems {
                FileHandle.standardError.write(Data("warning: \(problem)\n".utf8))
            }
            if options.json {
                try Output.json(jobs)
                return
            }
            if jobs.isEmpty {
                print("No jobs")
                return
            }
            for job in jobs {
                for line in Self.lines(job) {
                    print(line)
                }
            }
        }

        /// A job for a person: its id, state and command, then what it is doing or why it
        /// ended as it did.
        static func lines(_ job: Job) -> [String] {
            let command = Output.shellQuoted(job.command.filter { $0 != "--json" })
            var lines = ["\(job.id)  \(job.state.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0))  \(command)"]
            switch job.state {
            case .running:
                if let progress = job.progress {
                    let percent = progress.fraction.map { " \(Int(($0 * 100).rounded()))%" } ?? ""
                    lines.append("    \(progress.message)\(percent)")
                } else {
                    lines.append("    starting")
                }
                if let notice = job.notice {
                    lines.append("    \(notice)")
                }
            case .failed, .lost:
                let status = job.status.map { "status \($0): " } ?? ""
                let error = job.error.map { $0.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? $0 } ?? "no reason given"
                lines.append("    \(status)\(error)")
            case .done, .canceled:
                break
            }
            if let ended = job.endedAt {
                lines.append("    ended \(Output.time(ended))")
            }
            return lines
        }
    }

    struct Log: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show a job's progress and how it ended.",
            discussion: """
                The command's progress, one line per event, and its error, then the job's \
                state. --follow shows new lines as they come until the job ends. With --json: \
                `job` (as `job list --json` shows it), `events` (every progress event) and \
                `lines` (what the command wrote that is neither an event nor its error).
                """)

        @Argument(help: "The job's id (`agent-vm job list` shows them).")
        var id: String

        @Flag(name: .shortAndLong, help: "Keep showing new lines until the job ends.")
        var follow = false

        @OptionGroup var options: StoreOptions

        func validate() throws {
            if follow && options.json {
                throw ValidationError("--follow is for a person; with --json, read `job list --json` again instead")
            }
        }

        struct Report: Encodable {
            var job: Job
            var events: [ProgressEvent]
            var lines: [String]
        }

        func run() throws {
            let store = options.jobStore
            _ = try store.record(id)
            if options.json {
                let log = store.log(id)
                try Output.json(Report(job: try store.job(id), events: log.events, lines: log.otherLines))
                return
            }
            let reader = LineReader(path: store.logPath(id))
            while true {
                // Looked at before reading: what was written before the job ended is shown.
                let job = try store.job(id)
                for line in reader.readLines(final: job.state.isFinished) {
                    if let text = Self.text(line) {
                        print(text)
                    }
                }
                if !follow || job.state.isFinished {
                    print(Self.ending(job))
                    return
                }
                usleep(500_000)
            }
        }

        /// A log line for a person: an event's text, as the command would have printed it (a
        /// notice's text says it is one); any other line as it is.
        static func text(_ line: String) -> String? {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                return nil
            }
            return JobLog.parse(line).events.first?.message ?? line
        }

        static func ending(_ job: Job) -> String {
            switch job.state {
            case .running:
                return "Job \(job.id) is running"
            case .done:
                return "Job \(job.id) is done"
            case .failed:
                return "Job \(job.id) failed\(job.status.map { " (status \($0))" } ?? "")"
            case .canceled:
                return "Job \(job.id) was canceled"
            case .lost:
                return "Job \(job.id) was lost: \(job.error ?? "its runner stopped without recording a result")"
            }
        }
    }

    struct Cancel: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Ask a running job to stop.",
            discussion: """
                Sends SIGINT to the job's command, which stops at its next safe point (an image \
                build shuts its guest down and is recorded as canceled); the job then ends \
                canceled. It returns at once: `job log --follow` shows the end. With --json: \
                the job, as `job list --json` shows it.
                """)

        @Argument(help: "The job's id.")
        var id: String

        @OptionGroup var options: StoreOptions

        func run() throws {
            let store = options.jobStore
            try store.cancel(id)
            if options.json {
                try Output.json(try store.job(id))
                return
            }
            print("Asked job \(id) to stop; it stops at its next safe point")
        }
    }

    struct Forget: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove a finished job's record and log.",
            discussion: "A running job is refused: cancel it first. With --json: the job as it was.")

        @Argument(help: "The job's id.")
        var id: String

        @OptionGroup var options: StoreOptions

        func run() throws {
            let store = options.jobStore
            let job = try store.job(id)
            try store.forget(id)
            if options.json {
                try Output.json(job)
                return
            }
            print("Forgot job \(id)")
        }
    }

    struct Run: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run a job's command and record how it ends (job start does this in the background).",
            shouldDisplay: false)

        @Argument(help: "The job's id.")
        var id: String

        func run() throws {
            let status = JobRunner.run(store: JobStore(root: SessionStore.defaultRoot()), id: id, lockDescriptor: JobStore.runnerLockDescriptor)
            if status != 0 {
                throw ExitCode(status)
            }
        }
    }
}

/// Reads a growing file line by line: each call returns the whole lines added since the last.
final class LineReader {
    private let path: String
    private var offset: UInt64 = 0
    private var pending = Data()

    init(path: String) {
        self.path = path
    }

    /// `final`: the writer is done, so a last line without its newline is returned too.
    func readLines(final: Bool) -> [String] {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor >= 0 {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            if (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd() {
                offset += UInt64(data.count)
                pending.append(data)
            }
        }
        var lines: [String] = []
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
            pending = Data(pending[pending.index(after: newline)...])
        }
        if final && !pending.isEmpty {
            lines.append(String(decoding: pending, as: UTF8.self))
            pending = Data()
        }
        return lines
    }
}
