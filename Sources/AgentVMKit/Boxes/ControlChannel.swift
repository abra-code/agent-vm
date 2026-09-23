// Sources/AgentVMKit/Boxes/ControlChannel.swift
//
// The supervisor's control socket: a Unix socket in the box folder (mode 0600, and every
// connection's peer must be this user, checked with getpeereid). Messages are a 4-byte
// big-endian length and JSON, each sent with one sendmsg; the answer to `open` carries a vsock
// descriptor to the guest daemon (SCM_RIGHTS), so `agent-vm exec` talks to the guest directly
// and the supervisor is not in the data path. The supervisor keeps that vsock connection open
// until the client closes its control connection: closing it earlier would break the client's
// copy (measured).

import Darwin
import Foundation

public struct ControlRequest: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable {
        /// The supervisor's state.
        case status
        /// A new connection to the guest daemon, passed as a descriptor. With `path`, the
        /// project is shared first, and kept for this connection's lifetime.
        case open
        /// Shut the guest down and end the supervisor.
        case stop
        /// Reread the box's network rules (after `box network` changed them).
        case reload
        /// Share a project folder into the box at the same path (`path`, `readOnly`).
        case share
    }

    public var v: Int
    public var op: Operation
    public var path: String?
    public var readOnly: Bool?

    public init(op: Operation, path: String? = nil, readOnly: Bool? = nil) {
        self.v = ControlChannel.version
        self.op = op
        self.path = path
        self.readOnly = readOnly
    }
}

public struct ControlResponse: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        /// The VM is booting; the guest daemon has not answered yet.
        case starting
        /// The guest daemon answers; exec works.
        case ready
        /// Shutting down.
        case stopping
    }

    public var ok: Bool
    public var error: String?
    public var state: State?
    public var guestVersion: String?
    public var pid: Int32?
    /// The project folder shared into the box, if any, and whether read only.
    public var project: String?
    public var projectReadOnly: Bool?

    public init(ok: Bool, error: String? = nil, state: State? = nil, guestVersion: String? = nil, pid: Int32? = nil,
                project: String? = nil, projectReadOnly: Bool? = nil) {
        self.ok = ok
        self.error = error
        self.state = state
        self.guestVersion = guestVersion
        self.pid = pid
        self.project = project
        self.projectReadOnly = projectReadOnly
    }
}

/// A guest connection lent to a control client, with what to do once the client is done.
public struct LentConnection: Sendable {
    public var descriptor: Int32
    public var release: @Sendable () -> Void

    public init(descriptor: Int32, release: @escaping @Sendable () -> Void) {
        self.descriptor = descriptor
        self.release = release
    }
}

/// What the supervisor answers. Called on the control socket's threads.
public protocol ControlHandler: AnyObject, Sendable {
    func controlStatus() -> ControlResponse
    func controlOpenGuest(project: String?, readOnly: Bool) throws -> LentConnection
    func controlStop()
    func controlReload() throws
    func controlShare(path: String, readOnly: Bool) throws
}

public enum ControlChannel {
    public static let version = 1
    static let maxMessage = 65536

    // MARK: - Sockets

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count < capacity else {
            throw AgentVMError.hostNotReady("the control socket path \(path) is longer than macOS allows (\(capacity - 1) bytes); use a shorter AGENT_VM_HOME")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    /// Binds a listening socket at `path` (replacing a stale one: the caller holds the box
    /// lock), readable and writable by this user only.
    public static func listen(_ path: String) throws -> Int32 {
        var address = try address(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw AgentVMError.system(operation: "control socket", code: errno)
        }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        unlink(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let code = errno
            close(descriptor)
            throw AgentVMError.system(operation: "bind \(path)", code: code)
        }
        // Not umask: it is process-wide, and other threads create files meanwhile. The box
        // folder is 0700 already, and every peer's user is checked.
        guard chmod(path, 0o600) == 0 else {
            let code = errno
            close(descriptor)
            unlink(path)
            throw AgentVMError.system(operation: "chmod \(path)", code: code)
        }
        guard Darwin.listen(descriptor, 16) == 0 else {
            let code = errno
            close(descriptor)
            throw AgentVMError.system(operation: "listen on \(path)", code: code)
        }
        return descriptor
    }

    public static func connect(_ path: String) throws -> Int32 {
        var address = try address(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw AgentVMError.system(operation: "control socket", code: errno)
        }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            let code = errno
            close(descriptor)
            throw AgentVMError.system(operation: "connect to \(path)", code: code)
        }
        return descriptor
    }

