// Sources/agent-vm/SessionCommand.swift
//
// `agent-vm session ...`: Live-mode sessions. A session snapshots a project folder before an
// agent works on it, reports what the agent changed (flagging what would run later on the
// host), and can undo the run.

import AgentVMKit
import ArgumentParser
import Foundation

struct SessionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session",
        abstract: "Snapshot a project before an agent works on it, and undo the run.",
        discussion: """
            A session takes an instant copy-on-write snapshot of the project folder (an APFS \
            clone of every file). The agent then edits the real folder; `report` lists what \
            changed and flags files that run code later on this Mac; `undo` puts back what \
            changed and keeps what the agent left behind for recovery.
            State lives in $AGENT_VM_HOME (default ~/Library/Application Support/agent-vm); the \
            project must be on the same APFS volume.
            """,
        subcommands: [Start.self, List.self, Report.self, End.self, Undo.self, Discard.self]
    )

    struct Start: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Snapshot a project and start a session.")

        @Option(name: .long, help: "The project folder the agent will work on.")
        var project: String

        @OptionGroup var options: StoreOptions

        func run() throws {
            let clock = ContinuousClock()
            let began = clock.now
            let session = try options.store.start(project: project)
            let elapsed = clock.now - began
            if options.json {
                try Output.json(session.record)
                return
            }
            print("Started session \(session.id) for \(session.record.project)")
            print("  snapshot: \(session.snapshotPath) (\(elapsed.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow))))")
            print("  undo everything with: agent-vm session undo \(session.id)")
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List sessions, oldest first.")

        @OptionGroup var options: StoreOptions

        func run() throws {
            let (sessions, problems) = try options.store.listWithProblems()
            for problem in problems {
                FileHandle.standardError.write(Data("warning: \(problem)\n".utf8))
            }
            if options.json {
                try Output.json(sessions.map(\.record))
                return
            }
            if sessions.isEmpty {
                print("No sessions.")
                return
            }
            for session in sessions {
                let record = session.record
                let state = record.state.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)
                print("\(record.id)  \(state)  \(Output.time(record.startedAt))  \(record.project)")
            }
        }
    }

    struct End: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Mark a session as ended. The snapshot is kept for undo.")

        @Argument(help: "The session id.")
        var id: String

        @OptionGroup var options: StoreOptions

        func run() throws {
            let session = try options.store.end(id: id)
            if options.json {
                try Output.json(session.record)
                return
            }
            print("Ended session \(session.id). Undo is still available: agent-vm session undo \(session.id)")
        }
    }

    struct Report: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show what changed in the project since the session started.",
            discussion: """
                Flags mark changes that run code later on this Mac (git hooks and config, agent \
                configuration such as .mcp.json or AGENTS.md, build scripts, package manifests, \
                editor tasks, executables, symlinks leaving the project). They are a review aid, \
                not a security boundary.
                """)

        @Argument(help: "The session id.")
        var id: String

        @Option(name: .long, help: "Exit with status 2 if any change is flagged at this severity or above (high or medium).")
        var failOn: RiskFlag.Severity?

        @OptionGroup var options: StoreOptions

        func run() throws {
            let report = try options.store.report(id: id)
            if options.json {
                try Output.json(report)
            } else {
                Output.printReport(report)
            }
            if let failOn, report.changes.contains(where: { ($0.highestSeverity ?? .info) >= failOn }) {
                throw ExitCode(2)
            }
        }
    }

    struct Undo: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Restore the project to its state when the session started.",
            discussion: """
                Stop the agent first. By default only what changed is put back, so editors and \
                shells with the project open stay attached; the agent's versions are moved into \
                the session folder, never deleted. --whole-tree instead swaps the whole folder \
                with a copy of the snapshot in one atomic step (programs with the project open \
                then keep seeing the replaced copy until they reopen it).
                """)

        @Argument(help: "The session id.")
        var id: String

        @Flag(name: .long, help: "Swap the whole project folder instead of restoring changed files.")
        var wholeTree = false

        @OptionGroup var options: StoreOptions

        func run() throws {
            let outcome = try options.store.undo(id: id, mode: wholeTree ? .wholeTree : .changedFiles)
            let session = outcome.session
            if options.json {
                try Output.json(UndoJSON(session: session.record, restore: outcome.restore))
            } else if outcome.isComplete {
                print("Restored \(session.record.project) to its state at \(Output.time(session.record.startedAt)).")
                if let restore = outcome.restore {
                    print("  \(restore.restored.count) changed entries put back")
                } else {
                    print("  editors or shells with the project open should reopen it")
                }
                if let replaced = session.replacedTreePath {
                    print("  what the agent left is kept at: \(replaced)")
                }
                print("  delete the snapshot and kept files with: agent-vm session discard \(session.id)")
            } else if let restore = outcome.restore {
                print("Could not restore everything in \(session.record.project):")
                for (path, reason) in restore.failed.sorted(by: { $0.key < $1.key }) {
                    print("  \(path): \(reason)")
                }
                print("  \(restore.remaining) changes remain; the session can still be undone.")
                print("  Retry, or swap the whole folder: agent-vm session undo \(session.id) --whole-tree")
            }
            if !outcome.isComplete {
                throw ExitCode(1)
            }
        }

        struct UndoJSON: Encodable {
            let session: SessionRecord
            let restore: RestoreResult?
        }
    }

    struct Discard: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete a session's snapshot and replaced tree. Undo is no longer possible.")

        @Argument(help: "The session id.")
        var id: String

        @OptionGroup var options: StoreOptions

        func run() throws {
            let session = try options.store.discard(id: id)
            if options.json {
                try Output.json(session.record)
                return
            }
            print("Discarded session \(session.id): snapshot deleted; the record remains in `agent-vm session list`.")
        }
    }
}
