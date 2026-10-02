// Sources/AgentVMKit/Network/NetworkPolicy.swift
//
// What a box may reach. Three modes:
// - allowlist: the box's network card leads nowhere; the only way out is the host proxy, which
//   lets through connections to the listed hosts and logs every attempt.
// - off: the same, with nothing allowed (every attempt is refused and logged).
// - open: NAT through the host - the internet and the local network. No proxy, no log.
//
// Rules are host names ("github.com" matches only itself), wildcard suffixes ("*.github.com"
// matches every subdomain, not github.com itself), optional ports ("example.com:8443"), packs
// ("pack:github") that expand to curated lists, and "public" (any public DNS name, never an IP
// literal or a local name; the proxy still refuses every address that is not public or that is
// on this Mac's own networks). Without a port, a rule allows HTTPS tunnels to 443 and plain
// HTTP requests to 80 - not tunnels to 80, whose raw requests could name any other site the
// allowed server hosts (the proxy rewrites Host only for plain HTTP).

import Foundation

public struct BoxNetwork: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        case allowlist
        case off
        case open
    }

    public var mode: Mode
    /// Rules as the user wrote them (hosts, wildcards, `pack:<name>`).
    public var allow: [String]

    public init(mode: Mode, allow: [String] = []) {
        self.mode = mode
        self.allow = allow
    }

    /// Boxes created before network policy existed ran on NAT.
    public static let legacy = BoxNetwork(mode: .open)

    /// Whether the box's traffic goes through the host proxy (a dead-end network card).
    public var usesProxy: Bool {
        return mode != .open
    }
}

/// One parsed rule.
public struct AllowRule: Equatable, Sendable, CustomStringConvertible {
    /// Lower-case host name or IP literal, without a leading "*.".
    public var host: String
    /// True for "*.host": any subdomain, not the host itself.
    public var subdomains: Bool
    /// nil means the default port for the kind of request: 443 for tunnels, 80 for plain HTTP.
    public var port: UInt16?
    /// True for "public": any public DNS name (`isPublicHostName`); `host` is "public".
    public var anyPublicHost = false

    public static let defaultTunnelPort: UInt16 = 443
    public static let defaultHTTPPort: UInt16 = 80
    public static let publicKeyword = "public"

    public var description: String {
        return (subdomains ? "*." : "") + host + (port.map { ":\($0)" } ?? "")
    }

