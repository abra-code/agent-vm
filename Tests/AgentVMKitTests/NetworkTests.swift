// Tests/AgentVMKitTests/NetworkTests.swift
//
// Network policy, address checks, the proxy (end to end against a local server, with private
// upstreams allowed only in these tests) and the dead-end link's ARP answer.

import Darwin
import Foundation
import Testing
@testable import AgentVMKit

/// The repository's built-in packs (Resources/packs.json), without any user packs.
enum TestPacks {
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/packs.json")
    static let builtIn: NetworkPacks = {
        // A store with no Packs folder.
        let empty = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agent-vm-no-user-packs")
        return try! NetworkPacks.load(store: empty, builtIn: repository)
    }()
}

@Suite struct AllowRuleTests {
    @Test func parsing() {
        #expect(AllowRule.parse("GitHub.com") == AllowRule(host: "github.com", subdomains: false, port: nil))
        #expect(AllowRule.parse("*.example.com") == AllowRule(host: "example.com", subdomains: true, port: nil))
        #expect(AllowRule.parse("example.com:8443") == AllowRule(host: "example.com", subdomains: false, port: 8443))
        #expect(AllowRule.parse("[2606:4700::1]:443") == AllowRule(host: "2606:4700::1", subdomains: false, port: 443))
        #expect(AllowRule.parse("203.0.113.5") == AllowRule(host: "203.0.113.5", subdomains: false, port: nil))
        for bad in ["", "*", "*.", "a..b", "exa mple.com", "example.com:0", "example.com:99999", "http://example.com", "ex/ample", "\u{0435}xample.com", "[::1"] {
            #expect(AllowRule.parse(bad) == nil, "\(bad)")
        }
    }

    @Test func matching() {
        let exact = AllowRule.parse("github.com")!
        #expect(exact.matches(host: "github.com", port: 443, tunnel: true))
        #expect(exact.matches(host: "GITHUB.COM.", port: 80, tunnel: false))
        // Without a port: tunnels to 443 only, plain HTTP to 80 only.
        #expect(!exact.matches(host: "github.com", port: 80, tunnel: true))
        #expect(!exact.matches(host: "github.com", port: 443, tunnel: false))
        #expect(!exact.matches(host: "github.com", port: 22, tunnel: true))
        #expect(!exact.matches(host: "api.github.com", port: 443, tunnel: true))
        #expect(!exact.matches(host: "evilgithub.com", port: 443, tunnel: true))

        let wildcard = AllowRule.parse("*.github.com")!
        #expect(wildcard.matches(host: "api.github.com", port: 443, tunnel: true))
        #expect(wildcard.matches(host: "a.b.github.com", port: 443, tunnel: true))
        #expect(!wildcard.matches(host: "github.com", port: 443, tunnel: true))
        #expect(!wildcard.matches(host: "evilgithub.com", port: 443, tunnel: true))

        let port = AllowRule.parse("example.com:8443")!
        #expect(port.matches(host: "example.com", port: 8443, tunnel: true))
        #expect(port.matches(host: "example.com", port: 8443, tunnel: false))
        #expect(!port.matches(host: "example.com", port: 443, tunnel: true))
    }

    @Test func policiesExpandPacksAndRespectTheMode() throws {
        let policy = try CompiledPolicy(BoxNetwork(mode: .allowlist, allow: ["pack:npm", "example.com"]), packs: TestPacks.builtIn)
        #expect(policy.allows(host: "registry.npmjs.org", port: 443, tunnel: true) == "pack:npm")
        #expect(policy.allows(host: "example.com", port: 443, tunnel: true) == "example.com")
        #expect(policy.allows(host: "example.com", port: 80, tunnel: false) == "example.com")
        #expect(policy.allows(host: "pypi.org", port: 443, tunnel: true) == nil)

        let off = try CompiledPolicy(BoxNetwork(mode: .off, allow: ["example.com"]), packs: TestPacks.builtIn)
        #expect(off.allows(host: "example.com", port: 443, tunnel: true) == nil)

        #expect(throws: AgentVMError.self) { _ = try CompiledPolicy(BoxNetwork(mode: .allowlist, allow: ["pack:nope"]), packs: TestPacks.builtIn) }
        #expect(throws: AgentVMError.self) { _ = try CompiledPolicy(BoxNetwork(mode: .allowlist, allow: ["not a host"]), packs: TestPacks.builtIn) }
        #expect(throws: AgentVMError.self) { _ = try CompiledPolicy(BoxNetwork(mode: .allowlist, allow: ["public:0"]), packs: TestPacks.builtIn) }
        // The repository's packs file loads (every host a valid rule, none "public").
        #expect(TestPacks.builtIn.packs["anthropic"]?.hosts.contains("platform.claude.com") == true)
        #expect(TestPacks.builtIn.packs["anthropic-connectors"]?.hosts == ["mcp-proxy.anthropic.com"])
    }
}

@Suite struct PublicRuleTests {
    @Test func parsing() {
        #expect(AllowRule.parse("public") == AllowRule(host: "public", subdomains: false, port: nil, anyPublicHost: true))
        #expect(AllowRule.parse(" Public:8443 ") == AllowRule(host: "public", subdomains: false, port: 8443, anyPublicHost: true))
        #expect(AllowRule.parse("public:8443")?.description == "public:8443")
        #expect(AllowRule.parse("public")?.description == "public")
        // Only the keyword itself: a host under "public" stays a host.
        #expect(AllowRule.parse("*.public")?.anyPublicHost == false)
        #expect(AllowRule.parse("public.example.com")?.anyPublicHost == false)
        for bad in ["public:", "public:0", "public:x", "public:99999"] {
            #expect(AllowRule.parse(bad) == nil, "\(bad)")
        }
    }

    @Test func matchesPublicNamesOnly() {
        let rule = AllowRule.parse("public")!
        #expect(rule.matches(host: "example.com", port: 443, tunnel: true))
        #expect(rule.matches(host: "api.example.co.uk.", port: 80, tunnel: false))
        #expect(rule.matches(host: "xn--80ak6aa92e.xn--p1ai", port: 443, tunnel: true))
        #expect(!rule.matches(host: "example.com", port: 80, tunnel: true))
        #expect(!rule.matches(host: "example.com", port: 22, tunnel: true))
        // IP literals in every notation getaddrinfo takes, single-label and local-only names.
        for host in ["1.1.1.1", "2606:4700::1111", "[::1]", "2130706433", "0x7f.1", "127.1", "1.2.3.4.", "localhost", "router",
                     "printer.local", "foo.localhost", "db.internal", "nas.home.arpa", "home.arpa", "a..b", "-", "."] {
            #expect(!rule.matches(host: host, port: 443, tunnel: true), "\(host)")
        }
        let port = AllowRule.parse("public:8443")!
        #expect(port.matches(host: "example.com", port: 8443, tunnel: true))
        #expect(!port.matches(host: "example.com", port: 443, tunnel: true))
    }

    /// Names of home and office networks are not public names, so "public" never looks them up.
    @Test func thePublicRuleRefusesLocalOnlyDomains() throws {
        let rule = AllowRule.parse("public")!
        for host in ["nas.lan", "printer.home", "db.corp", "wiki.intranet", "x.localdomain", "foo.test", "a.private", "b.invalid", "c.example",
                     "d.onion", "mac.local", "x.internal", "router.home.arpa", "NAS.LAN."] {
            #expect(!rule.matches(host: host, port: 443, tunnel: true), "\(host)")
        }
        for host in ["lan.example.com", "home.net", "test.org", "corp.io"] {
            #expect(rule.matches(host: host, port: 443, tunnel: true), "\(host)")
        }
    }

    /// Named rules come first, so the log names them; the rest is logged as "public".
    @Test func namedRulesComeBeforePublic() throws {
        let policy = try CompiledPolicy(BoxNetwork(mode: .allowlist, allow: ["public", "pack:npm", "example.com:8443"]), packs: TestPacks.builtIn)
        #expect(policy.allows(host: "registry.npmjs.org", port: 443, tunnel: true) == "pack:npm")
        #expect(policy.allows(host: "example.com", port: 8443, tunnel: true) == "example.com:8443")
        #expect(policy.allows(host: "example.com", port: 443, tunnel: true) == "public")
        #expect(policy.allows(host: "1.1.1.1", port: 443, tunnel: true) == nil)
        #expect(try CompiledPolicy(BoxNetwork(mode: .allowlist, allow: ["PUBLIC:8443"]), packs: TestPacks.builtIn).allows(host: "example.org", port: 8443, tunnel: true) == "public:8443")
        #expect(try CompiledPolicy(BoxNetwork(mode: .off, allow: ["public"]), packs: TestPacks.builtIn).allows(host: "example.com", port: 443, tunnel: true) == nil)
    }
}

@Suite struct AddressCheckTests {
    func v4(_ text: String) -> UInt32 {
        var address = in_addr()
        _ = inet_pton(AF_INET, text, &address)
        return UInt32(bigEndian: address.s_addr)
    }

