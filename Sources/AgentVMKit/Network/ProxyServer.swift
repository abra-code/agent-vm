// Sources/AgentVMKit/Network/ProxyServer.swift
//
// The box's only way out in allowlist and off modes: an HTTP proxy on the host, reached from
// the guest over vsock (the guest daemon relays 127.0.0.1:3128 to it). It serves one request
// per connection:
// - CONNECT host:port (HTTPS and anything tunneled), or
// - an absolute-form plain HTTP request (GET http://host/path), sent on with Connection: close.
//
// Every request is checked against the policy by host name and port, the name is resolved on
// the host, and only public addresses are used (so an allowed name cannot lead to this Mac or
// the local network). Every attempt, allowed or not, is in the box's network log: one line for
// a refusal, and for an allowed connection a line when it opens, one a minute with its bytes
// while it carries data, and one when it ends (see `NetworkLog`).
//
// The proxy knows its open connections: a rule change closes the ones the new rules no longer
// allow, and a server that stays silent after the box closed its side is not waited for.

import Darwin
import Foundation

public final class ProxyServer: @unchecked Sendable {
    private let lock = NSLock()
    private var policy: CompiledPolicy
    private let log: NetworkLog?
    /// Tests only: allow loopback and private upstreams.
    private let allowPrivate: Bool
    /// Connections being served; each holds three threads and two descriptors, so the guest
    /// must not be able to open them without limit.
    private var active = 0
    private let maxConnections: Int
    /// Allowed connections being relayed, by log id.
    private var open: [String: Open] = [:]
    /// How long a server may stay silent once the box has closed its side.
    private let silenceLimit: Duration

    private struct Open {
        var request: Request
        /// The line logged when it opened.
        var entry: NetworkLog.Entry
        var began: ContinuousClock.Instant
        var progress: Splice.Progress
        /// Bytes sent on before the relay started: a plain request's head, and what came with it.
        var sentBefore: Int
        /// The counts of the last progress line, so a quiet connection adds no lines.
        var logged: (up: Int, down: Int)
    }

    static let maxHead = 16384
    static let headTimeoutSeconds = 30
    static let connectTimeoutMilliseconds: Int32 = 10_000
    static let connectTotalMilliseconds: Int32 = 30_000
    static let keepAliveIdleSeconds: Int32 = 600
    public static let defaultMaxConnections = 256
    public static let defaultSilenceLimit: Duration = .seconds(60)
    /// How often the supervisor calls `logProgress`.
    public static let progressInterval: Duration = .seconds(60)
    static let ruleRemovedReason = "closed by agent-vm: the box's rules no longer allow it"

    public init(policy: CompiledPolicy, log: NetworkLog?, allowPrivate: Bool = false, maxConnections: Int = defaultMaxConnections,
                silenceLimit: Duration = defaultSilenceLimit) {
        self.policy = policy
        self.log = log
        self.allowPrivate = allowPrivate
        self.maxConnections = maxConnections
        self.silenceLimit = silenceLimit
    }

    /// Serves `client` on its own thread and then calls `done` (which closes it), or refuses
    /// it at once when `maxConnections` are already being served.
    public func accept(client: Int32, done: @escaping @Sendable () -> Void) {
        lock.lock()
        let admitted = active < maxConnections
        if admitted {
            active += 1
        }
        lock.unlock()
        guard admitted else {
            var entry = NetworkLog.Entry(arrived: Date(), method: "?", host: "?", port: 0, decision: .denied)
            entry.reason = "more than \(maxConnections) connections at once"
            log?.append(entry)
            // A fresh socket's send buffer is empty: this short write does not block.
            Self.respond(client, status: "503 Service Unavailable", message: "agent-vm: more than \(maxConnections) connections through the proxy at once")
            done()
            return
        }
        Thread.detachNewThread { [self] in
            handle(client: client)
            done()
            lock.lock()
            active -= 1
            lock.unlock()
        }
    }

    /// Replaces the policy, and closes every open connection the new one does not allow (its
    /// end is logged with the reason). One still allowed, by any rule, keeps going.
    public func update(_ policy: CompiledPolicy) {
        lock.lock()
        self.policy = policy
        for connection in open.values where policy.allows(host: connection.request.host, port: connection.request.port, tunnel: connection.request.tunnel) == nil {
            connection.progress.cut(reason: Self.ruleRemovedReason)
        }
        lock.unlock()
    }