    /// Parses "host", "*.host", "host:port", "[v6]:port", "public" or "public:port"; nil for
    /// anything else.
    public static func parse(_ text: String) -> AllowRule? {
        var rest = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !rest.isEmpty else {
            return nil
        }
        if rest == publicKeyword || rest.hasPrefix(publicKeyword + ":") {
            var port: UInt16?
            if rest != publicKeyword {
                guard let parsed = UInt16(rest.dropFirst(publicKeyword.count + 1)), parsed > 0 else {
                    return nil
                }
                port = parsed
            }
            return AllowRule(host: publicKeyword, subdomains: false, port: port, anyPublicHost: true)
        }
        var port: UInt16?
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else {
                return nil
            }
            let after = rest[rest.index(after: close)...]
            if after.hasPrefix(":") {
                guard let parsed = UInt16(after.dropFirst()), parsed > 0 else {
                    return nil
                }
                port = parsed
            } else if !after.isEmpty {
                return nil
            }
            rest = String(rest[rest.index(after: rest.startIndex)..<close])
            guard !rest.isEmpty, rest.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }) else {
                return nil
            }
            return AllowRule(host: rest, subdomains: false, port: port)
        }
        if let colon = rest.lastIndex(of: ":") {
            guard let parsed = UInt16(rest[rest.index(after: colon)...]), parsed > 0 else {
                return nil
            }
            port = parsed
            rest = String(rest[..<colon])
        }
        var subdomains = false
        if rest.hasPrefix("*.") {
            subdomains = true
            rest = String(rest.dropFirst(2))
        }
        // Letters, digits, "-" and "." only; no empty labels.
        let labels = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty, labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }) else {
            return nil
        }
        return AllowRule(host: rest, subdomains: subdomains, port: port)
    }

    /// `tunnel`: a CONNECT request (else a plain HTTP request).
    public func matches(host candidate: String, port candidatePort: UInt16, tunnel: Bool) -> Bool {
        let name = Self.normalized(candidate)
        let hostMatches = anyPublicHost ? Self.isPublicHostName(name) : subdomains ? name.hasSuffix("." + host) : name == host
        guard hostMatches else {
            return false
        }
        if let port {
            return candidatePort == port
        }
        return candidatePort == (tunnel ? Self.defaultTunnelPort : Self.defaultHTTPPort)
    }

    /// Names that only a local resolver answers (mDNS, RFC 6762; RFC 6761; ICANN's private-use
    /// "internal"; RFC 8375; the top-level names home and office networks use, none of them
    /// delegated; RFC 7686): never public, and looking them up could reach the local network.
    static let localSuffixes = ["local", "localhost", "internal", "home.arpa", "lan", "home", "corp", "intranet", "private", "localdomain",
                                "test", "invalid", "example", "onion"]

    /// Whether `name` (normalized) can be a public DNS name, as the "public" rule requires: at
    /// least two labels, a top-level label starting with a letter (so no IP literal in any
    /// notation getaddrinfo accepts, such as "1.2.3.4", "0x7f.1" or "2130706433"), and not
    /// under a local-only domain. Single-label names would go through the Mac's search domains,
    /// which are the local network's.
    static func isPublicHostName(_ name: String) -> Bool {
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }),
              let top = labels.last?.first, top.isLetter else {
            return false
        }
        return !localSuffixes.contains { name == $0 || name.hasSuffix("." + $0) }
    }

    /// Lower case, without a trailing dot or IPv6 brackets.
    static func normalized(_ host: String) -> String {
        var name = host.lowercased()
        if name.hasPrefix("[") && name.hasSuffix("]") {
            name = String(name.dropFirst().dropLast())
        }
        while name.hasSuffix(".") {
            name.removeLast()
        }
        return name
    }
}

/// The rules of a policy, expanded and parsed.
public struct CompiledPolicy: Sendable {
    public struct Entry: Sendable {
        public var rule: AllowRule
        /// Where the rule came from: the rule text, or "pack:<name>".
        public var source: String
    }

    public var mode: BoxNetwork.Mode
    public var entries: [Entry]

    /// Expands packs (from `packs`) and parses every rule; throws on an unknown or unusable
    /// pack, or a malformed rule.
    public init(_ network: BoxNetwork, packs: NetworkPacks) throws {
        mode = network.mode
        entries = []
        for text in network.allow {
            if text.lowercased().hasPrefix("pack:") {
                let name = String(text.dropFirst("pack:".count)).lowercased()
                let hosts = try packs.hosts(of: name)
                for host in hosts {
                    guard let rule = AllowRule.parse(host) else {
                        continue
                    }
                    entries.append(Entry(rule: rule, source: "pack:\(name)"))
                }
                continue
            }
            guard let rule = AllowRule.parse(text) else {
                throw AgentVMError.invalidNetworkRule(text, reason: "expected a host name, *.domain, host:port, pack:<name>, public or public:port")
            }
            entries.append(Entry(rule: rule, source: rule.description))
        }
    }

    /// The source of the first rule allowing `host:port`, or nil when none does (or the
    /// mode is `off`). Named rules come before "public", so the log shows which hosts a box
    /// would need without it.
    public func allows(host: String, port: UInt16, tunnel: Bool) -> String? {
        guard mode == .allowlist else {
            return nil
        }
        let named = entries.first { !$0.rule.anyPublicHost && $0.rule.matches(host: host, port: port, tunnel: tunnel) }
        return (named ?? entries.first { $0.rule.anyPublicHost && $0.rule.matches(host: host, port: port, tunnel: tunnel) })?.source
    }
}
