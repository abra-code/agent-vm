// Sources/AgentVMKit/Network/AddressCheck.swift
//
// Which resolved addresses the proxy may connect to. An allowed name that resolves to this Mac,
// the local network or a link-local address (DNS rebinding, or a hostile /etc/hosts-style
// answer) is refused: the box must never reach the host or the LAN through the proxy. The
// proxy resolves names itself and connects to the address it checked, never re-resolving.

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
        case 192 where b == 0 && (address >> 8) & 0xff == 0:
            return false // IETF protocol assignments
        case 198 where b == 18 || b == 19:
            return false // benchmarking
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
        return true
    }

    /// Whether `host` is an IP literal (v4, or v6 with or without brackets).
    public static func isIPLiteral(_ host: String) -> Bool {
        let name = AllowRule.normalized(host)
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, name, &v4) == 1 || inet_pton(AF_INET6, name, &v6) == 1
    }

    /// Resolves `host` and returns the addresses the proxy may use: public ones only, unless
    /// `allowPrivate` (tests). Throws with the reason when there is none.
    public static func resolve(_ host: String, port: UInt16, allowPrivate: Bool = false) throws -> [Resolved] {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_family = AF_UNSPEC
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(AllowRule.normalized(host), String(port), &hints, &result)
        guard status == 0, let first = result else {
            throw ProxyRefusal("cannot resolve \(host): \(String(cString: gai_strerror(status)))")
        }
        defer { freeaddrinfo(result) }
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
            let (text, isPublicAddress) = describe(&storage)
            if isPublicAddress || allowPrivate {
                usable.append(Resolved(storage: storage, length: entry.pointee.ai_addrlen, text: text))
            } else {
                refused.append(text)
            }
        }
        guard !usable.isEmpty else {
            throw ProxyRefusal("\(host) resolves only to non-public addresses (\(refused.joined(separator: ", ")))")
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

/// Why the proxy refused a request; the message goes to the log and to the client.
public struct ProxyRefusal: Error, CustomStringConvertible {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String {
        return message
    }
}
