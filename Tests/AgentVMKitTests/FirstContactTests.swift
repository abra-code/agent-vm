// Tests/AgentVMKitTests/FirstContactTests.swift

import Foundation
import Testing
@testable import AgentVMKit

struct FirstContactTests {
    @Test func aRefusalByThisMacIsSaidOnceAfterItsPatience() {
        var contact = FirstContact()
        let start = ContinuousClock.now
        #expect(contact.record(.failed(EHOSTUNREACH), host: "192.168.64.2", at: start) == nil)
        #expect(contact.record(.failed(EHOSTUNREACH), host: "192.168.64.2", at: start + .seconds(29)) == nil)
        let notice = contact.record(.failed(EPERM), host: "192.168.64.2", at: start + .seconds(30))
        #expect(notice?.contains("192.168.64.2") == true)
        #expect(notice?.contains("Operation not permitted") == true)
        #expect(notice?.contains("Local Network") == true)
        #expect(contact.record(.failed(EHOSTUNREACH), host: "192.168.64.2", at: start + .seconds(90)) == nil)
    }

    @Test func aGuestThatIsOnlyNotReadyGetsNoNotice() {
        var contact = FirstContact()
        let start = ContinuousClock.now
        #expect(contact.record(.failed(ECONNREFUSED), host: "192.168.64.2", at: start) == nil)
        #expect(contact.record(.noAnswer, host: "192.168.64.2", at: start + .seconds(300)) == nil)
        #expect(contact.record(.failed(ECONNREFUSED), host: "192.168.64.2", at: start + .seconds(590)) == nil)
    }

    @Test func anotherAnswerOrAnotherAddressStartsThePatienceAgain() {
        var contact = FirstContact()
        let start = ContinuousClock.now
        #expect(contact.record(.failed(EHOSTUNREACH), host: "192.168.64.2", at: start) == nil)
        #expect(contact.record(.failed(ECONNREFUSED), host: "192.168.64.2", at: start + .seconds(20)) == nil)
        #expect(contact.record(.failed(EHOSTUNREACH), host: "192.168.64.2", at: start + .seconds(40)) == nil)
        #expect(contact.record(.failed(EHOSTUNREACH), host: "192.168.64.3", at: start + .seconds(69)) == nil)
        #expect(contact.record(.failed(EHOSTUNREACH), host: "192.168.64.3", at: start + .seconds(99)) != nil)
    }

    @Test func theFailureNamesTheLastAttempt() {
        var contact = FirstContact()
        #expect(contact.failure(after: .seconds(600)).contains("got no address"))
        _ = contact.record(.failed(ECONNREFUSED), host: "192.168.64.2")
        let refused = contact.failure(after: .seconds(600))
        #expect(refused.contains("the last attempt to reach 192.168.64.2 port 22 failed with Connection refused"))
        #expect(!refused.contains("Local Network"))
        _ = contact.record(.noAnswer, host: "192.168.64.2")
        #expect(contact.failure(after: .seconds(600)).hasSuffix("port 22 got no answer"))
        _ = contact.record(.failed(EHOSTUNREACH), host: "192.168.64.2")
        let blocked = contact.failure(after: .seconds(600))
        #expect(blocked.contains("failed with No route to host"))
        #expect(blocked.contains("Local Network"))
    }

    @Test func anAttemptSaysWhyItFailed() {
        // A port held bound without listening does not answer as open; one nothing is bound to
        // refuses the connection. The refused one is port 1, which no test is ever given: a
        // port just closed is free, and another test's socket had it before the attempt ran.
        let held = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(held) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let reserved = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Bool in
                bind(held, pointer, length) == 0 && getsockname(held, pointer, &length) == 0
            }
        }
        #expect(reserved)
        #expect(GuestNetwork.attempt("127.0.0.1", port: UInt16(bigEndian: address.sin_port), timeout: 1) != .open)
        #expect(GuestNetwork.attempt("127.0.0.1", port: 1) == .failed(ECONNREFUSED))
        #expect(GuestNetwork.attempt("not an address", port: 22) == .failed(EINVAL))
        #expect(GuestNetwork.Attempt.failed(ECONNREFUSED).refusedByThisMac == false)
        #expect(GuestNetwork.Attempt.noAnswer.refusedByThisMac == false)
    }
}
