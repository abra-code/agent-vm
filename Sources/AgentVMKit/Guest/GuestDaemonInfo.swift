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

extension LocalGuestDaemon {
    /// The first bytes of an ELF file for 64-bit ARM Linux, as far as they are checked: the
    /// magic, the 64-bit class, little-endian data, and the machine (EM_AARCH64, 183).
    static let elfHeaderBytes = 20

    /// Looks at the Linux guest daemon at `url`: its digest, and whether it is a program for a
    /// 64-bit ARM Linux guest. It is never run: it cannot be, on a Mac. What version it is and
    /// what it can do, it says in its first hello from inside a guest.
    public static func inspectLinux(_ url: URL) -> LocalGuestDaemon {
        var result = LocalGuestDaemon(path: url.path)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            result.error = "no linux/agent-vm-guest executable at \(url.path)"
            return result
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            result.error = "cannot read \(url.path)"
            return result
        }
        defer { try? handle.close() }
        let header = [UInt8]((try? handle.read(upToCount: elfHeaderBytes)) ?? Data())
        guard isLinuxARM64(header) else {
            result.error = "\(url.path) is not a program for a 64-bit ARM Linux guest"
            return result
        }
        guard let digest = try? ImageBuilder.sha256(of: url) else {
            result.error = "cannot read \(url.path)"
            return result
        }
        result.digest = digest
        return result
    }

    /// Whether `header` (the start of a file) is that of an ELF program for 64-bit ARM.
    static func isLinuxARM64(_ header: [UInt8]) -> Bool {
        guard header.count >= elfHeaderBytes, Array(header[0..<4]) == [0x7f, 0x45, 0x4c, 0x46] else {
            return false
        }
        // EI_CLASS 2: 64-bit. EI_DATA 1: little-endian. e_machine, two bytes at 18: 183.
        return header[4] == 2 && header[5] == 1 && Int(header[18]) | Int(header[19]) << 8 == 183
    }
}
