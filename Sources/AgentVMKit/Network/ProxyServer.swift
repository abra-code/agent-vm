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
// the local network). Every attempt, allowed or not, is one line in the box's network log, and
// an allowed connection has a second line when it opens (see `NetworkLog`).

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

    static let maxHead = 16384
    static let headTimeoutSeconds = 30
    static let connectTimeoutMilliseconds: Int32 = 10_000
    public static let defaultMaxConnections = 256

    public init(policy: CompiledPolicy, log: NetworkLog?, allowPrivate: Bool = false, maxConnections: Int = defaultMaxConnections) {
        self.policy = policy
        self.log = log
        self.allowPrivate = allowPrivate
        self.maxConnections = maxConnections
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

    /// Replaces the policy; connections already open keep going.
    public func update(_ policy: CompiledPolicy) {
        lock.lock()
        self.policy = policy
        lock.unlock()
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
    }

    /// Serves one client connection to the end. Does not close `client`.
    public func handle(client: Int32) {
        let clock = ContinuousClock()
        let began = clock.now
        var entry = NetworkLog.Entry(time: Date(), method: "?", host: "?", port: 0, decision: .denied)
        defer {
            entry.milliseconds = Int(ImageBuilder.seconds(clock.now - began) * 1000)
            log?.append(entry)
        }

        var one: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        let head: [UInt8]
        let leftover: [UInt8]
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
            Self.respond(client, status: "502 Bad Gateway", message: "agent-vm: \(error)")
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
        entry.id = NetworkLog.newID()
        var opening = entry
        opening.open = true
        log?.append(opening)
        let (up, down) = Splice.run(client, upstream)
        entry.bytesUp = up + leftover.count
        entry.bytesDown = down
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
        for line in lines.dropFirst() {
            let name = line.split(separator: ":", maxSplits: 1).first.map { $0.lowercased() } ?? ""
            if name == "host" || name == "proxy-connection" || name == "proxy-authorization" || name == "connection" || name == "keep-alive" {
                continue
            }
            upstream.append(line)
        }
        upstream.append("Connection: close")
        return Request(method: method, host: host, port: port, tunnel: false, upstreamHead: upstream.joined(separator: "\r\n") + "\r\n\r\n")
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
        }
        let port: UInt16
        if let portText {
            guard let parsed = UInt16(portText), parsed > 0 else {
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
        return (AllowRule.normalized(host), port)
    }

    // MARK: - Upstream

    /// Connects to the first address that answers within the timeout.
    static func connect(_ addresses: [AddressCheck.Resolved]) throws -> (Int32, String) {
        var lastError = "no address"
        for resolved in addresses {
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
                if poll(&watched, 1, connectTimeoutMilliseconds) == 1 {
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

/// The box's network log: one JSON object per line. A refused or failed connection is one
/// line. An allowed one is two lines with the same `id`: one with `open` when it is connected,
/// and one with the bytes when it ends. Logs from before 0.3.8 have only the second, with no
/// `id`. `entries` pairs the two, so a reader sees each connection once.
public final class NetworkLog: @unchecked Sendable {
    public enum Decision: String, Codable, Sendable {
        case allowed
        case denied
        /// Allowed by policy, but resolving or connecting failed.
        case failed
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var time: Date
        public var method: String
        public var host: String
        public var port: Int
        public var decision: Decision
        /// The rule or pack that allowed it.
        public var rule: String?
        public var reason: String?
        /// The address connected to.
        public var address: String?
        public var bytesUp: Int?
        public var bytesDown: Int?
        public var milliseconds: Int?
        /// Pairs an allowed connection's two lines (agent-vm 0.3.8 and later).
        public var id: String?
        /// True on the line logged when an allowed connection opens; from `entries`, true
        /// on a connection whose end is not logged yet.
        public var open: Bool?

        /// An allowed connection whose end was never logged, because its supervisor stopped
        /// first: no bytes, and not open.
        public var endNotLogged: Bool {
            return decision == .allowed && open != true && bytesUp == nil
        }
    }

    /// A new connection id: random, so ids stay unique across supervisor runs.
    static func newID() -> String {
        return String(UInt64.random(in: 0...UInt64.max), radix: 16)
    }

    public let url: URL
    /// The size at which the log moves to `<name>.1` (replacing the previous one).
    public let maxBytes: Int64
    private let lock = NSLock()

    public init(url: URL, maxBytes: Int64 = 64 << 20) {
        self.url = url
        self.maxBytes = maxBytes
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
        lock.lock()
        defer { lock.unlock() }
        // An idle macOS guest is refused 2-4 times a second (its background services), and a
        // hostile one can go much faster: keep one previous file, about `maxBytes` each.
        var info = stat()
        if lstat(url.path, &info) == 0, info.st_size + Int64(line.count) > maxBytes {
            _ = rename(url.path, url.path + ".1")
        }
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
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
    /// once; see `Tail.read`. `liveSince` is when the box's supervisor started (`.distantFuture`
    /// when none runs): a connection opened before it has ended unlogged, so it is not `open`.
    public func entries(last count: Int? = nil, liveSince: Date = .distantPast, matching: (Entry) -> Bool = { _ in true }) -> [Entry] {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            return []
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            return []
        }
        return Tail.read(descriptor, end: info.st_size, last: count, liveSince: liveSince, matching: matching).entries
    }

    /// Reads a log from its end, so the last few connections of a large log cost only the
    /// lines they take.
    enum Tail {
        static let chunkSize = 64 * 1024
        /// Longer lines are skipped rather than gathered: the proxy writes about 1 KB at most.
        static let maxLineLength = 64 * 1024

        /// The connections in `descriptor` up to `end` (see `entries`), and the offset just past
        /// the last complete line. Unreadable lines are skipped, and so is a last line still
        /// being written (no newline yet).
        ///
        /// A connection's place is its open line, so the order is the order connections were
        /// made, and the end line replaces the open line. An end line whose open line is not in
        /// this file (it moved to `.1`) counts as older than every line in the file.
        static func read(_ descriptor: Int32, end: off_t, last count: Int?, liveSince: Date = .distantPast,
                         matching: (Entry) -> Bool) -> (entries: [Entry], complete: off_t) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var found: [Entry] = []  // newest first
            var ended: [String: Entry] = [:]  // end lines waiting for their open line
            var complete: off_t?
            var position = end
            var carry: [UInt8] = []  // the end of a line that starts in the chunk read next
            var buffer = [UInt8](repeating: 0, count: chunkSize)

            func full() -> Bool {
                return count.map { found.count >= $0 } ?? false
            }
            func take(_ entry: Entry) {
                var entry = entry
                if entry.open == true, entry.time < liveSince {
                    entry.open = nil
                }
                if matching(entry) {
                    found.append(entry)
                }
            }
            func line(_ bytes: ArraySlice<UInt8>) {
                guard !bytes.isEmpty, let entry = try? decoder.decode(Entry.self, from: Data(bytes)) else {
                    return
                }
                guard let id = entry.id else {
                    take(entry)
                    return
                }
                if entry.open == true {
                    take(ended.removeValue(forKey: id) ?? entry)
                } else {
                    ended[id] = entry
                }
            }

            // Until the last complete line is found even when no entry is wanted (--last 0):
            // the follower goes on from there.
            while position > 0 && (complete == nil || !full()) {
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
                        return (found.reversed(), complete ?? 0)
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
                while index > floor && !full() {
                    index -= 1
                    if data[index] == 10 {
                        line(data[(index + 1)..<lineEnd])
                        lineEnd = index
                    }
                }
                if !full() {
                    line(data[floor..<lineEnd])
                }
                carry = first.map { Array(data[..<$0]) } ?? []
                if carry.count > maxLineLength {
                    carry = []
                }
            }
            // The start of the file: end lines left over opened before it, oldest last.
            if position == 0 && !full() {
                for entry in ended.values.sorted(by: { $0.time > $1.time }) where !full() {
                    take(entry)
                }
            }
            return (found.reversed(), complete ?? 0)
        }
    }
}
