// Sources/agent-vm/VersionCommand.swift
//
// `agent-vm version`: this agent-vm's version and protocols, and the guest daemon next to it,
// so a client can tell which images `image update-guest` would change (their `guestDigest`
// differs from the daemon's digest) and which lack features, without booting anything.

import AgentVMKit
import ArgumentParser
import Foundation

struct VersionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Show this agent-vm's version and protocols, and the guest daemons it would install.",
        discussion: """
            The guest daemon is the agent-vm-guest next to agent-vm, which `image create` and \
            `image update-guest` install; its digest is what images record as guestDigest, and \
            its designated code requirement what they record as guestRequirement (Full Disk \
            Access carries over to a daemon with the same requirement when it names a signer, \
            as a Developer ID signature does). \
            Supervisors of running boxes may be other builds: `box status` names theirs. \
            The daemon for Linux guests, linux/agent-vm-guest, is listed with its digest when it \
            was built; without it, Linux images cannot be created.
            """)

    @Flag(name: .long, help: "Print machine-readable JSON instead of text.")
    var json = false

    struct Report: Encodable {
        var version: String
        var controlProtocol: Int
        var guestProtocol: Int
        var path: String
        var guestDaemon: LocalGuestDaemon
        /// The daemon for Linux guests: its path and digest, or why there is none. It cannot be
        /// run on a Mac, so its version and features are not here.
        var linuxGuestDaemon: LocalGuestDaemon
    }

    func run() throws {
        let report = Report(version: AgentVM.version, controlProtocol: ControlChannel.version, guestProtocol: AgentVM.guestProtocolVersion,
                            path: try AskpassEntry.executablePath(), guestDaemon: LocalGuestDaemon.inspect(try ImageCommand.localGuestDaemon()),
                            linuxGuestDaemon: LocalGuestDaemon.inspectLinux(try ImageCommand.localGuestDaemon(for: .linux)))
        if json {
            try Output.json(report)
            return
        }
        print("agent-vm \(report.version) (control protocol \(report.controlProtocol), guest protocol \(report.guestProtocol))")
        print("    \(report.path)")
        let daemon = report.guestDaemon
        defer {
            let linux = report.linuxGuestDaemon
            if let digest = linux.digest, linux.error == nil {
                print("linux/agent-vm-guest (for Linux guests)")
                print("    \(linux.path)")
                print("    sha256 \(digest)")
            } else {
                print("linux/agent-vm-guest: \(linux.error ?? "not found")")
            }
        }
        if let error = daemon.error {
            print("agent-vm-guest: \(error)")
            return
        }
        var line = "agent-vm-guest \(daemon.version ?? "?")"
        if let number = daemon.protocol {
            line += " (protocol \(number))"
        }
        if let features = daemon.features {
            line += ": \(features.isEmpty ? "no features" : features.joined(separator: ", "))"
        }
        print(line)
        print("    \(daemon.path)")
        if let digest = daemon.digest {
            print("    sha256 \(digest)")
        }
        if let requirement = daemon.requirement {
            let note = CodeSignature.namesASigner(requirement) ? "Full Disk Access carries over between builds signed this way" : "no signing identity (ad hoc): Full Disk Access is lost with every new build"
            print("    signature: \(requirement)")
            print("    (\(note))")
        }
    }
}
