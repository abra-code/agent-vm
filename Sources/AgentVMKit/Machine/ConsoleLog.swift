// Sources/AgentVMKit/Machine/ConsoleLog.swift
//
// What a Linux guest prints on its console, kept in a file: a guest that does not come up has
// nothing else to show. The guest decides how much it prints, so the file is bounded in size
// and in rate, and the guest can never wait on it:
//
// - The machine's serial port writes into a pipe; a thread here reads it and appends to
//   `console.log`. At `limit` bytes that file becomes `console.log.1` and a new one starts:
//   two files at most.
// - Past `bytesPerMinute` within a minute, what comes is dropped until the minute is over, and
//   one line says how much. A guest that prints at full speed then costs a read loop, not an
//   endless rewriting of two files.
// - The reader never stops reading while the log is open. A write that fails (a full disk, a
//   deleted folder) drops the bytes.
//
// The content is the guest's: print it only through `tail`, which makes it printable.

import Darwin
import Foundation

final class ConsoleLog: @unchecked Sendable {
    static let defaultLimit = 1 << 20
    static let defaultBytesPerMinute = 4 << 20

    /// The pipe's write end, for the machine's serial port. Valid until `close`.
    let writeHandle: FileHandle

    private let url: URL
    private let limit: Int
    private let bytesPerMinute: Int
    private let window: TimeInterval
    private let readEnd: Int32
    private let writeEnd: Int32
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var closing = false
    private var closed = false

    // The reader thread's own.
    private var file: Int32 = -1
    private var written = 0
    private var windowStart = ConsoleLog.now()
    private var windowBytes = 0
    private var dropped = 0

    /// Starts a new `console.log` at `url`; the one of the last boot, if any, is kept as
    /// `console.log.1`. `window` is the "minute", shorter in a test.
    init(url: URL, limit: Int = ConsoleLog.defaultLimit, bytesPerMinute: Int = ConsoleLog.defaultBytesPerMinute, window: TimeInterval = 60) throws {
        self.url = url
        self.limit = max(1, limit)
        self.bytesPerMinute = max(1, bytesPerMinute)
        self.window = window
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else {
            throw AgentVMError.system(operation: "create a pipe for \(url.path)", code: errno)
        }
        for end in ends {
            _ = fcntl(end, F_SETFD, FD_CLOEXEC)
        }
        // The machine writes from another process; a write after this log closed must fail
        // there, not end that process with a signal.
        _ = fcntl(ends[1], F_SETNOSIGPIPE, 1)
        readEnd = ends[0]
        writeEnd = ends[1]
        writeHandle = FileHandle(fileDescriptor: ends[1], closeOnDealloc: false)
        // Whatever is there, a link someone left included (rename moves the link itself).
        _ = rename(url.path, Self.previous(url).path)
        file = Self.open(url)
        guard file >= 0 else {
            let code = errno
            Darwin.close(ends[0])
            Darwin.close(ends[1])
            throw AgentVMError.system(operation: "open \(url.path)", code: code)
        }
        let thread = Thread { [self] in
            read()
            done.signal()
        }
        thread.name = "console-log"
        thread.start()
    }

    deinit {
        close()
    }

    static func previous(_ url: URL) -> URL {
        return URL(fileURLWithPath: url.path + ".1")
    }

    /// Seconds on a clock that is never set back, for the minute's budget.
    private static func now() -> TimeInterval {
        return TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1e9
    }

    /// Stops reading and closes the pipe, once what is in it has been written. Call it after
    /// the machine stopped: a machine still running would find its console closed. It must be
    /// called: a log that is only let go keeps its thread, its pipe and its file open.
    func close() {
        lock.lock()
        let first = !closed
        closed = true
        closing = true
        lock.unlock()
        guard first else {
            return
        }
        done.wait()
        Darwin.close(writeEnd)
        Darwin.close(readEnd)
    }