    /// Logs the bytes so far of every open connection that carried any since its last line, so
    /// the log shows the volume of a connection that never ends, or whose end is never logged
    /// (the supervisor killed). Called once a minute, and when the box begins to stop.
    public func logProgress() {
        let now = ContinuousClock.now
        var lines: [NetworkLog.Entry] = []
        lock.lock()
        for (id, connection) in open {
            let (up, down) = connection.progress.counts
            let counts = (up: up + connection.sentBefore, down: down)
            guard counts != connection.logged else {
                continue
            }
            open[id]?.logged = counts
            var line = connection.entry
            line.partial = true
            line.bytesUp = counts.up
            line.bytesDown = counts.down
            line.milliseconds = Int(ImageBuilder.seconds(now - connection.began) * 1000)
            lines.append(line)
        }
        // Written under the lock: a connection leaves the table before its end line is logged,
        // so no line of this kind can follow its end line (which readers would take for a
        // connection that is open again).
        for line in lines.sorted(by: { $0.time < $1.time }) {
            log?.append(line)
        }
        lock.unlock()
    }

    /// The number of allowed connections being relayed.
    var openCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return open.count
    }

    private var currentPolicy: CompiledPolicy {
        lock.lock()
        defer { lock.unlock() }
        return policy
    }

    /// A parsed request head.
    struct Request: Equatable {
        var method: String
        var host: String
        var port: UInt16
        /// True for CONNECT; false for absolute-form HTTP.
        var tunnel: Bool
        /// The head to send upstream (plain HTTP only).
        var upstreamHead: String
        /// How many bytes after the head are the request's (plain HTTP only): its
        /// Content-Length, 0 without one. nil for a tunnel, and for a body in chunks, whose
        /// end only its own framing tells.
        var bodyLength: Int? = nil
    }

    /// Serves one client connection to the end. Does not close `client`.
    public func handle(client: Int32) {
        let clock = ContinuousClock()
        let began = clock.now
        var entry = NetworkLog.Entry(arrived: Date(), method: "?", host: "?", port: 0, decision: .denied)
        defer {
            entry.milliseconds = Int(ImageBuilder.seconds(clock.now - began) * 1000)
            log?.append(entry)
        }

        var one: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        let head: [UInt8]
        var leftover: [UInt8]
        let request: Request
        do {
            (head, leftover) = try Self.readHead(client)
            request = try Self.parse(head)
        } catch {
            entry.reason = "\(error)"
            Self.respond(client, status: "400 Bad Request", message: "\(error)")
            return
        }
        entry.method = request.method
        entry.host = request.host
        entry.port = Int(request.port)

        let policy = currentPolicy
        guard let rule = policy.allows(host: request.host, port: request.port, tunnel: request.tunnel) else {
            entry.reason = policy.mode == .off ? "network is off for this box" : "not in the allowlist"
            Self.respond(client, status: "403 Forbidden", message: "agent-vm: \(request.host):\(request.port) is \(entry.reason!)")
            return
        }
        entry.rule = rule

        let upstream: Int32
        do {
            let addresses = try AddressCheck.resolve(request.host, port: request.port, allowPrivate: allowPrivate)
            (upstream, entry.address) = try Self.connect(addresses)
        } catch {
            entry.decision = .failed
            entry.reason = "\(error)"
            // Not the reason: it names the addresses a name has on this Mac's networks.
            Self.respond(client, status: "502 Bad Gateway", message: "agent-vm: \((error as? ProxyRefusal)?.forClient ?? "\(error)")")
            return
        }
        defer { close(upstream) }

        do {
            if request.tunnel {
                // HTTP/1.0, which every client takes: macOS's nc (an ssh ProxyCommand) refuses
                // an HTTP/1.1 reply ("Proxy error"; measured).
                try FrameChannel.writeAll(client, Array("HTTP/1.0 200 Connection established\r\n\r\n".utf8))
            } else {
                try FrameChannel.writeAll(upstream, Array(request.upstreamHead.utf8))
            }
            // A plain request is one request: what follows its body (a second request, with a
            // Host of its own choosing, for the same server address) is not passed on.
            if let length = request.bodyLength, leftover.count > length {
                leftover = Array(leftover[..<length])
            }
            if !leftover.isEmpty {
                try FrameChannel.writeAll(upstream, leftover)
            }
        } catch {
            entry.decision = .failed
            entry.reason = "\(error)"
            return
        }
        entry.decision = .allowed
        // A line now as well as at the end: a tunnel can stay open for hours (an agent's own
        // connection to its provider), and readers of the log should see it meanwhile.
        let id = NetworkLog.newID()
        entry.id = id
        var opening = entry
        opening.open = true
        log?.append(opening)
        // A plain request's head is data the box chose too (its target and header lines).
        let sentBefore = leftover.count + (request.tunnel ? 0 : request.upstreamHead.utf8.count)
        let progress = Splice.Progress()
        lock.lock()
        open[id] = Open(request: request, entry: opening, began: began, progress: progress, sentBefore: sentBefore, logged: (0, 0))
        // The rules may have changed while the name was resolved and the server connected to.
        if self.policy.allows(host: request.host, port: request.port, tunnel: request.tunnel) == nil {
            progress.cut(reason: Self.ruleRemovedReason)
        }
        lock.unlock()
        let (up, down) = Splice.run(client, upstream, progress: progress, silenceLimit: silenceLimit,
                                    forwardLimit: request.bodyLength.map { $0 - leftover.count })
        // Out of the table before either descriptor is closed: `update` shuts them down.
        lock.lock()
        open[id] = nil
        lock.unlock()
        entry.bytesUp = up + sentBefore
        entry.bytesDown = down
        entry.reason = progress.reason
    }

    // MARK: - Parsing

    /// Reads up to the blank line ending the head; returns the head and any bytes after it.
    /// The whole head must arrive within `timeout` (a total, so a client trickling one byte
    /// at a time cannot hold the connection open). No timeout after that: tunnels may idle.
    static func readHead(_ descriptor: Int32, timeout: Duration = .seconds(headTimeoutSeconds)) throws -> ([UInt8], [UInt8]) {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var data: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= maxHead {
            let remaining = clock.now.duration(to: deadline)
            let milliseconds = Int32(clamping: remaining.components.seconds * 1000 + remaining.components.attoseconds / 1_000_000_000_000_000)
            var watched = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = milliseconds > 0 ? poll(&watched, 1, milliseconds) : 0
            if ready < 0 && errno == EINTR {
                continue
            }
            if ready == 0 {
                throw ProxyRefusal("no complete request within \(headTimeoutSeconds) seconds")
            }
            let count = ready < 0 ? -1 : read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR {
                continue
            }
            if count <= 0 {
                throw ProxyRefusal("the connection closed before a complete request")
            }
            data.append(contentsOf: buffer[0..<count])
            if let end = headEnd(data) {
                return (Array(data[0..<end]), Array(data[end...]))
            }
        }
        throw ProxyRefusal("request head longer than \(maxHead) bytes")
    }

    /// The index just past "\r\n\r\n", if present.
    static func headEnd(_ data: [UInt8]) -> Int? {
        guard data.count >= 4 else {
            return nil
        }
        for index in 0...(data.count - 4) where data[index] == 13 && data[index + 1] == 10 && data[index + 2] == 13 && data[index + 3] == 10 {
            return index + 4
        }
        return nil
    }

    static func parse(_ head: [UInt8]) throws -> Request {
        guard let text = String(bytes: head, encoding: .utf8) else {
            throw ProxyRefusal("request head is not UTF-8")
        }
        var lines = text.components(separatedBy: "\r\n")
        while lines.last == "" {
            lines.removeLast()
        }
        guard let first = lines.first else {
            throw ProxyRefusal("empty request")
        }
        let parts = first.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        // Strict: an exact version and a target of visible ASCII only, so no bare CR or LF
        // can smuggle a line into the head sent upstream.
        guard parts.count == 3, parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0", !parts[0].isEmpty, parts[0].allSatisfy({ $0.isASCII && $0.isUppercase }),
              !parts[1].isEmpty, parts[1].utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7f }) else {
            throw ProxyRefusal("malformed request line")
        }
        // Header lines: a token name directly followed by ":", no control characters but tab,
        // no folded (continued) lines.
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), line[..<colon].utf8.allSatisfy(isTokenByte), colon != line.startIndex,
                  line.utf8.allSatisfy({ $0 == 9 || ($0 >= 0x20 && $0 != 0x7f) }) else {
                throw ProxyRefusal("malformed header line")
            }
        }
        let method = parts[0]
        let target = parts[1]
        if method == "CONNECT" {
            let (host, port) = try splitAuthority(target, defaultPort: nil)
            return Request(method: method, host: host, port: port, tunnel: true, upstreamHead: "")
        }
        // Plain HTTP must be absolute-form: http://host[:port]/path
        guard target.lowercased().hasPrefix("http://") else {
            throw ProxyRefusal("only CONNECT and absolute http:// requests are proxied")
        }
        let afterScheme = target.dropFirst("http://".count)
        let slash = afterScheme.firstIndex(of: "/") ?? afterScheme.endIndex
        let authority = String(afterScheme[..<slash])
        var path = String(afterScheme[slash...])
        if path.isEmpty {
            path = "/"
        }
        guard !authority.contains("@") else {
            throw ProxyRefusal("credentials in the URL are not proxied")
        }
        let (host, port) = try splitAuthority(authority, defaultPort: 80)
        // Rebuild the head: origin-form target, Host from the target (a proxy must replace the
        // client's, RFC 9112 3.2.2 - else it could name another site at the allowed address),
        // no proxy headers, one request per connection.
        let hostHeader = (host.contains(":") ? "[\(host)]" : host) + (port == 80 ? "" : ":\(port)")
        var upstream = ["\(method) \(path) \(parts[2])", "Host: \(hostHeader)"]
        // Where the request ends: its Content-Length, or its chunks. Both, or two lengths, is
        // how one request is made to look like two to the server.
        var lengths: [String] = []
        var chunked = false
        for line in lines.dropFirst() {
            let name = line.split(separator: ":", maxSplits: 1).first.map { $0.lowercased() } ?? ""
            if name == "content-length" {
                lengths.append(line.split(separator: ":", maxSplits: 1).dropFirst().first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t")) } ?? "")
            } else if name == "transfer-encoding" {
                chunked = true
            }
            if name == "host" || name == "proxy-connection" || name == "proxy-authorization" || name == "connection" || name == "keep-alive" {
                continue
            }
            upstream.append(line)
        }
        upstream.append("Connection: close")
        var bodyLength: Int? = 0
        if chunked {
            guard lengths.isEmpty else {
                throw ProxyRefusal("a request with both Content-Length and Transfer-Encoding is not proxied")
            }
            bodyLength = nil
        } else if let first = lengths.first {
            guard lengths.allSatisfy({ $0 == first }), !first.isEmpty, first.utf8.count <= 18, first.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                  let length = Int(first) else {
                throw ProxyRefusal("malformed Content-Length")
            }
            bodyLength = length
        }
        return Request(method: method, host: host, port: port, tunnel: false, upstreamHead: upstream.joined(separator: "\r\n") + "\r\n\r\n",
                       bodyLength: bodyLength)
    }

    /// An HTTP token character (RFC 9110 5.6.2).
    static func isTokenByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"):
            return true
        default:
            return Array("!#$%&'*+-.^_`|~".utf8).contains(byte)
        }
    }

    /// "host:port" or "[v6]:port" (port optional when a default is given).
    static func splitAuthority(_ authority: String, defaultPort: UInt16?) throws -> (String, UInt16) {
        var host = authority
        var portText: String?
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else {
                throw ProxyRefusal("malformed address \(authority)")
            }
            host = String(authority[authority.index(after: authority.startIndex)..<close])
            let after = authority[authority.index(after: close)...]
            if after.hasPrefix(":") {
                portText = String(after.dropFirst())
            } else if !after.isEmpty {
                throw ProxyRefusal("malformed address \(authority)")
            }
        } else if let colon = authority.lastIndex(of: ":") {
            host = String(authority[..<colon])
            portText = String(authority[authority.index(after: colon)...])
            // An address with colons goes in brackets; without, `example.com:80:80` would be
            // the host `example.com:80`.
            guard !host.contains(":") else {
                throw ProxyRefusal("malformed address \(authority)")
            }
        }
        let port: UInt16
        if let portText {
            // Digits only, as written: `+443` and `0443` are not ports.
            guard let parsed = UInt16(portText), parsed > 0, String(parsed) == portText else {
                throw ProxyRefusal("bad port in \(authority)")
            }
            port = parsed
        } else if let defaultPort {
            port = defaultPort
        } else {
            throw ProxyRefusal("CONNECT needs host:port")
        }
        guard !host.isEmpty, host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "." || $0 == ":") }) else {
            throw ProxyRefusal("malformed host \(host)")
        }
        // No empty labels: `.github.com` and `x..github.com` would match `*.github.com`, and
        // `.` alone is no name at all.
        let name = AllowRule.normalized(host)
        guard !name.isEmpty, name.contains(":") || name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty }) else {
            throw ProxyRefusal("malformed host \(host)")
        }
        // With a colon it is an IPv6 address, or nothing: `[:.github.com]` would match
        // `*.github.com` as a name.
        var v6 = in6_addr()
        guard !name.contains(":") || inet_pton(AF_INET6, name, &v6) == 1 else {
            throw ProxyRefusal("malformed address \(host)")
        }
        return (name, port)
    }

    // MARK: - Upstream

    /// Connects to the first address that answers within the timeout. All attempts together
    /// get `connectTotalMilliseconds`: a name with many dead addresses does not hold its slot
    /// for ten seconds each.
    static func connect(_ addresses: [AddressCheck.Resolved]) throws -> (Int32, String) {
        var lastError = "no address"
        let deadline = ContinuousClock.now + .milliseconds(Int(connectTotalMilliseconds))
        for resolved in addresses {
            let left = (deadline - ContinuousClock.now).components
            let leftMilliseconds = Int32(clamping: left.seconds * 1000 + left.attoseconds / 1_000_000_000_000_000)
            guard leftMilliseconds > 0 else {
                lastError = "connection timed out"
                break
            }
            var storage = resolved.storage
            let descriptor = socket(Int32(storage.ss_family), SOCK_STREAM, 0)
            guard descriptor >= 0 else {
                lastError = String(cString: strerror(errno))
                continue
            }
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            var one: Int32 = 1
            _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let flags = fcntl(descriptor, F_GETFL)
            _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
            let started = withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, resolved.length) }
            }
            var connected = started == 0
            if !connected && errno == EINPROGRESS {
                var watched = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                if poll(&watched, 1, min(connectTimeoutMilliseconds, leftMilliseconds)) == 1 {
                    var socketError: Int32 = 0
                    var length = socklen_t(MemoryLayout<Int32>.size)
                    connected = getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 && socketError == 0
                    if !connected {
                        lastError = String(cString: strerror(socketError))
                    }
                } else {
                    lastError = "connection timed out"
                }
            } else if !connected {
                lastError = String(cString: strerror(errno))
            }
            if connected {
                _ = fcntl(descriptor, F_SETFL, flags)
                // A server that vanished without a word is noticed, and the connection ended.
                _ = setsockopt(descriptor, SOL_SOCKET, SO_KEEPALIVE, &one, socklen_t(MemoryLayout<Int32>.size))
                var idle = keepAliveIdleSeconds
                _ = setsockopt(descriptor, IPPROTO_TCP, TCP_KEEPALIVE, &idle, socklen_t(MemoryLayout<Int32>.size))
                return (descriptor, resolved.text)
            }
            close(descriptor)
        }
        throw ProxyRefusal("cannot connect: \(lastError)")
    }

    static func respond(_ client: Int32, status: String, message: String) {
        var one: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let body = message + "\n"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        try? FrameChannel.writeAll(client, Array(response.utf8))
    }
}

