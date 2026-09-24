// Sources/AgentVMKit/Guest/GuestClient.swift
//
// The host side of the protocol, on an already connected descriptor (a vsock connection handed
// out by the supervisor, or a socket pair in tests). Blocking calls: run them off the main
// actor.

import Darwin
import Foundation

public enum GuestClient {
    /// Version and health check.
    public static func hello(_ descriptor: Int32) throws -> GuestResponse {
        let channel = FrameChannel(descriptor: descriptor)
        try channel.send(.request, json: GuestRequest(op: .hello))
        let response = try channel.receive(.response, as: GuestResponse.self)
        guard response.ok else {
            throw AgentVMError.guestRefused(response.error ?? "no reason given")
        }
        return response
    }

    /// Asks the guest to shut down; returns once the guest accepted.
    public static func shutdown(_ descriptor: Int32) throws {
        let channel = FrameChannel(descriptor: descriptor)
        try channel.send(.request, json: GuestRequest(op: .shutdown))
        let response = try channel.receive(.response, as: GuestResponse.self)
        guard response.ok else {
            throw AgentVMError.guestRefused(response.error ?? "no reason given")
        }
    }

    /// Runs a program and collects its output (for short commands the host itself needs), with
    /// `input` as its stdin.
    public static func capture(_ descriptor: Int32, _ request: GuestRequest, input: Data? = nil) throws -> (report: ExitReport, stdout: String, stderr: String) {
        let session = try ExecSession(descriptor: descriptor, request: request)
        if let input {
            try session.sendStdin(Array(input))
        }
        try session.sendStdinEnd()
        var stdout = Data()
        var stderr = Data()
        let report = try session.run(stdout: { stdout.append(contentsOf: $0) }, stderr: { stderr.append(contentsOf: $0) })
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
        try channel.send(.request, json: request)
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

    /// Sets the size of the program's terminal (exec with `terminal` only).
    public func sendResize(_ size: TerminalSize) throws {
        try channel.send(Frame(.resize, size.bytes))
    }

    /// Delivers a signal to the program's process group.
    public func sendSignal(_ signal: Int32) throws {
        try channel.send(Frame(.signal, signal.bigEndianBytes))
    }

    /// Reads frames until the program exits; output goes to the two handlers in order.
    public func run(stdout: ([UInt8]) throws -> Void, stderr: ([UInt8]) throws -> Void) throws -> ExitReport {
        while let frame = try channel.receive() {
            switch frame.type {
            case .stdout:
                try stdout(frame.payload)
            case .stderr:
                try stderr(frame.payload)
            case .exit:
                do {
                    return try JSONDecoder().decode(ExitReport.self, from: Data(frame.payload))
                } catch {
                    throw GuestProtocolError.malformed("unreadable exit report")
                }
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