    func v6(_ text: String) -> [UInt8] {
        var address = in6_addr()
        _ = inet_pton(AF_INET6, text, &address)
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    @Test func privateAndSpecialAddressesAreRefused() {
        for text in ["10.1.2.3", "127.0.0.1", "172.16.0.1", "172.31.255.255", "192.168.64.1", "169.254.1.1", "100.64.0.1", "0.0.0.0", "224.0.0.251", "255.255.255.255", "198.18.0.1"] {
            #expect(!AddressCheck.isPublic(ipv4: v4(text)), "\(text)")
        }
        for text in ["1.1.1.1", "140.82.112.3", "172.32.0.1", "100.128.0.1"] {
            #expect(AddressCheck.isPublic(ipv4: v4(text)), "\(text)")
        }
        for text in ["::1", "fe80::1", "fc00::1", "fd12::1", "::ffff:192.168.1.1", "::ffff:127.0.0.1", "2001:db8::1", "ff02::1", "::"] {
            #expect(!AddressCheck.isPublic(ipv6: v6(text)), "\(text)")
        }
        for text in ["2606:4700:4700::1111", "::ffff:1.1.1.1"] {
            #expect(AddressCheck.isPublic(ipv6: v6(text)), "\(text)")
        }
    }

    @Test func namesResolvingToThisMacAreRefused() {
        #expect(throws: ProxyRefusal.self) { _ = try AddressCheck.resolve("localhost", port: 443) }
        #expect(throws: ProxyRefusal.self) { _ = try AddressCheck.resolve("127.0.0.1", port: 443) }
        #expect((try? AddressCheck.resolve("127.0.0.1", port: 443, allowPrivate: true))?.first?.text == "127.0.0.1")
        #expect(AddressCheck.isIPLiteral("[::1]"))
        #expect(!AddressCheck.isIPLiteral("example.com"))
    }

    @Test func localNetworksContainTheirAddresses() {
        let lan = AddressCheck.LocalNetwork(address: [203, 0, 113, 7], mask: [255, 255, 255, 0])
        #expect(lan.contains([203, 0, 113, 200]))
        #expect(!lan.contains([203, 0, 114, 1]))
        #expect(!lan.contains(v6("2001:db8::1")))
        let v6lan = AddressCheck.LocalNetwork(address: v6("2a01:4f8:1:2::10"), mask: v6("ffff:ffff:ffff:ffff::"))
        #expect(v6lan.contains(v6("2a01:4f8:1:2:aaaa::1")))
        // A /64 counts as its /56: the home's other subnets.
        #expect(v6lan.contains(v6("2a01:4f8:1:3::1")))
        #expect(v6lan.contains(v6("2a01:4f8:1:ff::1")))
        #expect(!v6lan.contains(v6("2a01:4f8:1:100::1")))
        // A /50 stays a /50.
        let v6wide = AddressCheck.LocalNetwork(address: v6("2a01:4f8:1:2::10"), mask: v6("ffff:ffff:ffff:c000::"))
        #expect(v6wide.contains(v6("2a01:4f8:1:3fff::1")))
        #expect(!v6wide.contains(v6("2a01:4f8:1:4000::1")))
        // A mask wider than /16 or /48 counts as the address alone.
        let wide = AddressCheck.LocalNetwork(address: [100, 71, 102, 28], mask: [255, 0, 0, 0])
        #expect(wide.contains([100, 71, 102, 28]))
        #expect(!wide.contains([100, 71, 102, 29]))
        #expect(!AddressCheck.LocalNetwork(address: v6("2a01::1"), mask: v6("ffff::")).contains(v6("2a01::2")))
        // IPv4-mapped IPv6 is judged as IPv4.
        #expect(AddressCheck.isOnLocalNetwork(v6("::ffff:203.0.113.9"), networks: [lan]))
        #expect(!AddressCheck.isOnLocalNetwork(v6("::ffff:198.51.100.9"), networks: [lan]))
    }

    /// Public addresses on this Mac's own networks (its IPv6 prefix, or a public IPv4 LAN) are
    /// refused like private ones.
    @Test func addressesOnThisMacsNetworksAreRefused() throws {
        let lan = AddressCheck.LocalNetwork(address: [203, 0, 113, 7], mask: [255, 255, 255, 0])
        #expect(throws: ProxyRefusal.self) { _ = try AddressCheck.resolve("203.0.113.9", port: 443, localNetworks: [lan]) }
        do {
            _ = try AddressCheck.resolve("203.0.113.9", port: 443, localNetworks: [lan])
        } catch let refusal as ProxyRefusal {
            #expect(refusal.message.contains("203.0.113.9 on this Mac's network"))
        }
        #expect((try? AddressCheck.resolve("203.0.113.9", port: 443, localNetworks: []))?.first?.text == "203.0.113.9")
        let v6lan = AddressCheck.LocalNetwork(address: v6("2a01:4f8:1:2::10"), mask: v6("ffff:ffff:ffff:ffff::"))
        #expect(throws: ProxyRefusal.self) { _ = try AddressCheck.resolve("2a01:4f8:1:2::99", port: 443, localNetworks: [v6lan]) }
        #expect((try? AddressCheck.resolve("2a01:4f8:1:100::99", port: 443, localNetworks: [v6lan]))?.first?.text == "2a01:4f8:1:100::99")
    }

    /// The interfaces are read, netmasks included: the loopback's 127.0.0.1/8 is always there.
    @Test func thisMacsNetworksAreRead() throws {
        let networks = try #require(AddressCheck.localNetworks())
        #expect(networks.contains(AddressCheck.LocalNetwork(address: [127, 0, 0, 1], mask: [255, 0, 0, 0])))
        #expect(networks.contains { $0.address == v6("::1") && $0.mask == [UInt8](repeating: 0xff, count: 16) })
    }
}

@Suite struct ProxyParsingTests {
    func parse(_ head: String) throws -> ProxyServer.Request {
        return try ProxyServer.parse(Array(head.utf8))
    }

    @Test func connectRequests() throws {
        let request = try parse("CONNECT GitHub.com:443 HTTP/1.1\r\nHost: github.com:443\r\n\r\n")
        #expect(request.method == "CONNECT")
        #expect(request.host == "github.com")
        #expect(request.port == 443)
        #expect(request.tunnel)
        #expect(try parse("CONNECT [2606:4700::1]:443 HTTP/1.1\r\n\r\n").host == "2606:4700::1")
        #expect(throws: ProxyRefusal.self) { _ = try parse("CONNECT github.com HTTP/1.1\r\n\r\n") }
    }

    @Test func plainHTTPIsRewrittenToOriginForm() throws {
        let request = try parse("GET http://example.com/a?b=1 HTTP/1.1\r\nHost: example.com\r\nProxy-Connection: keep-alive\r\nConnection: keep-alive\r\nAccept: */*\r\n\r\n")
        #expect(request.host == "example.com")
        #expect(request.port == 80)
        #expect(!request.tunnel)
        #expect(request.upstreamHead == "GET /a?b=1 HTTP/1.1\r\nHost: example.com\r\nAccept: */*\r\nConnection: close\r\n\r\n")
        #expect(try parse("GET http://example.com:8080 HTTP/1.0\r\n\r\n").upstreamHead.hasPrefix("GET / HTTP/1.0\r\n"))
    }

    @Test func theHostHeaderComesFromTheTarget() throws {
        // A client Host naming another site would reach it at the allowed address (a shared CDN).
        let request = try parse("GET http://Example.com./a HTTP/1.1\r\nhost: evil.example\r\nHOST: evil2.example\r\n\r\n")
        #expect(request.upstreamHead == "GET /a HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n")
        #expect(try parse("GET http://[2606:4700::1]:8080/ HTTP/1.1\r\n\r\n").upstreamHead.hasPrefix("GET / HTTP/1.1\r\nHost: [2606:4700::1]:8080\r\n"))
    }

    @Test func headsThatCouldSmuggleLinesAreRefused() {
        for head in ["GET http://example.com/a\nHost:\tevil HTTP/1.1\r\n\r\n",
                     "GET http://example.com/ HTTP/1.1\nHost:\tevil\r\n\r\n",
                     "GET http://example.com/ HTTP/1.1\r\nX: a\nHost: evil\r\n\r\n",
                     "GET http://example.com/ HTTP/1.1\r\nX: a\rHost: evil\r\n\r\n",
                     "GET http://example.com/ HTTP/1.1\r\nX: a\r\n Host: evil\r\n\r\n",
                     "GET http://example.com/ HTTP/1.1\r\nHost : evil\r\n\r\n",
                     "GET http://example.com/ HTTP/1.1\r\nno colon\r\n\r\n",
                     "GET http://example.com/ HTTP/1.1\r\n: empty name\r\n\r\n",
                     "GET http://example.com/ HTTP/1.1\r\nX: a\u{0}b\r\n\r\n",
                     "GET http://example.com/ HTTP/1.10\r\n\r\n",
                     "CONNECT example.com:443 HTTP/1.1\r\nX: a\nY: b\r\n\r\n"] {
            #expect(throws: ProxyRefusal.self, "\(head.debugDescription)") { _ = try parse(head) }
        }
    }

    @Test func theHeadMustArriveWithinTheTimeoutInTotal() throws {
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let writer = pair[0]
        // A write after the shutdown below fails with EPIPE instead of killing the tests.
        _ = fcntl(writer, F_SETNOSIGPIPE, 1)
        let writerDone = DispatchSemaphore(value: 0)
        defer {
            // The writer goes on for seconds after the reader gives up. It must be done before
            // the descriptors close: its next byte would go to whatever took the number next,
            // another test's connection or terminal (a stray "t" was read there as "unknown
            // frame type 116", and made the guest server hang up a program).
            shutdown(writer, SHUT_RDWR)
            writerDone.wait()
            close(pair[0])
            close(pair[1])
        }
        // One byte every 200 ms: each read succeeds, but the whole head never comes in time.
        Thread.detachNewThread {
            defer { writerDone.signal() }
            for byte in Array("GET http://example.com/ HTTP/1.1\r\nX: ".utf8) {
                var value = byte
                if write(writer, &value, 1) != 1 {
                    return
                }
                usleep(200_000)
            }
        }
        let clock = ContinuousClock()
        let began = clock.now
        #expect(throws: ProxyRefusal.self) { _ = try ProxyServer.readHead(pair[1], timeout: .seconds(1)) }
        #expect(clock.now - began < .seconds(3))
    }