/// The box's network log: one JSON object per line, in two files. Refused and failed
/// connections are one line each in `network.jsonl`. Allowed connections are in
/// `network-allowed.jsonl`, so that refusals, which cost a box nothing to cause, can never push
/// them out: a line with `open` when it is connected, a line with `partial` and its bytes so far
/// about once a minute while it carries data, and a line with its bytes when it ends, all with
/// the same `id`. `entries` puts the two files together by time and gives each connection once.
///
/// Logs from before 0.5.12 have both kinds in `network.jsonl` and no `partial` lines; those from
/// before 0.3.8 have only an allowed connection's last line, with no `id`.
public final class NetworkLog: @unchecked Sendable {
    public enum Decision: String, Codable, Sendable {
        case allowed
        case denied
        /// Allowed by policy, but resolving or connecting failed.
        case failed
    }

    public struct Entry: Codable, Equatable, Sendable {
        /// When the request arrived, on every line of a connection. Written in whole seconds.
        public var time: Date
        /// The milliseconds of `time` (0 to 999), so that the entries of one second keep their
        /// order when the log's two files are put together (agent-vm 0.5.12 and later).
        public var timeMilliseconds: Int?
        public var method: String
        public var host: String
        public var port: Int
        public var decision: Decision
        /// The rule or pack that allowed it.
        public var rule: String?
        /// Why it was refused or failed; on an allowed connection, why agent-vm ended it.
        public var reason: String?
        /// The address connected to.
        public var address: String?
        public var bytesUp: Int?
        public var bytesDown: Int?
        public var milliseconds: Int?
        /// Pairs an allowed connection's lines (agent-vm 0.3.8 and later).
        public var id: String?
        /// True on the lines logged when an allowed connection opens and while it runs; from
        /// `entries`, true on a connection whose end is not logged yet.
        public var open: Bool?
        /// True when the bytes are those of a line logged while the connection ran: what it
        /// had carried by then, not its total (agent-vm 0.5.12 and later).
        public var partial: Bool?

