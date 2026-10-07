// Tests/AgentVMKitTests/GuestKitTests.swift
//
// The guest daemon is built from the guest kit alone: it must not link what only the host
// uses, the Virtualization framework first of all.

import Foundation
import Testing
@testable import AgentVMGuestKit
@testable import AgentVMKit

@Suite struct GuestKitTests {
    /// The libraries the built agent-vm-guest names, as `otool -L` lists them.
    private func linkedLibraries() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/otool")
        process.arguments = ["-L", try GuestPair.builtHelper()]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return text
    }

    @Test func theDaemonLinksNoHostFramework() throws {
        let libraries = try linkedLibraries()
        // Foundation is there, so the list was read; the host's frameworks are not.
        #expect(libraries.contains("Foundation.framework"))
        #expect(!libraries.contains("Virtualization.framework"))
        #expect(!libraries.contains("vmnet.framework"))
        #expect(!libraries.contains("Security.framework"))
    }

    @Test func aSystemErrorReadsLikeTheHostsOwn() {
        let guest = GuestSystemError(operation: "listen on vsock port 7", code: EADDRINUSE)
        let host = AgentVMError.system(operation: "listen on vsock port 7", code: EADDRINUSE)
        #expect("\(guest)" == "\(host)")
    }

    @Test func aWallpaperFailureReadsLikeTheHostsOwn() {
        // A control character in the reason (a home folder's name) is replaced on both sides.
        let reason = "the desktop did not take /Users/a\u{1B}b/x.png within 10 s"
        let guest = GuestWallpaper.Failure(reason: reason)
        let host = AgentVMError.guestCommandFailed(command: "wallpaper", status: 0, output: reason)
        #expect("\(guest)" == "\(host)")
        #expect(!"\(guest)".contains("\u{1B}"))
        let system = GuestSystemError(operation: "look up \u{1B}", code: ENOENT)
        #expect("\(system)" == "\(AgentVMError.system(operation: "look up \u{1B}", code: ENOENT))")
    }
}
