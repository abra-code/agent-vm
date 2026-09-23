// Sources/agent-vm/SessionCommand.swift
//
// `agent-vm session ...`: Live-mode sessions. A session snapshots a project folder before an
// agent works on it, so the run can be undone as a whole.

import AgentVMKit
import ArgumentParser
import Foundation

struct SessionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session",
        abstract: "Snapshot a project before an agent works on it, and undo the run.",
        discussion: """
            A session takes an instant copy-on-write snapshot of the project folder (an APFS \
            clone of every file). The agent then edits the real folder; `undo` restores the \
            folder to the snapshot in one atomic swap and keeps what the agent left behind for \
            recovery.
            State lives in $AGENT_VM_HOME (default ~/Library/Application Support/agent-vm); the \
            project must be on the same APFS volume.
            """,
        subcommands: [Start.self, List.self, End.self, Undo.self, Discard.self]
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

    struct Undo: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Restore the project to its state when the session started.",
            discussion: """
                Stop the agent first. The project folder is swapped atomically with a copy of \
                the snapshot; what the agent left behind is kept in the session folder. \
                Programs that still have the project open (editors, shells) keep seeing the \
                replaced copy until they reopen it.
                """)

        @Argument(help: "The session id.")
        var id: String

        @OptionGroup var options: StoreOptions

        func run() throws {
            let session = try options.store.undo(id: id)
            if options.json {
                try Output.json(session.record)
                return
            }
            print("Restored \(session.record.project) to its state at \(Output.time(session.record.startedAt)).")
            if let replaced = session.replacedTreePath {
                print("  the replaced tree is kept at: \(replaced)")
            }
            print("  editors or shells with the project open should reopen it")
            print("  delete the snapshot and replaced tree with: agent-vm session discard \(session.id)")
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
