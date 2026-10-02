// Sources/AgentVMKit/Network/AddressCheck.swift
//
// Which resolved addresses the proxy may connect to. An allowed name that resolves to this Mac,
// the local network or a link-local address (DNS rebinding, or a hostile /etc/hosts-style
// answer) is refused: the box must never reach the host or the LAN through the proxy. Besides
// the private and reserved ranges, that means the networks of this Mac's own interfaces: with
// IPv6 the Mac and its neighbors usually have global addresses, which look public. The proxy
// resolves names itself and connects to the address it checked, never re-resolving.

import Darwin
import Foundation

public enum AddressCheck {
    /// A resolved address the proxy may connect to, as text for logs.
    public struct Resolved: Sendable {
        public var storage: sockaddr_storage
        public var length: socklen_t
        public var text: String
    }

    /// Whether an IPv4 address (host byte order) is on the public internet.
    public static func isPublic(ipv4 address: UInt32) -> Bool {
        let a = address >> 24
        let b = (address >> 16) & 0xff
        let c = (address >> 8) & 0xff
        switch a {
        case 0, 10, 127:
            return false // "this network", private, loopback
        case 100 where (64...127).contains(b):
            return false // carrier-grade NAT
        case 169 where b == 254:
            return false // link-local
        case 172 where (16...31).contains(b):
            return false // private
        case 192 where b == 168:
            return false // private
        case 192 where b == 0 && (c == 0 || c == 2):
            return false // IETF protocol assignments, documentation
        case 192 where b == 88 && c == 99:
            return false // the retired 6to4 relay range
        case 198 where b == 18 || b == 19:
            return false // benchmarking
        case 198 where b == 51 && c == 100:
            return false // documentation
        case 203 where b == 0 && c == 113:
            return false // documentation
        case 224...255:
            return false // multicast, reserved, broadcast
        default:
            return true
        }
    }

    /// Whether an IPv6 address is on the public internet; IPv4-mapped and -compatible
    /// addresses are judged as IPv4.
    public static func isPublic(ipv6 bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else {
            return false
        }
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && ((bytes[10] == 0xff && bytes[11] == 0xff) || (bytes[10] == 0 && bytes[11] == 0)) {
            let v4 = UInt32(bytes[12]) << 24 | UInt32(bytes[13]) << 16 | UInt32(bytes[14]) << 8 | UInt32(bytes[15])
            return isPublic(ipv4: v4)
        }
        // Only global unicast (2000::/3) is public; exclude documentation 2001:db8::/32.
        guard bytes[0] & 0xe0 == 0x20 else {
            return false
        }
        if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8 {
            return false
        }
        // 6to4 (2002::/16) and Teredo (2001::/32) addresses carry an IPv4 address that a relay
        // would connect to, unjudged; nothing on today's internet needs either.
        if bytes[0] == 0x20 && bytes[1] == 0x02 {
            return false
        }
        if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0 {
            // 2001::/32 Teredo, 2001:10::/28 and 2001:20::/28 (ORCHID, not routed).
            if bytes[3] == 0 || bytes[3] & 0xf0 == 0x10 || bytes[3] & 0xf0 == 0x20 {
                return false
            }
        }
        // Documentation, 3fff::/20.
        if bytes[0] == 0x3f && bytes[1] == 0xff && bytes[2] & 0xf0 == 0 {
            return false
        }
        return true
    }

    /// A network one of this Mac's interfaces is on: its address and netmask, in network byte
    /// order (4 bytes for IPv4, 16 for IPv6).
    public struct LocalNetwork: Equatable, Sendable {
        public var address: [UInt8]
        public var mask: [UInt8]

        public init(address: [UInt8], mask: [UInt8]) {
            self.address = address
            self.mask = mask
        }

        /// Shorter prefixes than these (a point-to-point link or a VPN with a very wide mask)
        /// count as the interface's own address only, so they cannot shut out the internet.
        static let shortestIPv4Prefix = 16
        static let shortestIPv6Prefix = 48
        /// An IPv6 network counts as at least this wide: providers usually give a home a /56,
        /// and its other /64s (a guest or device network) are the same local network, though
        /// the Mac sees only its own.
        static let widestIPv6Prefix = 56

