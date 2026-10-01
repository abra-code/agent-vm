// Sources/AgentVMKit/Guest/GuestClient.swift
//
// The host side of the protocol, on an already connected descriptor (a vsock connection handed
// out by the supervisor, or a socket pair in tests). Blocking calls: run them off the main
// actor.

import Darwin
import Foundation

public enum GuestClient {
    /// The most output `capture` keeps of each stream. The commands the host runs for itself
    /// print a few lines; a guest must not be able to fill the host's memory through one.
    public static let captureLimit = 1 << 20

    /// The same calls with a time limit for the whole exchange (GuestDeadline): for a process
    /// that must not be held up by its guest, as a box's supervisor.
    public static func hello(_ descriptor: Int32, within limit: Duration) throws -> GuestResponse {
        return try GuestDeadline.run(descriptor, within: limit, what: "its hello") { try hello(descriptor) }
    }

    public static func syncTime(_ descriptor: Int32, within limit: Duration) throws -> Double {
        return try GuestDeadline.run(descriptor, within: limit, what: "setting its clock") { try syncTime(descriptor) }
    }

    public static func shutdown(_ descriptor: Int32, within limit: Duration) throws {
        try GuestDeadline.run(descriptor, within: limit, what: "accepting the shutdown") { try shutdown(descriptor) }
    }

    public static func capture(_ descriptor: Int32, _ request: GuestRequest, input: Data? = nil,
                               within limit: Duration) throws -> (report: ExitReport, stdout: String, stderr: String) {
        return try GuestDeadline.run(descriptor, within: limit, what: request.argv?.first ?? "a command") {
            try capture(descriptor, request, input: input)
        }
    }

    /// Version and health check.
    public static func hello(_ descriptor: Int32) throws -> GuestResponse {
        let channel = FrameChannel(descriptor: descriptor)
        try channel.sendRequest(GuestRequest(op: .hello))
        let response = try channel.receive(.response, as: GuestResponse.self)
        guard response.ok else {
            throw AgentVMError.guestRefused(response.error ?? "no reason given")
        }
        return response
    }

    /// Sets the guest's clock to this Mac's (feature `time-sync`); returns how far the guest
    /// was behind, in seconds (negative: ahead). The time is taken just before sending.
    public static func syncTime(_ descriptor: Int32) throws -> Double {
        let channel = FrameChannel(descriptor: descriptor)
        try channel.sendRequest(GuestRequest(op: .timeSync, epoch: Date().timeIntervalSince1970))
        let response = try channel.receive(.response, as: GuestResponse.self)
        guard response.ok, let offset = response.offset else {
            throw AgentVMError.guestRefused(response.error ?? "no offset in the answer")
        }
        return offset
    }

    /// Asks the guest to shut down; returns once the guest accepted.
    public static func shutdown(_ descriptor: Int32) throws {
        let channel = FrameChannel(descriptor: descriptor)
        try channel.sendRequest(GuestRequest(op: .shutdown))
        let response = try channel.receive(.response, as: GuestResponse.self)
        guard response.ok else {
            throw AgentVMError.guestRefused(response.error ?? "no reason given")
        }
    }

    /// Runs a program and collects its output (for short commands the host itself needs), with
    /// `input` as its stdin. Output past `limit` bytes on either stream is an error: the caller
    /// closes the connection, which makes the guest daemon end the program.
    public static func capture(_ descriptor: Int32, _ request: GuestRequest, input: Data? = nil,
                               limit: Int = GuestClient.captureLimit) throws -> (report: ExitReport, stdout: String, stderr: String) {
        let session = try ExecSession(descriptor: descriptor, request: request)
        // A program that ended first leaves its report to run() (see sendInput).
        if try input.map({ try session.sendInput(Array($0)) }) ?? true {
            _ = try session.endInput()
        }
        var stdout = Data()
        var stderr = Data()
        func keep(_ bytes: [UInt8], in stream: inout Data) throws {
            guard stream.count + bytes.count <= limit else {
                throw GuestProtocolError.malformed("the program printed more than \(limit) bytes")
            }
            stream.append(contentsOf: bytes)
        }
        let report = try session.run(stdout: { try keep($0, in: &stdout) }, stderr: { try keep($0, in: &stderr) })
        return (report, String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self))
    }
}

