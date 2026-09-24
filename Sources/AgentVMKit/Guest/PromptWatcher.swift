// Sources/AgentVMKit/Guest/PromptWatcher.swift
//
// In the guest daemon: notices that a program run by exec waits on a privacy prompt. Every
// program exec runs is started by the daemon, so macOS asks on the daemon's behalf, on the
// guest's screen, where nobody sees it: the program just waits (for the Downloads folder, for
// one, until the image has Full Disk Access). The privacy service (tccd) logs each request:
// an AUTHREQ_ATTRIBUTION line names the program that tried the access, and an AUTHREQ_PROMPTING
// line with the same message id says a prompt went up (measured on macOS 27). The watcher reads
// them from `log stream`, finds the exec the program belongs to (its session: exec starts every
// program in a new one), and sends that exec a notice frame.

import Darwin
import Foundation

/// What the guest tells an exec that asked for notices.
public struct GuestNotice: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// The program waits on a privacy prompt on the guest's screen.
        case permissionPrompt = "permission-prompt"
    }

    public var kind: Kind
    /// The privacy service asked about (kTCCService...).
    public var service: String?
    /// The program that tried the access.
    public var program: String?
    public var pid: Int32?

    public init(kind: Kind, service: String? = nil, program: String? = nil, pid: Int32? = nil) {
        self.kind = kind
        self.service = service
        self.program = program
        self.pid = pid
    }

    /// The service in words: "the Downloads folder".
    public var serviceDescription: String {
        guard let service else {
            return "something macOS protects"
        }
        let names: [String: String] = [
            "kTCCServiceSystemPolicyDownloadsFolder": "the Downloads folder",
            "kTCCServiceSystemPolicyDocumentsFolder": "the Documents folder",
            "kTCCServiceSystemPolicyDesktopFolder": "the Desktop folder",
            "kTCCServiceSystemPolicyAllFiles": "all files (Full Disk Access)",
            "kTCCServiceSystemPolicyRemovableVolumes": "removable volumes",
            "kTCCServiceSystemPolicyNetworkVolumes": "network volumes",
            "kTCCServiceSystemPolicyAppData": "another app's data",
            "kTCCServiceFileProviderDomain": "a file provider (cloud storage)",
            "kTCCServiceAppleEvents": "control of another app (Automation)",
            "kTCCServiceAccessibility": "Accessibility",
            "kTCCServiceScreenCapture": "screen recording",
            "kTCCServiceListenEvent": "input monitoring",
            "kTCCServiceMicrophone": "the microphone",
            "kTCCServiceCamera": "the camera",
            "kTCCServicePhotos": "Photos",
            "kTCCServiceAddressBook": "Contacts",
            "kTCCServiceCalendar": "Calendars",
            "kTCCServiceReminders": "Reminders",
        ]
        return names[service] ?? service
    }
}

final class PromptWatcher: @unchecked Sendable {
    /// One privacy-service log line that matters here.
    enum Event: Equatable {
        /// `accessing` (else `requesting`: pid, path) tried an access, in request `messageID`.
        case attribution(messageID: String, pid: Int32, program: String?)
        /// Request `messageID` put a prompt on the screen.
        case prompting(messageID: String, service: String)
    }

    /// One exec that asked for notices. Its lock orders a notice against `unregister`, so none
    /// is sent once the exec is about to send its exit frame.
    final class Registration: @unchecked Sendable {
        let pid: pid_t
        private let channel: FrameChannel
        private let lock = NSLock()
        private var isActive = true

        init(pid: pid_t, channel: FrameChannel) {
            self.pid = pid
            self.channel = channel
        }

        func send(_ notice: GuestNotice) {
            lock.lock()
            defer { lock.unlock() }
            if isActive {
                try? channel.send(.notice, json: notice)
            }
        }

        /// Waits for a notice being sent; none is sent afterwards.
        func deactivate() {
            lock.lock()
            isActive = false
            lock.unlock()
        }
    }

    private let lock = NSLock()
    /// Running execs that asked for notices, by session id (the exec's pid).
    private var sessions: [pid_t: Registration] = [:]
    /// Recent attributions by "<tccd pid>/<message id>" (message ids repeat across tccd
    /// processes), oldest first for trimming.
    private var attributions: [String: (pid: Int32, program: String?)] = [:]
    private var order: [String] = []
    private var started = false

    static let shared = PromptWatcher()
    static let predicate = "subsystem == \"com.apple.TCC\" AND (eventMessage BEGINSWITH \"AUTHREQ_ATTRIBUTION\" OR eventMessage BEGINSWITH \"AUTHREQ_PROMPTING\")"

    /// Watches the privacy log from now on, once: the daemon starts it before serving, since a
    /// program meets its prompt within milliseconds, sooner than `log stream` attaches.
    func start() {
        lock.lock()
        let start = !started
        started = true
        lock.unlock()
        if start {
            Thread.detachNewThread { [self] in
                watch()
            }
        }
    }

