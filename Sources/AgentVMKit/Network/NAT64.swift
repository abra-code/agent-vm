// Sources/AgentVMKit/Network/NAT64.swift
//
// IPv6 addresses that stand for IPv4 ones. On an IPv6-only network (a phone's hotspot, some
// carriers and home routers), the DNS server answers IPv4-only names with IPv6 addresses made
// of a translation prefix and the IPv4 address (DNS64), and a gateway translates connections to
// them (NAT64). The prefix may be public-looking global space: measured on a T-Mobile hotspot,
// 2607:7700:0:33:0:1::/96. Such an address must be judged as the IPv4 address inside it, or a
// name that points at 10.0.0.1 or 192.168.1.5 would pass the proxy's address check.
//
// The prefixes: the well-known 64:ff9b::/96 (RFC 6052), and the network's own, found as RFC 7050
// says: resolve ipv4only.arpa, whose only addresses are 192.0.0.170 and 192.0.0.171, and see
// where they appear in the IPv6 answers.

import Darwin
import Foundation

public enum NAT64 {
    /// A translation prefix: its first bytes and its length in bits (32, 40, 48, 56, 64 or 96,
    /// the lengths RFC 6052 allows).
    public struct Prefix: Equatable, Sendable {
        public var bytes: [UInt8]
        public var length: Int

        public init(bytes: [UInt8], length: Int) {
            self.bytes = Array(bytes.prefix(length / 8))
            self.length = length
        }

        /// 64:ff9b::/96, reserved for NAT64 everywhere.
        public static let wellKnown = Prefix(bytes: [0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0], length: 96)

        static let lengths = [32, 40, 48, 56, 64, 96]

        /// Where RFC 6052 puts the IPv4 address after a prefix of `length` bits: byte 8 (bits
        /// 64-71) is always skipped. Senders set it to zero; nothing says a gateway checks it,
        /// so an address with another value there is judged by the IPv4 address all the same.
        static func positions(_ length: Int) -> [Int] {
            let start = length / 8
            return Array((start..<16).filter { $0 != 8 }.prefix(4))
        }

        /// The IPv4 address `address` (16 bytes) stands for, when it is under this prefix.
        public func embeddedIPv4(_ address: [UInt8]) -> [UInt8]? {
            guard address.count == 16, Array(address.prefix(bytes.count)) == bytes else {
                return nil
            }
            return Self.positions(length).map { address[$0] }
        }
    }

    /// The prefixes whose IPv6 answers for ipv4only.arpa (`addresses`) show: each address that
    /// holds 192.0.0.170 or 192.0.0.171 after a prefix of an allowed length.
    public static func prefixes(fromDiscovery addresses: [[UInt8]]) -> [Prefix] {
        var found: [Prefix] = []
        for address in addresses where address.count == 16 {
            // The usual /96 first.
            for length in Prefix.lengths.reversed() {
                let candidate = Prefix(bytes: address, length: length)
                guard let v4 = candidate.embeddedIPv4(address), v4 == [192, 0, 0, 170] || v4 == [192, 0, 0, 171] else {
                    continue
                }
                if !found.contains(candidate) {
                    found.append(candidate)
                }
                break
            }
        }
        return found
    }

    /// The prefixes in use now: the well-known one, and this network's, looked up at most once
    /// a minute, and again as soon as this Mac's networks (`networks`) change, since a prefix
    /// still unknown would let the new network's translated addresses pass as IPv6 (a lookup
    /// that fails counts for a minute too).
    public static func current(networks: [AddressCheck.LocalNetwork]) -> [Prefix] {
        return cache.value(networks: networks) {
            return [Prefix.wellKnown] + prefixes(fromDiscovery: discoveryAnswers()).filter { $0 != Prefix.wellKnown }
        }
    }

    /// Whether `address` (16 bytes) is in space reserved for translation, which can be nothing
    /// else: 64:ff9b::/96 (RFC 6052) and 64:ff9b:1::/48, for local use (RFC 8215).
    public static func isReservedForTranslation(_ address: [UInt8]) -> Bool {
        guard address.count == 16, address.prefix(4) == [0x00, 0x64, 0xff, 0x9b] else {
            return false
        }
        return address[4..<12].allSatisfy { $0 == 0 } || address[4..<6] == [0x00, 0x01]
    }

    /// The IPv4 address `address` (16 bytes) stands for under one of `prefixes`, if any.
    public static func embeddedIPv4(_ address: [UInt8], prefixes: [Prefix]) -> [UInt8]? {
        for prefix in prefixes {
            if let v4 = prefix.embeddedIPv4(address) {
                return v4
            }
        }
        return nil
    }

    /// The IPv6 addresses ipv4only.arpa resolves to (none off a NAT64 network).
    static func discoveryAnswers() -> [[UInt8]] {
        var hints = addrinfo()
        hints.ai_family = AF_INET6
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo("ipv4only.arpa", nil, &hints, &result) == 0, let first = result else {
            return []
        }
        defer { freeaddrinfo(result) }
        var answers: [[UInt8]] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
            cursor = entry.pointee.ai_next
            if let address = entry.pointee.ai_addr, let bytes = AddressCheck.addressBytes(address), bytes.count == 16 {
                answers.append(bytes)
            }
        }
        return answers
    }

    private static let cache = Cache()

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var prefixes: [Prefix] = []
        private var networks: [AddressCheck.LocalNetwork] = []
        private var until = ContinuousClock.now

        func value(networks: [AddressCheck.LocalNetwork], _ lookUp: () -> [Prefix]) -> [Prefix] {
            lock.lock()
            defer { lock.unlock() }
            if prefixes.isEmpty || networks != self.networks || ContinuousClock.now >= until {
                prefixes = lookUp()
                self.networks = networks
                until = ContinuousClock.now + .seconds(60)
            }
            return prefixes
        }
    }
}
