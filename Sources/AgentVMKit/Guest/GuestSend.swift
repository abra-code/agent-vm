// Sources/AgentVMKit/Guest/GuestSend.swift
//
// Sends a file or folder from this Mac into the guest account's Downloads folder (the Send
// button of a box's or an image's window). ditto packs it on the Mac, keeping extended
// attributes, resource forks and bundles; the archive goes to the guest as a program's stdin
// through the guest daemon; and a short script, run as the account, unpacks it with ditto into
// a folder in the account's caches, then moves it into Downloads under a free name ("Name
// 2.ext"). So nothing in Downloads is overwritten, and a half-sent item never shows there.
// Only exec is used, so it works with every guest daemon.
//
// Nothing here lists Downloads: macOS protects reading its contents, and in an image without
// Full Disk Access that asks on the guest's screen (measured). Making, testing and moving
// entries in it does not ask.
//
// ditto -x reports success on an archive cut short, so the guest's stdin is ended only after
// the Mac's ditto has finished well. A send that is stopped or fails closes the connection
// instead: the guest daemon hangs up the script, which removes what it unpacked.

import Darwin
import Foundation

public final class GuestSend: @unchecked Sendable {
    public enum Event: Sendable {
        /// Archive bytes sent so far, and about how many there are in all (the size of the
        /// files; the archive's own headers add a little).
        case progress(sent: Int64, total: Int64)
        /// The guest waits on something shown on its screen (a privacy prompt for Downloads,
        /// in an image without Full Disk Access): the notice's words, "the Downloads folder".
        case waiting(String)
    }

    /// A send that did not arrive, with why, for a person.
    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let message: String
        public var description: String { message }

