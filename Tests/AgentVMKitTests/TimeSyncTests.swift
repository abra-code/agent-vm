// Tests/AgentVMKitTests/TimeSyncTests.swift
//
// Setting the guest's clock (feature time-sync), against the real GuestServer on a socket pair
// with its clock setter replaced: a test never sets this Mac's clock.

import Darwin
import Foundation
import Testing
@testable import AgentVMKit

private final class SetTimes: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    func add(_ value: Double) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var all: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@Suite struct TimeSyncTests {
    @Test func theGuestIsSetToTheHostsTime() throws {
        let set = SetTimes()
        let pair = try GuestPair(setClock: { set.add($0); return 0 })
        let before = Date().timeIntervalSince1970
        let offset = try GuestClient.syncTime(pair.client)
        let after = Date().timeIntervalSince1970
        let applied = try #require(set.all.first)
        #expect(applied >= before && applied <= after)
        // Both clocks are this Mac's here: the offset is the request's travel time.
        #expect(abs(offset) < 1)
    }

    @Test func aRefusedClockIsAnError() throws {
        let pair = try GuestPair(setClock: { _ in EPERM })
        #expect(throws: AgentVMError.self) { _ = try GuestClient.syncTime(pair.client) }
    }

    @Test func implausibleTimesAreNeverApplied() throws {
        for epoch: Double in [0, 1_000_000_000, 9_000_000_000, -5] {
            let set = SetTimes()
            let pair = try GuestPair(setClock: { set.add($0); return 0 })
            let channel = FrameChannel(descriptor: pair.client)
            try channel.send(.request, json: GuestRequest(op: .timeSync, epoch: epoch))
            let response = try channel.receive(.response, as: GuestResponse.self)
            #expect(!response.ok, "\(epoch)")
            #expect(set.all.isEmpty, "\(epoch)")
        }
    }

    @Test func daemonsAnnounceIt() {
        #expect(GuestFeature.all.contains(GuestFeature.timeSync))
        #expect(GuestDaemonInfo.current.features?.contains("time-sync") == true)
    }
}