        /// Whether `bytes` (of the same family) is this address or on this network.
        public func contains(_ bytes: [UInt8]) -> Bool {
            guard bytes.count == address.count, mask.count == address.count else {
                return false
            }
            let prefix = mask.reduce(0) { $0 + $1.nonzeroBitCount }
            let shortest = address.count == 4 ? Self.shortestIPv4Prefix : Self.shortestIPv6Prefix
            if prefix < shortest {
                return bytes == address
            }
            var effective = mask
            if address.count == 16 && prefix > Self.widestIPv6Prefix {
                effective = (0..<16).map { index in
                    let bits = min(max(Self.widestIPv6Prefix - index * 8, 0), 8)
                    return bits == 0 ? 0 : UInt8(truncatingIfNeeded: 0xff << (8 - bits))
                }
            }
            return zip(zip(bytes, address), effective).allSatisfy { pair, mask in pair.0 & mask == pair.1 & mask }
        }
    }

    /// The networks of this Mac's interfaces, up or not (an address stays this Mac's while its
    /// interface is down), read fresh on every call: Wi-Fi networks and VPNs come and go. nil
    /// when the interfaces cannot be read.
    public static func localNetworks() -> [LocalNetwork]? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else {
            return nil
        }
        defer { freeifaddrs(list) }
        var networks: [LocalNetwork] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            guard let address = entry.pointee.ifa_addr else {
                continue
            }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6, let bytes = addressBytes(address) else {
                continue
            }
            // A missing netmask: the address alone.
            let mask = entry.pointee.ifa_netmask.flatMap { addressBytes($0, family: family) } ?? [UInt8](repeating: 0xff, count: bytes.count)
            networks.append(LocalNetwork(address: bytes, mask: mask))
        }
        return networks
    }

    /// The address bytes of an AF_INET or AF_INET6 sockaddr. A netmask's sockaddr may carry no
    /// family of its own, so `family` can be given, and may be shorter than its structure (the
    /// kernel drops trailing zero bytes), so only `sa_len` bytes are read.
    static func addressBytes(_ address: UnsafePointer<sockaddr>, family: Int32? = nil) -> [UInt8]? {
        var storage = sockaddr_storage()
        let length = min(Int(address.pointee.sa_len), MemoryLayout<sockaddr_storage>.size)
        withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: UnsafeRawBufferPointer(start: address, count: length)) }
        switch family ?? Int32(address.pointee.sa_family) {
        case AF_INET:
            return withUnsafeBytes(of: &storage) { raw in
                let offset = MemoryLayout<sockaddr_in>.offset(of: \sockaddr_in.sin_addr)!
                return Array(raw[offset..<(offset + 4)])
            }
        case AF_INET6:
            return withUnsafeBytes(of: &storage) { raw in
                let offset = MemoryLayout<sockaddr_in6>.offset(of: \sockaddr_in6.sin6_addr)!
                return Array(raw[offset..<(offset + 16)])
            }
        default:
            return nil
        }
    }

    /// Whether address `bytes` is on one of `networks`; IPv4-mapped and -compatible IPv6
    /// addresses are judged as IPv4.
    public static func isOnLocalNetwork(_ bytes: [UInt8], networks: [LocalNetwork]) -> Bool {
        var candidate = bytes
        if bytes.count == 16 && bytes[0..<10].allSatisfy({ $0 == 0 }) && ((bytes[10] == 0xff && bytes[11] == 0xff) || (bytes[10] == 0 && bytes[11] == 0)) {
            candidate = Array(bytes[12..<16])
        }
        return networks.contains { $0.contains(candidate) }
    }

    /// Whether `host` is an IP literal (v4, or v6 with or without brackets).
    public static func isIPLiteral(_ host: String) -> Bool {
        let name = AllowRule.normalized(host)
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, name, &v4) == 1 || inet_pton(AF_INET6, name, &v6) == 1
    }

    /// Resolves `host` and returns the addresses the proxy may use: public ones not on this
    /// Mac's networks (`localNetworks`, read from the interfaces when nil) only, unless
    /// `allowPrivate` (tests). An IPv6 address under a NAT64 prefix (`nat64`, the ones in use
    /// now when nil) is judged as the IPv4 address it stands for. Throws with the reason when
    /// there is none.
    public static func resolve(_ host: String, port: UInt16, allowPrivate: Bool = false, localNetworks networks: [LocalNetwork]? = nil,
                               nat64: [NAT64.Prefix]? = nil) throws -> [Resolved] {
        let name = AllowRule.normalized(host)
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_family = AF_UNSPEC
        // An address stays that address: on an IPv6-only network macOS would otherwise turn an
        // IPv4 one into a NAT64 address (measured), which reaches the carrier's side of the
        // gateway instead of the address given.
        var v4 = in_addr()
        var v6 = in6_addr()
        // A name is looked up as written, with a final dot: without one the resolver may try
        // it with this Mac's search domains appended, and `db` would become `db.corp.example`.
        var lookedUp = name + "."
        if inet_pton(AF_INET, name, &v4) == 1 {
            hints.ai_family = AF_INET
            hints.ai_flags = AI_NUMERICHOST
            lookedUp = name
        } else if inet_pton(AF_INET6, name, &v6) == 1 {
            hints.ai_family = AF_INET6
            hints.ai_flags = AI_NUMERICHOST
            lookedUp = name
        }
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(lookedUp, String(port), &hints, &result)
        // The box is told the same for a name that does not resolve and for one that resolves to
        // addresses it may not reach: else it could list the names of networks it cannot reach.
        let forClient = "\(host) has no address the proxy may use (the box's network log on the Mac says why)"
        guard status == 0, let first = result else {
            throw ProxyRefusal("cannot resolve \(host): \(String(cString: gai_strerror(status)))", forClient: forClient)
        }
        defer { freeaddrinfo(result) }
        // Without the interfaces, nothing is known to be off this Mac's networks: refuse.
        guard let local = allowPrivate ? [] : (networks ?? localNetworks()) else {
            throw ProxyRefusal("cannot read this Mac's network interfaces")
        }
        let prefixes = allowPrivate ? [] : (nat64 ?? NAT64.current(networks: local))
        var usable: [Resolved] = []
        var refused: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
            cursor = entry.pointee.ai_next
            guard let address = entry.pointee.ai_addr else {
                continue
            }
            var storage = sockaddr_storage()
            memcpy(&storage, address, Int(entry.pointee.ai_addrlen))
            let (text, judged) = describe(&storage)
            var isPublicAddress = judged
            var shown = text
            let bytes = addressBytes(address) ?? []
            let v4 = NAT64.embeddedIPv4(bytes, prefixes: prefixes)
            if let v4 {
                // Where the gateway connects: judged as that IPv4 address too, named in refusals.
                // Outside the space reserved for translation the IPv6 checks stay, so a prefix
                // from a hostile ipv4only.arpa answer (a ULA, this Mac's subnet) only refuses more.
                isPublicAddress = (judged || NAT64.isReservedForTranslation(bytes)) && isPublic(ipv4: v4.reduce(0) { $0 << 8 | UInt32($1) })
                shown += " (NAT64 for \(v4.map(String.init).joined(separator: ".")))"
            }
            let onLocalNetwork = isPublicAddress && (isOnLocalNetwork(bytes, networks: local) || v4.map { isOnLocalNetwork($0, networks: local) } == true)
            if allowPrivate || (isPublicAddress && !onLocalNetwork) {
                usable.append(Resolved(storage: storage, length: entry.pointee.ai_addrlen, text: text))
            } else {
                refused.append(onLocalNetwork ? "\(shown) on this Mac's network" : shown)
            }
        }
        guard !usable.isEmpty else {
            throw ProxyRefusal("\(host) resolves only to non-public addresses (\(refused.joined(separator: ", ")))", forClient: forClient)
        }
        return usable
    }

    static func describe(_ storage: inout sockaddr_storage) -> (String, Bool) {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        switch Int32(storage.ss_family) {
        case AF_INET:
            return withUnsafePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { v4 in
                    var address = v4.pointee.sin_addr
                    inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count))
                    let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    return (text, isPublic(ipv4: UInt32(bigEndian: address.s_addr)))
                }
            }
        case AF_INET6:
            return withUnsafePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { v6 in
                    var address = v6.pointee.sin6_addr
                    inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count))
                    let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    let bytes = withUnsafeBytes(of: &address) { Array($0) }
                    return (text, isPublic(ipv6: bytes))
                }
            }
        default:
            return ("?", false)
        }
    }
}

/// Why the proxy refused a request; the message goes to the log, and to the client unless
/// there is another text for it.
public struct ProxyRefusal: Error, CustomStringConvertible {
    public var message: String
    /// What the client is told.
    public var forClient: String

    public init(_ message: String, forClient: String? = nil) {
        self.message = message
        self.forClient = forClient ?? message
    }

    public var description: String {
        return message
    }
}
