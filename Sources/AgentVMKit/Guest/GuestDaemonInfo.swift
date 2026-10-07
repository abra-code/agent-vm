// Sources/AgentVMKit/Guest/GuestDaemonInfo.swift
//
// What an agent-vm-guest executable on this Mac is, without a box: its version, protocol and
// features (it describes itself with `--version --json`) and its SHA-256, the digest images
// record for their daemon. `agent-vm version` reports the daemon found next to agent-vm, so a
// client can tell which images `image update-guest` would change without booting any.

import Darwin
import Foundation

/// An agent-vm-guest executable on this Mac, as `agent-vm version` reports it.
public struct LocalGuestDaemon: Encodable, Equatable, Sendable {
    public var path: String
    public var version: String?
    public var `protocol`: Int?
    public var features: [String]?
    /// SHA-256 of the executable, as images record it (`guestDigest`).
    public var digest: String?
    /// Its designated code requirement, as images record it (`guestRequirement`); Full Disk
    /// Access granted to a daemon with the same requirement naming a signer carries over.
    public var requirement: String?
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
        result.requirement = CodeSignature.designatedRequirement(of: url)
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
