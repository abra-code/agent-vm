// Sources/agent-vm/SendCommand.swift
//
// `agent-vm box send <box> <path>...`: copies files or folders from this Mac into the Downloads
// folder of a running box's account, as the Send button of its window does (GuestSend). Each
// item goes on its own guest connection, lent by the box's supervisor as for exec.

import AgentVMKit
import ArgumentParser
import Darwin
import Foundation

extension BoxCommand {
    struct Send: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Copy files or folders from this Mac into a running box's Downloads folder.",
            discussion: """
                Each path goes into the box account's Downloads folder, whole (folders and \
                bundles with everything in them, extended attributes included). Nothing there is \
                replaced: a name in use gets a number ("Setup 2.pkg"), and the name each item \
                got is printed. An item appears only once it is complete; SIGINT or SIGTERM \
                stops the send and sends no further items, and leaves nothing of the item under \
                way in the box (unless all of it was sent already: the message then says it may \
                be in Downloads). The box must be running. With --json, progress events go to \
                stderr (step send) and the result to stdout, also after a stop or a failure: \
                [{"source": ..., "name": ...}], one entry for each item that arrived.
                """)

        @Argument(help: "The running box.")
        var name: String

        @Argument(help: "Files or folders on this Mac.", completion: .file())
        var paths: [String]

        @OptionGroup var options: StoreOptions

        struct Sent: Encodable {
            /// The path on this Mac, as given.
            var source: String
            /// The name it got in Downloads.
            var name: String
        }

        func run() throws {
            let box = try options.boxStore.box(named: name)
            guard box.isRunning else {
                throw AgentVMError.boxNotRunning(box.name)
            }
            // All checked first: a typo in the last path must not leave the first ones sent.
            let sources = try paths.map { path -> URL in
                let url = URL(fileURLWithPath: path).standardizedFileURL
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw AgentVMError.system(operation: "find \(path)", code: ENOENT)
                }
                guard url.resolvingSymlinksInPath().path != "/" else {
                    throw GuestSend.Failure(message: "the startup disk cannot be sent; name the files or folders on it")
                }
                return url
            }
            let json = options.json
            let signals = Self.watchSignals()
            defer { signals.stop() }
            var sent: [Sent] = []
            // With --json, what arrived before a stop or a failure is still the result.
            defer {
                if json {
                    try? Output.json(sent)
                }
            }
            for (index, source) in sources.enumerated() {
                let sender = GuestSend(source: source)
                signals.current.set(sender)
                let item = source.lastPathComponent
                let what = sources.count > 1 ? "\(item) (\(index + 1) of \(sources.count))" : item
                let meter = SendMeter(box: box.name, what: what, index: index + 1, count: sources.count, json: json)
                if let signal = signals.signal {
                    meter.say(.notice, "Stopped before sending \(what): \(AgentVMError.canceled(signal: signal))")
                    throw ExitCode(128 + signal)
                }
                meter.begin()
                let received: String
                do {
                    let (control, guest, _) = try ControlClient.openGuest(path: box.controlSocketPath)
                    defer {
                        close(guest)
                        close(control)
                    }
                    received = try sender.run(descriptor: guest) { event in
                        meter.update(event)
                    }
                } catch {
                    meter.end()
                    signals.current.set(nil)
                    if let signal = signals.signal {
                        let detail = (error as? GuestSend.Failure)?.message == "stopped" ? "" : " (\(error))"
                        meter.say(.notice, "Stopped sending \(what): \(AgentVMError.canceled(signal: signal))\(detail)")
                        throw ExitCode(128 + signal)
                    }
                    // GuestSend's failures say where it failed (on this Mac, in the box).
                    throw error
                }
                signals.current.set(nil)
                meter.end()
                sent.append(Sent(source: paths[index], name: received))
                meter.say(.log, "Sent \(what) to Downloads\(received == item ? "" : " as \(received)")")
            }
        }

        /// The send under way, for the signal handler.
        final class Current: @unchecked Sendable {
            private let lock = NSLock()
            private var sender: GuestSend?
            private var stopped = false

            func set(_ sender: GuestSend?) {
                lock.lock()
                self.sender = sender
                let stop = stopped
                lock.unlock()
                if stop {
                    sender?.cancel()
                }
            }

            func stop() {
                lock.lock()
                stopped = true
                let sender = self.sender
                lock.unlock()
                sender?.cancel()
            }
        }

        final class Signals: @unchecked Sendable {
            let current = Current()
            private let lock = NSLock()
            private var received: Int32?
            var sources: [DispatchSourceSignal] = []

            var signal: Int32? {
                lock.lock()
                defer { lock.unlock() }
                return received
            }

            func receive(_ signal: Int32) {
                lock.lock()
                if received == nil {
                    received = signal
                }
                lock.unlock()
                current.stop()
            }

            func stop() {
                for source in sources {
                    source.cancel()
                }
                for signalNumber in [SIGINT, SIGTERM] {
                    Darwin.signal(signalNumber, SIG_DFL)
                }
            }
        }

        /// SIGINT and SIGTERM stop the send; watched off the main queue, which `run` blocks.
        static func watchSignals() -> Signals {
            let signals = Signals()
            for signalNumber in [SIGINT, SIGTERM] {
                Darwin.signal(signalNumber, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
                source.setEventHandler {
                    signals.receive(signalNumber)
                }
                source.resume()
                signals.sources.append(source)
            }
            return signals
        }
    }
}