        /// Whether this entry's request arrived before `other`'s.
        func arrivedBefore(_ other: Entry) -> Bool {
            return time != other.time ? time < other.time : (timeMilliseconds ?? 0) < (other.timeMilliseconds ?? 0)
        }

        /// An allowed connection whose end was never logged, because its supervisor stopped
        /// first: not open, and no bytes or only those of a line logged while it ran.
        public var endNotLogged: Bool {
            return decision == .allowed && open != true && (bytesUp == nil || partial == true)
        }
    }

    /// A new connection id: random, so ids stay unique across supervisor runs.
    static func newID() -> String {
        return String(UInt64.random(in: 0...UInt64.max), radix: 16)
    }

    /// The file of refused and failed connections; the box's `network.jsonl`.
    public let url: URL
    /// The file of allowed connections, next to it: `network-allowed.jsonl`.
    public let allowedURL: URL
    /// The size at which each file moves to `<name>.1` (replacing the previous one).
    public let maxBytes: Int64
    private let lock = NSLock()

    public init(url: URL, maxBytes: Int64 = 64 << 20) {
        self.url = url
        self.allowedURL = Self.allowedURL(for: url)
        self.maxBytes = maxBytes
    }

    /// `network.jsonl` gives `network-allowed.jsonl`.
    static func allowedURL(for url: URL) -> URL {
        let name = url.deletingPathExtension().lastPathComponent + "-allowed." + url.pathExtension
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }

