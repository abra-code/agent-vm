// Sources/agent-vm/StoreCommand.swift
//
// `agent-vm store ...`: what concerns the whole store. `secure-passwords` moves the account
// passwords of images and boxes made before 0.6.0 from their `Password` files into the login
// Keychain (AccountPasswordMove).

import AgentVMKit
import ArgumentParser
import Foundation

struct StoreCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "store",
        abstract: "Look after the store as a whole.",
        subcommands: [SecurePasswords.self]
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
}