    /// Whether the peer of a connected Unix socket runs as this process's user.
    static func peerIsSameUser(_ descriptor: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(descriptor, &uid, &gid) == 0 && uid == geteuid()
    }

    // MARK: - Messages

    /// Sends one message, with `descriptor` attached when given.
    public static func send(_ value: some Encodable, over socket: Int32, passing descriptor: Int32? = nil) throws {
        let json = try JSONEncoder().encode(value)
        guard json.count <= maxMessage else {
            throw GuestProtocolError.malformed("control message too long")
        }
        var bytes = Int32(json.count).bigEndianBytes
        bytes.append(contentsOf: json)
        let controlLength = MemoryLayout<cmsghdr>.size + MemoryLayout<Int32>.size
        let control = UnsafeMutableRawPointer.allocate(byteCount: controlLength, alignment: MemoryLayout<cmsghdr>.alignment)
        defer { control.deallocate() }
        memset(control, 0, controlLength)
        var sent = 0
        try bytes.withUnsafeMutableBytes { raw in
            var vector = iovec(iov_base: raw.baseAddress, iov_len: raw.count)
            var message = msghdr()
            try withUnsafeMutablePointer(to: &vector) { vectorPointer in
                message.msg_iov = vectorPointer
                message.msg_iovlen = 1
                if let descriptor {
                    let header = control.assumingMemoryBound(to: cmsghdr.self)
                    header.pointee.cmsg_len = socklen_t(controlLength)
                    header.pointee.cmsg_level = SOL_SOCKET
                    header.pointee.cmsg_type = SCM_RIGHTS
                    (control + MemoryLayout<cmsghdr>.size).storeBytes(of: descriptor, as: Int32.self)
                    message.msg_control = control
                    message.msg_controllen = socklen_t(controlLength)
                }
                let result = sendmsg(socket, &message, 0)
                guard result >= 0 else {
                    throw GuestProtocolError.io(operation: "sendmsg", code: errno)
                }
                sent = result
            }
        }
        // Control messages are small; a short send would mean the peer is gone.
        guard sent == bytes.count else {
            throw GuestProtocolError.disconnected
        }
    }

