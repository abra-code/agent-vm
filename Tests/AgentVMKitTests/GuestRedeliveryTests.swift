// Tests/AgentVMKitTests/GuestRedeliveryTests.swift
//
// ImageBuilder's retry of a request the guest refused before it had it (the connection closed
// first): sent again while refused, within its window; any other failure is not retried. Also
// how requests are named in errors and notes.

import Darwin
import Foundation
import Testing
@testable import AgentVMKit

/// Outcomes handed out one per attempt; the last one repeats.
@MainActor
final class Attempts {
    private var outcomes: [Result<Int, Error>]
    private(set) var count = 0

    init(_ outcomes: [Result<Int, Error>]) {
        self.outcomes = outcomes
    }

    func next() throws -> Int {
        count += 1
        let outcome = outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0]
        return try outcome.get()
    }
}

@MainActor
@Suite struct GuestRedeliveryTests {
    let refused = GuestProtocolError.notDelivered(code: EPIPE)

    func run(_ attempts: Attempts, window: Duration = .seconds(5)) async throws -> (Int, ImageBuilder.Redelivery?) {
        return try await ImageBuilder.redelivering("hello", window: window, pause: .milliseconds(10), check: {}) {
            try attempts.next()
        }
    }

    @Test func aRefusedRequestIsSentAgain() async throws {
        let attempts = Attempts([.failure(refused), .failure(refused), .success(7)])
        let (value, redelivery) = try await run(attempts)
        #expect(value == 7)
        #expect(attempts.count == 3)
        #expect(redelivery?.attempts == 3)
        #expect(redelivery?.refusal == refused)
        #expect(redelivery?.note("hello").hasPrefix("hello: the guest closed the connection before the request was sent (Broken pipe); sent again, it went through on attempt 3") == true)
    }

    @Test func aRequestThatGoesThroughAtOnceHasNoNote() async throws {
        let (value, redelivery) = try await run(Attempts([.success(1)]))
        #expect(value == 1)
        #expect(redelivery == nil)
    }

    @Test func refusalsEndWithTheWindow() async throws {
        let attempts = Attempts([.failure(refused)])
        do {
            _ = try await run(attempts, window: .milliseconds(100))
            Issue.record("it went through")
        } catch let AgentVMError.guestUnreachable(reason) {
            #expect(reason.hasPrefix("hello: the guest closed the connection before the request was sent"), "\(reason)")
            #expect(reason.contains("tried \(attempts.count) times over"), "\(reason)")
        }
        #expect(attempts.count > 1)
    }

    @Test func otherFailuresAreNotRetried() async throws {
        // The request may have run: a lost connection after it was sent is not sent again.
        let lost = Attempts([.failure(GuestProtocolError.disconnected), .success(1)])
        await #expect(throws: GuestProtocolError.disconnected) { _ = try await run(lost) }
        #expect(lost.count == 1)
        // A daemon not listening at the first attempt is the caller's to wait for (waitForDaemon).
        let absent = Attempts([.failure(ImageBuilder.ConnectFailure(error: AgentVMError.guestUnreachable("vsock port 1024"))), .success(1)])
        await #expect(throws: ImageBuilder.ConnectFailure.self) { _ = try await run(absent) }
        #expect(absent.count == 1)
    }

    @Test func aDaemonRestartingAfterARefusalIsWaitedFor() async throws {
        let restart = ImageBuilder.ConnectFailure(error: AgentVMError.guestUnreachable("vsock port 1024"))
        let attempts = Attempts([.failure(refused), .failure(restart), .failure(restart), .success(3)])
        let (value, redelivery) = try await run(attempts)
        #expect(value == 3)
        #expect(redelivery?.attempts == 4)
    }

    @Test func aCancelStopsTheRetries() async throws {
        let attempts = Attempts([.failure(refused)])
        await #expect(throws: AgentVMError.canceled(signal: SIGINT)) {
            _ = try await ImageBuilder.redelivering("hello", window: .seconds(5), pause: .milliseconds(10), check: {
                throw AgentVMError.canceled(signal: SIGINT)
            }) {
                try attempts.next()
            }
        }
        #expect(attempts.count == 1)
    }

    @Test func requestsAreNamed() {
        #expect(ImageBuilder.describe(GuestRequest(op: .hello)) == "hello")
        #expect(ImageBuilder.describe(GuestRequest(op: .exec, argv: ["/usr/bin/head", "-c", "16", "/Library/Application Support/x.db"])) == "/usr/bin/head -c 16 '/Library/Application Support/x.db'")
        let long = ImageBuilder.describe(GuestRequest(op: .exec, argv: ["/bin/sh", "-c", String(repeating: "echo hi; ", count: 30)]))
        #expect(long.count == 100 && long.hasSuffix("..."))
        #expect(!ImageBuilder.describe(GuestRequest(op: .exec, argv: ["/bin/sh", "-c", "a\nb"])).contains("\n"))
        #expect(ImageBuilder.describe(GuestRequest(op: .exec, argv: ["/bin/echo", "a\tb", "c\r\nd"])) == "/bin/echo 'a\tb' 'c d'")
    }
}
