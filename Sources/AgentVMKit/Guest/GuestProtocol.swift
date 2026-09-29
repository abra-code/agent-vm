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
    /// A new terminal size (exec with a terminal only): rows, then columns, 2 bytes each, big-endian;
    /// then, with feature `terminal-pixels`, the width and height in pixels, 2 bytes each.
    case resize = 0x13
    // Guest to host during exec.
    case stdout = 0x20
    case stderr = 0x21
    case exit = 0x22
    /// Something the program waits on that nobody in the box may see (feature `prompt-notices`,
    /// sent only when the request asked for notices): JSON, a GuestNotice.
    case notice = 0x23
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
        /// Set the guest's clock to `epoch` (feature `time-sync`): a box on the allowlist
        /// network has no network time, and its clock drifts, most of all across the Mac's sleep.
        case timeSync = "time-sync"
    }

    public var v: Int
    public var op: Operation
    public var argv: [String]?
    /// Added to (and overriding) the guest's default environment for the user.
    public var env: [String: String]?
    public var cwd: String?
    /// Account to run as; nil means the daemon's default (the box user).
    public var user: String?
    /// Run the program on a new terminal (pseudo-terminal) of this size instead of pipes. Its
    /// output then arrives as stdout frames only. Needs the `terminal` feature: a guest
    /// without it ignores the field.
    public var terminal: TerminalSize?
    /// Send notice frames (feature `prompt-notices`): for example when the program waits on a
    /// privacy prompt shown on the guest's screen. A guest without the feature ignores the field.
    public var notices: Bool?
    /// time-sync: the Mac's time, in seconds since 1970 (with fractions).
    public var epoch: Double?

    public init(op: Operation, argv: [String]? = nil, env: [String: String]? = nil, cwd: String? = nil, user: String? = nil, terminal: TerminalSize? = nil,
                notices: Bool? = nil, epoch: Double? = nil) {
        self.epoch = epoch
        self.notices = notices
        self.v = AgentVM.guestProtocolVersion
        self.op = op
        self.argv = argv
        self.env = env
        self.cwd = cwd
        self.user = user
        self.terminal = terminal
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
    /// What this guest daemon can do beyond protocol 1 (hello only; see GuestFeature).
    public var features: [String]?
    /// time-sync: how far the guest's clock was behind the time it was set to, in seconds
    /// (negative: ahead).
    public var offset: Double?

    public init(ok: Bool, error: String? = nil, v: Int? = nil, version: String? = nil, osBuild: String? = nil, pid: Int32? = nil, status: Int32? = nil,
                features: [String]? = nil, offset: Double? = nil) {
        self.offset = offset
        self.ok = ok
        self.error = error
        self.v = v
        self.version = version
        self.osBuild = osBuild
        self.pid = pid
        self.status = status
        self.features = features
    }

    public static func failure(_ message: String) -> GuestResponse {
        return GuestResponse(ok: false, error: message, v: AgentVM.guestProtocolVersion)
    }
}

/// Additions to protocol 1 that a guest daemon announces in its hello answer, so an older daemon
/// (in an image built earlier) is never sent what it would ignore or misread.
public enum GuestFeature {
    /// exec with `terminal`, and resize frames.
    public static let terminal = "terminal"
    /// exec with `notices`, and notice frames.
    public static let promptNotices = "prompt-notices"
    /// `agent-vm-guest wallpaper`, run in the box user's desktop session (GuestWallpaper).
    public static let wallpaper = "wallpaper"
    /// The `time-sync` request.
    public static let timeSync = "time-sync"
    /// exec runs a program for an account in that account's login session (`launchctl asuser`):
    /// the desktop (Aqua) session once it is logged in, so the program shares the login
    /// Keychain with apps in the box; and Keychain dialogs are sent as notices.
    public static let userSession = "user-session"
    /// The terminal's size in pixels too: in the exec request's `terminal`, and in 8-byte
    /// `resize` frames (a guest without it reads only 4-byte ones).
    public static let terminalPixels = "terminal-pixels"
    /// Everything this build's daemon supports.
    public static let all = [terminal, promptNotices, wallpaper, timeSync, userSession, terminalPixels]
}

