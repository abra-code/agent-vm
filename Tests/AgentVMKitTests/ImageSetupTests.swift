// Tests/AgentVMKitTests/ImageSetupTests.swift
//
// Pieces of image setup and the window that need no virtual machine: the keys typed into a
// guest, Full Disk Access as the image record knows it, and the control request that types.

import Foundation
import Testing
@testable import AgentVMKit

@Suite struct ImageSetupTests {
    @Test func everyPasswordCharacterHasAKey() throws {
        for _ in 0..<20 {
            for character in try ImageBuilder.newPassword() {
                let key = try #require(GuestKeys.key(for: character), "\(character)")
                #expect(key.shift == character.isUppercase, "\(character)")
            }
        }
    }

    @Test func keysFollowAUSKeyboard() {
        #expect(GuestKeys.key(for: "a")! == (0, false))
        #expect(GuestKeys.key(for: "A")! == (0, true))
        #expect(GuestKeys.key(for: "_")! == (27, true))
        #expect(GuestKeys.key(for: "-")! == (27, false))
        #expect(GuestKeys.key(for: ">")! == (47, true))
        #expect(GuestKeys.key(for: "\r")! == (36, false))
        for unsupported: Character in ["\u{00E9}", "\u{00DF}", "~", "\t"] {
            #expect(GuestKeys.key(for: unsupported) == nil, "\(unsupported)")
        }
    }

    @Test func fullDiskAccessCountsOnlyForTheDaemonItWasCheckedFor() {
        var record = ImageStoreTests.record("dev", state: .ready)
        record.guestDigest = "new"
        #expect(record.hasFullDiskAccess == nil)
        record.fullDiskAccess = ImageRecord.FullDiskAccess(granted: true, guestDigest: "old", checkedAt: Date())
        #expect(record.hasFullDiskAccess == nil)
        record.fullDiskAccess = ImageRecord.FullDiskAccess(granted: true, guestDigest: "new", checkedAt: Date())
        #expect(record.hasFullDiskAccess == true)
        record.fullDiskAccess = ImageRecord.FullDiskAccess(granted: false, guestDigest: "new", checkedAt: Date())
        #expect(record.hasFullDiskAccess == false)
    }

    @Test func typeRequestsReachTheHandler() throws {
        let scratch = try ShortFolder()
        let handler = FakeHandler()
        let path = scratch.path + "/control.sock"
        let server = try ControlServer(path: path, handler: handler)
        defer { server.close() }
        let text = try ControlClient.request(ControlRequest(op: .type, text: "hello"), path: path)
        let password = try ControlClient.request(ControlRequest(op: .type), path: path)
        #expect(!text.ok && !password.ok)
        #expect(handler.typed == ["hello", "<password>"])
    }
}