    @Test func otherRequestsAreRefused() {
        for head in ["GET /path HTTP/1.1\r\n\r\n", "GET https://example.com/ HTTP/1.1\r\n\r\n", "get http://x/ HTTP/1.1\r\n\r\n",
                     "GET http://user:pw@example.com/ HTTP/1.1\r\n\r\n", "GET http://exa mple.com/ HTTP/1.1\r\n\r\n", "HELLO\r\n\r\n"] {
            #expect(throws: ProxyRefusal.self, "\(head)") { _ = try parse(head) }
        }
    }
}

/// A local TCP server on 127.0.0.1: answers each connection with a fixed reply after reading
/// the first chunk, and records what it received.
final class LocalServer: @unchecked Sendable {
    let port: UInt16
    private let listener: Int32
    private let lock = NSLock()
    private var received: [String] = []

    init(reply: String) throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, length) == 0 && listen(listener, 8) == 0 && getsockname(listener, $0, &length) == 0
            }
        }
        guard ok else {
            throw AgentVMError.system(operation: "local server", code: errno)
        }
        port = UInt16(bigEndian: address.sin_port)
        self.listener = listener
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 {
                    return
                }
                var buffer = [UInt8](repeating: 0, count: 4096)
                let count = read(client, &buffer, buffer.count)
                lock.lock()
                received.append(String(decoding: buffer[0..<max(count, 0)], as: UTF8.self))
                lock.unlock()
                _ = reply.withCString { write(client, $0, strlen($0)) }
                close(client)
            }
        }
    }

    var requests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    deinit {
        close(listener)
    }
}

/// A local TCP server on 127.0.0.1 that keeps every connection open until told to close them:
/// it counts what it receives (or never reads), and can send without end.
final class HoldingServer: @unchecked Sendable {
    let port: UInt16
    private let listener: Int32
    private let lock = NSLock()
    private var connections: [Int32] = []
    private var count = 0

    init(reads: Bool = true, floods: Bool = false, halfCloses: Bool = false) throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, length) == 0 && listen(listener, 8) == 0 && getsockname(listener, $0, &length) == 0
            }
        }
        guard ok else {
            throw AgentVMError.system(operation: "holding server", code: errno)
        }
        port = UInt16(bigEndian: address.sin_port)
        self.listener = listener
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 {
                    return
                }
                var one: Int32 = 1
                _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                lock.lock()
                connections.append(client)
                lock.unlock()
                if reads {
                    Thread.detachNewThread { [self] in
                        var buffer = [UInt8](repeating: 0, count: 65536)
                        while true {
                            let got = read(client, &buffer, buffer.count)
                            if got <= 0 {
                                return
                            }
                            lock.lock()
                            count += got
                            lock.unlock()
                        }
                    }
                }
                if halfCloses {
                    shutdown(client, SHUT_WR)
                }
                if floods {
                    Thread.detachNewThread {
                        let chunk = [UInt8](repeating: 9, count: 65536)
                        while write(client, chunk, chunk.count) > 0 {}
                    }
                }
            }
        }
    }

    /// Bytes received on all connections.
    var received: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    /// Shuts every connection down; the descriptors are closed with the server. Each way by
    /// itself: SHUT_RDWR does nothing on a socket whose peer has finished sending.
    func closeConnections() {
        lock.lock()
        for connection in connections {
            shutdown(connection, SHUT_RD)
            shutdown(connection, SHUT_WR)
        }
        lock.unlock()
    }

    deinit {
        closeConnections()
        close(listener)
        for connection in connections {
            close(connection)
        }
    }
}

