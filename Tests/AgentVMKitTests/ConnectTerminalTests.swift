// Tests/AgentVMKitTests/ConnectTerminalTests.swift
//
// `agent-vm connect` (avm) on a pseudo-terminal: the debug agent-vm this build produced, next to
// the test bundle, run with a scratch store holding two stopped boxes. The picker is driven
// with keys; --dry-run keeps it from starting anything. The terminal's settings must be what
// they were however connect ends. An agent's secret typed at the offer goes to a test Keychain
// service, never to the output.

import Darwin
import Foundation
import Testing
@testable import AgentVMKit

/// A scratch store with a fake image and two stopped boxes, b1 and b2, made by the built
/// agent-vm itself (`box create` clones stand-in machine files).
final class ConnectScratch {
    let scratch: Scratch
    let home: URL
    let agentVM: String

    init() throws {
        scratch = try Scratch()
        home = scratch.root.appendingPathComponent("home", isDirectory: true)
        agentVM = try ConnectScratch.builtAgentVM()
        let image = home.appendingPathComponent("Images/img", isDirectory: true)
        try FileManager.default.createDirectory(at: image, withIntermediateDirectories: true)
        for (name, text) in [("Disk.img", "disk"), ("AuxiliaryStorage", "aux"), ("HardwareModel", "hw"),
                             ("MachineIdentifier", "id"), ("Password", "secret")] {
            try Data(text.utf8).write(to: image.appendingPathComponent(name))
        }
        let record = """
            {"formatVersion": 1, "name": "img", "state": "ready", "createdAt": "2026-09-23T10:00:00Z", "createdBy": "test",
             "macOSVersion": "27.0", "macOSBuild": "26A428", "cpuCount": 4, "memoryBytes": 8589934592, "diskBytes": 68719476736,
             "macAddress": "da:51:72:d4:e5:72", "userName": "agent", "guestProtocol": 1}
            """
        try Data(record.utf8).write(to: image.appendingPathComponent("image.json"))
        // As the store makes them: private folders, a private password.
        for folder in [home, home.appendingPathComponent("Images"), image] {
            chmod(folder.path, 0o700)
        }
        chmod(image.appendingPathComponent("Password").path, 0o600)
        for box in ["b1", "b2"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: agentVM)
            process.arguments = ["box", "create", box, "--image", "img"]
            process.environment = ["AGENT_VM_HOME": home.path, "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw AgentVMError.system(operation: "agent-vm box create \(box)", code: process.terminationStatus)
            }
        }
    }

    /// The agent-vm this build produced (swift test builds every target), next to the test
    /// bundle.
    static func builtAgentVM() throws -> String {
        let bundle = Bundle(for: ConnectBundleMarker.self).bundleURL
        let path = bundle.deletingLastPathComponent().appendingPathComponent("agent-vm").path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw AgentVMError.system(operation: "find \(path) (run swift build first)", code: ENOENT)
        }
        return path
    }

    var environment: [String: String] {
        return ["AGENT_VM_HOME": home.path, "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "TERM": "xterm-256color"]
    }
}

private final class ConnectBundleMarker {}

/// A program on a new pseudo-terminal: the test types into the master side and reads it.
final class TerminalProgram {
    let master: Int32
    let slave: Int32
    let pid: pid_t
    private var output = Data()
    private(set) var status: Int32?