/// A send's progress: with --json, events on stderr (one per whole percent); on a terminal, one
/// line redrawn in place; otherwise only the lines `say` writes.
final class SendMeter: @unchecked Sendable {
    private let box: String
    private let what: String
    private let index: Int
    private let count: Int
    private let json: Bool
    private let live: Bool
    private let lock = NSLock()
    /// 0 at first: begin() already said 0%.
    private var percent = 0
    private var lineOpen = false
    private var waitingSaid = false

    init(box: String, what: String, index: Int, count: Int, json: Bool) {
        self.box = box
        self.what = what
        self.index = index
        self.count = count
        self.json = json
        let term = ProcessInfo.processInfo.environment["TERM"] ?? ""
        live = !json && isatty(STDOUT_FILENO) == 1 && !term.isEmpty && term != "dumb"
    }

    func begin() {
        if json {
            emit(ProgressEvent(.progress, "Sending \(what)", step: "send", fraction: 0, index: index, count: count, box: box))
        }
    }

    func update(_ event: GuestSend.Event) {
        switch event {
        case let .progress(sent, total):
            let fraction = total > 0 ? min(1, Double(sent) / Double(total)) : 0
            let now = Int(fraction * 100)
            lock.lock()
            let changed = now != percent
            percent = now
            lock.unlock()
            guard changed else {
                return
            }
            let text = "Sending \(what): \(GuestSend.byteCount(sent)) of \(GuestSend.byteCount(max(total, sent))) (\(now)%)"
            if json {
                emit(ProgressEvent(.progress, text, step: "send", fraction: fraction, index: index, count: count, box: box))
            } else if live {
                draw(text)
            }
        case let .waiting(service):
            lock.lock()
            let first = !waitingSaid
            waitingSaid = true
            lock.unlock()
            if first {
                say(.notice, "Sending \(what) waits for access to \(service): answer the prompt on the box's screen (agent-vm box view \(box) --interactive)")
            }
        }
    }

    /// The line is over: erased, so what follows starts on a clean line.
    func end() {
        lock.lock()
        defer { lock.unlock() }
        if lineOpen {
            write("\r\u{1B}[K")
            lineOpen = false
        }
    }

    /// A line of its own: a log line on stdout (an event with --json), a notice on stderr
    /// ("note: ...").
    func say(_ kind: ProgressEvent.Kind, _ text: String) {
        if json {
            emit(ProgressEvent(kind, text, box: box))
            return
        }
        end()
        if kind == .notice {
            Stderr.write(("note: " + text + "\n"))
        } else {
            print(text)
            fflush(stdout)
        }
    }

    private func emit(_ event: ProgressEvent) {
        Events.emit(event, json: true)
    }

    private func draw(_ text: String) {
        var size = winsize()
        let columns = ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 && size.ws_col > 0 ? Int(size.ws_col) : 80
        lock.lock()
        defer { lock.unlock() }
        // Short enough never to wrap, which would break the redraw.
        write("\r" + String(Printable.line(text).prefix(max(1, columns - 1))) + "\u{1B}[K")
        lineOpen = true
    }

    private func write(_ text: String) {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count) }
            if written < 0 && errno == EINTR {
                continue
            }
            guard written > 0 else {
                return
            }
            offset += written
        }
    }
}
