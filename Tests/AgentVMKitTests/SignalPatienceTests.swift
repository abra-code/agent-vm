// Tests/AgentVMKitTests/SignalPatienceTests.swift
//
// When `agent-vm exec` gives up on a program that does not end.

import Darwin
import Foundation
import Testing
@testable import AgentVMKit

@Suite struct SignalPatienceTests {
    /// The first signal is forwarded; one that follows at once is the same request; one after
    /// the gap gives up, and so does every later one.
    @Test func theSecondRequestToEndGivesUp() {
        let patience = SignalPatience()
        let start = ContinuousClock.now
        #expect(!patience.givesUp(on: SIGINT, at: start))
        #expect(!patience.givesUp(on: SIGINT, at: start + .milliseconds(5)))
        #expect(!patience.givesUp(on: SIGTERM, at: start + .milliseconds(999)))
        #expect(patience.givesUp(on: SIGINT, at: start + .seconds(1)))
        #expect(patience.givesUp(on: SIGTERM, at: start + .seconds(30)))
    }

    /// A program that answered the first signal without ending (it canceled a step) is not
    /// ended by one much later: that one begins a new count.
    @Test func aSignalLongAfterTheFirstIsANewRequest() {
        let patience = SignalPatience()
        let start = ContinuousClock.now
        #expect(!patience.givesUp(on: SIGINT, at: start))
        #expect(!patience.givesUp(on: SIGINT, at: start + .seconds(31)))
        #expect(!patience.givesUp(on: SIGINT, at: start + .milliseconds(31_500)))
        #expect(patience.givesUp(on: SIGINT, at: start + .seconds(33)))
    }

    /// Any two ending signals count together, since a caller may try SIGINT and then SIGTERM.
    @Test func endingSignalsCountTogether() {
        for (first, second) in [(SIGINT, SIGTERM), (SIGTERM, SIGHUP), (SIGHUP, SIGQUIT), (SIGQUIT, SIGINT)] {
            let patience = SignalPatience()
            let start = ContinuousClock.now
            #expect(!patience.givesUp(on: first, at: start))
            #expect(patience.givesUp(on: second, at: start + .seconds(2)))
        }
    }

    /// SIGUSR1 and SIGUSR2 mean what the program says they mean: always forwarded, and they
    /// do not start the count.
    @Test func otherSignalsNeverGiveUp() {
        let patience = SignalPatience()
        let start = ContinuousClock.now
        for offset in 0..<5 {
            #expect(!patience.givesUp(on: SIGUSR1, at: start + .seconds(offset * 10)))
            #expect(!patience.givesUp(on: SIGUSR2, at: start + .seconds(offset * 10)))
        }
        #expect(!patience.givesUp(on: SIGINT, at: start + .seconds(100)))
        #expect(!patience.givesUp(on: SIGUSR1, at: start + .seconds(101)))
        #expect(patience.givesUp(on: SIGINT, at: start + .seconds(102)))
    }
}
