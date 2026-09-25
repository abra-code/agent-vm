// Tests/AgentVMKitTests/BuildCancellationTests.swift
//
// Canceling a build: the first signal wins, registered guest connections are shut down (what
// ends a guest command that would otherwise run on), actions run once, and a canceled image
// records "canceled" as its failure.

import Darwin
import Foundation
import Testing
@testable import AgentVMKit

@Suite struct BuildCancellationTests {
    @Test func theFirstSignalWins() {
        let cancellation = BuildCancellation()
        #expect(!cancellation.isCanceled)
        cancellation.cancel(signal: SIGTERM)
        cancellation.cancel(signal: SIGINT)
        #expect(cancellation.signal == SIGTERM)
    }

    /// A read blocked on a registered connection returns once the build is canceled.
    @Test func aBlockedReadEndsOnCancel() async throws {
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer {
            close(pair[0])
            close(pair[1])
        }
        let cancellation = BuildCancellation()
        #expect(cancellation.register(descriptor: pair[0]))
        let reader = pair[0]
        let blocked = Task.detached { () -> Int in
            var byte: UInt8 = 0
            return read(reader, &byte, 1)
        }
        try await Task.sleep(for: .milliseconds(100))
        cancellation.cancel(signal: SIGINT)
        #expect(await blocked.value == 0)
        // Registering after the cancel is refused: the caller must not start the exchange.
        #expect(!cancellation.register(descriptor: pair[1]))
    }

    @Test func anUnregisteredConnectionIsLeftAlone() {
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer {
            close(pair[0])
            close(pair[1])
        }
        let cancellation = BuildCancellation()
        #expect(cancellation.register(descriptor: pair[0]))
        cancellation.unregister(descriptor: pair[0])
        cancellation.cancel(signal: SIGINT)
        #expect(write(pair[0], "x", 1) == 1)
    }

    @Test func actionsRunOnceAndLateOnesAtOnce() {
        let cancellation = BuildCancellation()
        let counter = Counter()
        let removed = cancellation.whenCanceled { counter.add(100) }
        _ = cancellation.whenCanceled { counter.add(1) }
        cancellation.remove(removed)
        cancellation.cancel(signal: SIGINT)
        cancellation.cancel(signal: SIGINT)
        #expect(counter.value == 1)
        _ = cancellation.whenCanceled { counter.add(10) }
        #expect(counter.value == 11)
    }

    @MainActor
    @Test func canceledImagesRecordCanceled() {
        #expect(ImageBuilder.failureReason(AgentVMError.canceled(signal: SIGINT)) == "canceled")
        #expect(ImageBuilder.failureReason(AgentVMError.guestUnreachable("x")) == "the guest is unreachable: x")
        #expect(AgentVMError.canceled(signal: SIGTERM).description == "canceled by SIGTERM")
    }

    /// After a cancel, whatever failed is reported as the cancel.
    @MainActor
    @Test func failuresAfterACancelAreTheCancel() throws {
        let scratch = try Scratch()
        let builder = ImageBuilder(store: ImageStore(root: scratch.root)) { (_: ProgressEvent) in }
        #expect(throws: Never.self) { try builder.checkCanceled() }
        let cancellation = BuildCancellation()
        builder.cancellation = cancellation
        #expect((builder.canceledError(AgentVMError.guestUnreachable("x")) as? AgentVMError) == .guestUnreachable("x"))
        cancellation.cancel(signal: SIGINT)
        #expect((builder.canceledError(AgentVMError.guestUnreachable("x")) as? AgentVMError) == .canceled(signal: SIGINT))
        #expect(throws: AgentVMError.canceled(signal: SIGINT)) { try builder.checkCanceled() }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0

    func add(_ amount: Int) {
        lock.lock()
        total += amount
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return total
    }
}
