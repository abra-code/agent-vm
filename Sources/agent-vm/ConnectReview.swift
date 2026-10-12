// Sources/agent-vm/ConnectReview.swift
//
// What a session changed, as the rows of the list connect shows after it (a Checklist): one
// row for each change, the flagged ones first, with what can be undone on its own markable.
// An entry inside a folder that was added, deleted or replaced as a whole is listed only
// because it carries a flag; it goes with its folder, so its row cannot be marked.

import AgentVMKit
import Foundation
import TerminalUI

enum ConnectReview {
    static func kind(_ change: Change) -> String {
        switch change.kind {
        case .added: return "added"
        case .deleted: return "deleted"
        case .modified: return "modified"
        case .typeChanged: return "new type"
        case .metadata: return "permissions"
        }
    }

    static func severity(_ change: Change) -> String {
        switch change.highestSeverity {
        case .high?: return "HIGH"
        case .medium?: return "medium"
        default: return ""
        }
    }

    /// The path as the report shows it: a folder ends with "/".
    static func path(_ change: Change) -> String {
        return Printable.line(change.path) + (change.type == .directory && change.kind != .metadata ? "/" : "")
    }

    /// The rows (the id of each is its change's path), and the lines shown about the row
    /// under the cursor: the whole path, then why it is flagged (for a folder changed as a
    /// whole, also why the entries inside it are).
    static func rows(_ report: ChangeReport) -> (rows: [PickerRow], details: [String: [String]]) {
        func rank(_ change: Change) -> Int {
            switch change.highestSeverity {
            case .high?: return 0
            case .medium?: return 1
            default: return 2
            }
        }
        let sorted = report.changes.sorted { rank($0) != rank($1) ? rank($0) < rank($1) : $0.path < $1.path }
        let whole = report.changes.filter { !$0.coveredByAncestor }
        var rows: [PickerRow] = []
        var details: [String: [String]] = [:]
        // For a folder changed as a whole: the flags of the entries inside it.
        var covered: [String: [String]] = [:]
        for change in sorted {
            var notes: [String] = []
            if let inside = change.entriesInside, inside > 0 {
                notes.append("\(inside) \(inside == 1 ? "entry" : "entries") inside")
            }
            if let target = change.symlinkTarget {
                notes.append("-> " + Printable.line(target))
            }
            if change.coveredByAncestor {
                // The nearest folder above it that changed as a whole.
                let folder = whole.filter { change.path.unicodeScalars.starts(with: ($0.path + "/").unicodeScalars) }
                    .max { $0.path.unicodeScalars.count < $1.path.unicodeScalars.count }
                notes.append(folder.map { "goes with \(Printable.line($0.path))/" } ?? "goes with its folder")
                // The cursor never rests on this row: why it is flagged is said with its folder.
                if let folder {
                    covered[folder.path, default: []] += change.flags.filter { $0.severity != .info }.map { "\(path(change)): \(Printable.line($0.reason))" }
                }
            }
            rows.append(PickerRow(id: change.path, columns: [severity(change), kind(change), path(change)],
                                  note: notes.isEmpty ? nil : notes.joined(separator: ", "), enabled: !change.coveredByAncestor))
            details[change.path] = [path(change)] + change.flags.filter { $0.severity != .info }.map { Printable.line($0.reason) }
        }
        for (folder, reasons) in covered {
            details[folder, default: []] += reasons
        }
        return (rows, details)
    }

    /// The list for `report`; `summary` is its lines under the title.
    static func list(_ report: ChangeReport, summary: [String]) -> Checklist {
        let (rows, details) = rows(report)
        let place = report.scope == .gitFolders ? "the git folders of " : ""
        return Checklist(name: "AgentVM", title: "what changed in \(place)\(ConnectRunner.tilde(report.project))", summary: summary,
                         rows: rows, details: details, words: Checklist.Words(action: "undo", rest: "keep"))
    }
}
