// Tests/AgentVMKitTests/ThreadsTests.swift
//
// The lock and the detached thread the Linux daemon uses in place of Foundation's, and its
// plain text helpers. They are built on macOS too, so they are tested here.

import Foundation
import Testing
@testable import AgentVMGuestKit

@Suite struct ThreadsTests {
    private final class Counter: @unchecked Sendable {
        var value = 0
    }

    @Test func theLockKeepsThreadsApart() {
        let lock = PthreadLock()
        let counter = Counter()
        let done = DispatchGroup()
        for _ in 0..<8 {
            done.enter()
            DetachedThread.detachNewThread {
                for _ in 0..<20_000 {
                    lock.lock()
                    counter.value += 1
                    lock.unlock()
                }
                done.leave()
            }
        }
        #expect(done.wait(timeout: .now() + 30) == .success)
        lock.lock()
        #expect(counter.value == 160_000)
        lock.unlock()
    }

    @Test func aDetachedThreadIsNotTheCallingThread() {
        let caller = UInt(bitPattern: pthread_self())
        let other = Counter()
        let done = DispatchSemaphore(value: 0)
        DetachedThread.detachNewThread {
            other.value = UInt(bitPattern: pthread_self()) != caller ? 1 : 2
            done.signal()
        }
        #expect(done.wait(timeout: .now() + 10) == .success)
        #expect(other.value == 1)
    }

    /// The stack the thread was given is asked for by its size: a large temporary allocation
    /// proves nothing, because Swift moves one that does not fit on the stack to the heap
    /// (measured: 300 KiB in a thread with a 128 KiB stack is served from the heap).
    @Test func aDetachedThreadHasRoomOnItsStack() {
        let size = Counter()
        let sum = Counter()
        let done = DispatchSemaphore(value: 0)
        DetachedThread.detachNewThread {
            size.value = pthread_get_stacksize_np(pthread_self())
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 300 * 1024) { buffer in
                buffer.initialize(repeating: 1)
                sum.value = buffer.reduce(0) { $0 + Int($1) }
            }
            done.signal()
        }
        #expect(done.wait(timeout: .now() + 10) == .success)
        #expect(size.value >= DetachedThread.stackSize)
        #expect(sum.value == 300 * 1024)
    }

    @Test func manyThreadsAllRun() {
        let lock = PthreadLock()
        let counter = Counter()
        let done = DispatchGroup()
        for _ in 0..<200 {
            done.enter()
            DetachedThread.detachNewThread {
                lock.lock()
                counter.value += 1
                lock.unlock()
                done.leave()
            }
        }
        #expect(done.wait(timeout: .now() + 30) == .success)
        #expect(counter.value == 200)
    }

    @Test func sleepLastsAsLongAsAsked() {
        let start = DispatchTime.now().uptimeNanoseconds
        DetachedThread.sleep(forTimeInterval: 0.15)
        let passed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        #expect(passed >= 0.15)
        #expect(passed < 5)
        DetachedThread.sleep(forTimeInterval: 0)
        DetachedThread.sleep(forTimeInterval: -1)
    }

    @Test func trimmedDropsBothEnds() {
        #expect(PlainText.trimmed("  0.7.45 \r\n") == "0.7.45")
        #expect(PlainText.trimmed("\r\n{\"a\": 1}\n") == "{\"a\": 1}")
        #expect(PlainText.trimmed("a b") == "a b")
        #expect(PlainText.trimmed(" \t\n") == "")
        #expect(PlainText.trimmed("") == "")
        #expect(PlainText.trimmed("\"13\"\r", of: "\"' \t\r") == "13")
        #expect(PlainText.trimmed(" \t ", of: " \t").isEmpty)
        #expect(PlainText.trimmed(" \n ", of: " \t") == "\n")
        #expect(PlainText.trimmed("x\u{301} ") == "x\u{301}")
    }

    @Test func trimmedIsWhatFoundationGivesForPlainText() {
        for text in ["  agent-vm-guest 0.1.5 (protocol 1)\n", "\t{\"version\":\"1\"}\r\n\r\n", "none", ""] {
            #expect(PlainText.trimmed(text) == text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    @Test func numbersReadAsTheFormatsDid() {
        for value in [0.5, 20, 120, 0.25, 1.5, 0, 3600] {
            #expect(PlainText.number(value) == String(format: "%g", value))
        }
        for value in [1.0, 3.04, 12.5, 0.96, 86400.26, 1_760_000_000.4] {
            #expect(PlainText.tenths(value) == String(format: "%.1f", value))
        }
    }
}
