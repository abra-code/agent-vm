// Sources/AgentVMKit/Guest/GuestDaemonInfo.swift
//
// What an agent-vm-guest executable on this Mac is, without a box: its version, protocol and
// features (it describes itself with `--version --json`) and its SHA-256, the digest images
// record for their daemon. `agent-vm version` reports the daemon found next to agent-vm, so a
// client can tell which images `image update-guest` would change without booting any.

import Darwin
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

/// An agent-vm-guest executable on this Mac, as `agent-vm version` reports it.
public struct LocalGuestDaemon: Encodable, Equatable, Sendable {
    public var path: String
    public var version: String?
    public var `protocol`: Int?
    public var features: [String]?
    /// SHA-256 of the executable, as images record it (`guestDigest`).
    public var digest: String?
    /// Why the rest is missing: no such file, or it did not describe itself.
    public var error: String?

    /// Looks at the executable at `url`: its digest, and what it says it is. Runs it with
    /// `--version --json` (a few milliseconds; at most `timeout`).
    public static func inspect(_ url: URL, timeout: TimeInterval = 5) -> LocalGuestDaemon {
        var result = LocalGuestDaemon(path: url.path)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            result.error = "no agent-vm-guest executable at \(url.path)"
            return result
        }
        result.digest = try? ImageBuilder.sha256(of: url)
        let process = Process()
        process.executableURL = url
        process.arguments = ["--version", "--json"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            finished.signal()
        }
        do {
            try process.run()
        } catch {
            result.error = "cannot run \(url.path): \(error.localizedDescription)"
            return result
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            result.error = "\(url.path) --version did not answer within \(Int(timeout)) s"
            return result
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0, let info = GuestDaemonInfo.parse(text) else {
            result.error = "\(url.path) --version did not describe an agent-vm-guest (status \(process.terminationStatus))"
            return result
        }
        result.version = info.version
        result.protocol = info.protocol
        result.features = info.features
        return result
    }
}