    /// Receives one message and any descriptor attached to it; nil at a clean end of file.
    public static func receive<T: Decodable>(_ type: T.Type, from socket: Int32) throws -> (T, Int32?)? {
        var buffer = [UInt8](repeating: 0, count: 4 + maxMessage)
        let controlLength = MemoryLayout<cmsghdr>.size + MemoryLayout<Int32>.size * 4
        let control = UnsafeMutableRawPointer.allocate(byteCount: controlLength, alignment: MemoryLayout<cmsghdr>.alignment)
        defer { control.deallocate() }
        var received = 0
        var passed: Int32?
        try buffer.withUnsafeMutableBytes { raw in
            var vector = iovec(iov_base: raw.baseAddress, iov_len: raw.count)
            var message = msghdr()
            try withUnsafeMutablePointer(to: &vector) { vectorPointer in
                message.msg_iov = vectorPointer
                message.msg_iovlen = 1
                message.msg_control = control
                message.msg_controllen = socklen_t(controlLength)
                var result: Int
                repeat {
                    result = recvmsg(socket, &message, 0)
                } while result < 0 && errno == EINTR
                guard result >= 0 else {
                    throw GuestProtocolError.io(operation: "recvmsg", code: errno)
                }
                received = result
                if message.msg_controllen >= socklen_t(MemoryLayout<cmsghdr>.size) {
                    let header = control.assumingMemoryBound(to: cmsghdr.self)
                    if header.pointee.cmsg_level == SOL_SOCKET && header.pointee.cmsg_type == SCM_RIGHTS {
                        // When a peer sends more descriptors than fit (MSG_CTRUNC), cmsg_len
                        // still counts them all (measured): read only what the buffer holds.
                        let filled = min(Int(header.pointee.cmsg_len), Int(message.msg_controllen), controlLength)
                        let count = max(0, filled - MemoryLayout<cmsghdr>.size) / MemoryLayout<Int32>.size
                        for index in 0..<count {
                            let descriptor = (control + MemoryLayout<cmsghdr>.size + index * MemoryLayout<Int32>.size).load(as: Int32.self)
                            // One descriptor is expected; close any extra a peer might send.
                            if passed == nil {
                                passed = descriptor
                                _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
                            } else {
                                close(descriptor)
                            }
                        }
                    }
                }
            }
        }
        if received == 0 {
            if let passed {
                close(passed)
            }
            return nil
        }
        do {
            // The rest of a message that arrived in pieces.
            while received < 4 {
                received += try readMore(socket, &buffer, from: received, upTo: 4)
            }
            guard let length = Int32(bigEndianBytes: Array(buffer[0..<4])), length >= 0, Int(length) <= maxMessage else {
                throw GuestProtocolError.malformed("bad control message length")
            }
            while received < 4 + Int(length) {
                received += try readMore(socket, &buffer, from: received, upTo: 4 + Int(length))
            }
            guard received == 4 + Int(length) else {
                throw GuestProtocolError.malformed("control message longer than announced")
            }
            let value = try JSONDecoder().decode(T.self, from: Data(buffer[4..<(4 + Int(length))]))
            return (value, passed)
        } catch {
            if let passed {
                close(passed)
            }
            throw error
        }
    }

    private static func readMore(_ socket: Int32, _ buffer: inout [UInt8], from offset: Int, upTo end: Int) throws -> Int {
        let got = buffer.withUnsafeMutableBytes { raw in
            read(socket, raw.baseAddress! + offset, end - offset)
        }
        if got < 0 {
            throw GuestProtocolError.io(operation: "read", code: errno)
        }
        if got == 0 {
            throw GuestProtocolError.disconnected
        }
        return got
    }
}

/// Serves the control socket on background threads: one thread accepts, one per connection.
public final class ControlServer: @unchecked Sendable {
    public let path: String
    private let handler: ControlHandler
    private let listener: Int32
    private let lock = NSLock()
    private var closed = false

    public init(path: String, handler: ControlHandler) throws {
        self.path = path
        self.handler = handler
        self.listener = try ControlChannel.listen(path)
        Thread.detachNewThread { [self] in
            acceptLoop()
        }
    }

