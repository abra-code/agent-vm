// Sources/AgentVMKit/Guest/GuestProtocol.swift
//
// The host-to-guest protocol, spoken over one vsock connection per request (a connection costs
// about 0.2 ms, measured). Language-neutral, so a Linux guest side can implement it too; the
// full description is Docs/guest-protocol.md.
//
// Every message is a frame: 1 byte type, 4 bytes big-endian payload length, payload. The host
// opens with a `request` frame (JSON), the guest answers with a `response` frame (JSON). For
// `exec`, stream frames follow in both directions until the guest sends `exit`.

import Darwin
import Foundation

public enum GuestProtocol {
    /// The vsock port the guest daemon listens on.
    public static let port: UInt32 = 1024
    /// The largest payload either side accepts; anything larger is a protocol error.
    public static let maxPayload = 1 << 20
}

public enum FrameType: UInt8, Sendable {
    // Opening exchange.
    case request = 0x01
    case response = 0x02
    // Host to guest during exec.
    case stdin = 0x10
    case stdinEnd = 0x11
    case signal = 0x12
    // Guest to host during exec.
    case stdout = 0x20
    case stderr = 0x21
    case exit = 0x22
}

public struct Frame: Equatable, Sendable {
    public var type: FrameType
    public var payload: [UInt8]

    public init(_ type: FrameType, _ payload: [UInt8] = []) {
        self.type = type
        self.payload = payload
    }
}

/// The host's opening message.
public struct GuestRequest: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable {
        /// Version and health check.
        case hello
        /// Run a program; stream frames follow.
        case exec
        /// Shut the guest down cleanly (the only clean way for a macOS guest with a logged-in user).
        case shutdown
    }

    public var v: Int
    public var op: Operation
    public var argv: [String]?
    /// Added to (and overriding) the guest's default environment for the user.
    public var env: [String: String]?
    public var cwd: String?
    /// Account to run as; nil means the daemon's default (the box user).
    public var user: String?

    public init(op: Operation, argv: [String]? = nil, env: [String: String]? = nil, cwd: String? = nil, user: String? = nil) {
        self.v = AgentVM.guestProtocolVersion
        self.op = op
        self.argv = argv
        self.env = env
        self.cwd = cwd
        self.user = user
    }
}

/// The guest's answer to the opening message.
public struct GuestResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var error: String?
    public var v: Int?
    /// agent-vm-guest's version, and the guest's macOS build (hello only).
    public var version: String?
    public var osBuild: String?
    /// The started process (exec only).
    public var pid: Int32?
    /// For a refused exec: the status a shell would give (127 not found, 126 cannot run).
    public var status: Int32?

    public init(ok: Bool, error: String? = nil, v: Int? = nil, version: String? = nil, osBuild: String? = nil, pid: Int32? = nil, status: Int32? = nil) {
        self.ok = ok
        self.error = error
        self.v = v
        self.version = version
        self.osBuild = osBuild
        self.pid = pid
        self.status = status
    }

    public static func failure(_ message: String) -> GuestResponse {
        return GuestResponse(ok: false, error: message, v: AgentVM.guestProtocolVersion)
    }
}

/// How an exec'd process ended: exactly one of the two is set.
public struct ExitReport: Codable, Equatable, Sendable {
    public var status: Int32?
    public var signal: Int32?

    public init(status: Int32? = nil, signal: Int32? = nil) {
        self.status = status
        self.signal = signal
    }

    /// The conventional shell status: the exit status, or 128 + the signal number.
    public var shellStatus: Int32 {
        if let status {
            return status
        }
        return 128 + (signal ?? 0)
    }
}

public enum GuestProtocolError: Error, Equatable, CustomStringConvertible {
    /// The peer sent something that is not a valid frame or message.
    case malformed(String)
    /// The connection ended in the middle of a frame or before the expected message.
    case disconnected
    case io(operation: String, code: Int32)

