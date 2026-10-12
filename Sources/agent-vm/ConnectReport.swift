// Sources/agent-vm/ConnectReport.swift
//
// After a session whose folder was snapshotted: what changed, as a list on the whole window
// in which the entries to undo are marked (ConnectReview); Enter undoes the marked ones and
// keeps the rest, and with none marked keeps them all. Without cursor control (TERM=dumb): what
// changed in short, then keep the changes, show every change, or undo them all. No changes: the session is discarded, since there is
// nothing to undo (unless something could not be examined; the snapshot then stays). The report, the undo and ending the session run
// with signals held (SignalHold), so none of them stops halfway; a signal that arrived
// meanwhile ends connect afterwards, with the session ended and kept for undo.

import AgentVMKit
import Darwin
import Foundation
import TerminalUI

enum ConnectReport {
    /// The summary and the report's warnings.
    static func summaryLines(_ report: ChangeReport) -> [String] {
        let summary = report.summary
        var counts: [String] = []
        for (count, words) in [(summary.added, "added"), (summary.deleted, "deleted"), (summary.modified, "modified"),
                               (summary.typeChanged, "changed type"), (summary.metadata, "permission")] where count > 0 {
            counts.append(words == "permission" ? "\(count) permission change\(count == 1 ? "" : "s")" : "\(count) \(words)")
        }
        let place = report.scope == .gitFolders ? "the git folders of " : ""
        var line = "Session \(report.session): \(counts.joined(separator: ", ")) in \(place)\(ConnectRunner.tilde(report.project))"
        var review: [String] = []
        if summary.flaggedHigh > 0 {
            review.append("\(summary.flaggedHigh) high")
        }
        if summary.flaggedMedium > 0 {
            review.append("\(summary.flaggedMedium) medium")
        }
        if !review.isEmpty {
            line += "; review first: " + review.joined(separator: ", ")
        }
        var lines = [line]
        for warning in report.warnings {
            lines.append("  warning: \(Printable.line(warning))")
        }
        return lines
    }

    /// The summary, the report's warnings, and the flagged changes (at most `flaggedLimit`).
    static func shortLines(_ report: ChangeReport, flaggedLimit: Int = 10) -> [String] {
        var lines = summaryLines(report)
        let flagged = report.changes.filter { $0.highestSeverity == .high || $0.highestSeverity == .medium }
        for change in flagged.prefix(flaggedLimit) {
            lines += Output.changeLines(change)
        }
        if flagged.count > flaggedLimit {
            lines.append("... and \(flagged.count - flaggedLimit) more flagged; r shows every change")
        }
        return lines
    }

    /// Reports on `session` and asks what to do with the changes. Returns a signal that ended
    /// the conversation (SIGTERM, SIGHUP, or SIGINT during a step), for connect to exit with;
    /// the session is then ended, kept for undo.
    static func run(session: Session, store: SessionStore, box: Box, terminal: Terminal, warn: (String) -> Void) -> Int32? {
        let project = ConnectRunner.tilde(session.record.project)
        let (result, signal) = SignalHold.around { try store.report(id: session.id) }
        if let signal {
            end(session, store: store, warn: warn)
            return signal
        }
        let report: ChangeReport
        switch result {
        case .success(let value):
            report = value
        case .failure(let error):
            warn("could not report on session \(session.id): \(error); the snapshot is kept: agent-vm session report \(session.id), agent-vm session undo \(session.id)")
            return end(session, store: store, warn: warn)
        }
        // What ran and what was contacted, in one line; the whole is `session report`.
        let activity = SessionActivity.of(session, root: store.root).line(size: StoreCommand.Logs.size)
        if report.isEmpty && report.warnings.isEmpty {
            print(report.scope == .gitFolders ? "No changes in the git folders of \(project) (working files were not compared)." : "No changes in \(project).")
            if let activity {
                print("  \(activity)")
            }
            // Discarding ends an active session too.
            let (outcome, signal) = SignalHold.around { try store.discard(id: session.id) }
            if case .failure(let error) = outcome {
                warn("could not discard session \(session.id): \(error)")
            }
            return signal
        }
        if report.isEmpty {
            // Something could not be examined, so the scan may have missed a change: the
            // snapshot stays.
            print("No changes found in \(report.scope == .gitFolders ? "the git folders of " : "")\(project), but:")
            for warning in report.warnings {
                print("  warning: \(Printable.line(warning))")
            }
            return keep(session, store: store, warn: warn)
        }
        if terminal.style.cursorControl {
            // The list, then its summary again: the list leaves nothing on the terminal.
            let summary = summaryLines(report) + (activity.map { ["  \($0)"] } ?? [])
            var marked = Set<String>()
            var shown = true
            do {
                marked = try ConnectReview.list(report, summary: summary).run(on: terminal)
            } catch TerminalUIError.interrupted(let signal) {
                end(session, store: store, warn: warn)
                return signal
            } catch TerminalUIError.canceled {
                // Escape or Control-C: nothing is undone without a yes.
            } catch {
                // The list could not be shown: the flagged changes are printed with the summary.
                shown = false
            }
            for line in shown ? summary : shortLines(report) + (activity.map { ["  \($0)"] } ?? []) {
                print(line)
            }
            if marked.isEmpty {
                return keep(session, store: store, warn: warn)
            }
            // Every entry that can be undone on its own: the whole session.
            let all = report.changes.filter { !$0.coveredByAncestor }.count
            return undo(session, store: store, box: box, project: project, paths: marked.count == all ? nil : marked.sorted(),
                        terminal: terminal, warn: warn)
        }
        for line in shortLines(report) {
            print(line)
        }
        if let activity {
            print("  \(activity)")
        }
        let choice = Choice(prompt: nil, options: [Choice.Option(key: "k", label: "keep the changes"),
                                                   Choice.Option(key: "r", label: "show every change"),
                                                   Choice.Option(key: "u", label: "undo them all")],
                            defaultKey: "k")
        while true {
            let key: Character
            do {
                key = try choice.run(on: terminal)
            } catch TerminalUIError.interrupted(let signal) {
                end(session, store: store, warn: warn)
                return signal
            } catch {
                // Escape or Control-C: nothing is undone without a yes.
                key = "k"
            }
            switch key {
            case "r":
                // Held too: a signal while a long list prints must not leave the session active.
                let (_, signal) = SignalHold.around { Output.printReport(report) }
                if let signal {
                    end(session, store: store, warn: warn)
                    return signal
                }
                continue
            case "u":
                return undo(session, store: store, box: box, project: project, paths: nil, terminal: terminal, warn: warn)
            default:
                return keep(session, store: store, warn: warn)
            }
        }
    }