    /// Longest text kept per field: the guest chooses these, and must not be able to write
    /// many kilobytes to the host's disk with each connection.
    static let maxFieldLength = 256

    public func append(_ entry: Entry) {
        var entry = entry
        entry.method = Self.clipped(entry.method)
        entry.host = Self.clipped(entry.host)
        entry.reason = entry.reason.map(Self.clipped)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(entry) else {
            return
        }
        line.append(10)
        let path = (entry.decision == .allowed ? allowedURL : url).path
        lock.lock()
        defer { lock.unlock() }
        // An idle macOS guest is refused 2-4 times a second (its background services), and a
        // hostile one can go much faster: keep one previous file, about `maxBytes` each.
        var info = stat()
        if lstat(path, &info) == 0, info.st_size + Int64(line.count) > maxBytes {
            _ = rename(path, path + ".1")
        }
        let descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            return
        }
        defer { close(descriptor) }
        try? FrameChannel.writeAll(descriptor, Array(line))
    }

    static func clipped(_ text: String) -> String {
        return text.count > maxFieldLength ? String(text.prefix(maxFieldLength)) + "..." : text
    }

    /// The last `count` connections (all when nil) that `matching` accepts, oldest first, each
    /// once; see `Tail.read`. Both files are read, each with its `.1`, and put together by the
    /// time the requests arrived. `liveSince` is when the box's supervisor started
    /// (`.distantFuture` when none runs): a connection opened before it has ended unlogged, so
    /// it is not `open`. Without `includeAllowed` the file of allowed connections is left
    /// unread, for a caller whose `matching` accepts none of them.
    public func entries(last count: Int? = nil, liveSince: Date = .distantPast, includeAllowed: Bool = true,
                        matching: (Entry) -> Bool = { _ in true }) -> [Entry] {
        let refused = Self.entries(at: url, last: count, liveSince: liveSince, matching: matching)
        guard includeAllowed else {
            return refused
        }
        return Self.merged(refused, Self.entries(at: allowedURL, last: count, liveSince: liveSince, matching: matching), last: count)
    }

    /// The same, from one file and its `.1`.
    static func entries(at url: URL, last count: Int?, liveSince: Date, matching: (Entry) -> Bool) -> [Entry] {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            // Only the previous file is there: between the move and the next line.
            let previous = open(url.path + ".1", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard previous >= 0 else {
                return []
            }
            defer { close(previous) }
            var info = stat()
            guard fstat(previous, &info) == 0 else {
                return []
            }
            return Tail.read(previous, end: info.st_size, last: count, liveSince: liveSince, matching: matching).entries
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            return []
        }
        return Tail.read(descriptor, end: info.st_size, previous: url.path + ".1", last: count, liveSince: liveSince, matching: matching).entries
    }

    /// Two lists, each in its own order, as one in order of arrival; then its last `count`. An
    /// entry of `first` comes before one of `second` that arrived in the same millisecond.
    static func merged(_ first: [Entry], _ second: [Entry], last count: Int?) -> [Entry] {
        var result: [Entry] = []
        result.reserveCapacity(first.count + second.count)
        var index = 0
        for entry in first {
            while index < second.count && second[index].arrivedBefore(entry) {
                result.append(second[index])
                index += 1
            }
            result.append(entry)
        }
        result.append(contentsOf: second[index...])
        return count.map { Array(result.suffix($0)) } ?? result
    }

    /// Reads a log from its end, so the last few connections of a large log cost only the
    /// lines they take.
    enum Tail {
        static let chunkSize = 64 * 1024
        /// Longer lines are skipped rather than gathered: the proxy writes about 1 KB at most.
        static let maxLineLength = 64 * 1024

        /// The connections in `descriptor` up to `end` (see `entries`), and the offset just past
        /// its last complete line. Unreadable lines are skipped, and so is a last line still
        /// being written (no newline yet). When the file does not hold `count` of them, the
        /// reading goes on in the file at `previous` (the log's `.1`), if there is one.
        ///
        /// A connection's place is its open line, so the order is the order connections were
        /// made, and its newest later line (its end, else its bytes so far) replaces the open
        /// line. A later line whose open line is in neither file counts as older than every
        /// line read.
        static func read(_ descriptor: Int32, end: off_t, previous: String? = nil, last count: Int?, liveSince: Date = .distantPast,
                         matching: (Entry) -> Bool) -> (entries: [Entry], complete: off_t) {
            var scan = Scan(count: count, liveSince: liveSince)
            let (complete, whole) = scan.file(descriptor, end: end, matching: matching)
            var reachedStart = whole
            if whole, !scan.full, let previous {
                let older = open(previous, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
                if older >= 0 {
                    defer { close(older) }
                    var current = stat()
                    var info = stat()
                    // The same file: the log moved to `.1` after it was opened here.
                    if fstat(descriptor, &current) == 0, fstat(older, &info) == 0, info.st_ino != current.st_ino {
                        reachedStart = scan.file(older, end: info.st_size, matching: matching).whole
                    }
                }
            }
            if reachedStart {
                scan.finish(matching: matching)
            }
            return (scan.found.reversed(), complete)
        }

        /// What reading backward has gathered, across a log's files.
        struct Scan {
            let count: Int?
            let liveSince: Date
            var found: [Entry] = []  // newest first
            var later: [String: Entry] = [:]  // end and progress lines waiting for their open line
            let decoder: JSONDecoder

            init(count: Int?, liveSince: Date) {
                self.count = count
                self.liveSince = liveSince
                decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
            }

            var full: Bool {
                return count.map { found.count >= $0 } ?? false
            }

            mutating func take(_ entry: Entry, matching: (Entry) -> Bool) {
                var entry = entry
                if entry.open == true, entry.time < liveSince {
                    entry.open = nil
                }
                if matching(entry) {
                    found.append(entry)
                }
            }

            mutating func line(_ bytes: ArraySlice<UInt8>, matching: (Entry) -> Bool) {
                guard !bytes.isEmpty, let entry = try? decoder.decode(Entry.self, from: Data(bytes)) else {
                    return
                }
                guard let id = entry.id else {
                    take(entry, matching: matching)
                    return
                }
                if entry.open == true && entry.partial != true {
                    take(later.removeValue(forKey: id) ?? entry, matching: matching)
                } else if later[id] == nil || (later[id]?.partial == true && entry.partial != true) {
                    // Read backward: the first one met is the newest. An end line still wins
                    // over a progress line after it, which the proxy never writes.
                    later[id] = entry
                }
            }

            /// Reads `descriptor` backward from `end` until `count` are found. Returns the offset
            /// just past its last complete line (0 when it has none), and whether the reading
            /// reached the start of the file with room for more.
            mutating func file(_ descriptor: Int32, end: off_t, matching: (Entry) -> Bool) -> (complete: off_t, whole: Bool) {
                var complete: off_t?
                var position = end
                var carry: [UInt8] = []  // the end of a line that starts in the chunk read next
                var buffer = [UInt8](repeating: 0, count: chunkSize)

                // Until the last complete line is found even when no entry is wanted (--last 0):
                // the follower goes on from there.
                while position > 0 && (complete == nil || !full) {
                    let size = Int(min(off_t(chunkSize), position))
                    position -= off_t(size)
                    var got = 0
                    while got < size {
                        let bytes = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress! + got, size - got, position + off_t(got)) }
                        if bytes < 0 && errno == EINTR {
                            continue
                        }
                        guard bytes > 0 else {
                            // Cut short under us: what was read is all there is.
                            return (complete ?? 0, false)
                        }
                        got += bytes
                    }
                    var data = Array(buffer[0..<size])
                    data.append(contentsOf: carry)
                    // Everything after the last newline in the file is a line still being written.
                    var stop = data.endIndex
                    if complete == nil {
                        guard let newline = data.lastIndex(of: 10) else {
                            carry = data.count > maxLineLength ? [] : data
                            continue
                        }
                        complete = position + off_t(newline + 1)
                        stop = newline
                    }
                    // Before the first newline is the end of a line that began in an earlier chunk,
                    // unless this chunk starts the file.
                    let first = position > 0 ? data[..<stop].firstIndex(of: 10) : nil
                    if position > 0 && first == nil {
                        carry = data.count > maxLineLength ? [] : Array(data[..<stop])
                        continue
                    }
                    var lineEnd = stop
                    var index = stop
                    let floor = first.map { $0 + 1 } ?? 0
                    while index > floor && !full {
                        index -= 1
                        if data[index] == 10 {
                            line(data[(index + 1)..<lineEnd], matching: matching)
                            lineEnd = index
                        }
                    }
                    if !full {
                        line(data[floor..<lineEnd], matching: matching)
                    }
                    carry = first.map { Array(data[..<$0]) } ?? []
                    if carry.count > maxLineLength {
                        carry = []
                    }
                }
                return (complete ?? 0, position == 0 && !full)
            }

            /// The start of the oldest file: the later lines left over opened before it, oldest
            /// last.
            mutating func finish(matching: (Entry) -> Bool) {
                for entry in later.values.sorted(by: { $0.time > $1.time }) where !full {
                    take(entry, matching: matching)
                }
                later = [:]
            }
        }
    }
}

extension NetworkLog.Entry {
    /// An entry for a request that arrived at `arrived`. (Here, so that the memberwise
    /// initializer stays.)
    init(arrived: Date, method: String, host: String, port: Int, decision: NetworkLog.Decision) {
        let seconds = arrived.timeIntervalSince1970.rounded(.down)
        self.init(time: Date(timeIntervalSince1970: seconds), method: method, host: host, port: port, decision: decision)
        timeMilliseconds = min(999, Int((arrived.timeIntervalSince1970 - seconds) * 1000))
    }
}