    public var description: String {
        switch self {
        case let .malformed(reason):
            return "guest protocol error: \(reason)"
        case .disconnected:
            return "the connection to the guest ended unexpectedly"
        case let .io(operation, code):
            return "\(operation) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// Frames over a connected stream socket. Writes are serialized, so several threads may send;
/// one thread reads.
public final class FrameChannel: @unchecked Sendable {
    public let descriptor: Int32
    private let writeLock = NSLock()
    private var isClosed = false

    public init(descriptor: Int32) {
        self.descriptor = descriptor
        // A peer that goes away must produce EPIPE, never a process-killing SIGPIPE.
        var one: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    public func send(_ frame: Frame) throws {
        guard frame.payload.count <= GuestProtocol.maxPayload else {
            throw GuestProtocolError.malformed("payload of \(frame.payload.count) bytes is over the limit")
        }
        let length = UInt32(frame.payload.count)
        var bytes: [UInt8] = [frame.type.rawValue, UInt8(length >> 24), UInt8((length >> 16) & 0xff), UInt8((length >> 8) & 0xff), UInt8(length & 0xff)]
        bytes.append(contentsOf: frame.payload)
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !isClosed else {
            throw GuestProtocolError.disconnected
        }
        try Self.writeAll(descriptor, bytes)
    }

    public func send(_ type: FrameType, json value: some Encodable) throws {
        let data = try JSONEncoder().encode(value)
        try send(Frame(type, Array(data)))
    }

    /// The next frame, or nil when the peer closed the connection between frames.
    public func receive() throws -> Frame? {
        var header = [UInt8](repeating: 0, count: 5)
        let got = try Self.readAll(descriptor, &header, header.count)
        if got == 0 {
            return nil
        }
        guard got == header.count else {
            throw GuestProtocolError.disconnected
        }
        guard let type = FrameType(rawValue: header[0]) else {
            throw GuestProtocolError.malformed("unknown frame type \(header[0])")
        }
        let length = Int(header[1]) << 24 | Int(header[2]) << 16 | Int(header[3]) << 8 | Int(header[4])
        guard length <= GuestProtocol.maxPayload else {
            throw GuestProtocolError.malformed("payload of \(length) bytes is over the limit")
        }
        var payload = [UInt8](repeating: 0, count: length)
        if length > 0 {
            guard try Self.readAll(descriptor, &payload, length) == length else {
                throw GuestProtocolError.disconnected
            }
        }
        return Frame(type, payload)
    }

    /// The next frame, which must be of `type` and hold JSON for `T`.
    public func receive<T: Decodable>(_ type: FrameType, as: T.Type) throws -> T {
        guard let frame = try receive() else {
            throw GuestProtocolError.disconnected
        }
        guard frame.type == type else {
            throw GuestProtocolError.malformed("expected a \(type) frame, got \(frame.type)")
        }
        do {
            return try JSONDecoder().decode(T.self, from: Data(frame.payload))
        } catch {
            throw GuestProtocolError.malformed("unreadable \(type) message: \(error.localizedDescription)")
        }
    }

    /// Stops both directions; a thread blocked in `receive` returns.
    public func shutdownBoth() {
        _ = Darwin.shutdown(descriptor, SHUT_RDWR)
    }

    /// Closes the descriptor. Later sends fail instead of writing to whatever reuses the
    /// descriptor number; no thread may still be in `receive`.
    public func close() {
        writeLock.lock()
        defer { writeLock.unlock() }
        if !isClosed {
            isClosed = true
            Darwin.close(descriptor)
        }
    }

    static func writeAll(_ descriptor: Int32, _ bytes: [UInt8]) throws {
        var done = 0
        try bytes.withUnsafeBytes { buffer in
            while done < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + done, buffer.count - done)
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw GuestProtocolError.io(operation: "write", code: errno)
                }
                done += written
            }
        }
    }

    /// Reads up to `count` bytes, stopping early only at end of file; returns how many.
    static func readAll(_ descriptor: Int32, _ buffer: inout [UInt8], _ count: Int) throws -> Int {
        var done = 0
        try buffer.withUnsafeMutableBytes { raw in
            while done < count {
                let got = read(descriptor, raw.baseAddress! + done, count - done)
                if got < 0 {
                    if errno == EINTR {
                        continue
                    }
                    if errno == ECONNRESET {
                        break
                    }
                    throw GuestProtocolError.io(operation: "read", code: errno)
                }
                if got == 0 {
                    break
                }
                done += got
            }
        }
        return done
    }
}

extension Int32 {
    var bigEndianBytes: [UInt8] {
        let value = UInt32(bitPattern: self)
        return [UInt8(value >> 24), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }

    init?(bigEndianBytes bytes: [UInt8]) {
        guard bytes.count == 4 else {
            return nil
        }
        self = Int32(bitPattern: UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
    }
}
