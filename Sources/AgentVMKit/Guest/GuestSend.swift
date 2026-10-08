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
// For a Linux box the archive is tar: the Mac's tar packs the one item, leaving out what means
// nothing there (extended attributes, access control lists, file flags, the "._" files that
// carry them), and the guest's tar unpacks it as the account, without restoring owners, into a
// folder under ~/.cache. Everything else is the same.
//
// Nothing here lists Downloads: macOS protects reading its contents, and in an image without
// Full Disk Access that asks on the guest's screen (measured). Making, testing and moving
// entries in it does not ask.
//
// ditto -x reports success on an archive cut short, and so does tar -x when the cut falls
// between two entries (measured), so the guest's stdin is ended only after the Mac's packer
// has finished well. A send that is stopped or fails closes the connection instead: the guest
// daemon hangs up the script, which removes what it unpacked. ditto -x reads to the end of its
// input; tar -x is done at the archive's end mark, which the Mac's tar writes even after a
// file it could not read. So for a Linux guest the Mac sends a few words after the archive
// once its tar finished well, and the script moves nothing that is not followed by them.

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
    /// The system the box runs: it decides the packer on the Mac and the script in the guest.
    public let guest: GuestKind
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

    public init(source: URL, guest: GuestKind = .macOS) {
        self.source = source
        self.guest = guest
    }

    /// The program that packs the item on this Mac, for messages and to run.
    static func packer(for guest: GuestKind) -> (name: String, path: String) {
        switch guest {
        case .macOS:
            return ("ditto", "/usr/bin/ditto")
        case .linux:
            return ("tar", "/usr/bin/tar")
        }
    }

    public var isCanceled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return canceled
    }

    /// Stops the send from any thread: the Mac's packer ends, and the connection is closed, so
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
        // The box answers with the name the item got, on a line of its own: a name with a
        // line end or another control character could not be told from a wrong answer, and
        // would be in Downloads by the time the Mac said the send failed.
        guard Printable.line(name) == name else {
            throw Failure(message: "cannot send \(Printable.line(name)): its name has a line end or another control character; rename it first")
        }
        let total = isDirectory ? Self.size(ofFolder: URL(fileURLWithPath: path)) : Int64(info.st_size)

        let packer = Self.packer(for: guest)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: packer.path)
        process.arguments = Self.archiveArguments(path, isDirectory: isDirectory, guest: guest)
        if guest == .linux {
            // A small fixed environment: what tar reads from it (TAR_OPTIONS and its like) is
            // not the caller's to set, and COPYFILE_DISABLE keeps "._" files out of the archive.
            process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "en_US.UTF-8", "COPYFILE_DISABLE": "1"]
        }
        let archive = Pipe()
        let errors = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = archive
        process.standardError = errors
        let packerErrors = OutputTail(limit: Self.maxOutput)
        errors.fileHandleForReading.readabilityHandler = { handle in
            packerErrors.append(handle.availableData)
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
            throw Failure(message: "cannot run \(packer.name) on this Mac: \(error)")
        }
        // Process.run closed this side's copy of the write end, so the read below ends when the
        // packer does. Never close it again: FileHandle does not know, and the number may already be
        // another thread's descriptor (measured; that cut other connections in tests).

        // The writer: the archive to the guest's stdin; stdin end only after the packer did well.
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
                let delivered: Bool
                do {
                    delivered = try session.sendInput(Array(buffer[0..<count]))
                } catch {
                    abort(process: process, descriptor: descriptor)
                    return
                }
                guard delivered else {
                    // The guest ended first (its script failed, say). No shutdown here: it would
                    // drop the guest's report, which run() reads.
                    if process.isRunning {
                        process.terminate()
                    }
                    return
                }
                sent += Int64(count)
                if clock.now - reported >= Self.progressInterval {
                    reported = clock.now
                    event(.progress(sent: sent, total: total))
                }
            }
            process.waitUntilExit()
            writer.packerStatus = process.terminationReason == .exit ? process.terminationStatus : 128 + process.terminationStatus
            guard writer.packerStatus == 0, !isCanceled else {
                abort(process: nil, descriptor: descriptor)
                return
            }
            event(.progress(sent: sent, total: max(total, sent)))
            // For a Linux guest, the word that says the archive is whole (see `completeMark`).
            // The guest gone here is for session.run to report.
            if guest == .linux {
                _ = try? session.sendInput(Array(Self.completeMark.utf8))
            }
            _ = try? session.endInput()
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
        // The guest ended first (it could not make its folder, say): end the packer, so the
        // writer's read ends, and wait for the writer before the caller closes the descriptor.
        // The packer's status then says nothing about this Mac: the guest's report is the reason.
        let stoppedPacker = process.isRunning
        if stoppedPacker {
            process.terminate()
        }
        writer.done.wait()
        process.waitUntilExit()
        // What the handler has not delivered yet: the packer has exited, so this read ends.
        errors.fileHandleForReading.readabilityHandler = nil
        packerErrors.append(errors.fileHandleForReading.readDataToEndOfFile())

        if isCanceled {
            // Once the whole archive was sent, the guest may have moved the item in before the
            // hang-up reached it.
            throw Failure(message: writer.ended ? "stopped after the last byte was sent: \(name) may be in Downloads" : "stopped")
        }
        if let status = writer.packerStatus, status != 0, !(stoppedPacker && report != nil) {
            let reason = packerErrors.text.isEmpty ? "\(packer.name) exited with status \(status)" : packerErrors.text
            throw Failure(message: "cannot read \(name) on this Mac: \(reason)")
        }
        guard let report else {
            throw Failure(message: "the box closed the connection: \(disconnected.map { "\($0)" } ?? "no answer")")
        }
        guard report == ExitReport(status: 0) else {
            let reason = guestErrors.text.isEmpty ? "status \(report.shellStatus)" : Printable.lines(guestErrors.text, limit: 2000)
            throw Failure(message: "the box could not unpack \(name): \(reason)")
        }
        let received = output.text
        // A file name, as the box says it: no folder, no line end or control character, and no
        // longer than a name can be.
        guard !received.isEmpty, received != ".", received != "..", !received.contains("/"), received.utf8.count <= 255,
              Printable.line(received) == received else {
            throw Failure(message: "the box did not say where \(name) went")
        }
        return received
    }

    /// Shared between `run` and its writer thread; each field is written before `done` is
    /// signaled and read after it is waited on.
    private final class Writer: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        var packerStatus: Int32?
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

    /// The packer's arguments to archive `path` to stdout.
    /// - ditto (a macOS guest): a folder keeps its own name in the archive (--keepParent); for
    ///   a file that option would add the folder it is in.
    /// - tar (a Linux guest): the one item, named from its parent folder as "./name" (a name
    ///   that starts with "-" or "@" is then no option and no archive to include), without
    ///   what Linux has no use for: extended attributes, access control lists, file flags, and
    ///   the "._" files that would carry them.
    static func archiveArguments(_ path: String, isDirectory: Bool, guest: GuestKind = .macOS) -> [String] {
        switch guest {
        case .macOS:
            return ["-c"] + (isDirectory ? ["--keepParent"] : []) + [path, "-"]
        case .linux:
            let parent = (path as NSString).deletingLastPathComponent
            return ["-c", "--no-mac-metadata", "--no-xattrs", "--no-acls", "--no-fflags", "-f", "-",
                    "-C", parent.isEmpty ? "/" : parent, "./" + (path as NSString).lastPathComponent]
        }
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

    /// The Linux form of `receiveScript`: the same steps, with tar in place of ditto and a
    /// folder under ~/.cache in place of the one under ~/Library/Caches.
    /// - tar unpacks as the account and takes no owner from the archive; by itself it refuses
    ///   members with absolute paths or ".." in them.
    /// - tar is done at the archive's end mark, before its input ends, and the Mac's tar writes
    ///   that mark after a file it could not read too (measured: it stops there, and the archive
    ///   is a good one of what came before). So the script then reads on to the end of its
    ///   input and moves nothing unless the input ends with `completeMark` ($4), which the Mac
    ///   sends once its tar has finished well and at no other time. Without that, a folder with
    ///   a file the Mac could not read was in Downloads as if whole, while the Mac said it had
    ///   failed (measured on a box, 6 times of 6). The end of the input alone is not the sign:
    ///   when a send is given up, the guest daemon closes the program's input a moment before
    ///   it hangs it up.
    /// - The staging folder must then hold one item and nothing else: the archive is this
    ///   Mac's own, of one named item, and anything more in it is not what was sent. That one
    ///   item is what is moved, whatever bytes tar gave its name: a name is not compared byte
    ///   for byte on a Mac's disk, and is on a Linux one.
    /// - Every tool is named by a path that Debian and macOS both have (Debian's /bin is a link
    ///   to its /usr/bin), so the script's tests run it on the Mac.
    static let linuxReceiveScript = """
        dir="$HOME/Downloads"
        caches="$HOME/.cache/agent-vm-receiving"
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
        /usr/bin/tar -x -f - -C "$staging" --no-same-owner
        status=$?
        if [ "$status" -ne 0 ]; then /bin/rm -rf "$staging"; exit "$status"; fi
        mark="$(/bin/cat | /usr/bin/tail -c 32)"
        if [ "$mark" != "$4" ]; then
            echo "the archive of $1 ended early" >&2
            /bin/rm -rf "$staging"
            exit 1
        fi
        count="$(/usr/bin/find "$staging" -mindepth 1 -maxdepth 1 -exec /usr/bin/printf x \\; | /usr/bin/wc -c)"
        if [ "$count" -eq 0 ]; then
            echo "the archive did not hold $1" >&2
            /bin/rm -rf "$staging"
            exit 1
        fi
        if [ "$count" -ne 1 ]; then
            echo "the archive held more than $1" >&2
            /bin/rm -rf "$staging"
            exit 1
        fi
        item="$(/usr/bin/find "$staging" -mindepth 1 -maxdepth 1)"
        target="$1"
        n=2
        while [ -e "$dir/$target" ] || [ -L "$dir/$target" ]; do
            target="$2 $n$3"
            n=$((n + 1))
        done
        /bin/mv -n "$item" "$dir/$target"
        status=$?
        if [ "$status" -ne 0 ] || [ -e "$item" ] || [ -L "$item" ]; then
            echo "cannot move $1 into $dir" >&2
            /bin/rm -rf "$staging"
            exit 1
        fi
        /bin/rmdir "$staging"
        printf '%s\\n' "$target"
        """

    /// What the Mac sends after the archive, to a Linux guest, once its tar finished well: the
    /// last bytes of the script's input. tar reads its input a record of 10240 bytes at a time
    /// and the Mac's tar ends the archive on a record's end, so the guest's tar never takes
    /// these bytes for itself. No line end: the shell's `$(...)` would drop one, and nothing
    /// else.
    static let completeMark = "agent-vm: the archive is whole"

    /// The item's name as a guest of `kind` gets it. A Mac's disk takes a name in either
    /// spelling of an accented letter (one character, or the letter and its accent) as the
    /// same name; a Linux disk does not, and Linux tools write the first. The Mac's tar writes
    /// the names in an archive that way too, so the name sent beside it must be spelled the
    /// same.
    static func guestName(_ name: String, guest: GuestKind) -> String {
        return guest == .linux ? name.precomposedStringWithCanonicalMapping : name
    }

    func request(name: String) -> GuestRequest {
        let name = Self.guestName(name, guest: guest)
        let parts = Self.nameParts(name)
        // The account's own (the daemon's default), so the item is theirs, in their session.
        switch guest {
        case .macOS:
            return GuestRequest(op: .exec, argv: ["/bin/sh", "-c", Self.receiveScript, "sh", name, parts.stem, parts.ext], env: environment, notices: true)
        case .linux:
            // No notices: a Linux daemon does not send them, and a Linux box has no prompt to
            // wait on.
            return GuestRequest(op: .exec, argv: ["/bin/sh", "-c", Self.linuxReceiveScript, "sh", name, parts.stem, parts.ext, Self.completeMark], env: environment)
        }
    }
}
