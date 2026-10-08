// Sources/agent-vm/BoxEventsCommand.swift
//
// `agent-vm box events <name>`: what happened to a box that is neither a program nor a
// connection (BoxEventLog): started, ready, stopped, a folder shared, the rules changed, the
// screen shown and typed into, files sent.

import AgentVMKit
import ArgumentParser
import Foundation

extension BoxCommand {
    struct EventLogCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "events",
            abstract: "Show what happened to a box: started, shared, rules changed, shown, files sent.",
            discussion: """
                One line per event, oldest first: the box started, its guest daemon answered \
                (ready), it stopped; a folder of this Mac was shared with it or taken back; its \
                network rules or mode were changed (the rules before and after, and whether it \
                ran: a running box is told of the change at once); its screen was shown; its password \
                or other text was typed into the screen (never what was typed); files were sent \
                to it. Programs are in `box execlog` and connections in `box netlog`.

                The log is kept on this Mac (Boxes/<name>/events.jsonl), out of the box's reach, \
                since agent-vm 0.7.19: a box started by an earlier agent-vm has no events until \
                it is started again. --since, --until, --session and --kept are as for the \
                other two logs.
                """)

        @Argument(help: "The box name.")
        var name: String

        @Option(name: .long, help: "Only the last N events.")
        var last: Int?

        @OptionGroup var log: LogOptions

        @OptionGroup var options: StoreOptions

        func validate() throws {
            if let last, last < 0 {
                throw ValidationError("--last takes a count of 0 or more")
            }
        }

        func run() throws {
            let source = try log.source(name, store: options.boxStore)
            defer { source.discard() }
            let window = try log.window(hosts: [], root: options.boxStore.root)
            let events = source.eventLog.events(last: last) { window.accepts(time: $0.time) }
            if options.json {
                try Output.json(events)
                return
            }
            if events.isEmpty {
                print("No events are logged for \(source.label)\(window.isEmpty ? "" : " in that time").")
                return
            }
            for event in events {
                // One line each: a path, a file's name and the guest daemon's version are not
                // agent-vm's text, and a newline in one would read as an event of its own.
                print(Printable.line(Self.text(event)))
            }
        }

        static func rules(_ network: BoxNetwork) -> String {
            switch network.mode {
            case .open:
                return "open"
            case .off:
                return "off"
            case .allowlist:
                return network.allow.isEmpty ? "allowlist, nothing allowed" : "allowlist: \(network.allow.joined(separator: ", "))"
            }
        }

        static func text(_ event: BoxEventLog.Event) -> String {
            var line = "\(Output.time(event.time))  \(event.event.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0))"
            switch event.event {
            case .start, .ready, .stop:
                line += event.detail.map { "  \($0)" } ?? ""
            case .share:
                line += "  \(event.path ?? "?")\(event.readOnly == true ? " (read only)" : "")"
            case .unshare:
                line += "  \(event.path ?? "?")"
            case .rules:
                line += "  \(event.before.map(rules) ?? "?")  ->  \(event.after.map(rules) ?? "?")"
                line += event.running == true ? "  (the box was running)" : "  (the box was stopped)"
            case .view:
                line += event.interactive == true ? "  interactive" : "  view only"
            case .type:
                line += event.password == true ? "  the account's password" : "  \(event.characters ?? 0) characters"
            case .send:
                let items = (event.items ?? []).map { item in
                    var text = item.name
                    if let received = item.received {
                        text += " as \(received)"
                    }
                    if let bytes = item.bytes {
                        text += " (\(StoreCommand.Logs.size(bytes)))"
                    }
                    return text
                }
                line += "  \(items.joined(separator: ", "))"
            }
            // The kinds stand in a column; one with nothing more to say ends at its name.
            while line.hasSuffix(" ") {
                line.removeLast()
            }
            return line
        }
    }
}