@Suite struct ProxyServerTests {
    /// Runs one proxied exchange: sends `request` from the client side, returns everything the
    /// client got back.
    func exchange(_ proxy: ProxyServer, _ request: String) throws -> String {
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let (client, server) = (pair[0], pair[1])
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            proxy.handle(client: server)
            close(server)
            done.signal()
        }
        _ = request.withCString { write(client, $0, strlen($0)) }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            // A tunnel ends with a shutdown, which a thread asleep in read(2) can miss (SocketRead).
            let count = buffer.withUnsafeMutableBytes { SocketRead.read(client, $0.baseAddress!, $0.count) }
            if count <= 0 {
                break
            }
            output.append(contentsOf: buffer[0..<count])
        }
        close(client)
        #expect(done.wait(timeout: .now() + 10) == .success)
        return String(decoding: output, as: UTF8.self)
    }

    @Test func allowedTunnelsAndRequestsGoThroughAndAreLogged() throws {
        let scratch = try Scratch()
        let log = NetworkLog(url: scratch.root.appendingPathComponent("network.jsonl"))
        let server = try LocalServer(reply: "pong")
        let policy = try CompiledPolicy(BoxNetwork(mode: .allowlist, allow: ["127.0.0.1:\(server.port)"]), packs: TestPacks.builtIn)
        let proxy = ProxyServer(policy: policy, log: log, allowPrivate: true)

        let tunneled = try exchange(proxy, "CONNECT 127.0.0.1:\(server.port) HTTP/1.1\r\n\r\nping")
        #expect(tunneled == "HTTP/1.0 200 Connection established\r\n\r\npong")
        #expect(server.requests.first == "ping")

        let plain = try exchange(proxy, "GET http://127.0.0.1:\(server.port)/x HTTP/1.1\r\nHost: 127.0.0.1\r\nProxy-Connection: keep-alive\r\n\r\n")
        #expect(plain == "pong")
        #expect(server.requests.last == "GET /x HTTP/1.1\r\nHost: 127.0.0.1:\(server.port)\r\nConnection: close\r\n\r\n")

        let entries = log.entries()
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.decision == .allowed && $0.rule == "127.0.0.1:\(server.port)" && $0.address == "127.0.0.1" })
        #expect(entries.first?.bytesUp == 4)
        #expect(entries.first?.bytesDown == 4)
    }

    /// A tunnel is in the log as soon as it is connected, not only when it ends.
    @Test func anOpenTunnelIsLoggedWhileItRuns() throws {
        let scratch = try Scratch()
        let log = NetworkLog(url: scratch.root.appendingPathComponent("network.jsonl"))
        let server = try LocalServer(reply: "pong")
        let policy = try CompiledPolicy(BoxNetwork(mode: .allowlist, allow: ["127.0.0.1:\(server.port)"]), packs: TestPacks.builtIn)
        let proxy = ProxyServer(policy: policy, log: log, allowPrivate: true)
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let (client, served) = (pair[0], pair[1])
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            proxy.handle(client: served)
            close(served)
            done.signal()
        }
        defer { close(client) }
        _ = "CONNECT 127.0.0.1:\(server.port) HTTP/1.1\r\n\r\n".withCString { write(client, $0, strlen($0)) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        #expect(read(client, &buffer, buffer.count) > 0)

        // The open line follows the proxy's answer closely.
        var open: [NetworkLog.Entry] = []
        for _ in 0..<100 where open.isEmpty {
            open = log.entries()
            usleep(20_000)
        }
        #expect(open.count == 1)
        #expect(open.first?.open == true)
        #expect(open.first?.bytesUp == nil)
        #expect(open.first?.id != nil)
        // A supervisor started after it: the connection ended unlogged.
        let stale = try #require(log.entries(liveSince: .distantFuture).first)
        #expect(stale.open == nil)
        #expect(stale.endNotLogged)

        // A tunnel ends when both sides have closed.
        _ = "ping".withCString { write(client, $0, strlen($0)) }
        shutdown(client, SHUT_WR)
        #expect(done.wait(timeout: .now() + 10) == .success)
        let ended = log.entries()
        #expect(ended.count == 1)
        #expect(ended.first?.open == nil)
        #expect(ended.first?.id == open.first?.id)
        #expect(ended.first?.bytesUp == 4)
        #expect(ended.first?.endNotLogged == false)
    }

    @Test func refusalsAnswerAndAreLogged() throws {
        let scratch = try Scratch()
        let log = NetworkLog(url: scratch.root.appendingPathComponent("network.jsonl"))
        let server = try LocalServer(reply: "pong")
        let proxy = ProxyServer(policy: try CompiledPolicy(BoxNetwork(mode: .allowlist, allow: ["example.com"]), packs: TestPacks.builtIn), log: log, allowPrivate: true)

        let denied = try exchange(proxy, "CONNECT 127.0.0.1:\(server.port) HTTP/1.1\r\n\r\n")
        #expect(denied.hasPrefix("HTTP/1.1 403 Forbidden\r\n"))
        #expect(server.requests.isEmpty)

        let malformed = try exchange(proxy, "BREW coffee\r\n\r\n")
        #expect(malformed.hasPrefix("HTTP/1.1 400 Bad Request\r\n"))

        let entries = log.entries()
        #expect(entries.map(\.decision) == [.denied, .denied])
        #expect(entries.first?.reason == "not in the allowlist")
        #expect(NetworkLog(url: log.url).entries(last: 1).count == 1)
    }

    @Test func privateAddressesAreRefusedEvenWhenAllowedByName() throws {
        let proxy = ProxyServer(policy: try CompiledPolicy(BoxNetwork(mode: .allowlist, allow: ["localhost:9"]), packs: TestPacks.builtIn), log: nil)
        let answer = try exchange(proxy, "CONNECT localhost:9 HTTP/1.1\r\n\r\n")
        #expect(answer.hasPrefix("HTTP/1.1 502 Bad Gateway\r\n"))
        #expect(answer.contains("no address the proxy may use"))
    }

    /// The box is not told which private addresses a name has, nor whether the name exists:
    /// the answer is the same for both, and the addresses are in the log only.
    @Test func aRefusedAddressIsNamedInTheLogOnly() throws {
        let scratch = try Scratch()
        let log = NetworkLog(url: scratch.root.appendingPathComponent("network.jsonl"))
        let rules = ["localhost:9", "no-such-name.invalid:9"]
        let proxy = ProxyServer(policy: try CompiledPolicy(BoxNetwork(mode: .allowlist, allow: rules), packs: TestPacks.builtIn), log: log)
        let local = try exchange(proxy, "CONNECT localhost:9 HTTP/1.1\r\n\r\n")
        let missing = try exchange(proxy, "CONNECT no-such-name.invalid:9 HTTP/1.1\r\n\r\n")
        #expect(local.hasPrefix("HTTP/1.1 502 Bad Gateway\r\n"))
        #expect(!local.contains("127.0.0.1") && !local.contains("::1") && !local.contains("non-public"), "\(local)")
        func body(_ answer: String) -> String {
            return answer.components(separatedBy: "\r\n\r\n").last ?? ""
        }
        #expect(body(missing).replacingOccurrences(of: "no-such-name.invalid", with: "localhost") == body(local))
        let entries = log.entries()
        #expect(entries.map(\.decision) == [.failed, .failed])
        #expect(entries.first?.reason?.contains("127.0.0.1") == true)
        #expect(entries.last?.reason?.hasPrefix("cannot resolve") == true)
    }

    /// An allowed connection that is still open: the client's end, and a signal for when the
    /// proxy is done with it.
    struct OpenTunnel {
        let client: Int32
        let done: DispatchSemaphore
    }

    /// Opens a tunnel through `proxy` and waits for its 200 answer.
    func openTunnel(_ proxy: ProxyServer, port: UInt16) throws -> OpenTunnel {
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let (client, served) = (pair[0], pair[1])
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            proxy.handle(client: served)
            close(served)
            done.signal()
        }
        _ = "CONNECT 127.0.0.1:\(port) HTTP/1.1\r\n\r\n".withCString { write(client, $0, strlen($0)) }
        let expected = "HTTP/1.0 200 Connection established\r\n\r\n"
        var answer: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 256)
        while answer.count < expected.utf8.count {
            let count = read(client, &buffer, expected.utf8.count - answer.count)
            try #require(count > 0)
            answer.append(contentsOf: buffer[0..<count])
        }
        #expect(String(decoding: answer, as: UTF8.self) == expected)
        return OpenTunnel(client: client, done: done)
    }

    /// Waits until `condition` holds, 5 s at most.
    func eventually(_ condition: () -> Bool) -> Bool {
        for _ in 0..<250 {
            if condition() {
                return true
            }
            usleep(20_000)
        }
        return condition()
    }

    /// Removing a rule ends the connections it allowed, at once, and the log says why; one
    /// that another rule still allows goes on.
    @Test func aRuleChangeClosesTheConnectionsItNoLongerAllows() throws {
        let scratch = try Scratch()
        let log = NetworkLog(url: scratch.root.appendingPathComponent("network.jsonl"))
        let kept = try HoldingServer()
        let removed = try HoldingServer()
        let both = BoxNetwork(mode: .allowlist, allow: ["127.0.0.1:\(kept.port)", "127.0.0.1:\(removed.port)"])
        let proxy = ProxyServer(policy: try CompiledPolicy(both, packs: TestPacks.builtIn), log: log, allowPrivate: true)
        let staying = try openTunnel(proxy, port: kept.port)
        let leaving = try openTunnel(proxy, port: removed.port)
        defer {
            close(staying.client)
            close(leaving.client)
        }
        _ = "data".withCString { write(leaving.client, $0, 4) }
        #expect(eventually { removed.received == 4 })
        #expect(proxy.openCount == 2)

        proxy.update(try CompiledPolicy(BoxNetwork(mode: .allowlist, allow: ["127.0.0.1:\(kept.port)"]), packs: TestPacks.builtIn))
        #expect(leaving.done.wait(timeout: .now() + 5) == .success)
        // The box sees its end of the tunnel closed.
        var buffer = [UInt8](repeating: 0, count: 16)
        #expect(buffer.withUnsafeMutableBytes { SocketRead.read(leaving.client, $0.baseAddress!, $0.count) } == 0)
        #expect(proxy.openCount == 1)
        let ended = try #require(log.entries().first { $0.port == Int(removed.port) })
        #expect(ended.open == nil)
        #expect(ended.bytesUp == 4)
        #expect(ended.reason == ProxyServer.ruleRemovedReason)
        #expect(try exchange(proxy, "CONNECT 127.0.0.1:\(removed.port) HTTP/1.1\r\n\r\n").hasPrefix("HTTP/1.1 403"))

        // The other still carries data.
        _ = "more".withCString { write(staying.client, $0, 4) }
        #expect(eventually { kept.received == 4 })
        #expect(log.entries().first { $0.port == Int(kept.port) }?.open == true)
        shutdown(staying.client, SHUT_RDWR)
        kept.closeConnections()
        #expect(staying.done.wait(timeout: .now() + 5) == .success)
        #expect(log.entries().first { $0.port == Int(kept.port) }?.reason == nil)
    }

    /// A tunnel whose two sides are both stuck in a write (neither end reads) is closed by a
    /// rule change all the same.
    @Test func aRuleChangeClosesATunnelStuckInWrites() throws {
        let server = try HoldingServer(reads: false, floods: true)
        let allowed = BoxNetwork(mode: .allowlist, allow: ["127.0.0.1:\(server.port)"])
        let proxy = ProxyServer(policy: try CompiledPolicy(allowed, packs: TestPacks.builtIn), log: nil, allowPrivate: true)
        let tunnel = try openTunnel(proxy, port: server.port)
        defer { close(tunnel.client) }
        // Fill the way up until this end's write would block; the way down fills by itself.
        _ = fcntl(tunnel.client, F_SETFL, fcntl(tunnel.client, F_GETFL) | O_NONBLOCK)
        let chunk = [UInt8](repeating: 7, count: 65536)
        var stalled = 0
        while stalled < 25 {
            if write(tunnel.client, chunk, chunk.count) > 0 {
                stalled = 0
            } else {
                stalled += 1
                usleep(20_000)
            }
        }
        proxy.update(try CompiledPolicy(BoxNetwork(mode: .allowlist), packs: TestPacks.builtIn))
        // At once.
        #expect(tunnel.done.wait(timeout: .now() + 2) == .success)
        #expect(proxy.openCount == 0)
    }

    /// The same when the server has finished sending and reads nothing: on macOS a shutdown of
    /// both ways at once does nothing on such a socket, and the copier stuck writing to it
    /// would stay.
    @Test func aRuleChangeClosesATunnelWhoseServerHalfClosed() throws {
        let server = try HoldingServer(reads: false, halfCloses: true)
        let allowed = BoxNetwork(mode: .allowlist, allow: ["127.0.0.1:\(server.port)"])
        let proxy = ProxyServer(policy: try CompiledPolicy(allowed, packs: TestPacks.builtIn), log: nil, allowPrivate: true)
        let tunnel = try openTunnel(proxy, port: server.port)
        defer { close(tunnel.client) }
        // The server's end of file has come through.
        var buffer = [UInt8](repeating: 0, count: 16)
        #expect(buffer.withUnsafeMutableBytes { SocketRead.read(tunnel.client, $0.baseAddress!, $0.count) } == 0)
        _ = fcntl(tunnel.client, F_SETFL, fcntl(tunnel.client, F_GETFL) | O_NONBLOCK)
        let chunk = [UInt8](repeating: 7, count: 65536)
        var stalled = 0
        while stalled < 25 {
            if write(tunnel.client, chunk, chunk.count) > 0 {
                stalled = 0
            } else {
                stalled += 1
                usleep(20_000)
            }
        }
        proxy.update(try CompiledPolicy(BoxNetwork(mode: .allowlist), packs: TestPacks.builtIn))
        // At once. With a cut that shut both ways in one call, which does nothing here, the
        // tunnel still ended about 4 s later (measured), so a longer wait would pass anyway.
        #expect(tunnel.done.wait(timeout: .now() + 2) == .success)
        #expect(proxy.openCount == 0)
    }

    /// The log shows what an open connection has carried before it ends, and keeps that when
    /// its end is never logged.
    @Test func anOpenConnectionShowsItsBytesSoFar() throws {
        let scratch = try Scratch()
        let log = NetworkLog(url: scratch.root.appendingPathComponent("network.jsonl"))
        let server = try HoldingServer()
        let allowed = BoxNetwork(mode: .allowlist, allow: ["127.0.0.1:\(server.port)"])
        let proxy = ProxyServer(policy: try CompiledPolicy(allowed, packs: TestPacks.builtIn), log: log, allowPrivate: true)
        let tunnel = try openTunnel(proxy, port: server.port)
        defer { close(tunnel.client) }
        // The open line follows the proxy's answer closely.
        #expect(eventually { log.entries().count == 1 })
        let follower = NetworkLogFollower(url: log.url)
        #expect(follower.start(last: 10).map(\.open) == [true])

        // Nothing carried: no line.
        proxy.logProgress()
        #expect(follower.read().isEmpty)
        _ = "12345".withCString { write(tunnel.client, $0, 5) }
        #expect(eventually { server.received == 5 })
        proxy.logProgress()
        // The same counts again: no second line.
        proxy.logProgress()
        let lines = follower.read()
        #expect(lines.count == 1)
        #expect(lines.first?.open == true && lines.first?.partial == true)

        let running = try #require(log.entries().first)
        #expect(log.entries().count == 1)
        #expect(running.open == true && running.partial == true)
        #expect(running.bytesUp == 5 && running.bytesDown == 0)
        #expect(!running.endNotLogged)
        // The supervisor is gone and the end was never logged: the bytes stay.
        let stale = try #require(log.entries(liveSince: .distantFuture).first)
        #expect(stale.open == nil && stale.bytesUp == 5)
        #expect(stale.endNotLogged)

        _ = "678".withCString { write(tunnel.client, $0, 3) }
        shutdown(tunnel.client, SHUT_WR)
        #expect(eventually { server.received == 8 })
        server.closeConnections()
        #expect(tunnel.done.wait(timeout: .now() + 5) == .success)
        let ended = try #require(log.entries().first)
        #expect(log.entries().count == 1)
        #expect(ended.open == nil && ended.partial == nil && ended.bytesUp == 8)
        #expect(!ended.endNotLogged)
    }

    /// A line with the bytes so far is never logged after the connection's end line: read on
    /// its own (a follower does) it would show an ended connection as open.
    @Test func noProgressLineFollowsAnEndLine() throws {
        let scratch = try Scratch()
        let log = NetworkLog(url: scratch.root.appendingPathComponent("network.jsonl"))
        let server = try LocalServer(reply: "pong")
        let allowed = BoxNetwork(mode: .allowlist, allow: ["127.0.0.1:\(server.port)"])
        let proxy = ProxyServer(policy: try CompiledPolicy(allowed, packs: TestPacks.builtIn), log: log, allowPrivate: true)
        let stop = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            while stop.wait(timeout: .now()) == .timedOut {
                proxy.logProgress()
            }
            stopped.signal()
        }
        for _ in 0..<300 {
            _ = try exchange(proxy, "CONNECT 127.0.0.1:\(server.port) HTTP/1.1\r\n\r\nsecret")
        }
        stop.signal()
        stopped.wait()
        var ended: Set<String> = []
        var late = 0
        var progress = 0
        for line in NetworkLogFollower(url: log.url).read() {
            guard let id = line.id else {
                continue
            }
            if line.open != true {
                ended.insert(id)
            } else if line.partial == true {
                progress += 1
                late += ended.contains(id) ? 1 : 0
            }
        }
        #expect(ended.count == 300)
        #expect(progress > 0)
        #expect(late == 0)
        #expect(log.entries().allSatisfy { $0.open == nil && $0.partial == nil })
    }

    /// What a plain request carries in its head (the target, the header lines) is counted.
    @Test func aPlainRequestsHeadIsCounted() throws {
        let scratch = try Scratch()
        let log = NetworkLog(url: scratch.root.appendingPathComponent("network.jsonl"))
        let server = try LocalServer(reply: "ok")
        let allowed = BoxNetwork(mode: .allowlist, allow: ["127.0.0.1:\(server.port)"])
        let proxy = ProxyServer(policy: try CompiledPolicy(allowed, packs: TestPacks.builtIn), log: log, allowPrivate: true)
        let payload = String(repeating: "d", count: 1500)
        #expect(try exchange(proxy, "GET http://127.0.0.1:\(server.port)/?d=\(payload) HTTP/1.1\r\nX-More: \(payload)\r\n\r\n") == "ok")
        let sent = try #require(server.requests.first)
        #expect(sent.utf8.count > 3000)
        #expect(log.entries().first?.bytesUp == sent.utf8.count)
    }

    /// The box closed its side and the server never answers that: the connection is given up
    /// after the limit, and its slot is free again.
    @Test func aSilentServerDoesNotHoldASlot() throws {
        let scratch = try Scratch()
        let log = NetworkLog(url: scratch.root.appendingPathComponent("network.jsonl"))
        let server = try HoldingServer()
        let allowed = BoxNetwork(mode: .allowlist, allow: ["127.0.0.1:\(server.port)"])
        let proxy = ProxyServer(policy: try CompiledPolicy(allowed, packs: TestPacks.builtIn), log: log, allowPrivate: true, maxConnections: 1,
                                silenceLimit: .seconds(2))
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let (client, served) = (pair[0], pair[1])
        let done = DispatchSemaphore(value: 0)
        proxy.accept(client: served) {
            close(served)
            done.signal()
        }
        _ = "CONNECT 127.0.0.1:\(server.port) HTTP/1.1\r\n\r\n".withCString { write(client, $0, strlen($0)) }
        var buffer = [UInt8](repeating: 0, count: 256)
        #expect(read(client, &buffer, buffer.count) > 0)
        // Still open on the box's side: no limit applies.
        #expect(done.wait(timeout: .now() + 3) == .timedOut)
        close(client)
        #expect(done.wait(timeout: .now() + 6) == .success)
        #expect(log.entries().first?.reason?.contains("nothing from the server") == true)
        #expect(eventually { (try? self.exchange(proxy, "CONNECT example.com:443 HTTP/1.1\r\n\r\n"))?.hasPrefix("HTTP/1.1 403") == true })
    }

    /// A box cannot make an allowed connection leave the log by causing refusals: they are in a
    /// file of their own.
    @Test func aFloodOfRefusalsKeepsAllowedConnectionsInTheLog() throws {
        let scratch = try Scratch()
        let log = NetworkLog(url: scratch.root.appendingPathComponent("network.jsonl"), maxBytes: 20_000)
        let server = try LocalServer(reply: "pong")
        let allowed = BoxNetwork(mode: .allowlist, allow: ["127.0.0.1:\(server.port)"])
        let proxy = ProxyServer(policy: try CompiledPolicy(allowed, packs: TestPacks.builtIn), log: log, allowPrivate: true)
        #expect(try exchange(proxy, "CONNECT 127.0.0.1:\(server.port) HTTP/1.1\r\n\r\nsecret").hasSuffix("pong"))
        let long = String(repeating: "a", count: 300)
        for index in 0..<200 {
            _ = try exchange(proxy, "CONNECT \(long)\(index).example:443 HTTP/1.1\r\n\r\n")
        }
        // The refusals moved their file to .1 more than once.
        #expect(try FileSystem.status(log.url.path + ".1").st_size > 10_000)
        #expect(try FileSystem.status(log.url.path).st_size <= 20_000)
        let entries = log.entries()
        // The first to arrive, and the list is in that order to the millisecond.
        let kept = try #require(entries.first)
        #expect(kept.decision == .allowed && kept.port == Int(server.port) && kept.bytesUp == 6)
        #expect(entries.count < 201)
        #expect(log.entries(last: 3).allSatisfy { $0.decision == .denied })
        #expect(log.entries(includeAllowed: false).allSatisfy { $0.decision == .denied })
        #expect(!FileManager.default.fileExists(atPath: log.allowedURL.path + ".1"))
    }

    /// "public" matches no local name, even where the address check is off (as here).
    @Test func thePublicRuleRefusesNamesThatAreNotPublic() throws {
        let scratch = try Scratch()
        let log = NetworkLog(url: scratch.root.appendingPathComponent("network.jsonl"))
        let proxy = ProxyServer(policy: try CompiledPolicy(BoxNetwork(mode: .allowlist, allow: ["public"]), packs: TestPacks.builtIn), log: log, allowPrivate: true)
        let answer = try exchange(proxy, "CONNECT localhost:443 HTTP/1.1\r\n\r\n")
        #expect(answer.hasPrefix("HTTP/1.1 403 Forbidden\r\n"))
        #expect(log.entries().first?.reason == "not in the allowlist")
    }

    @Test func connectionsBeyondTheCapAreRefusedAtOnce() throws {
        let scratch = try Scratch()
        let log = NetworkLog(url: scratch.root.appendingPathComponent("network.jsonl"))
        let proxy = ProxyServer(policy: try CompiledPolicy(BoxNetwork(mode: .off), packs: TestPacks.builtIn), log: log, maxConnections: 1)
        var first: [Int32] = [-1, -1]
        var second: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &first) == 0)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &second) == 0)
        let firstDone = DispatchSemaphore(value: 0)
        // The first holds the only slot: it sends nothing yet.
        let (firstServer, secondServer) = (first[1], second[1])
        proxy.accept(client: firstServer) {
            close(firstServer)
            firstDone.signal()
        }
        proxy.accept(client: secondServer) {
            close(secondServer)
        }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(second[0], &buffer, buffer.count)
        #expect(String(decoding: buffer[0..<max(count, 0)], as: UTF8.self).hasPrefix("HTTP/1.1 503 "))
        close(second[0])
        // It leaves a line.
        #expect(log.entries().map(\.reason) == ["more than 1 connections at once"])
        // Once the first ends, its slot is free again.
        _ = "CONNECT example.com:443 HTTP/1.1\r\n\r\n".withCString { write(first[0], $0, strlen($0)) }
        #expect(firstDone.wait(timeout: .now() + 10) == .success)
        close(first[0])
        #expect(try exchange(proxy, "CONNECT example.com:443 HTTP/1.1\r\n\r\n").hasPrefix("HTTP/1.1 403"))
    }

    @Test func logFieldsAreClipped() throws {
        let scratch = try Scratch()
        let log = NetworkLog(url: scratch.root.appendingPathComponent("network.jsonl"))
        let proxy = ProxyServer(policy: try CompiledPolicy(BoxNetwork(mode: .off), packs: TestPacks.builtIn), log: log)
        let long = String(repeating: "a", count: 10_000)
        _ = try exchange(proxy, "CONNECT \(long).com:443 HTTP/1.1\r\n\r\n")
        let entry = try #require(log.entries().first)
        #expect(entry.host.count <= NetworkLog.maxFieldLength + 3)
        let size = try FileManager.default.attributesOfItem(atPath: log.url.path)[.size] as? Int ?? 0
        #expect(size < 2048)
    }

    @Test func theLogRollsOverAtItsSizeCap() throws {
        let scratch = try Scratch()
        let log = NetworkLog(url: scratch.root.appendingPathComponent("network.jsonl"), maxBytes: 1000)
        for index in 0..<30 {
            log.append(NetworkLog.Entry(time: Date(), method: "CONNECT", host: "host\(index).example", port: 443, decision: .denied))
        }
        let current = try FileSystem.status(log.url.path).st_size
        let previous = try FileSystem.status(log.url.path + ".1").st_size
        #expect(current <= 1000)
        #expect(previous <= 1000)
        #expect(previous > 500)
        #expect(log.entries().last?.host == "host29.example")
    }

    @Test func policyUpdatesApplyToNewConnections() throws {
        let server = try LocalServer(reply: "pong")
        let proxy = ProxyServer(policy: try CompiledPolicy(BoxNetwork(mode: .off), packs: TestPacks.builtIn), log: nil, allowPrivate: true)
        #expect(try exchange(proxy, "CONNECT 127.0.0.1:\(server.port) HTTP/1.1\r\n\r\n").hasPrefix("HTTP/1.1 403"))
        proxy.update(try CompiledPolicy(BoxNetwork(mode: .allowlist, allow: ["127.0.0.1:\(server.port)"]), packs: TestPacks.builtIn))
        // The server answers after the first bytes arrive, so the tunnel carries a payload.
        #expect(try exchange(proxy, "CONNECT 127.0.0.1:\(server.port) HTTP/1.1\r\n\r\nping").hasPrefix("HTTP/1.0 200"))
    }
}

