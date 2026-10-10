// Tests/AgentVMKitTests/HostMemoryTests.swift
//
// The judgment of the Mac's memory before a Linux guest boots on a kernel with small pages:
// a note when there is little to spare, a refusal when there is none.

import Foundation
import Testing
@testable import AgentVMKit

@Suite struct HostMemoryTests {
    static let what = "the build of t"

    @Test func aMacWithRoomIsNotSpokenOf() {
        #expect(HostMemory(availableBytes: 8 << 30, pressure: .normal).verdict(guestBytes: 4 << 30, what: Self.what) == .enough)
        // As much as the guest may take is enough.
        #expect(HostMemory(availableBytes: 4 << 30, pressure: .normal).verdict(guestBytes: 4 << 30, what: Self.what) == .enough)
    }

    @Test func littleToSpareIsANoteAndTheJobGoesOn() throws {
        guard case .tight(let text) = HostMemory(availableBytes: 3 << 30, pressure: .normal).verdict(guestBytes: 4 << 30, what: Self.what) else {
            Issue.record("less than the guest's memory is tight")
            return
        }
        #expect(text == "this Mac has about 3.0 GB of memory to spare for a guest of 4 GB; the build of t runs on a kernel with 4 KiB memory pages, "
                + "which can lose kernel memory and fail when the Mac runs short of memory (macOS 27). If it fails, quit programs that use much memory and try again")
        // What macOS says counts even with room on paper.
        guard case .tight(let pressed) = HostMemory(availableBytes: 16 << 30, pressure: .warning).verdict(guestBytes: 4 << 30, what: Self.what) else {
            Issue.record("a pressure warning is tight")
            return
        }
        #expect(pressed.hasPrefix("this Mac has about 16.0 GB of memory to spare for a guest of 4 GB, and macOS reports memory pressure (warning); the build of t runs"))
        // Very little with macOS at ease is a note too: a Mac that runs boxes often reads so.
        guard case .tight = HostMemory(availableBytes: 200 << 20, pressure: .normal).verdict(guestBytes: 4 << 30, what: Self.what) else {
            Issue.record("below the floor without pressure is tight, not refused")
            return
        }
        // The floor itself is not below the floor.
        guard case .tight = HostMemory(availableBytes: HostMemory.floorBytes, pressure: .warning).verdict(guestBytes: 4 << 30, what: Self.what) else {
            Issue.record("the floor is tight, not refused")
            return
        }
    }

    @Test func nothingToSpareIsRefused() {
        guard case .exhausted(let text) = HostMemory(availableBytes: (1 << 30) - 1, pressure: .warning).verdict(guestBytes: 4 << 30, what: Self.what) else {
            Issue.record("less than the floor under pressure is refused")
            return
        }
        #expect(text.hasPrefix("this Mac has about 1023 MB of memory to spare, and macOS reports memory pressure (warning); the build of t runs on a kernel with 4 KiB memory pages"))
        #expect(text.hasSuffix(". Quit programs that use much memory or stop running boxes, and try again"))
        guard case .exhausted(let pressed) = HostMemory(availableBytes: 16 << 30, pressure: .critical).verdict(guestBytes: 4 << 30, what: Self.what) else {
            Issue.record("critical pressure is refused")
            return
        }
        #expect(pressed.contains("macOS reports memory pressure (critical)"))
    }

    @Test func thisMacsMemoryIsRead() throws {
        let memory = try #require(HostMemory.current())
        #expect(memory.availableBytes > 0)
        #expect(memory.availableBytes <= ProcessInfo.processInfo.physicalMemory)
    }
}
