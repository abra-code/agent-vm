// Sources/agent-vm-guest/main.swift
//
// Entry point of the daemon that runs inside the guest. Only the version report exists so far.

import AgentVMKit
import Foundation

let arguments = CommandLine.arguments.dropFirst()

if arguments.first == "--version" {
    print("agent-vm-guest \(AgentVM.version) (protocol \(AgentVM.guestProtocolVersion))")
    exit(0)
}

FileHandle.standardError.write(Data("agent-vm-guest \(AgentVM.version): not implemented yet. Try --version.\n".utf8))
exit(64) // EX_USAGE