/// A terminal's size in character cells.
public struct TerminalSize: Codable, Equatable, Sendable {
    public var rows: UInt16
    public var columns: UInt16
    /// The window in pixels, when the terminal says (feature `terminal-pixels`); programs that
    /// draw images size them by it.
    public var xpixels: UInt16?
    public var ypixels: UInt16?

    public init(rows: UInt16, columns: UInt16, xpixels: UInt16? = nil, ypixels: UInt16? = nil) {
        self.rows = rows
        self.columns = columns
        self.xpixels = xpixels
        self.ypixels = ypixels
    }

    /// The resize frame's payload: rows and columns, then the pixels when known (8 bytes,
    /// which only a guest with `terminal-pixels` reads).
    public var bytes: [UInt8] {
        var bytes = [UInt8(rows >> 8), UInt8(rows & 0xff), UInt8(columns >> 8), UInt8(columns & 0xff)]
        if let xpixels, let ypixels {
            bytes += [UInt8(xpixels >> 8), UInt8(xpixels & 0xff), UInt8(ypixels >> 8), UInt8(ypixels & 0xff)]
        }
        return bytes
    }

    public init?(bytes: [UInt8]) {
        guard bytes.count == 4 || bytes.count == 8 else {
            return nil
        }
        func value(_ at: Int) -> UInt16 {
            return UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1])
        }
        self.init(rows: value(0), columns: value(2), xpixels: bytes.count == 8 ? value(4) : nil, ypixels: bytes.count == 8 ? value(6) : nil)
    }

    /// For the guest's TIOCSWINSZ.
    public var winsize: winsize {
        return Darwin.winsize(ws_row: rows, ws_col: columns, ws_xpixel: xpixels ?? 0, ws_ypixel: ypixels ?? 0)
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

    /// How a process ended, from waitpid's status (WIFEXITED, WEXITSTATUS and WTERMSIG are
    /// macros Swift does not import).
    public init(waitStatus: Int32) {
        let low = waitStatus & 0x7f
        if low == 0 {
            self.init(status: (waitStatus >> 8) & 0xff)
        } else {
            self.init(signal: low)
        }
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
    /// The guest closed the connection before the request that opens it was sent in full, so
    /// nothing of it ran and it may be sent again (FrameChannel.sendRequest).
    case notDelivered(code: Int32)

    public var description: String {
        switch self {
        case let .malformed(reason):
            return "guest protocol error: \(reason)"
        case .disconnected:
            return "the connection to the guest ended unexpectedly"
        case let .io(operation, code):
            return "\(operation) failed: \(String(cString: strerror(code)))"
        case let .notDelivered(code):
            return "the guest closed the connection before the request was sent (\(String(cString: strerror(code))))"
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
        // A peer that goes away must produce EPIPE, never a process-killing SIGPIPE. The socket
        // option is not enough on a socket pair whose other end is closed (measured); the
        // descriptor flag is.
        var one: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
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

    /// Sends the request that opens a connection. A write the peer refused because it closed
    /// first is `notDelivered`: the guest cannot act on a request it did not get in full.
    public func sendRequest(_ request: some Encodable) throws {
        do {
            try send(.request, json: request)
        } catch let GuestProtocolError.io(operation, code) where operation == "write" && [EPIPE, ECONNRESET, ENOTCONN].contains(code) {
            throw GuestProtocolError.notDelivered(code: code)
        }
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
                // Not read(2): a thread asleep in it can miss a shutdown (SocketRead).
                let got = SocketRead.read(descriptor, raw.baseAddress! + done, count - done)
                if got < 0 {
                    let code = errno
                    if code == ECONNRESET {
                        break
                    }
                    throw GuestProtocolError.io(operation: "read", code: code)
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