    /// Stops accepting and removes the socket file. Connections in progress finish.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if !closed {
            closed = true
            unlink(path)
            Darwin.shutdown(listener, SHUT_RDWR)
            Darwin.close(listener)
        }
    }

    private var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    private func acceptLoop() {
        while !isClosed {
            let connection = accept(listener, nil, nil)
            if connection < 0 {
                if isClosed {
                    return
                }
                // Keep serving through transient failures (EMFILE, ENFILE): a dead control
                // socket would leave only signals to stop the box.
                if errno != EINTR && errno != ECONNABORTED {
                    usleep(100_000)
                }
                continue
            }
            _ = fcntl(connection, F_SETFD, FD_CLOEXEC)
            var one: Int32 = 1
            _ = setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            guard ControlChannel.peerIsSameUser(connection) else {
                Darwin.close(connection)
                continue
            }
            Thread.detachNewThread { [self] in
                serve(connection)
            }
        }
    }

    /// Answers requests until the client closes; then gives back every lent guest connection.
    private func serve(_ connection: Int32) {
        var lent: [LentConnection] = []
        defer {
            for connection in lent {
                connection.release()
            }
            Darwin.close(connection)
        }
        while true {
            let request: ControlRequest
            do {
                guard let (received, stray) = try ControlChannel.receive(ControlRequest.self, from: connection) else {
                    return
                }
                if let stray {
                    Darwin.close(stray)
                }
                request = received
            } catch {
                try? ControlChannel.send(ControlResponse(ok: false, error: "\(error)"), over: connection)
                return
            }
            guard request.v == ControlChannel.version else {
                try? ControlChannel.send(ControlResponse(ok: false, error: "control protocol \(request.v) is not supported; this agent-vm speaks \(ControlChannel.version)"), over: connection)
                return
            }
            switch request.op {
            case .status:
                try? ControlChannel.send(handler.controlStatus(), over: connection)
            case .open:
                do {
                    let guest = try handler.controlOpenGuest(project: request.path, readOnly: request.readOnly ?? false)
                    lent.append(guest)
                    try ControlChannel.send(ControlResponse(ok: true), over: connection, passing: guest.descriptor)
                } catch {
                    try? ControlChannel.send(ControlResponse(ok: false, error: "\(error)"), over: connection)
                }
            case .stop:
                try? ControlChannel.send(ControlResponse(ok: true, state: .stopping), over: connection)
                handler.controlStop()
            case .reload:
                do {
                    try handler.controlReload()
                    try? ControlChannel.send(handler.controlStatus(), over: connection)
                } catch {
                    try? ControlChannel.send(ControlResponse(ok: false, error: "\(error)"), over: connection)
                }
            case .share:
                do {
                    guard let path = request.path else {
                        throw AgentVMError.guestRefused("share needs a path")
                    }
                    try handler.controlShare(path: path, readOnly: request.readOnly ?? false)
                    try? ControlChannel.send(handler.controlStatus(), over: connection)
                } catch {
                    try? ControlChannel.send(ControlResponse(ok: false, error: "\(error)"), over: connection)
                }
            }
        }
    }
}

/// The client side, used by `agent-vm box start|stop|list` and `agent-vm exec`.
public enum ControlClient {
    /// How long a client waits for the supervisor's answer; a wedged supervisor must not hang
    /// `box stop` or `exec`.
    public static let answerTimeout = 30
    /// Sharing a project takes up to four guest commands of at most 60 s each.
    public static let shareTimeout = 310

    /// One request on a fresh connection; the connection is closed afterwards.
    public static func request(_ op: ControlRequest.Operation, path: String) throws -> ControlResponse {
        return try request(ControlRequest(op: op), path: path)
    }

    public static func request(_ request: ControlRequest, path: String, timeout: Int = answerTimeout) throws -> ControlResponse {
        let socket = try ControlChannel.connect(path)
        defer { close(socket) }
        setReceiveTimeout(socket, seconds: timeout)
        try ControlChannel.send(request, over: socket)
        guard let (response, stray) = try ControlChannel.receive(ControlResponse.self, from: socket) else {
            throw GuestProtocolError.disconnected
        }
        if let stray {
            close(stray)
        }
        return response
    }

    /// A connection to the guest daemon. Keep `control` open for as long as `guest` is in
    /// use: the supervisor closes the guest connection when `control` closes.
    /// With `project`, the supervisor shares it first (as `share` does) and keeps it shared,
    /// unchanged, until `control` closes - one step, so another client cannot switch it in
    /// between.
    public static func openGuest(path: String, project: String? = nil, readOnly: Bool = false) throws -> (control: Int32, guest: Int32) {
        let socket = try ControlChannel.connect(path)
        do {
            setReceiveTimeout(socket, seconds: project == nil ? answerTimeout : shareTimeout)
            try ControlChannel.send(ControlRequest(op: .open, path: project, readOnly: project == nil ? nil : readOnly), over: socket)
            guard let (response, passed) = try ControlChannel.receive(ControlResponse.self, from: socket) else {
                throw GuestProtocolError.disconnected
            }
            guard response.ok, let passed else {
                if let passed {
                    close(passed)
                }
                throw AgentVMError.supervisorRefused(response.error ?? "the supervisor sent no connection")
            }
            // The control connection now only has to stay open; nothing more is read.
            setReceiveTimeout(socket, seconds: 0)
            return (socket, passed)
        } catch {
            close(socket)
            throw error
        }
    }

    static func setReceiveTimeout(_ socket: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
}