@Suite struct DeadEndLinkTests {
    func arpRequest(target: [UInt8]) -> [UInt8] {
        let mac: [UInt8] = [0xda, 0x51, 0x72, 0x00, 0x00, 0x01]
        let ip: [UInt8] = [10, 254, 0, 2]
        return [0xff, 0xff, 0xff, 0xff, 0xff, 0xff] + mac + [0x08, 0x06, 0x00, 0x01, 0x08, 0x00, 6, 4, 0x00, 0x01] + mac + ip + [0, 0, 0, 0, 0, 0] + target
    }

    @Test func onlyARPForTheRouterIsAnswered() {
        let reply = DeadEndLink.arpReply(to: arpRequest(target: [10, 254, 0, 1]))
        #expect(reply?.count == 42)
        #expect(Array(reply?[0..<6] ?? []) == [0xda, 0x51, 0x72, 0x00, 0x00, 0x01]) // back to the asker
        #expect(Array(reply?[20..<22] ?? []) == [0x00, 0x02])                        // a reply
        #expect(Array(reply?[28..<32] ?? []) == [10, 254, 0, 1])                     // from the router
        #expect(Array(reply?[38..<42] ?? []) == [10, 254, 0, 2])                     // to the asker's IP

        #expect(DeadEndLink.arpReply(to: arpRequest(target: [10, 254, 0, 7])) == nil)
        var notARP = arpRequest(target: [10, 254, 0, 1])
        notARP[13] = 0x00 // IPv4 ethertype
        #expect(DeadEndLink.arpReply(to: notARP) == nil)
        #expect(DeadEndLink.arpReply(to: [1, 2, 3]) == nil)
    }