    init(_ path: String, arguments: [String], environment: [String: String]) throws {
        master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master).map({ String(cString: $0) }) else {
            throw AgentVMError.system(operation: "open a pseudo-terminal", code: errno)
        }
        slave = open(name, O_RDWR | O_NOCTTY)
        guard slave >= 0 else {
            throw AgentVMError.system(operation: "open \(name)", code: errno)
        }
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        var size = winsize(ws_row: 24, ws_col: 100, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor: Int32 in [0, 1, 2] {
            posix_spawn_file_actions_adddup2(&actions, slave, descriptor)
        }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT))
        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
        guard status == 0 else {
            throw AgentVMError.system(operation: "start \(path)", code: status)
        }
        self.pid = pid
    }

    deinit {
        if status == nil {
            kill(pid, SIGKILL)
            var ignored: Int32 = 0
            waitpid(pid, &ignored, 0)
        }
        close(master)
        close(slave)
    }

    func type(_ text: String) {
        _ = Array(text.utf8).withUnsafeBytes { write(master, $0.baseAddress!, $0.count) }
    }

    var text: String {
        drain()
        return String(decoding: output, as: UTF8.self)
    }

    func settings() -> termios {
        var settings = termios()
        _ = tcgetattr(slave, &settings)
        return settings
    }

    /// Waits up to `seconds` for `expected` in the output.
    @discardableResult
    func waitFor(_ expected: String, seconds: Double = 10) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if text.contains(expected) {
                return true
            }
            var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            _ = poll(&descriptor, 1, 20)
        }
        return text.contains(expected)
    }

    /// The exit status (128 + n for a signal), reading the output meanwhile: the program's
    /// restore waits until its output is read (TCSADRAIN). Nil when it did not end in time.
    func exitStatus(seconds: Double = 10) -> Int32? {
        let deadline = Date().addingTimeInterval(seconds)
        while status == nil && Date() < deadline {
            drain()
            var raw: Int32 = 0
            if waitpid(pid, &raw, WNOHANG) == pid {
                status = ExitReport(waitStatus: raw).shellStatus
                break
            }
            usleep(20_000)
        }
        drain()
        return status
    }

    private func drain() {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(master, &chunk, chunk.count)
            guard count > 0 else {
                return
            }
            output.append(contentsOf: chunk[0..<count])
        }
    }
}

/// Field by field, without PENDIN: a kernel state bit, not a setting, set when a terminal goes
/// back to canonical mode.
func sameTerminalSettings(_ a: termios, _ b: termios) -> Bool {
    let state = ~tcflag_t(PENDIN)
    return a.c_iflag == b.c_iflag && a.c_oflag == b.c_oflag && a.c_cflag == b.c_cflag && a.c_lflag & state == b.c_lflag & state
        && withUnsafeBytes(of: a.c_cc) { Array($0) } == withUnsafeBytes(of: b.c_cc) { Array($0) }
        && a.c_ispeed == b.c_ispeed && a.c_ospeed == b.c_ospeed
}

@Suite struct ConnectTerminalTests {
    func connect(_ store: ConnectScratch, _ arguments: [String], environment: [String: String]? = nil) throws -> TerminalProgram {
        return try TerminalProgram(store.agentVM, arguments: ["connect", "--project", store.scratch.project.path] + arguments,
                                   environment: environment ?? store.environment)
    }

    @Test func escapeQuitsWithStatus130AndRestores() throws {
        let store = try ConnectScratch()
        let program = try connect(store, ["--dry-run"])
        let before = program.settings()
        #expect(program.waitFor("AgentVM - project"))
        program.type("\u{1B}")
        #expect(program.exitStatus() == 130)
        #expect(sameTerminalSettings(program.settings(), before))
        #expect(program.text.hasSuffix("\u{1B}[?25h"), "\(program.text.debugDescription)")
    }

    @Test func sigtermInThePickerRestoresAndExits143() throws {
        let store = try ConnectScratch()
        let program = try connect(store, ["--dry-run"])
        let before = program.settings()
        #expect(program.waitFor("AgentVM - project"))
        kill(program.pid, SIGTERM)
        #expect(program.exitStatus() == 143)
        #expect(sameTerminalSettings(program.settings(), before))
    }

    @Test func downAndEnterChooseTheSecondBox() throws {
        let store = try ConnectScratch()
        let program = try connect(store, ["--dry-run", "--shell"])
        #expect(program.waitFor("AgentVM - project"))
        program.type("\u{1B}[B\r")
        #expect(program.exitStatus() == 0)
        #expect(program.text.contains("start box b2"), "\(program.text)")
        #expect(program.text.contains("run: agent-vm exec --tty --box b2 --project "))
    }

