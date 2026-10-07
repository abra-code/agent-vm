// Sources/AgentVMGuestKit/GuestDaemonInfo.swift
//
// What an agent-vm-guest executable says it is with `--version --json`: its version, protocol
// and features. The daemon prints it; the host reads it from a daemon on the Mac without a box.

import Foundation

/// A daemon's description of itself (`agent-vm-guest --version --json`).
public struct GuestDaemonInfo: Codable, Equatable, Sendable {
    public var version: String
    public var `protocol`: Int?
    /// nil from daemons older than 0.1.6, which describe themselves only in text.
    public var features: [String]?

    public init(version: String, protocol: Int?, features: [String]?) {
        self.version = version
        self.protocol = `protocol`
        self.features = features
    }

    /// This build's daemon.
    public static let current = GuestDaemonInfo(version: AgentVM.version, protocol: AgentVM.guestProtocolVersion, features: GuestFeature.all)

    /// Reads what `--version --json` printed: JSON, or the text line of older daemons,
    /// "agent-vm-guest 0.1.5 (protocol 1)", which ignore `--json`.
    public static func parse(_ output: String) -> GuestDaemonInfo? {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("{") {
            return try? JSONDecoder().decode(GuestDaemonInfo.self, from: Data(text.utf8))
        }
        let words = text.split(separator: " ")
        guard words.count >= 2, words[0] == "agent-vm-guest" else {
            return nil
        }
        var protocolNumber: Int?
        if words.count >= 4, words[2] == "(protocol", words[3].hasSuffix(")") {
            protocolNumber = Int(words[3].dropLast())
        }
        return GuestDaemonInfo(version: String(words[1]), protocol: protocolNumber, features: nil)
    }
}