    @Test func theLinkAnswersOverItsSocket() throws {
        let link = try DeadEndLink()
        let guest = link.guestHandle.fileDescriptor
        let request = arpRequest(target: [10, 254, 0, 1])
        _ = request.withUnsafeBytes { write(guest, $0.baseAddress, $0.count) }
        var reply = [UInt8](repeating: 0, count: 128)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(guest, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        #expect(read(guest, &reply, reply.count) == 42)
        let other = [UInt8](repeating: 0, count: 60)
        _ = other.withUnsafeBytes { write(guest, $0.baseAddress, $0.count) }
        // Until the frame is counted, not a fixed wait: 0.2 s was too short with every suite
        // running at once.
        for _ in 0..<250 where link.counts.dropped == 0 {
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(link.counts.answered == 1)
        #expect(link.counts.dropped == 1)
    }
}

@Suite struct BoxNetworkTests {
    @Test func newBoxesDefaultToAnEmptyAllowlistAndOldOnesToNAT() throws {
        let fixture = try BoxScratch()
        let box = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images)
        #expect(box.record.effectiveNetwork == BoxNetwork(mode: .allowlist))
        var legacy = box.record
        legacy.network = nil
        #expect(legacy.effectiveNetwork.mode == .open)
        #expect(throws: AgentVMError.self) {
            _ = try fixture.boxes.create(name: "b2", from: fixture.image, imageStore: fixture.images, network: BoxNetwork(mode: .allowlist, allow: ["pack:nope"]))
        }
        #expect(!FileSystem.exists(fixture.boxes.boxesDirectory.appendingPathComponent("b2").path))
    }

    @Test func rulesChangeAnyTimeTheModeOnlyWhileStopped() throws {
        let fixture = try BoxScratch()
        let box = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images)
        let lock = try #require(try FolderLock.tryAcquire(box.lockPath))
        let updated = try fixture.boxes.updateNetwork(named: "b1", to: BoxNetwork(mode: .allowlist, allow: ["pack:github"]))
        #expect(updated.record.network?.allow == ["pack:github"])
        #expect(throws: AgentVMError.boxRunning("b1")) {
            try fixture.boxes.updateNetwork(named: "b1", to: BoxNetwork(mode: .open))
        }
        lock.release()
        try fixture.boxes.updateNetwork(named: "b1", to: BoxNetwork(mode: .open))
        #expect(try fixture.boxes.box(named: "b1").record.effectiveNetwork.mode == .open)
    }

    @Test func guestSetupCommands() {
        let proxied = GuestNetworkSetup.command(for: .allowlist)
        #expect(proxied.contains("-setmanual \"$service\" 10.254.0.2 255.255.255.0 10.254.0.1"))
        #expect(proxied.contains("-setsecurewebproxy \"$service\" 127.0.0.1 3128 off"))
        #expect(GuestNetworkSetup.command(for: .off) == proxied)
        let open = GuestNetworkSetup.command(for: .open)
        #expect(open.contains("-setdhcp"))
        #expect(open.contains("ipconfig waitall"))
        #expect(!open.contains("-setwebproxy \""))
        #expect(GuestNetworkSetup.proxyEnvironment["HTTPS_PROXY"] == "http://127.0.0.1:3128")
        // ssh through the proxy: the system config file, written in proxied modes, gone in open.
        #expect(proxied.contains("> /etc/ssh/ssh_config.d/agent-vm.conf || exit 1"))
        #expect(proxied.contains("ProxyCommand /usr/bin/nc -X connect -x 127.0.0.1:3128 %h %p"))
        #expect(open.contains("/bin/rm -f /etc/ssh/ssh_config.d/agent-vm.conf || exit 1"))
        // The lines go in single quotes.
        #expect(GuestNetworkSetup.sshConfigLines.allSatisfy { !$0.contains("'") })
        // Both commands are valid sh.
        for command in [proxied, open] {
            let check = Process()
            check.executableURL = URL(fileURLWithPath: "/bin/sh")
            check.arguments = ["-n", "-c", command]
            #expect((try? check.run()) != nil)
            check.waitUntilExit()
            #expect(check.terminationStatus == 0, "\(command)")
        }
    }
}

@Suite struct NetworkLogFollowerTests {
    func entry(_ host: String, _ decision: NetworkLog.Decision = .allowed) -> NetworkLog.Entry {
        return NetworkLog.Entry(time: Date(timeIntervalSince1970: 1_790_000_000), method: "CONNECT", host: host, port: 443, decision: decision)
    }