/// One running program in the guest. `run` delivers its output until it exits; stdin and
/// signals may be sent from other threads meanwhile. The session does not own the descriptor:
/// its owner keeps it open until `run` has returned and a `forwardStdin` thread has ended
/// (closing it earlier lets the number be reused under those threads).
public final class ExecSession: @unchecked Sendable {
    let channel: FrameChannel
    /// The process id inside the guest.
    public let pid: Int32

    /// Sends the request; throws if the guest refuses it (unknown account, missing program,
    /// bad working directory).
    public init(descriptor: Int32, request: GuestRequest) throws {
        channel = FrameChannel(descriptor: descriptor)
        try channel.sendRequest(request)
        let response = try channel.receive(.response, as: GuestResponse.self)
        guard response.ok, let pid = response.pid else {
            throw ExecRefusal(message: response.error ?? "no reason given", status: response.status ?? 126)
        }
        self.pid = pid
    }

    public func sendStdin(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + GuestProtocol.maxPayload, bytes.count)
            try channel.send(Frame(.stdin, Array(bytes[offset..<end])))
            offset = end
        }
    }

    public func sendStdinEnd() throws {
        try channel.send(Frame(.stdinEnd))
    }

    /// Input sent before anything is read: false when the guest has closed its end. The program
    /// then ended first (a quick one, or one that stopped reading its input), and its exit
    /// report, sent before the close, waits to be read with `run`, which fails on its own when
    /// the connection is really gone. Other errors are thrown.
    public func sendInput(_ bytes: [UInt8]) throws -> Bool {
        return try Self.delivered { try sendStdin(bytes) }
    }

    /// Ends the input, as `sendInput` sends it.
    public func endInput() throws -> Bool {
        return try Self.delivered { try sendStdinEnd() }
    }

    private static func delivered(_ send: () throws -> Void) throws -> Bool {
        do {
            try send()
            return true
        } catch let GuestProtocolError.io(operation, code) where operation == "write" && [EPIPE, ECONNRESET, ENOTCONN].contains(code) {
            return false
        }
    }

    /// Sets the size of the program's terminal (exec with `terminal` only).
    public func sendResize(_ size: TerminalSize) throws {
        try channel.send(Frame(.resize, size.bytes))
    }

    /// Delivers a signal to the program's process group.
    public func sendSignal(_ signal: Int32) throws {
        try channel.send(Frame(.signal, signal.bigEndianBytes))
    }

    /// Reads frames until the program exits; output goes to the two handlers in order, and
    /// notices (sent only when the request asked for them) to `notice`.
    public func run(stdout: ([UInt8]) throws -> Void, stderr: ([UInt8]) throws -> Void,
                    notice: (GuestNotice) -> Void = { _ in }) throws -> ExitReport {
        while let frame = try channel.receive() {
            switch frame.type {
            case .notice:
                // One the host cannot read is dropped: a notice is advice, never the output.
                if let decoded = try? JSONDecoder().decode(GuestNotice.self, from: Data(frame.payload)) {
                    notice(decoded)
                }
            case .stdout:
                try stdout(frame.payload)
            case .stderr:
                try stderr(frame.payload)
            case .exit:
                guard let report = try? JSONDecoder().decode(ExitReport.self, from: Data(frame.payload)), report.isValid else {
                    throw GuestProtocolError.malformed("unreadable exit report")
                }
                return report
            default:
                throw GuestProtocolError.malformed("unexpected \(frame.type) frame from the guest")
            }
        }
        throw GuestProtocolError.disconnected
    }

    /// Copies `descriptor` (the local stdin) to the program until end of file, on a thread
    /// of its own; ends with stdin end-of-file.
    public func forwardStdin(from descriptor: Int32) {
        Thread.detachNewThread { [self] in
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = read(descriptor, &buffer, buffer.count)
                if count < 0 && errno == EINTR {
                    continue
                }
                if count <= 0 {
                    break
                }
                do {
                    try sendStdin(Array(buffer[0..<count]))
                } catch {
                    return
                }
            }
            try? sendStdinEnd()
        }
    }
}

/// The guest would not start the program; `status` is what a shell would exit with
/// (127 not found, 126 cannot run).
public struct ExecRefusal: Error, Equatable, CustomStringConvertible {
    public var message: String
    public var status: Int32

    public var description: String {
        return "the guest refused: \(message)"
    }
}
