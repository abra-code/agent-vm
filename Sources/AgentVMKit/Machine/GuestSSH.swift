// Sources/AgentVMKit/Machine/GuestSSH.swift
//
// Commands in a guest over SSH, used only while an image is built: the zero-click first boot
// turns on Remote Login for the new account, and SSH is the one way in until the guest daemon
// is installed. Password authentication only; the password comes from the image's 0600
// `Password` file through SSH_ASKPASS, never through the command line or the environment.
//
// The askpass program is agent-vm itself: ssh runs `$SSH_ASKPASS "<prompt>"` with this
// process's environment, and agent-vm answers when AGENT_VM_ASKPASS_FILE is set (see
// `askpassAnswer`). Nothing from the user's own SSH setup is used: no ~/.ssh/config, no keys,
// no ssh-agent, no known_hosts outside the image folder.

import Darwin
import Foundation

public struct GuestSSH: Sendable {
    public static let askpassFileVariable = "AGENT_VM_ASKPASS_FILE"

    public var host: String
    public var user: String
    public var passwordFile: URL
    public var knownHostsFile: URL
    /// Absolute path of an executable that implements `askpassAnswer` (the agent-vm binary).
    public var askpassProgram: String

    public init(host: String, user: String, passwordFile: URL, knownHostsFile: URL, askpassProgram: String) {
        self.host = host
        self.user = user
        self.passwordFile = passwordFile
        self.knownHostsFile = knownHostsFile
        self.askpassProgram = askpassProgram
    }

    public struct Result: Sendable {
        public var status: Int32
        public var output: String
    }

    /// ssh's arguments for running `command` in the guest.
    func arguments(_ command: String) throws -> [String] {
        // ssh splits UserKnownHostsFile on whitespace ("Application Support" became two files,
        // and the host key landed in ~/Library/Application), so the path is quoted; ssh has no
        // escape for a double quote inside quotes. ssh also expands "%" tokens (escaped as "%%")
        // and "${NAME}" environment variables (no escape) in this path.
        guard !knownHostsFile.path.contains("\""), !knownHostsFile.path.contains("${") else {
            throw AgentVMError.guestUnreachable("ssh cannot use \(knownHostsFile.path): the path contains a double quote or \"${\"")
        }
        let knownHostsPath = knownHostsFile.path.replacingOccurrences(of: "%", with: "%%")
        return [
            "-F", "/dev/null",
            "-o", "BatchMode=no",
            "-o", "PubkeyAuthentication=no",
            "-o", "IdentityAgent=none",
            "-o", "PreferredAuthentications=keyboard-interactive,password",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=\"\(knownHostsPath)\"",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=3",
            "-o", "ForwardAgent=no",
            "-o", "ForwardX11=no",
            "-o", "ClearAllForwardings=yes",
            "-o", "LogLevel=ERROR",
            "-T",
            "-l", user,
            host,
            "--",
            command,
        ]
    }

    /// ssh's environment: the caller's, minus anything that would bring in the user's SSH
    /// setup, plus the askpass variables.
    func environment(base: [String: String]) -> [String: String] {
        var environment = base.filter { key, _ in
            !key.hasPrefix("SSH_") && key != "DISPLAY"
        }
        environment["SSH_ASKPASS"] = askpassProgram
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment[Self.askpassFileVariable] = passwordFile.path
        return environment
    }

    /// Runs `command` in the guest with `input` on its standard input; standard output and
    /// error are returned together. Kills ssh after `timeout`.
    public func run(_ command: String, input: Data? = nil, timeout: Duration = .seconds(60)) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = try arguments(command)
        process.environment = environment(base: ProcessInfo.processInfo.environment)
        let output = Pipe()
        let inputPipe = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = inputPipe
        let collector = OutputCollector()
        output.fileHandleForReading.readabilityHandler = { handle in
            collector.append(handle.availableData)
        }
        let finished = ProcessWaiter()
        process.terminationHandler = { _ in
            finished.signal()
        }
        // If ssh exits before reading its input, a plain write would raise SIGPIPE and kill
        // agent-vm; with this flag the write fails with EPIPE instead, and ssh's status tells.
        _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            throw AgentVMError.system(operation: "run /usr/bin/ssh", code: FileSystem.posixCode(error))
        }
        if let input {
            try? inputPipe.fileHandleForWriting.write(contentsOf: input)
        }
        try? inputPipe.fileHandleForWriting.close()

        let completed = await finished.wait(timeout: timeout)
        if !completed {
            process.terminate()
            _ = await finished.wait(timeout: .seconds(5))
        }
        output.fileHandleForReading.readabilityHandler = nil
        collector.append(output.fileHandleForReading.readDataToEndOfFile())
        let text = collector.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !completed {
            throw AgentVMError.guestUnreachable("`\(command)` did not finish within \(timeout)")
        }
        return Result(status: process.terminationStatus, output: text)
    }

    /// Runs `command` and throws unless it exits with status 0.
    @discardableResult
    public func check(_ command: String, input: Data? = nil, timeout: Duration = .seconds(60)) async throws -> String {
        let result = try await run(command, input: input, timeout: timeout)
        guard result.status == 0 else {
            throw AgentVMError.guestCommandFailed(command: command, status: result.status, output: String(result.output.prefix(500)))
        }
        return result.output
    }

    public enum AskpassAnswer: Equatable, Sendable {
        /// This process was not started as ssh's askpass program.
        case notAskpass
        /// Started as askpass, but the prompt is not a password prompt (or the file is unreadable).
        case refuse
        case password(String)
    }

    /// The askpass side: what agent-vm answers when ssh starts it as SSH_ASKPASS. Only
    /// password prompts are answered; anything else (a host key question) gets no answer, so
    /// ssh gives up.
    public static func askpassAnswer(arguments: [String], environment: [String: String]) -> AskpassAnswer {
        guard let path = environment[askpassFileVariable], !path.isEmpty else {
            return .notAskpass
        }
        guard arguments.count == 2, arguments[1].lowercased().contains("password") else {
            return .refuse
        }
        guard let password = try? String(contentsOfFile: path, encoding: .utf8) else {
            return .refuse
        }
        return .password(password.trimmingCharacters(in: .newlines))
    }
}

/// Collects a child's output from the pipe's reading queue.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

/// A one-shot signal that can be awaited with a timeout.
private final class ProcessWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func signal() {
        lock.lock()
        done = true
        lock.unlock()
    }

    private var isDone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return done
    }

    func wait(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !isDone {
            if ContinuousClock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }
}