    func append(_ text: String, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    @Test func newEntriesArriveOnceEach() throws {
        let scratch = try Scratch()
        let log = NetworkLog(url: scratch.root.appendingPathComponent("network.jsonl"))
        let follower = NetworkLogFollower(url: log.url)
        // No log yet: nothing, and no error.
        #expect(follower.read().isEmpty)
        log.append(entry("a.example"))
        log.append(entry("b.example", .denied))
        // Refusals first: the two kinds are in two files.
        #expect(follower.read().map(\.host) == ["b.example", "a.example"])
        #expect(follower.read().isEmpty)
        log.append(entry("c.example"))
        #expect(follower.read().map(\.host) == ["c.example"])
    }

    /// A line still being written waits for its end; an unreadable one is skipped.
    @Test func partAndBadLinesAreHandled() throws {
        let scratch = try Scratch()
        let url = scratch.root.appendingPathComponent("network.jsonl")
        let log = NetworkLog(url: url)
        log.append(entry("a.example"))
        let follower = NetworkLogFollower(url: url)
        #expect(follower.read().count == 1)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let line = String(decoding: try encoder.encode(entry("b.example")), as: UTF8.self)
        let middle = line.index(line.startIndex, offsetBy: line.count / 2)
        try append("not json\n" + String(line[..<middle]), to: url)
        #expect(follower.read().isEmpty)
        try append(String(line[middle...]) + "\n", to: url)
        #expect(follower.read().map(\.host) == ["b.example"])
    }

    /// start() gives the end of the log, and read() then goes on after it, including a line
    /// that was still being written when start() read.
    @Test func startGivesTheEndThenReadGoesOn() throws {
        let scratch = try Scratch()
        let url = scratch.root.appendingPathComponent("network.jsonl")
        let log = NetworkLog(url: url)
        for index in 0..<5 {
            log.append(entry("h\(index).example"))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let line = String(decoding: try encoder.encode(entry("late.example")), as: UTF8.self)
        let middle = line.index(line.startIndex, offsetBy: line.count / 2)
        try append(String(line[..<middle]), to: url)
        let follower = NetworkLogFollower(url: url)
        #expect(follower.start(last: 2).map(\.host) == ["h3.example", "h4.example"])
        #expect(follower.read().isEmpty)
        try append(String(line[middle...]) + "\n", to: url)
        log.append(entry("h5.example"))
        #expect(follower.read().map(\.host) == ["late.example", "h5.example"])
    }

    /// --follow --last 0: nothing from before, and read() goes on after the last line.
    @Test func startWithNoneStillGoesOnFromTheEnd() throws {
        let scratch = try Scratch()
        let log = NetworkLog(url: scratch.root.appendingPathComponent("network.jsonl"))
        for index in 0..<5 {
            log.append(entry("h\(index).example"))
        }
        let follower = NetworkLogFollower(url: log.url)
        #expect(follower.start(last: 0).isEmpty)
        #expect(follower.read().isEmpty)
        log.append(entry("h5.example"))
        #expect(follower.read().map(\.host) == ["h5.example"])
    }

    /// Both files are followed: the start is one list by time, and each read gives the new
    /// lines of both; a follower of refusals leaves the other file alone.
    @Test func bothFilesAreFollowed() throws {
        let scratch = try Scratch()
        let log = NetworkLog(url: scratch.root.appendingPathComponent("network.jsonl"))
        func at(_ host: String, _ decision: NetworkLog.Decision, _ seconds: Double) -> NetworkLog.Entry {
            var line = entry(host, decision)
            line.time += seconds
            return line
        }
        log.append(at("r1.example", .denied, 1))
        log.append(at("a2.example", .allowed, 2))
        log.append(at("r3.example", .denied, 3))
        log.append(at("a4.example", .allowed, 4))
        let follower = NetworkLogFollower(url: log.url)
        let refusals = NetworkLogFollower(url: log.url, includeAllowed: false)
        #expect(follower.start(last: 3).map(\.host) == ["a2.example", "r3.example", "a4.example"])
        #expect(refusals.start(last: 3).map(\.host) == ["r1.example", "r3.example"])
        #expect(follower.read().isEmpty)
        log.append(at("a5.example", .allowed, 5))
        log.append(at("r6.example", .failed, 6))
        #expect(Set(follower.read().map(\.host)) == ["a5.example", "r6.example"])
        #expect(refusals.read().map(\.host) == ["r6.example"])
        #expect(follower.read().isEmpty)
    }

    /// The proxy moves a full log to .1 and starts a new one: the follower reads the end of the
    /// old file, then the new one from its start.
    @Test func aRotatedLogIsFollowed() throws {
        let scratch = try Scratch()
        let url = scratch.root.appendingPathComponent("network.jsonl")
        let log = NetworkLog(url: url, maxBytes: 400)
        let follower = NetworkLogFollower(url: url)
        log.append(entry("a.example"))
        #expect(follower.read().map(\.host) == ["a.example"])
        var hosts: [String] = []
        for index in 0..<8 {
            log.append(entry("h\(index).example"))
            if index == 2 {
                hosts += follower.read().map(\.host)
            }
        }
        #expect(FileManager.default.fileExists(atPath: log.allowedURL.path + ".1"))
        hosts += follower.read().map(\.host)
        // Rotated more than once here, and a file moved away twice is gone: what the follower
        // reads is in order, each once, and ends with the last entry.
        #expect(hosts.last == "h7.example")
        #expect(hosts == hosts.sorted { Int($0.dropFirst().prefix(while: \.isNumber))! < Int($1.dropFirst().prefix(while: \.isNumber))! })
        #expect(Set(hosts).count == hosts.count)
    }
}

/// `NetworkLog.entries` reads from the end of the log and gives each connection once.
@Suite struct NetworkLogTailTests {
    func entry(_ host: String, _ decision: NetworkLog.Decision = .denied, id: String? = nil, open: Bool? = nil,
               bytes: Int? = nil, time: TimeInterval = 1_790_000_000) -> NetworkLog.Entry {
        var entry = NetworkLog.Entry(time: Date(timeIntervalSince1970: time), method: "CONNECT", host: host, port: 443, decision: decision)
        entry.id = id
        entry.open = open
        entry.bytesUp = bytes
        entry.bytesDown = bytes
        return entry
    }

    /// Many chunks' worth: any count from the end matches reading everything.
    @Test func theLastEntriesAcrossChunks() throws {
        let scratch = try Scratch()
        let log = NetworkLog(url: scratch.root.appendingPathComponent("network.jsonl"))
        let total = 3000
        for index in 0..<total {
            log.append(entry("host\(index).example"))
        }
        let size = try FileSystem.status(log.url.path).st_size
        #expect(size > 3 * off_t(NetworkLog.Tail.chunkSize))
        let all = log.entries().map(\.host)
        #expect(all == (0..<total).map { "host\($0).example" })
        for count in [0, 1, 7, 450, 451, 1999, total, total + 5] {
            #expect(log.entries(last: count).map(\.host) == Array(all.suffix(count)), "last \(count)")
        }
        #expect(log.entries(last: 3) { $0.host.hasSuffix("0.example") }.map(\.host) == ["host2970.example", "host2980.example", "host2990.example"])
    }

    /// An allowed connection's two lines are one entry, placed where it opened; an end line
    /// whose open line moved to .1 counts as older than the file; old logs have no ids.
    @Test func openAndEndLinesArePaired() throws {
        let scratch = try Scratch()
        let log = NetworkLog(url: scratch.root.appendingPathComponent("network.jsonl"))
        log.append(entry("legacy.example", .allowed, bytes: 5, time: 1_790_000_000))
        log.append(entry("long.example", .allowed, id: "a", open: true, time: 1_790_000_001))
        log.append(entry("short.example", .allowed, id: "b", open: true, time: 1_790_000_002))
        log.append(entry("refused.example", time: 1_790_000_003))
        log.append(entry("rotated.example", .allowed, id: "r", bytes: 9, time: 1_789_999_000))
        log.append(entry("short.example", .allowed, id: "b", bytes: 3, time: 1_790_000_002))
        log.append(entry("still.example", .allowed, id: "c", open: true, time: 1_790_000_004))
        log.append(entry("long.example", .allowed, id: "a", bytes: 1000, time: 1_790_000_001))

        let all = log.entries()
        #expect(all.map(\.host) == ["rotated.example", "legacy.example", "long.example", "short.example", "refused.example", "still.example"])
        #expect(all.map(\.bytesUp) == [9, 5, 1000, 3, nil, nil])
        #expect(all.map(\.open) == [nil, nil, nil, nil, nil, true])
        #expect(log.entries(last: 2).map(\.host) == ["refused.example", "still.example"])
        #expect(log.entries(last: 4).map(\.host) == ["long.example", "short.example", "refused.example", "still.example"])
        #expect(log.entries(last: 6).first?.host == "rotated.example")
        #expect(log.entries { $0.decision != .allowed }.map(\.host) == ["refused.example"])
        // Opened before the running supervisor started: it ended unlogged.
        let later = log.entries(last: 1, liveSince: Date(timeIntervalSince1970: 1_790_000_005))
        #expect(later.first?.open == nil)
        #expect(later.first?.endNotLogged == true)
        #expect(log.entries(last: 1, liveSince: Date(timeIntervalSince1970: 1_790_000_004)).first?.open == true)
    }

    /// Allowed connections and refusals are in two files, and come out as one list in order
    /// of time.
    @Test func theTwoFilesAreReadAsOneListByTime() throws {
        let scratch = try Scratch()
        let log = NetworkLog(url: scratch.root.appendingPathComponent("network.jsonl"))
        log.append(entry("r1.example", time: 1_790_000_001))
        log.append(entry("a2.example", .allowed, id: "a", open: true, time: 1_790_000_002))
        log.append(entry("r3.example", .failed, time: 1_790_000_003))
        log.append(entry("a4.example", .allowed, id: "b", open: true, time: 1_790_000_004))
        log.append(entry("r5.example", time: 1_790_000_005))
        log.append(entry("a2.example", .allowed, id: "a", bytes: 7, time: 1_790_000_002))
        let refusedFile = String(decoding: try Data(contentsOf: log.url), as: UTF8.self)
        let allowedFile = String(decoding: try Data(contentsOf: log.allowedURL), as: UTF8.self)
        #expect(log.allowedURL.lastPathComponent == "network-allowed.jsonl")
        #expect(refusedFile.components(separatedBy: "\n").count == 4 && !refusedFile.contains("\"allowed\""))
        #expect(allowedFile.components(separatedBy: "\n").count == 4 && !allowedFile.contains("\"denied\"") && !allowedFile.contains("\"failed\""))

        #expect(log.entries().map(\.host) == ["r1.example", "a2.example", "r3.example", "a4.example", "r5.example"])
        #expect(log.entries().map(\.bytesUp) == [nil, 7, nil, nil, nil])
        #expect(log.entries(last: 2).map(\.host) == ["a4.example", "r5.example"])
        #expect(log.entries(last: 4).map(\.host) == ["a2.example", "r3.example", "a4.example", "r5.example"])
        #expect(log.entries(includeAllowed: false).map(\.host) == ["r1.example", "r3.example", "r5.example"])
        #expect(log.entries { $0.decision == .allowed }.map(\.host) == ["a2.example", "a4.example"])
    }

    /// A file that moved to .1 is read on into, and a connection with lines in both is one
    /// entry, where it opened.
    @Test func thePreviousFileIsReadToo() throws {
        let scratch = try Scratch()
        let log = NetworkLog(url: scratch.root.appendingPathComponent("network.jsonl"), maxBytes: 2000)
        log.append(entry("long.example", .allowed, id: "a", open: true, time: 1_790_000_000))
        var index = 0
        while !FileManager.default.fileExists(atPath: log.allowedURL.path + ".1") {
            index += 1
            log.append(entry("h\(index).example", .allowed, bytes: 1, time: 1_790_000_000 + Double(index)))
        }
        log.append(entry("long.example", .allowed, id: "a", bytes: 500, time: 1_790_000_000))
        let all = log.entries()
        #expect(all.map(\.host) == ["long.example"] + (1...index).map { "h\($0).example" })
        #expect(all.first?.bytesUp == 500 && all.first?.open == nil)
        for count in [1, 2, index, index + 1, index + 5] {
            #expect(log.entries(last: count).map(\.host) == Array(all.map(\.host).suffix(count)), "last \(count)")
        }
        // Between the move and the next line there is only the .1.
        try FileManager.default.removeItem(at: log.allowedURL)
        #expect(log.entries().first?.host == "long.example")
        #expect(NetworkLogFollower(url: log.url).start(last: 3).count == 3)
    }

    /// The lines logged while a connection runs stand for it until its end is logged, the
    /// newest one first; they never make a second entry.
    @Test func progressLinesAreOneConnection() throws {
        let scratch = try Scratch()
        let log = NetworkLog(url: scratch.root.appendingPathComponent("network.jsonl"))
        func progress(_ id: String, _ bytes: Int) -> NetworkLog.Entry {
            var line = entry("\(id).example", .allowed, id: id, open: true, bytes: bytes)
            line.partial = true
            return line
        }
        log.append(entry("a.example", .allowed, id: "a", open: true))
        log.append(entry("b.example", .allowed, id: "b", open: true))
        log.append(progress("a", 10))
        log.append(progress("b", 20))
        log.append(progress("a", 30))
        log.append(entry("b.example", .allowed, id: "b", bytes: 25))
        // Never written so, and still an ended connection.
        log.append(progress("b", 22))
        // Its open line is in a file that is gone.
        log.append(progress("c", 40))

        let all = log.entries()
        #expect(all.map(\.host) == ["c.example", "a.example", "b.example"])
        #expect(all.map(\.bytesUp) == [40, 30, 25])
        #expect(all.map(\.open) == [true, true, nil])
        #expect(all.map(\.partial) == [true, true, nil])
        #expect(all.map(\.endNotLogged) == [false, false, false])
        #expect(log.entries(last: 1).map(\.host) == ["b.example"])
        let stopped = log.entries(liveSince: .distantFuture)
        #expect(stopped.map(\.open) == [nil, nil, nil])
        #expect(stopped.map(\.endNotLogged) == [true, true, false])
        #expect(stopped.map(\.bytesUp) == [40, 30, 25])
    }

    /// A last line still being written, a bad line and an overlong one are skipped; the
    /// lines around them are kept.
    @Test func unreadableLinesAreSkipped() throws {
        let scratch = try Scratch()
        let url = scratch.root.appendingPathComponent("network.jsonl")
        let log = NetworkLog(url: url)
        log.append(entry("a.example"))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("not json\n" + String(repeating: "x", count: 3 * NetworkLog.Tail.chunkSize) + "\n").utf8))
        try handle.close()
        log.append(entry("b.example"))
        let append = try FileHandle(forWritingTo: url)
        try append.seekToEnd()
        try append.write(contentsOf: Data("{\"host\":\"half".utf8))
        try append.close()
        #expect(log.entries().map(\.host) == ["a.example", "b.example"])
        #expect(log.entries(last: 1).map(\.host) == ["b.example"])
        #expect(log.entries(last: 5).map(\.host) == ["a.example", "b.example"])
    }
}

