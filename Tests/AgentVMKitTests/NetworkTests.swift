// Tests/AgentVMKitTests/NetworkTests.swift
//
// Network policy, address checks, the proxy (end to end against a local server, with private
// upstreams allowed only in these tests) and the dead-end link's ARP answer.

import Darwin
import Foundation
import Testing
@testable import AgentVMKit

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
        let policy = try CompiledPolicy(BoxNetwork(mode: .allowlist, allow: ["pack:npm", "example.com"]))
        #expect(policy.allows(host: "registry.npmjs.org", port: 443, tunnel: true) == "pack:npm")
        #expect(policy.allows(host: "example.com", port: 443, tunnel: true) == "example.com")
        #expect(policy.allows(host: "example.com", port: 80, tunnel: false) == "example.com")
        #expect(policy.allows(host: "pypi.org", port: 443, tunnel: true) == nil)

        let off = try CompiledPolicy(BoxNetwork(mode: .off, allow: ["example.com"]))
        #expect(off.allows(host: "example.com", port: 443, tunnel: true) == nil)

        #expect(throws: AgentVMError.self) { _ = try CompiledPolicy(BoxNetwork(mode: .allowlist, allow: ["pack:nope"])) }
        #expect(throws: AgentVMError.self) { _ = try CompiledPolicy(BoxNetwork(mode: .allowlist, allow: ["not a host"])) }
        // Every pack's hosts are valid rules.
        for (name, hosts) in NetworkPacks.all {
            for host in hosts {
                #expect(AllowRule.parse(host) != nil, "pack \(name): \(host)")
            }
        }
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
        defer { close(pair[0]); close(pair[1]) }
        let writer = pair[0]
        // One byte every 200 ms: each read succeeds, but the whole head never comes in time.
        Thread.detachNewThread {
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
            let count = read(client, &buffer, buffer.count)
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
        let policy = try CompiledPolicy(BoxNetwork(mode: .allowlist, allow: ["127.0.0.1:\(server.port)"]))
        let proxy = ProxyServer(policy: policy, log: log, allowPrivate: true)

        let tunneled = try exchange(proxy, "CONNECT 127.0.0.1:\(server.port) HTTP/1.1\r\n\r\nping")
        #expect(tunneled == "HTTP/1.1 200 Connection established\r\n\r\npong")
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

    @Test func refusalsAnswerAndAreLogged() throws {
        let scratch = try Scratch()
        let log = NetworkLog(url: scratch.root.appendingPathComponent("network.jsonl"))
        let server = try LocalServer(reply: "pong")
        let proxy = ProxyServer(policy: try CompiledPolicy(BoxNetwork(mode: .allowlist, allow: ["example.com"])), log: log, allowPrivate: true)

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
        let proxy = ProxyServer(policy: try CompiledPolicy(BoxNetwork(mode: .allowlist, allow: ["localhost:9"])), log: nil)
        let answer = try exchange(proxy, "CONNECT localhost:9 HTTP/1.1\r\n\r\n")
        #expect(answer.hasPrefix("HTTP/1.1 502 Bad Gateway\r\n"))
        #expect(answer.contains("non-public"))
    }

    @Test func connectionsBeyondTheCapAreRefusedAtOnce() throws {
        let proxy = ProxyServer(policy: try CompiledPolicy(BoxNetwork(mode: .off)), log: nil, maxConnections: 1)
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
        // Once the first ends, its slot is free again.
        _ = "CONNECT example.com:443 HTTP/1.1\r\n\r\n".withCString { write(first[0], $0, strlen($0)) }
        #expect(firstDone.wait(timeout: .now() + 10) == .success)
        close(first[0])
        #expect(try exchange(proxy, "CONNECT example.com:443 HTTP/1.1\r\n\r\n").hasPrefix("HTTP/1.1 403"))
    }

    @Test func logFieldsAreClipped() throws {
        let scratch = try Scratch()
        let log = NetworkLog(url: scratch.root.appendingPathComponent("network.jsonl"))
        let proxy = ProxyServer(policy: try CompiledPolicy(BoxNetwork(mode: .off)), log: log)
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
        let proxy = ProxyServer(policy: try CompiledPolicy(BoxNetwork(mode: .off)), log: nil, allowPrivate: true)
        #expect(try exchange(proxy, "CONNECT 127.0.0.1:\(server.port) HTTP/1.1\r\n\r\n").hasPrefix("HTTP/1.1 403"))
        proxy.update(try CompiledPolicy(BoxNetwork(mode: .allowlist, allow: ["127.0.0.1:\(server.port)"])))
        // The server answers after the first bytes arrive, so the tunnel carries a payload.
        #expect(try exchange(proxy, "CONNECT 127.0.0.1:\(server.port) HTTP/1.1\r\n\r\nping").hasPrefix("HTTP/1.1 200"))
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
        Thread.sleep(forTimeInterval: 0.2)
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
    }
}
