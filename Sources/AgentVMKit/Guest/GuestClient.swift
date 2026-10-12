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
        // Kept in the box's status and records and shown by every list from then on: only what
        // a version, a build and a feature name look like is taken.
        guard response.version.map({ Printable.isToken($0) }) ?? true, response.osBuild.map({ Printable.isToken($0) }) ?? true,
              response.os.map({ Printable.isToken($0) }) ?? true,
              (response.features ?? []).count <= maxFeatures, (response.features ?? []).allSatisfy({ Printable.isToken($0) }) else {
            throw GuestProtocolError.malformed("the guest's hello names a version, build, system or feature that is not one")
        }
        return response
    }

    /// The most feature names a hello may list (agent-vm-guest has about ten).
    public static let maxFeatures = 64

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
    /// With flow control (the request named a window and the guest answered with its own;
    /// GuestFlow): how much input may still be sent, and the window output is acknowledged by.
    /// Then `sendStdin` waits for the guest's acknowledgments, which only `run` reads: input
    /// must be sent from another thread than the one in `run`, as `forwardStdin` does.
    private let inputGate: CreditGate?
    private let inputChunk: Int
    private let outputWindow: Int?
    /// Whether this session has flow control.
    public var hasFlowControl: Bool {
        return inputGate != nil
    }

    /// Sends the request; throws if the guest refuses it (unknown account, missing program,
    /// bad working directory).
    public init(descriptor: Int32, request: GuestRequest) throws {
        channel = FrameChannel(descriptor: descriptor)
        try channel.sendRequest(request)
        let response = try channel.receive(.response, as: GuestResponse.self)
        guard response.ok else {
            // The reason is the guest's text, and is printed: one line of it. The status is what
            // the client exits with: 126 unless it is one a shell could give.
            let status = response.status.flatMap { (1...255).contains($0) ? $0 : nil } ?? 126
            throw ExecRefusal(message: Printable.line(response.error ?? "no reason given", limit: 500), status: status)
        }
        // Kept in the exec log and shown as the program's: a process id, never 0 or a negative
        // number (which name process groups).
        guard let pid = response.pid, pid > 0 else {
            throw GuestProtocolError.malformed("the guest started a program without saying which process it is")
        }
        self.pid = pid
        if let asked = GuestFlow.accepted(request.window), let answered = GuestFlow.accepted(response.window) {
            inputGate = CreditGate(window: answered)
            inputChunk = GuestFlow.chunk(for: answered)
            outputWindow = asked
        } else {
            inputGate = nil
            inputChunk = GuestProtocol.maxPayload
            outputWindow = nil
        }
    }

    public func sendStdin(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + inputChunk, bytes.count)
            // Waits while the guest holds a window of input the program has not read.
            if let inputGate, !inputGate.take(GuestFlow.cost(payload: end - offset)) {
                throw GuestProtocolError.disconnected
            }
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
        var delivered: [GuestNotice] = []
        var windowBegan = ContinuousClock.now
        // Whatever ends the run ends a wait for room to send input too.
        defer { inputGate?.open() }
        var taken = outputWindow.map { AckTally(window: $0) }
        /// Output is acknowledged once its handler has returned, which is when the bytes left
        /// this process: a handler that waits (a full pipe, a paused terminal) holds the
        /// program in the guest, not the connection. The guest may have closed already.
        func acknowledge(_ count: Int) {
            if let total = taken?.took(payload: count) {
                try? channel.send(Frame(.outputAck, GuestFlow.acknowledgment(total)))
            }
        }
        // With flow control the connection is read on a thread of its own, into memory: what
        // the guest sent must not wait in the connection while a handler waits (GuestFlow),
        // and the window is what bounds the memory. The thread is out of the descriptor
        // before this returns, however it returns.
        let reader = outputWindow.map { FrameReader(channel: channel, inputGate: inputGate, limit: $0 + Self.readAheadSlack) }
        defer { reader?.finish() }
        while let frame = try reader.map({ try $0.next() }) ?? channel.receive() {
            switch frame.type {
            case .notice:
                // One the host cannot read is dropped: a notice is advice, never the output. So
                // is one that repeats another of the same minute, and every one past
                // `maxNotices` in a minute: each costs the caller a printed line, a log line
                // and perhaps a stopped program. A run can last hours, so the count starts over
                // every minute: a real program's prompt, much later, is still reported.
                if ContinuousClock.now - windowBegan >= .seconds(60) {
                    windowBegan = ContinuousClock.now
                    delivered.removeAll()
                }
                if delivered.count < Self.maxNotices, frame.payload.count <= Self.maxNoticeBytes,
                   let decoded = try? JSONDecoder().decode(GuestNotice.self, from: Data(frame.payload)),
                   let checked = decoded.checked, !delivered.contains(checked) {
                    delivered.append(checked)
                    notice(checked)
                }
            case .stdout:
                try stdout(frame.payload)
                acknowledge(frame.payload.count)
            case .stderr:
                try stderr(frame.payload)
                acknowledge(frame.payload.count)
            // An acknowledgment of input is taken on the reader thread and never comes here;
            // without flow control nobody asked for one.
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

    /// What the reader thread may hold beyond the output window: the exit report, which no
    /// window counts, and room for a guest that counts a little differently.
    static let readAheadSlack = 64 * 1024

    /// The most notices one program's run delivers in a minute, and the largest notice frame
    /// read as one.
    public static let maxNotices = 32
    public static let maxNoticeBytes = 4096

    /// A send that takes longer than this was held up by the other end.
    static let stallLimit: Duration = .milliseconds(250)
    /// A read of this size or more may have emptied a full terminal queue (macOS holds 1022
    /// bytes, measured), behind which the terminal program keeps more.
    static let fullRead = 512
    /// With no input for this long, nothing read earlier is still on its way.
    static let quietMilliseconds: Int32 = 100

    /// Copies `descriptor` (the local stdin) to the program until end of file, on a thread
    /// of its own; ends with stdin end-of-file. `observe` sees each read before it is sent, and
    /// whether it is `late`: possibly read long after it was typed. Whatever runs in the box
    /// can hold up the sending, and so the next read, for as long as it likes, and a key typed
    /// meanwhile waits in the terminal's queue, or in the terminal program once that is full.
    /// So input is late after a send that was held up, after a read that may have emptied a
    /// full queue, and at the start (typed before the session began), until none comes for a
    /// moment.
    public func forwardStdin(from descriptor: Int32, observe: (@Sendable (_ bytes: [UInt8], _ late: Bool) -> Void)? = nil) {
        Thread.detachNewThread { [self] in
            var buffer = [UInt8](repeating: 0, count: 65536)
            var late = true
            while true {
                if observe != nil && late {
                    var waiting = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                    if poll(&waiting, 1, Self.quietMilliseconds) == 0 {
                        late = false
                    }
                }
                let count = read(descriptor, &buffer, buffer.count)
                if count < 0 && errno == EINTR {
                    continue
                }
                if count <= 0 {
                    break
                }
                let bytes = Array(buffer[0..<count])
                observe?(bytes, late)
                let began = ContinuousClock.now
                do {
                    try sendStdin(bytes)
                } catch {
                    return
                }
                if count >= Self.fullRead || ContinuousClock.now - began > Self.stallLimit {
                    late = true
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

/// Reads a connection's frames into memory as they arrive, on a thread of its own, for
/// `ExecSession.run` to take one by one. The guest's acknowledgments of input are not queued:
/// they make room at once, so input is never held up by output nobody takes. A guest that
/// sends more than `limit` bytes ahead of what was taken broke its window; the run ends then,
/// and nothing more is read. Notices are no part of a window: a few are kept and the rest
/// dropped, as `run` drops those it has too many of.
private final class FrameReader: @unchecked Sendable {
    private let channel: FrameChannel
    private let lock = NSLock()
    private let wake = DispatchSemaphore(value: 0)
    private let done = DispatchSemaphore(value: 0)
    private var frames: [Frame] = []
    private var held = 0
    private var notices = 0
    /// Set when nothing more will be read: nil for the connection's end.
    private var ended = false
    private var failure: (any Error)?

    init(channel: FrameChannel, inputGate: CreditGate?, limit: Int) {
        self.channel = channel
        Thread.detachNewThread { [self] in
            read(inputGate: inputGate, limit: limit)
            done.signal()
        }
    }

    private func read(inputGate: CreditGate?, limit: Int) {
        var problem: (any Error)?
        while true {
            let frame: Frame?
            do {
                frame = try channel.receive()
            } catch {
                problem = error
                break
            }
            guard let frame else {
                break
            }
            if frame.type == .stdinAck {
                guard let inputGate, let count = GuestFlow.acknowledged(frame.payload) else {
                    problem = GuestProtocolError.malformed("unexpected \(frame.type) frame from the guest")
                    break
                }
                inputGate.add(count)
                continue
            }
            let last = frame.type == .exit
            lock.lock()
            if frame.type == .notice {
                // Advice, which a handler that waits for hours must not turn into a failure.
                guard notices < ExecSession.maxNotices, frame.payload.count <= ExecSession.maxNoticeBytes else {
                    lock.unlock()
                    continue
                }
                notices += 1
            } else {
                held += GuestFlow.cost(payload: frame.payload.count)
            }
            let over = held > limit
            if !over {
                frames.append(frame)
                // With the report, so `finish` knows that nothing is being read any more.
                ended = last
            }
            lock.unlock()
            if over {
                problem = GuestProtocolError.malformed("the guest sent more output than the window it was given")
                break
            }
            wake.signal()
            if last {
                // The last frame of a run; whatever follows is not read.
                return
            }
        }
        lock.lock()
        ended = true
        failure = problem
        lock.unlock()
        wake.signal()
    }

    /// The next frame, waiting for one; nil when the guest closed the connection. Frames read
    /// before a failure are given first.
    func next() throws -> Frame? {
        while true {
            lock.lock()
            if !frames.isEmpty {
                let frame = frames.removeFirst()
                if frame.type == .notice {
                    notices -= 1
                } else {
                    held -= GuestFlow.cost(payload: frame.payload.count)
                }
                lock.unlock()
                return frame
            }
            if ended {
                let failure = self.failure
                lock.unlock()
                if let failure {
                    throw failure
                }
                return nil
            }
            lock.unlock()
            wake.wait()
        }
    }

    /// Ends the reading and waits until the thread has left the descriptor. After the exit
    /// report or the connection's end it has already; otherwise the connection is shut down,
    /// which is what a run that ends early leaves behind anyway.
    func finish() {
        lock.lock()
        let reading = !ended
        lock.unlock()
        if reading {
            channel.shutdownBoth()
        }
        done.wait()
    }
}
