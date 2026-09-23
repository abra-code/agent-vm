// Sources/agent-vm/AgentVMCommand.swift
//
// Entry point of the agent-vm command-line tool. Every subcommand is a thin layer over
// AgentVMKit: parse arguments, call the library, print for a person or (with --json) for a
// program such as Cadabra.

import AgentVMKit
import ArgumentParser
import Foundation

@main
struct AgentVMCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent-vm",
        abstract: "Run AI agents inside disposable macOS virtual machines, and undo what they did.",
        version: AgentVM.version,
        subcommands: [SessionCommand.self]
    )
}

/// Options shared by commands that read or change the store.
struct StoreOptions: ParsableArguments {
    @Flag(name: .long, help: "Print machine-readable JSON instead of text.")
    var json = false

    var store: SessionStore {
        return SessionStore(root: SessionStore.defaultRoot())
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

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
