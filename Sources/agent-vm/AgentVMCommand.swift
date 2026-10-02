// Sources/agent-vm/AgentVMCommand.swift
//
// Entry point of the agent-vm command-line tool. Every subcommand is a thin layer over
// AgentVMKit: parse arguments, call the library, print for a person or (with --json) for a
// program such as Cadabra. Started under the name avm (a symlink), the tool is `agent-vm
// connect` (AVMCommand).

import AgentVMKit
import AppKit
import ArgumentParser
import Foundation

@main
enum Main {
    @MainActor
    static func main() async {
        AskpassEntry.handleIfAskpass()
        // Progress lines (an image build's) appear as they happen also when stdout is a file
        // or a pipe, which stdio would otherwise fill in blocks until the program exits.
        setvbuf(stdout, nil, _IOLBF, 0)
        // A box supervisor in a login session runs AppKit's loop, so `box view` can show the
        // box's screen. The loop is entered here, in main itself: entered inside a main-actor
        // job (as a command's run() is), it would never drain the main queue again, and the
        // supervisor, which runs on the main actor, would never start (measured).
        if !isAVM && (BoxCommand.Serve.shouldRunAppKit(CommandLine.arguments) || ImageCommand.Setup.shouldRunAppKit(CommandLine.arguments)) {
            BoxCommand.Serve.runsAppKit = true
            let application = NSApplication.shared
            application.setActivationPolicy(.prohibited)
            Task { @MainActor in
                await run()
                exit(0)
            }
            application.run()
            // run() returns only after NSApp.stop, which nothing calls; the command must not run twice.
            return
        }
        await run()
    }

    /// Started as avm: the last component of argv[0], so a symlink named avm anywhere (or a
    /// symlink to one) is avm, and any other name is agent-vm. The supervisor and the session
    /// child are started with the resolved path, never as avm.
    static var isAVM: Bool {
        guard let first = CommandLine.arguments.first else {
            return false
        }
        return (first as NSString).lastPathComponent == "avm"
    }

    /// How connect names itself in messages and hints.
    static var invokedName: String {
        return isAVM ? "avm" : "agent-vm connect"
    }

    @MainActor
    static func run() async {
        if isAVM {
            await run(AVMCommand.self)
        } else {
            await run(AgentVMCommand.self)
        }
    }

    /// Root.main(), except that a refusal for want of a free VM slot exits with its own status
    /// (AgentVMError.noFreeVMSlotStatus), so a program such as Cadabra tells it from other
    /// failures without reading the message. Errors exit through the root that was parsed, so
    /// usage lines name avm when started as avm.
    @MainActor
    static func run<Root: AsyncParsableCommand>(_ root: Root.Type) async {
        do {
            var command = try await Root.asyncParseAsRoot()
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch let error as AgentVMError {
            guard case .noFreeVMSlot = error else {
                Root.exit(withError: error)
            }
            Stderr.write("Error: \(error)\n")
            exit(AgentVMError.noFreeVMSlotStatus)
        } catch {
            // As Root.exit(withError:) does it (help and versions to standard output, errors to
            // standard error), but through this program's own printing: an error of another
            // type may quote text that is not agent-vm's as well.
            let message = Root.fullMessage(for: error)
            let code = Root.exitCode(for: error)
            if !message.isEmpty {
                if code == .success {
                    print(message)
                } else {
                    Stderr.write(message + "\n")
                }
            }
            exit(code.rawValue)
        }
    }
}

struct AgentVMCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent-vm",
        abstract: "Run AI agents inside disposable macOS virtual machines, and undo what they did.",
        version: AgentVM.version,
        subcommands: [ExecCommand.self, ConnectCommand.self, StatusCommand.self, BoxCommand.self, ImageCommand.self, JobCommand.self, SessionCommand.self, SecretCommand.self, StoreCommand.self, DoctorCommand.self, VersionCommand.self]
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

/// Where a long command's progress goes (ProgressEvent): each event's line on stdout for a
/// person, as before events existed; with --json one JSON object per line on stderr, so stdout
/// holds only the command's result.
enum Events {
    static func handler(json: Bool) -> @MainActor (ProgressEvent) -> Void {
        return { event in
            emit(event, json: json)
        }
    }

    static func emit(_ event: ProgressEvent, json: Bool) {
        if json {
            FileHandle.standardError.write(Data((event.jsonLine + "\n").utf8))
        } else {
            print(event.text)
        }
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
            print("  warning: \(Printable.line(warning))")
        }
        if report.isEmpty {
            print("  no changes")
            return
        }
        print("")
        for change in report.changes {
            for line in changeLines(change) {
                print(line)
            }
        }
    }

    /// One change as the report lists it: its line, then a line for each flag's reason.
    static func changeLines(_ change: Change) -> [String] {
        let marks: [ChangeKind: String] = [.added: "A", .deleted: "D", .modified: "M", .typeChanged: "T", .metadata: "P"]
        let severity: String
        switch change.highestSeverity {
        case .high?: severity = "HIGH  "
        case .medium?: severity = "medium"
        default: severity = "      "
        }
        // The names are the agent's: shown so that none can start a line of its own, erase the
        // lines above it or act on the terminal.
        var line = "\(severity) \(marks[change.kind] ?? "?") \(Printable.line(change.path))"
        if change.type == .directory, change.kind != .metadata {
            line += "/"
        }
        if let inside = change.entriesInside, inside > 0 {
            line += " (\(inside) entries inside)"
        }
        if let target = change.symlinkTarget {
            line += " -> \(Printable.line(target))"
        }
        if change.coveredByAncestor {
            line += " (inside a changed folder)"
        }
        return [line] + change.flags.filter { $0.severity != .info }.map { "         \(Printable.line($0.reason))" }
    }

    /// Bytes for a person, in decimal units as Finder shows them: "36.1 GB", "310 MB".
    static func size(_ bytes: Int64) -> String {
        if bytes >= 999_500_000 {
            return String(format: "%.1f GB", Double(bytes) / 1e9)
        }
        return "\((bytes + 500_000) / 1_000_000) MB"
    }

    /// The folder of an image or box and the space it takes, as indented lines under its entry
    /// in a list. `others` names what it may share blocks with; `delete` is the command that
    /// frees the unshared part.
    static func placeLines(_ folder: URL, _ usage: DiskUsage, others: String, delete: String) -> [String] {
        guard let unshared = usage.unsharedBytes else {
            return ["    \(folder.path)", "    \(size(usage.bytes)) (this volume does not report what is shared)"]
        }
        return ["    \(folder.path)", "    \(size(usage.bytes)), of which \(size(unshared)) not shared with \(others) (what \(delete) frees)"]
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