@Suite struct NAT64Tests {
    func v6(_ text: String) -> [UInt8] {
        var address = in6_addr()
        #expect(inet_pton(AF_INET6, text, &address) == 1)
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    /// RFC 6052's own examples: 192.0.2.33 after a prefix of each allowed length.
    @Test func theIPv4AddressIsFoundAfterEachPrefixLength() {
        let examples: [(String, Int, String)] = [
            ("2001:db8::", 32, "2001:db8:c000:221::"),
            ("2001:db8:100::", 40, "2001:db8:1c0:2:21::"),
            ("2001:db8:122::", 48, "2001:db8:122:c000:2:2100::"),
            ("2001:db8:122:300::", 56, "2001:db8:122:3c0:0:221::"),
            ("2001:db8:122:344::", 64, "2001:db8:122:344:c0:2:2100:0"),
            ("2001:db8:122:344::", 96, "2001:db8:122:344::c000:221"),
        ]
        for (prefix, length, address) in examples {
            let nat64 = NAT64.Prefix(bytes: v6(prefix), length: length)
            #expect(nat64.embeddedIPv4(v6(address)) == [192, 0, 2, 33], "/\(length)")
        }
        // Not under the prefix, or a nonzero byte 8 below /96.
        #expect(NAT64.Prefix(bytes: v6("2001:db8::"), length: 32).embeddedIPv4(v6("2001:db9:c000:221::")) == nil)
        #expect(NAT64.Prefix(bytes: v6("2001:db8::"), length: 32).embeddedIPv4(v6("2001:db8:c000:221:100::")) == nil)
        #expect(NAT64.Prefix.wellKnown.embeddedIPv4(v6("64:ff9b::a00:1")) == [10, 0, 0, 1])
    }

    /// The network's prefix, from its answers for ipv4only.arpa (measured on a T-Mobile hotspot).
    @Test func theNetworksPrefixIsDiscovered() {
        let answers = [v6("2607:7700:0:33:0:1:c000:aa"), v6("2607:7700:0:33:0:1:c000:ab")]
        #expect(NAT64.prefixes(fromDiscovery: answers) == [NAT64.Prefix(bytes: v6("2607:7700:0:33:0:1::"), length: 96)])
        #expect(NAT64.prefixes(fromDiscovery: [v6("2001:db8::1")]).isEmpty)
        #expect(NAT64.prefixes(fromDiscovery: []).isEmpty)
    }

    /// A NAT64 address is judged as the IPv4 address it stands for: a public-looking prefix
    /// must not carry a private address, or one on this Mac's network, past the proxy.
    @Test func translatedAddressesAreJudgedAsIPv4() throws {
        let prefix = NAT64.Prefix(bytes: v6("2607:7700:0:33:0:1::"), length: 96)
        do {
            _ = try AddressCheck.resolve("2607:7700:0:33:0:1:a00:1", port: 443, localNetworks: [], nat64: [prefix])
            Issue.record("a NAT64 address for 10.0.0.1 was allowed")
        } catch let refusal as ProxyRefusal {
            #expect(refusal.message.contains("NAT64 for 10.0.0.1"), "\(refusal.message)")
        }
        #expect(throws: ProxyRefusal.self) { _ = try AddressCheck.resolve("2607:7700:0:33:0:1:7f00:1", port: 443, localNetworks: [], nat64: [prefix]) }
        #expect(throws: ProxyRefusal.self) { _ = try AddressCheck.resolve("64:ff9b::c0a8:105", port: 443, localNetworks: [], nat64: [.wellKnown]) }
        let lan = AddressCheck.LocalNetwork(address: [203, 0, 113, 7], mask: [255, 255, 255, 0])
        #expect(throws: ProxyRefusal.self) { _ = try AddressCheck.resolve("2607:7700:0:33:0:1:cb00:7109", port: 443, localNetworks: [lan], nat64: [prefix]) }
        // A public IPv4 address behind the prefix is fine, and the log gets the plain address.
        let allowed = try AddressCheck.resolve("2607:7700:0:33:0:1:cb00:7109", port: 443, localNetworks: [], nat64: [prefix])
        #expect(allowed.map(\.text) == ["2607:7700:0:33:0:1:cb00:7109"])
    }

    /// A prefix from a hostile ipv4only.arpa answer can only refuse more: outside the space
    /// reserved for translation, the address must pass the IPv6 checks too.
    @Test func aHostilePrefixOpensNothing() throws {
        let ula = NAT64.prefixes(fromDiscovery: [v6("fd00::c000:aa")])
        #expect(throws: ProxyRefusal.self) { _ = try AddressCheck.resolve("fd00::808:808", port: 443, localNetworks: [], nat64: ula) }
        let subnet = AddressCheck.LocalNetwork(address: v6("2a01:4f8:1:2::10"), mask: v6("ffff:ffff:ffff:ffff::"))
        let own = NAT64.prefixes(fromDiscovery: [v6("2a01:4f8:1:2::c000:aa")])
        #expect(throws: ProxyRefusal.self) { _ = try AddressCheck.resolve("2a01:4f8:1:2::808:808", port: 443, localNetworks: [subnet], nat64: own) }
        // The reserved space (64:ff9b::/96, and 64:ff9b:1::/48 for local use) is judged as IPv4 alone.
        #expect(try AddressCheck.resolve("64:ff9b::808:808", port: 443, localNetworks: [], nat64: [.wellKnown]).count == 1)
        let localUse = NAT64.prefixes(fromDiscovery: [v6("64:ff9b:1::c000:aa")])
        #expect(try AddressCheck.resolve("64:ff9b:1::808:808", port: 443, localNetworks: [], nat64: localUse).count == 1)
    }

    /// An IP address given as the host is used as given, never translated.
    @Test func addressesStayAsGiven() throws {
        #expect(try AddressCheck.resolve("203.0.113.9", port: 443, localNetworks: [], nat64: []).map(\.text) == ["203.0.113.9"])
        #expect(try AddressCheck.resolve("[2001:4860::1]", port: 443, localNetworks: [], nat64: []).map(\.text) == ["2001:4860::1"])
    }
}
