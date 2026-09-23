// Sources/agent-vm/main.swift
//
// Entry point of the agent-vm command-line tool. Only the version report exists so far; the
// subcommands described in the README are added as they are implemented.

import AgentVMKit
import Foundation

let arguments = CommandLine.arguments.dropFirst()

if arguments.first == "--version" {
    print("agent-vm \(AgentVM.version)")
    exit(0)
}

FileHandle.standardError.write(Data("agent-vm \(AgentVM.version): no commands are implemented yet. Try --version.\n".utf8))
exit(64) // EX_USAGE
