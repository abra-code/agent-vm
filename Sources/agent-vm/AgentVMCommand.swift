// Sources/agent-vm/AgentVMCommand.swift
//
// Entry point of the agent-vm command-line tool. Every subcommand is a thin layer over
// AgentVMKit: parse arguments, call the library, print for a person or (with --json) for a
// program such as Cadabra.

import AgentVMKit
import AppKit
import ArgumentParser
import Foundation

@main
enum Main {
    @MainActor
    static func main() async {
        AskpassEntry.handleIfAskpass()
        // A box supervisor in a login session runs AppKit's loop, so `box view` can show the
        // box's screen. The loop is entered here, in main itself: entered inside a main-actor
        // job (as a command's run() is), it would never drain the main queue again, and the
        // supervisor, which runs on the main actor, would never start (measured).
        if BoxCommand.Serve.shouldRunAppKit(CommandLine.arguments) || ImageCommand.Setup.shouldRunAppKit(CommandLine.arguments) {
            BoxCommand.Serve.runsAppKit = true
            let application = NSApplication.shared
            application.setActivationPolicy(.prohibited)
            Task { @MainActor in
                await AgentVMCommand.main()
                exit(0)
            }
            application.run()
            // run() returns only after NSApp.stop, which nothing calls; the command must not run twice.
            return
        }
        await AgentVMCommand.main()
    }
}

struct AgentVMCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent-vm",
        abstract: "Run AI agents inside disposable macOS virtual machines, and undo what they did.",
        version: AgentVM.version,
        subcommands: [ExecCommand.self, BoxCommand.self, ImageCommand.self, SessionCommand.self, DoctorCommand.self]
    )
}

extension RiskFlag.Severity: ExpressibleByArgument {}
extension BoxNetwork.Mode: ExpressibleByArgument {}

/// Options shared by commands that read or change the store.
struct StoreOptions: ParsableArguments {
    @Flag(name: .long, help: "Print machine-readable JSON instead of text.")
    var json = false

    var store: SessionStore {
        return SessionStore(root: SessionStore.defaultRoot())
    }

    var imageStore: ImageStore {
        return ImageStore(root: SessionStore.defaultRoot())
    }

    var boxStore: BoxStore {
        return BoxStore(root: SessionStore.defaultRoot())
    }
}

enum Output {
    static func json<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    /// A change report for a person: a summary, then one line per change, flagged ones marked.
    static func printReport(_ report: ChangeReport) {
        let summary = report.summary
        print("Session \(report.session): \(report.project)")
        print("  since \(time(report.startedAt)): \(summary.added) added, \(summary.deleted) deleted, \(summary.modified) modified, \(summary.typeChanged) changed type, \(summary.metadata) permission changes")
        if summary.flaggedHigh + summary.flaggedMedium > 0 {
            print("  review first: \(summary.flaggedHigh) high, \(summary.flaggedMedium) medium")
        }
        for warning in report.warnings {
            print("  warning: \(warning)")
        }
        if report.isEmpty {
            print("  no changes")
            return
        }
        print("")
        let marks: [ChangeKind: String] = [.added: "A", .deleted: "D", .modified: "M", .typeChanged: "T", .metadata: "P"]
        for change in report.changes {
            let severity: String
            switch change.highestSeverity {
            case .high?: severity = "HIGH  "
            case .medium?: severity = "medium"
            default: severity = "      "
            }
            var line = "\(severity) \(marks[change.kind] ?? "?") \(change.path)"
            if change.type == .directory, change.kind != .metadata {
                line += "/"
            }
            if let inside = change.entriesInside, inside > 0 {
                line += " (\(inside) entries inside)"
            }
            if let target = change.symlinkTarget {
                line += " -> \(target)"
            }
            if change.coveredByAncestor {
                line += " (inside a changed folder)"
            }
            print(line)
            for flag in change.flags where flag.severity != .info {
                print("         \(flag.reason)")
            }
        }
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// A command as a shell would take it back: words with anything but letters, digits and
    /// @%+=:,./_- single-quoted.
    static func shellQuoted(_ argv: [String]) -> String {
        let plain = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./_-")
        return argv.map { word in
            if !word.isEmpty && word.allSatisfy({ plain.contains($0) }) {
                return word
            }
            return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
}