    private var isClosing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closing
    }

    /// How much is still read from the pipe once the log is closing.
    static let drainLimit = 1 << 20

    /// The reader thread: until the log is closed and the pipe is empty.
    private func read() {
        let size = 64 << 10
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 1)
        defer { buffer.deallocate() }
        // Once the log is closing, what is in the pipe is still written, but no more than a
        // pipe holds: a machine that did not stop and keeps printing must not hold `close`.
        var drained = 0
        while true {
            let closing = isClosing
            var descriptor = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, closing ? 0 : 200)
            if ready < 0 && errno != EINTR && errno != EAGAIN {
                break
            }
            if ready <= 0 {
                if closing {
                    break
                }
                endWindowIfOver()
                continue
            }
            let count = Darwin.read(readEnd, buffer, size)
            if count < 0 && (errno == EINTR || errno == EAGAIN) {
                continue
            }
            // No writer is left (this log holds one until `close`, so: it is closing).
            if count <= 0 {
                break
            }
            take(UnsafeRawBufferPointer(start: buffer, count: count))
            if closing {
                drained += count
                if drained >= Self.drainLimit {
                    break
                }
            }
        }
        noteDropped()
        if file >= 0 {
            Darwin.close(file)
            file = -1
        }
    }

    /// One block from the guest: written while the minute's budget lasts, else counted.
    private func take(_ bytes: UnsafeRawBufferPointer) {
        endWindowIfOver()
        let allowed = max(0, min(bytes.count, bytesPerMinute - windowBytes))
        windowBytes += allowed
        dropped += bytes.count - allowed
        if allowed > 0 {
            append(UnsafeRawBufferPointer(rebasing: bytes[0..<allowed]))
        }
    }

    private func endWindowIfOver() {
        guard Self.now() - windowStart >= window else {
            return
        }
        noteDropped()
        windowStart = Self.now()
        windowBytes = 0
    }

    /// The one line that says what was not kept.
    private func noteDropped() {
        guard dropped > 0 else {
            return
        }
        let line = "\n[agent-vm: \(dropped) bytes of console output were dropped: the guest printed more than \(bytesPerMinute) bytes within \(Int(window)) s]\n"
        dropped = 0
        Array(line.utf8).withUnsafeBytes { append($0) }
    }

    /// Appends to the current file, starting the next one at the limit. Nothing here can fail
    /// in a way the caller hears of: what cannot be written is dropped.
    private func append(_ bytes: UnsafeRawBufferPointer) {
        var rest = bytes
        while !rest.isEmpty {
            if written >= limit {
                rotate()
            }
            if file < 0 {
                // The folder may be back by now.
                file = Self.open(url)
                written = 0
                if file < 0 {
                    return
                }
            }
            let part = min(rest.count, limit - written)
            let count = Darwin.write(file, rest.baseAddress, part)
            if count < 0 && errno == EINTR {
                continue
            }
            // The file stays open: opening it again would empty it, and what a guest printed
            // before the disk filled up is the part worth keeping.
            if count <= 0 {
                return
            }
            written += count
            rest = UnsafeRawBufferPointer(rebasing: rest[count...])
        }
    }

    private func rotate() {
        if file >= 0 {
            Darwin.close(file)
            file = -1
        }
        _ = rename(url.path, Self.previous(url).path)
        file = Self.open(url)
        written = 0
    }

    /// A new, empty file that only this user reads; never through a link someone left there.
    private static func open(_ url: URL) -> Int32 {
        return Darwin.open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
    }

    /// How much of the end of a file `tail` reads.
    static let tailBytes = 64 << 10

    /// The last `lines` lines of the log at `url` (with what is left of the file before it,
    /// when the current one is short), made printable; empty when there is none.
    static func tail(of url: URL, lines: Int) -> String {
        // "\r\n" is one Character in Swift: made "\n" first, so lines split and count right.
        func normalized(_ text: String) -> String {
            return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        }
        var text = normalized(end(of: url))
        if text.split(separator: "\n", omittingEmptySubsequences: true).count < lines {
            text = normalized(end(of: previous(url))) + text
        }
        let all = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { Printable.line(String($0), limit: 300) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return all.suffix(max(0, lines)).joined(separator: "\n")
    }

    private static func end(of url: URL) -> String {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            return ""
        }
        defer { Darwin.close(descriptor) }
        let size = lseek(descriptor, 0, SEEK_END)
        guard size > 0 else {
            return ""
        }
        let count = Int(min(size, off_t(tailBytes)))
        var bytes = [UInt8](repeating: 0, count: count)
        let got = pread(descriptor, &bytes, count, size - off_t(count))
        guard got > 0 else {
            return ""
        }
        return String(decoding: bytes[0..<got], as: UTF8.self)
    }
}