    @Test func typingFilters() throws {
        let store = try ConnectScratch()
        let program = try connect(store, ["--dry-run"])
        #expect(program.waitFor("AgentVM - project"))
        program.type("b2")
        #expect(program.waitFor("filter: b2"))
        program.type("\r")
        #expect(program.exitStatus() == 0)
        #expect(program.text.contains("start box b2"))
    }

    @Test func noColorWritesNoAttributes() throws {
        let store = try ConnectScratch()
        var environment = store.environment
        environment["NO_COLOR"] = "1"
        let program = try connect(store, ["--dry-run"], environment: environment)
        #expect(program.waitFor("AgentVM - project"))
        program.type("\r")
        #expect(program.exitStatus() == 0)
        #expect(!program.text.contains("\u{1B}[7m"))
        #expect(!program.text.contains("\u{1B}[1m"))
        #expect(program.text.contains("  > b1"))
    }

    @Test func startedAsAvm() throws {
        let store = try ConnectScratch()
        let link = store.scratch.root.appendingPathComponent("avm").path
        #expect(symlink(store.agentVM, link) == 0)
        let program = try TerminalProgram(link, arguments: ["--project", store.scratch.project.path, "--dry-run"],
                                          environment: store.environment)
        #expect(program.waitFor("AgentVM - project"))
        program.type("\r")
        #expect(program.exitStatus() == 0)
        #expect(program.text.contains("avm would:"))
        #expect(program.text.contains("start box b1"))
        let help = try TerminalProgram(link, arguments: ["--help"], environment: store.environment)
        #expect(help.exitStatus() == 0)
        #expect(help.text.contains("USAGE: avm"))
    }

    @Test func theSecretPromptStoresWithoutEcho() throws {
        let store = try ConnectScratch()
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var environment = store.environment
        environment["AGENT_VM_SECRET_SERVICE"] = "agent-vm-test-\(UUID().uuidString)"
        environment["AGENT_VM_AGENTS_FILE"] = repository.appendingPathComponent("Resources/agents.json").path
        environment["AGENT_VM_PACKS_FILE"] = repository.appendingPathComponent("Resources/packs.json").path
        let secrets = SecretStore(service: environment["AGENT_VM_SECRET_SERVICE"]!)
        // Deleted by the agent-vm that stored it: this test process reading or deleting the
        // item would make macOS ask on the screen first.
        defer {
            let delete = Process()
            delete.executableURL = URL(fileURLWithPath: store.agentVM)
            delete.arguments = ["secret", "delete", "CLAUDE_CODE_OAUTH_TOKEN"]
            delete.environment = environment
            delete.standardOutput = FileHandle.nullDevice
            delete.standardError = FileHandle.nullDevice
            try? delete.run()
            delete.waitUntilExit()
        }
        // A box that already allows the agent's hosts, so no question comes between the secret
        // and the start.
        let create = Process()
        create.executableURL = URL(fileURLWithPath: store.agentVM)
        create.arguments = ["box", "create", "c1", "--image", "img", "--allow", "pack:anthropic"]
        create.environment = environment
        create.standardOutput = FileHandle.nullDevice
        try create.run()
        create.waitUntilExit()
        #expect(create.terminationStatus == 0)

        let program = try connect(store, ["c1", "--agent", "claude"], environment: environment)
        #expect(program.waitFor("signs in with one of these"))
        program.type("\r")
        #expect(program.waitFor("Paste or type CLAUDE_CODE_OAUTH_TOKEN (not shown), then Enter: "))
        // Pasted as a terminal with bracketed paste on sends it: the markers are dropped, and
        // the count of characters stored says so.
        let value = "sk-ant-oat-test-\(UUID().uuidString)"
        program.type("\u{1B}[200~" + value + "\u{1B}[201~\r")
        #expect(program.waitFor("(\(value.count) characters)"))
        #expect(program.waitFor("Stored secret CLAUDE_CODE_OAUTH_TOKEN in the Keychain"))
        // Then the start, which the debug build cannot do (no virtualization entitlement).
        #expect(program.exitStatus(seconds: 60) != nil)
        #expect(!program.text.contains(value))
        // Listing reads attributes only, which never asks.
        #expect(try secrets.list().map(\.name) == ["CLAUDE_CODE_OAUTH_TOKEN"])
    }

