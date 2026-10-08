// Sources/agent-vm/StoreCommand.swift
//
// `agent-vm store ...`: what concerns the whole store. `secure-passwords` moves the account
// passwords of images and boxes made before 0.6.0 from their `Password` files into the login
// Keychain (AccountPasswordMove). `logs` lists and removes the logs of deleted boxes (KeptLogs).

import AgentVMKit
import ArgumentParser
import Foundation

struct StoreCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "store",
        abstract: "Look after the store as a whole.",
        subcommands: [SecurePasswords.self, Logs.self]
    )

    struct SecurePasswords: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "secure-passwords",
            abstract: "Move account passwords from Password files into your login Keychain.",
            discussion: """
                Images and boxes made before 0.6.0 keep the guest account's password in a \
                plain-text file in their folder. This moves each one into the Keychain, where \
                new images keep theirs: an image, the images derived from it and their boxes \
                share one item. A file is removed only after the Keychain gave the same \
                password back. Images and boxes in use are skipped and named: run it again \
                later. An agent-vm older than 0.6.0 no longer reads what was moved.

                Leave out the image the tests use (`--except dev`): they run an ad hoc build, \
                which macOS asks about before it reads an item this agent-vm stored.
                """)

        @Option(name: .long, help: "An image to leave alone, with its boxes (repeatable). Images derived from it are named on their own.")
        var except: [String] = []

        @OptionGroup var options: StoreOptions

        func run() throws {
            guard AccountPasswordStore.keepsNewPasswords else {
                throw AgentVMError.keychain(operation: "move account passwords into the Keychain", message: "this agent-vm is an ad hoc build, which keeps account passwords in files: the Keychain ties an item to the program that stored it, and would ask about it after every rebuild. Run the installed agent-vm")
            }
            let result = try AccountPasswordMove.run(images: options.imageStore, boxes: options.boxStore, except: Set(except))
            if options.json {
                try Output.json(result)
                if !result.failed.isEmpty {
                    throw ExitCode(1)
                }
                return
            }
            if result.moved.isEmpty && result.skipped.isEmpty && result.failed.isEmpty {
                print("No image or box keeps its account password in a file.")
            }
            if !result.moved.isEmpty {
                print("Moved into the Keychain (\(result.items) new item\(result.items == 1 ? "" : "s")): \(result.moved.joined(separator: ", "))")
            }
            for skipped in result.skipped {
                print("Kept its file: \(skipped.name): \(skipped.reason)")
            }
            for failed in result.failed {
                Stderr.write("Not moved: \(failed.name): \(failed.reason)\n")
            }
            if !result.failed.isEmpty {
                throw ExitCode(1)
            }
        }
    }
    struct Logs: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "logs",
            abstract: "List or remove the logs of deleted boxes.",
            discussion: """
                A deleted box's logs are kept: `box delete`, `box recreate`, `box gc` and the \
                temporary box of avm move them to Logs/<box>-<time>/ in the store before the \
                box's folder goes (<time> is when, in UTC). They are the box's own files: \
                exec.jsonl (what ran), network-allowed.jsonl and network.jsonl (what it \
                contacted, and what was refused), supervisor.log, and a Linux box's console.log. \
                A box that logged nothing leaves nothing.

                They stay for \(KeptLogs.holdDays) days: `box gc` removes older ones (and so do `box list`, \
                `box start` and `doctor`, which run it). --remove takes the names this command \
                lists; --remove-older-than 0 removes all of them.
                """)

        @Option(name: .long, help: ArgumentHelp("Remove one deleted box's logs (repeatable).", valueName: "id"))
        var remove: [String] = []

        @Option(name: .customLong("remove-older-than"), help: ArgumentHelp("Remove the logs of boxes deleted this many days ago or earlier.", valueName: "days"))
        var removeOlderThan: Int?

        @OptionGroup var options: StoreOptions

        struct Result: Encodable {
            /// Where kept logs are, whether or not there are any.
            var directory: String
            var holdDays: Int
            /// What is kept now, the newest first.
            var logs: [KeptLogs.Entry]
            /// What this run removed, by id; absent when it was not asked to remove.
            var removed: [String]?
            var problems: [String]?
        }

        func validate() throws {
            if let removeOlderThan, removeOlderThan < 0 {
                throw ValidationError("--remove-older-than takes a number of days, 0 or more")
            }
        }

        func run() throws {
            let kept = KeptLogs(root: options.boxStore.root)
            var removed: [String]?
            var problems: [String] = []
            if !remove.isEmpty || removeOlderThan != nil {
                var ids: [String] = []
                // Every name is checked before the first one goes.
                for id in remove where !kept.exists(id) {
                    throw AgentVMError.keptLogsNotFound(id)
                }
                for id in remove where !ids.contains(id) {
                    try kept.remove(id)
                    ids.append(id)
                }
                if let removeOlderThan {
                    let older = kept.removeOlder(thanDays: removeOlderThan)
                    ids += older.removed
                    problems = older.problems
                }
                removed = ids
            }
            let entries = kept.list()
            if options.json {
                try Output.json(Result(directory: kept.directory.path, holdDays: KeptLogs.holdDays, logs: entries, removed: removed,
                                       problems: problems.isEmpty ? nil : problems))
                if !problems.isEmpty {
                    throw ExitCode(1)
                }
                return
            }
            for problem in problems {
                Stderr.write("warning: \(problem)\n")
            }
            if let removed {
                for id in removed {
                    print("Removed the kept logs \(id)")
                }
                if removed.isEmpty && problems.isEmpty {
                    print("No kept logs that old.")
                }
                if !problems.isEmpty {
                    throw ExitCode(1)
                }
                return
            }
            guard !entries.isEmpty else {
                print("No logs of deleted boxes are kept (they would be in \(kept.directory.path)).")
                return
            }
            for entry in entries {
                let from = entry.logs.image.map { ", image \(Printable.line($0, limit: 63))" } ?? ""
                print("\(entry.logs.id)  box \(Printable.line(entry.logs.box, limit: 63))\(from)  deleted \(Output.time(entry.logs.keptAt))  \(Self.size(entry.bytes))")
                print("    \(entry.path)")
                print("    \(entry.files.joined(separator: ", "))")
            }
            print("Kept for \(KeptLogs.holdDays) days after the box was deleted; remove one with: agent-vm store logs --remove <name>")
        }

        /// A log's size: these are KB more often than MB.
        static func size(_ bytes: Int64) -> String {
            if bytes < 1000 {
                return "\(bytes) bytes"
            }
            if bytes < 999_500 {
                return "\((bytes + 500) / 1000) KB"
            }
            return Output.size(bytes)
        }
    }
}
