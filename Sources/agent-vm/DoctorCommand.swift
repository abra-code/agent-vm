// Sources/agent-vm/DoctorCommand.swift
//
// `agent-vm doctor`: can this Mac, and this binary, run boxes? Exits 1 when something
// prevents it (wrong macOS, no Apple silicon, missing entitlement); warnings do not change
// the exit status.

import AgentVMKit
import ArgumentParser
import Foundation

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check that this Mac and this agent-vm binary can run boxes.",
        discussion: """
            Checks the macOS version, Apple silicon, the virtualization entitlement of this \
            binary (a plain `swift build` lacks it; Scripts/build.sh signs it), the signature, \
            free space for the store, and how many virtual machines already run. Exits 1 when \
            something prevents running boxes.
            """
    )

    @OptionGroup var options: StoreOptions

    func run() throws {
        // Stopped disposable boxes take disk space and count for nothing.
        BoxCommand.GC.collect(options.boxStore)
        let facts = HostFacts.current(storeRoot: options.store.root)
        let report = HostReport.evaluate(facts)
        if options.json {
            try Output.json(report)
        } else {
            let marks: [HostCheck.Status: String] = [.ok: "ok  ", .info: "info", .warning: "warn", .failure: "FAIL"]
            for check in report.checks {
                print("\(marks[check.status] ?? "?")  \(check.name): \(check.detail)")
            }
        }
        if !report.canRunBoxes {
            throw ExitCode(1)
        }
    }
}