    /// Sends notices for programs in session `pid` over `channel` until `unregister`.
    func register(pid: pid_t, channel: FrameChannel) -> Registration {
        let registration = Registration(pid: pid, channel: channel)
        lock.lock()
        sessions[pid] = registration
        lock.unlock()
        return registration
    }

    /// Returns once no notice for this exec is being sent, and none will be. Only the
    /// registration itself is removed: its pid may already be another exec's.
    func unregister(_ registration: Registration) {
        lock.lock()
        if sessions[registration.pid] === registration {
            sessions[registration.pid] = nil
        }
        lock.unlock()
        registration.deactivate()
    }

    /// Reads `log stream` for as long as the daemon runs, starting it again if it ends.
    private func watch() {
        while true {
            readLogStream()
            sleep(5)
        }
    }

    private func readLogStream() {
        var output: [Int32] = [-1, -1]
        guard pipe(&output) == 0 else {
            return
        }
        _ = fcntl(output[0], F_SETFD, FD_CLOEXEC)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, output[1], 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        let arguments = ["/usr/bin/log", "stream", "--style", "ndjson", "--predicate", Self.predicate]
        var pid: pid_t = 0
        let status = GuestServer.withCStrings(arguments) { argv in
            posix_spawn(&pid, "/usr/bin/log", &actions, &attributes, argv, environ)
        }
        close(output[1])
        guard status == 0 else {
            close(output[0])
            GuestServer.log("cannot watch the privacy log: \(String(cString: strerror(status)))")
            return
        }
        var pending = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(output[0], &buffer, buffer.count)
            if count < 0 && errno == EINTR {
                continue
            }
            if count <= 0 {
                break
            }
            pending.append(contentsOf: buffer[0..<count])
            while let newline = pending.firstIndex(of: 10) {
                let line = Array(pending[..<newline])
                pending.removeSubrange(...newline)
                handle(line: line)
            }
        }
        close(output[0])
        var exitStatus: Int32 = 0
        while waitpid(pid, &exitStatus, 0) < 0 && errno == EINTR {}
    }

    /// One ndjson line of `log stream`: the event's message and the logging tccd's pid.
    private func handle(line: [UInt8]) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let message = object["eventMessage"] as? String,
              let event = Self.parse(message) else {
            return
        }
        let process = (object["processID"] as? NSNumber)?.intValue ?? 0
        switch event {
        case let .attribution(messageID, pid, program):
            let key = "\(process)/\(messageID)"
            lock.lock()
            if attributions[key] == nil {
                order.append(key)
            }
            attributions[key] = (pid, program)
            // Only the last few hundred requests can still be prompting.
            if order.count > 512 {
                attributions[order.removeFirst()] = nil
            }
            lock.unlock()
        case let .prompting(messageID, service):
            lock.lock()
            let attribution = attributions["\(process)/\(messageID)"]
            lock.unlock()
            guard let attribution else {
                return
            }
            // The exec whose session the program is in; programs it started are in it too.
            let session = getsid(attribution.pid)
            lock.lock()
            let registration = session > 0 ? sessions[session] : nil
            lock.unlock()
            guard let registration else {
                return
            }
            // Off this thread: a host that stops reading must not stall the log for every exec.
            let notice = GuestNotice(kind: .permissionPrompt, service: service, program: attribution.program, pid: attribution.pid)
            DispatchQueue.global().async {
                registration.send(notice)
            }
        }
    }

    /// The event in one privacy-service message, or nil for any other message.
    static func parse(_ message: String) -> Event? {
        guard let messageID = field("msgID=", in: message, until: ",") else {
            return nil
        }
        if message.hasPrefix("AUTHREQ_ATTRIBUTION") {
            // accessing={TCCDProcess: identifier=..., pid=688, ..., binary_path=/bin/ls}. A program
            // that asks itself (Automation, the camera) has no `accessing`: it is `requesting`.
            guard let start = message.range(of: "accessing={") ?? message.range(of: "requesting={") else {
                return nil
            }
            let rest = message[start.upperBound...]
            let accessing = String(rest[..<(rest.firstIndex(of: "}") ?? rest.endIndex)])
            guard let pid = field("pid=", in: accessing, until: ",").flatMap({ Int32($0) }) else {
                return nil
            }
            return .attribution(messageID: messageID, pid: pid, program: field("binary_path=", in: accessing, until: ","))
        }
        if message.hasPrefix("AUTHREQ_PROMPTING") {
            guard let service = field("service=", in: message, until: ",") else {
                return nil
            }
            return .prompting(messageID: messageID, service: service)
        }
        return nil
    }

    /// The text after `name` up to `end` (or the end of `text`).
    private static func field(_ name: String, in text: String, until end: Character) -> String? {
        guard let start = text.range(of: name) else {
            return nil
        }
        let rest = text[start.upperBound...]
        let value = rest[..<(rest.firstIndex(of: end) ?? rest.endIndex)].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}