    /// Ends the session and says how to undo it later.
    private static func keep(_ session: Session, store: SessionStore, warn: (String) -> Void) -> Int32? {
        let signal = end(session, store: store, warn: warn)
        print("Kept. Undo later with: agent-vm session undo \(session.id)")
        return signal
    }

    /// Undoes the session, or only the changes at `paths` (as the report lists them). After
    /// an undo of some, the session is ended and the rest stays undoable.
    private static func undo(_ session: Session, store: SessionStore, box: Box, project: String, paths: [String]?, terminal: Terminal,
                             warn: (String) -> Void) -> Int32? {
        // A box left running still has the folder shared: what connect can see using it is other
        // clients' programs (exec counts them). Programs the agent left running in the
        // background are not counted; the documentation says to stop them first.
        // Held: the count can take a second or more, and a signal then must not leave the
        // session active.
        let (counted, countSignal) = SignalHold.around { otherPrograms(in: box) }
        if let countSignal {
            end(session, store: store, warn: warn)
            return countSignal
        }
        let others = (try? counted.get()) ?? 0
        if others > 0 {
            print("\(others == 1 ? "1 program runs" : "\(others) programs run") in box \(box.name) through exec (another terminal or application) and may use \(project).")
            do {
                if try !Confirm("Undo anyway?", defaultAnswer: false).run(on: terminal) {
                    return keep(session, store: store, warn: warn)
                }
            } catch TerminalUIError.interrupted(let signal) {
                end(session, store: store, warn: warn)
                return signal
            } catch {
                return keep(session, store: store, warn: warn)
            }
        }
        // Each marked entry alone: a folder marked for its permissions does not take the
        // unmarked changes under it.
        let (result, signal) = SignalHold.around { try store.undo(id: session.id, paths: paths, exactPaths: true) }
        switch result {
        case .success(let outcome):
            for line in paths != nil && outcome.isComplete ? SessionCommand.Undo.selectionLines(outcome) : SessionCommand.Undo.lines(outcome) {
                print(line)
            }
            if outcome.session.record.state != .undone {
                // An incomplete undo, or one of some entries, leaves the session active; ended,
                // a later session on the folder is not refused, and `session undo` still works
                // on it.
                return end(session, store: store, warn: warn) ?? signal
            }
            return signal
        case .failure(let error):
            // The error can name an entry (one marked that is no longer a change): the agent's text.
            warn("could not undo session \(session.id): \(Printable.line("\(error)")); retry with: agent-vm session undo \(session.id)")
            return end(session, store: store, warn: warn) ?? signal
        }
    }

    /// Programs other than this session's running in the box through exec. The supervisor may
    /// still count this session's connection for a moment after the child exited, so a count
    /// above 0 is asked again a few times before it is believed.
    static func otherPrograms(in box: Box) -> Int {
        var count = 0
        for attempt in 0..<4 {
            if attempt > 0 {
                usleep(300_000)
            }
            count = BoxStatus.of(box).activeExecs ?? 0
            if count == 0 {
                return 0
            }
        }
        return count
    }

    /// Ends an active session (held against signals), and returns a signal that arrived
    /// meanwhile. A session that is no longer active is left as it is.
    @discardableResult
    static func end(_ session: Session, store: SessionStore, warn: (String) -> Void) -> Int32? {
        let (result, signal) = SignalHold.around { () -> Void in
            guard try store.session(id: session.id).record.state == .active else {
                return
            }
            try store.end(id: session.id)
        }
        if case .failure(let error) = result {
            warn("could not end session \(session.id): \(error); end it with: agent-vm session end \(session.id)")
        }
        return signal
    }
}