    @Test func theHostsQuestionAddsTheAgentsRules() throws {
        let store = try ConnectScratch()
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var environment = store.environment
        environment["AGENT_VM_AGENTS_FILE"] = repository.appendingPathComponent("Resources/agents.json").path
        environment["AGENT_VM_PACKS_FILE"] = repository.appendingPathComponent("Resources/packs.json").path
        func agentVM(_ arguments: [String]) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: store.agentVM)
            process.arguments = arguments
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }
        _ = try agentVM(["box", "create", "c2", "--image", "img", "--allow", "github.com"])
        // opencode has no secrets, so its hosts are the only question.
        let program = try connect(store, ["c2", "--agent", "opencode"], environment: environment)
        #expect(program.waitFor("opencode needs opencode.ai, models.opencode.ai, which box c2 does not allow."))
        #expect(program.waitFor("Allow them? [Y/n]"))
        program.type("\r")
        #expect(program.waitFor("Box c2 now allows opencode.ai, models.opencode.ai"))
        // Then the start, which the debug build cannot do.
        #expect(program.exitStatus(seconds: 60) != nil)
        #expect(try agentVM(["box", "network", "c2"]).contains("github.com, opencode.ai, models.opencode.ai"))
    }

    @Test func aSecretAnotherBuildStoredIsUsedWithEnter() throws {
        let store = try ConnectScratch()
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var environment = store.environment
        environment["AGENT_VM_SECRET_SERVICE"] = "agent-vm-test-\(UUID().uuidString)"
        environment["AGENT_VM_AGENTS_FILE"] = repository.appendingPathComponent("Resources/agents.json").path
        environment["AGENT_VM_PACKS_FILE"] = repository.appendingPathComponent("Resources/packs.json").path
        // Stored by this test process, so for the agent-vm under test it is another program's
        // (and this process can delete it without macOS asking). It is never read: the debug
        // build cannot start the box, so no session reads it.
        let secrets = SecretStore(service: environment["AGENT_VM_SECRET_SERVICE"]!)
        try secrets.set("CLAUDE_CODE_OAUTH_TOKEN", value: Data("test-\(UUID().uuidString)".utf8))
        defer { try? secrets.delete("CLAUDE_CODE_OAUTH_TOKEN") }
        let create = Process()
        create.executableURL = URL(fileURLWithPath: store.agentVM)
        create.arguments = ["box", "create", "c1", "--image", "img", "--allow", "pack:anthropic"]
        create.environment = environment
        create.standardOutput = FileHandle.nullDevice
        try create.run()
        create.waitUntilExit()
        #expect(create.terminationStatus == 0)

        // Enter: use it.
        let use = try connect(store, ["c1", "--agent", "claude"], environment: environment)
        #expect(use.waitFor("CLAUDE_CODE_OAUTH_TOKEN is in the Keychain"))
        use.type("\r")
        #expect(use.waitFor("Using CLAUDE_CODE_OAUTH_TOKEN from the Keychain; if macOS asks to allow access to it, choose Always Allow"))
        #expect(use.waitFor("Starting box c1"))
        #expect(use.exitStatus(seconds: 60) != nil)
        // Down and Enter: go on without it.
        let without = try connect(store, ["c1", "--agent", "claude"], environment: environment)
        #expect(without.waitFor("CLAUDE_CODE_OAUTH_TOKEN is in the Keychain"))
        without.type("\u{1B}[B\r")
        #expect(without.waitFor("Going on without CLAUDE_CODE_OAUTH_TOKEN"))
        #expect(without.waitFor("Starting box c1"))
        #expect(without.exitStatus(seconds: 60) != nil)
    }
}