        public init(message: String) {
            self.message = message
        }
    }

    public let source: URL
    /// Tests only: the guest program's environment on top of the account's (a scratch HOME).
    var environment: [String: String]?

    private let lock = NSLock()
    private var canceled = false
    private var descriptor: Int32 = -1
    private var process: Process?

    /// How often progress is reported, at most.
    static let progressInterval: Duration = .milliseconds(200)
    /// Guest output kept for messages; the script prints one name.
    static let maxOutput = 4096
    static let chunkSize = GuestProtocol.maxPayload

    public init(source: URL) {
        self.source = source
    }

    public var isCanceled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return canceled
    }

    /// Stops the send from any thread: the Mac's ditto ends, and the connection is closed, so
    /// the guest removes what it unpacked. `run` then throws `Failure` "stopped".
    public func cancel() {
        // Under the lock: run clears the descriptor under it before returning, so the caller
        // cannot close it (and the number go to another connection) while this shuts it down.
        lock.lock()
        defer { lock.unlock() }
        canceled = true
        abort(process: process, descriptor: descriptor)
    }

    private func abort(process: Process?, descriptor: Int32) {
        if let process, process.isRunning {
            process.terminate()
        }
        if descriptor >= 0 {
            // Unblocks a send stuck behind input the guest does not read (a program waiting on
            // a prompt), and the guest daemon sees the host gone.
            shutdown(descriptor, SHUT_RDWR)
        }
    }

    /// Sends `source` over `descriptor`, a fresh connection to the guest daemon that the caller
    /// closes after this returns; returns the name it got in Downloads. Blocking: run it off the
    /// main actor. `event` is called from other threads.
    public func run(descriptor: Int32, event: @escaping @Sendable (Event) -> Void) throws -> String {
        // ditto follows a link given as its argument and names the archive's item after the
        // link's target, so a link is sent as its target, under the target's name.
        guard let resolved = realpath(source.path, nil) else {
            throw Failure(message: "cannot read \(source.path): \(String(cString: strerror(errno)))")
        }
        let path = String(cString: resolved)
        free(resolved)
        guard path != "/" else {
            throw Failure(message: "the startup disk cannot be sent; choose the files or folders on it")
        }
        var info = stat()
        guard stat(path, &info) == 0 else {
            throw Failure(message: "cannot read \(source.path): \(String(cString: strerror(errno)))")
        }
        let isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
        let name = (path as NSString).lastPathComponent
        let total = isDirectory ? Self.size(ofFolder: URL(fileURLWithPath: path)) : Int64(info.st_size)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = Self.archiveArguments(path, isDirectory: isDirectory)
        let archive = Pipe()
        let errors = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = archive
        process.standardError = errors
        let dittoErrors = OutputTail(limit: Self.maxOutput)
        errors.fileHandleForReading.readabilityHandler = { handle in
            dittoErrors.append(handle.availableData)
        }
        defer { errors.fileHandleForReading.readabilityHandler = nil }

        lock.lock()
        guard !canceled else {
            lock.unlock()
            throw Failure(message: "stopped")
        }
        self.descriptor = descriptor
        self.process = process
        lock.unlock()
        defer {
            lock.lock()
            self.descriptor = -1
            self.process = nil
            lock.unlock()
        }

        let session: ExecSession
        do {
            session = try ExecSession(descriptor: descriptor, request: request(name: name))
        } catch {
            throw isCanceled ? Failure(message: "stopped") : error
        }
        do {
            try process.run()
        } catch {
            abort(process: nil, descriptor: descriptor)
            throw Failure(message: "cannot run ditto on this Mac: \(error)")
        }
        // Process.run closed this side's copy of the write end, so the read below ends when ditto
        // does. Never close it again: FileHandle does not know, and the number may already be
        // another thread's descriptor (measured; that cut other connections in tests).

        // The writer: the archive to the guest's stdin; stdin end only after ditto did well.
        let writer = Writer()
        let reading = archive.fileHandleForReading.fileDescriptor
        Thread.detachNewThread { [self] in
            defer { writer.done.signal() }
            var buffer = [UInt8](repeating: 0, count: Self.chunkSize)
            var sent: Int64 = 0
            let clock = ContinuousClock()
            var reported = clock.now - Self.progressInterval
            event(.progress(sent: 0, total: total))
            while true {
                let count = read(reading, &buffer, buffer.count)
                if count < 0 && errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    break
                }
                do {
                    try session.sendStdin(Array(buffer[0..<count]))
                } catch {
                    abort(process: process, descriptor: descriptor)
                    return
                }
                sent += Int64(count)
                if clock.now - reported >= Self.progressInterval {
                    reported = clock.now
                    event(.progress(sent: sent, total: total))
                }
            }
            process.waitUntilExit()
            writer.dittoStatus = process.terminationReason == .exit ? process.terminationStatus : 128 + process.terminationStatus
            guard writer.dittoStatus == 0, !isCanceled else {
                abort(process: nil, descriptor: descriptor)
                return
            }
            event(.progress(sent: sent, total: max(total, sent)))
            // A failure here is the guest gone, which session.run reports.
            try? session.sendStdinEnd()
            writer.ended = true
        }

        let output = OutputTail(limit: Self.maxOutput)
        let guestErrors = OutputTail(limit: Self.maxOutput)
        let report: ExitReport?
        var disconnected: Error?
        do {
            report = try session.run(stdout: { output.append(Data($0)) }, stderr: { guestErrors.append(Data($0)) }, notice: { notice in
                event(.waiting(notice.serviceDescription))
            })
        } catch {
            report = nil
            disconnected = error
        }
        // The guest ended first (it could not make its folder, say): end ditto, so the writer's
        // read ends, and wait for the writer before the caller closes the descriptor. ditto's
        // status then says nothing about this Mac: the guest's report is the reason.
        let stoppedDitto = process.isRunning
        if stoppedDitto {
            process.terminate()
        }
        writer.done.wait()
        process.waitUntilExit()
        // What the handler has not delivered yet: ditto has exited, so this read ends.
        errors.fileHandleForReading.readabilityHandler = nil
        dittoErrors.append(errors.fileHandleForReading.readDataToEndOfFile())

        if isCanceled {
            // Once the whole archive was sent, the guest may have moved the item in before the
            // hang-up reached it.
            throw Failure(message: writer.ended ? "stopped after the last byte was sent: \(name) may be in Downloads" : "stopped")
        }
        if let status = writer.dittoStatus, status != 0, !(stoppedDitto && report != nil) {
            let reason = dittoErrors.text.isEmpty ? "ditto exited with status \(status)" : dittoErrors.text
            throw Failure(message: "cannot read \(name) on this Mac: \(reason)")
        }
        guard let report else {
            throw Failure(message: "the box closed the connection: \(disconnected.map { "\($0)" } ?? "no answer")")
        }
        guard report == ExitReport(status: 0) else {
            let reason = guestErrors.text.isEmpty ? "status \(report.shellStatus)" : guestErrors.text
            throw Failure(message: "the box could not unpack \(name): \(reason)")
        }
        let received = output.text
        guard !received.isEmpty, !received.contains("/") else {
            throw Failure(message: "the box did not say where \(name) went")
        }
        return received
    }

    /// Shared between `run` and its writer thread; each field is written before `done` is
    /// signaled and read after it is waited on.
    private final class Writer: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        var dittoStatus: Int32?
        /// The guest's stdin was ended: the whole archive went.
        var ended = false
    }

    /// The last `limit` bytes of a stream, as trimmed text.
    private final class OutputTail: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private let limit: Int

        init(limit: Int) {
            self.limit = limit
        }

        func append(_ more: Data) {
            lock.lock()
            defer { lock.unlock() }
            data.append(more)
            if data.count > limit {
                data = data.suffix(limit)
            }
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// A size for progress text: "1.23 GB", and "0 bytes" rather than "Zero KB".
    public static func byteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }

    /// ditto's arguments to archive `path` to stdout. A folder keeps its own name in the
    /// archive (--keepParent); for a file that option would add the folder it is in.
    static func archiveArguments(_ path: String, isDirectory: Bool) -> [String] {
        return ["-c"] + (isDirectory ? ["--keepParent"] : []) + [path, "-"]
    }

    /// The size of the files in a folder, not following links (as ditto does not).
    static func size(ofFolder url: URL) -> Int64 {
        guard let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [], errorHandler: { _, _ in true }) else {
            return 0
        }
        var total: Int64 = 0
        for case let item as URL in items {
            if let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    /// `name` split for a free name: "Setup.pkg" is tried as "Setup 2.pkg", "Setup 3.pkg" and so
    /// on. Only a short extension with a letter in it counts ("v1.2" becomes "v1.2 2").
    static func nameParts(_ name: String) -> (stem: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
            return (name, "")
        }
        let ext = name[name.index(after: dot)...]
        guard (1...8).contains(ext.count), ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }), ext.contains(where: \.isLetter) else {
            return (name, "")
        }
        return (String(name[..<dot]), "." + ext)
    }

    /// The guest side, run as the box account with the item's name, stem and extension as $1 to
    /// $3. It prints the name the item got in Downloads. Folders a stopped send left in the
    /// caches (the guest daemon kills what is still running 3 seconds after the hang-up) are
    /// removed once an hour old.
    static let receiveScript = """
        dir="$HOME/Downloads"
        caches="$HOME/Library/Caches/agent-vm-receiving"
        /bin/mkdir -p "$dir" "$caches"
        status=$?
        if [ "$status" -ne 0 ]; then exit "$status"; fi
        /usr/bin/find "$caches" -mindepth 1 -maxdepth 1 -mmin +60 -exec /bin/rm -rf {} + 2>/dev/null
        staging=""
        trap 'if [ -n "$staging" ]; then /bin/rm -rf "$staging"; fi; exit 129' HUP
        trap 'if [ -n "$staging" ]; then /bin/rm -rf "$staging"; fi; exit 143' TERM
        staging="$(/usr/bin/mktemp -d "$caches/XXXXXX")"
        status=$?
        if [ "$status" -ne 0 ]; then exit "$status"; fi
        /usr/bin/ditto -x - "$staging"
        status=$?
        if [ "$status" -ne 0 ]; then /bin/rm -rf "$staging"; exit "$status"; fi
        if [ ! -e "$staging/$1" ] && [ ! -L "$staging/$1" ]; then
            echo "the archive did not hold $1" >&2
            /bin/rm -rf "$staging"
            exit 1
        fi
        target="$1"
        n=2
        while [ -e "$dir/$target" ] || [ -L "$dir/$target" ]; do
            target="$2 $n$3"
            n=$((n + 1))
        done
        /bin/mv -n "$staging/$1" "$dir/$target"
        status=$?
        if [ "$status" -ne 0 ] || [ -e "$staging/$1" ] || [ -L "$staging/$1" ]; then
            echo "cannot move $1 into $dir" >&2
            /bin/rm -rf "$staging"
            exit 1
        fi
        /bin/rmdir "$staging"
        printf '%s\\n' "$target"
        """

    func request(name: String) -> GuestRequest {
        let parts = Self.nameParts(name)
        // The account's own (the daemon's default), so the item is theirs, in their session.
        return GuestRequest(op: .exec, argv: ["/bin/sh", "-c", Self.receiveScript, "sh", name, parts.stem, parts.ext], env: environment, notices: true)
    }
}
