// Sources/agent-vm/BoxCommand.swift
//
// `agent-vm box ...`: boxes are copy-on-write clones of a golden image, each run by its own
// supervisor process (`box serve`, started detached by `box start`).

import AgentVMKit
import AppKit
import ArgumentParser
import Foundation

struct BoxCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "box",
        abstract: "Create, start and stop boxes: clones of a golden image.",
        discussion: """
            A box is an instant copy-on-write clone of a ready image with its own identity \
            (MAC address, machine identifier). `box start` runs it in the background under a \
            supervisor process; `agent-vm exec --box <name> -- <program>` runs programs in it.
            Network modes: allowlist (default) - only listed hosts, through a proxy on this Mac \
            that logs every attempt; off - nothing; open - NAT to the internet and your local \
            network. See `box network`, `box netlog` and `box packs`. `box shell` opens a shell in \
            the box on this terminal, `box view` shows its screen in a window, `box execlog` \
            shows what exec and shell ran there, and `box status` shows its state without \
            starting anything.
            """,
        subcommands: [Create.self, List.self, Status.self, Start.self, Stop.self, Delete.self, Shell.self, View.self, ExecLogCommand.self, Network.self, NetLog.self,
                      Packs.self, Serve.self]
    )

    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Clone a ready image into a new box.")

        @Argument(help: "Name of the new box.")
        var name: String

        @Option(name: .long, help: "The image to clone.")
        var image: String

        @Option(name: .long, help: "Virtual CPUs (default: the image's).")
        var cpus: Int?

        @Option(name: .customLong("memory-gb"), help: "Memory in GB (default: the image's).")
        var memoryGB: Int?

        @Option(name: .long, help: "Network mode: allowlist (default), off or open (NAT, reaches your local network).")
        var net: BoxNetwork.Mode = .allowlist

        @Option(name: .long, help: "Allow a host (github.com), subdomains (*.example.com), host:port, or pack:<name> (repeatable).")
        var allow: [String] = []

        @OptionGroup var options: StoreOptions

        func validate() throws {
            // Before the image is looked up: a bad name is the first thing to hear about.
            guard ImageStore.isValidName(name) else {
                throw ValidationError(AgentVMError.invalidBoxName(name).description)
            }
            if let cpus, !(1...256).contains(cpus) {
                throw ValidationError("--cpus must be between 1 and 256")
            }
            if let memoryGB, !(1...4096).contains(memoryGB) {
                throw ValidationError("--memory-gb must be between 1 and 4096")
            }
        }

        func run() throws {
            let image = try options.imageStore.image(named: image)
            let box = try options.boxStore.create(name: name, from: image, imageStore: options.imageStore,
                                                  cpuCount: cpus, memoryBytes: memoryGB.map { UInt64($0) << 30 },
                                                  network: BoxNetwork(mode: net, allow: allow))
            if options.json {
                try Output.json(box.record)
                return
            }
            print("Created box \(box.name) from image \(image.name): \(box.directory.path)")
            print("  network: \(Network.describe(box.record.effectiveNetwork))")
            print("  start it with: agent-vm box start \(box.name)")
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List boxes and whether they run.")

        @OptionGroup var options: StoreOptions

        /// A box as `box list` and `box status` print it: the record, whether a supervisor
        /// holds it, its folder and space, and the status fields (BoxStatus) as more keys.
        struct Entry: Encodable {
            var box: BoxRecord
            var running: Bool
            var path: String
            var diskUsage: DiskUsage
            var status: BoxStatus

            init(_ box: Box) {
                self.status = BoxStatus.of(box)
                self.box = box.record
                // Held by a supervisor (or, briefly, by another command changing the box).
                self.running = status.state != .stopped
                self.path = box.directory.path
                self.diskUsage = DiskUsage.of(box.directory)
            }

            private enum Keys: String, CodingKey {
                case box
                case running
                case path
                case diskUsage
            }

            func encode(to encoder: Encoder) throws {
                try status.encode(to: encoder)
                var container = encoder.container(keyedBy: Keys.self)
                try container.encode(box, forKey: .box)
                try container.encode(running, forKey: .running)
                try container.encode(path, forKey: .path)
                try container.encode(diskUsage, forKey: .diskUsage)
            }

            /// The entry for a person: a line with the essentials, then indented details.
            var lines: [String] {
                // padding(toLength:) truncates: "unresponsive" is longer than the column.
                let name = status.state.rawValue
                let state = name.padding(toLength: max(8, name.count), withPad: " ", startingAt: 0)
                var lines = ["\(box.name)  \(state)  image \(box.image) (macOS \(box.macOSBuild))  \(box.cpuCount) CPUs  \(box.memoryBytes >> 30) GB  network \(box.effectiveNetwork.mode.rawValue)"]
                if status.state != .stopped {
                    if let pid = status.pid {
                        var line = "    supervisor pid \(pid)"
                        if let version = status.supervisorVersion {
                            line += ", agent-vm \(version)"
                        } else {
                            line += ", an agent-vm older than 0.1.6"
                        }
                        if let startedAt = status.startedAt {
                            line += ", started \(Output.time(startedAt))"
                        }
                        lines.append(line)
                    }
                    if let path = status.supervisorPath {
                        lines.append("    \(path)")
                    }
                    if let error = status.statusError {
                        lines.append("    no answer from its supervisor: \(error)")
                    }
                    if let version = status.guestVersion, status.state == .ready {
                        let features = status.guestFeatures ?? []
                        lines.append("    agent-vm-guest \(version)\(features.isEmpty ? "" : " (\(features.joined(separator: ", ")))")")
                    }
                    if let project = status.project {
                        lines.append("    project \(project)\(status.projectReadOnly == true ? " (read only)" : "")")
                    }
                    if let execs = status.activeExecs, execs > 0 {
                        lines.append("    \(execs) program\(execs == 1 ? "" : "s") running through exec or box shell")
                    }
                }
                return lines + Output.placeLines(URL(fileURLWithPath: path), diskUsage, others: "its image or other boxes", delete: "box delete")
            }
        }

        func run() throws {
            let (boxes, problems) = try options.boxStore.list()
            for problem in problems {
                FileHandle.standardError.write(Data("warning: \(problem)\n".utf8))
            }
            let entries = boxes.map { Entry($0) }
            if options.json {
                try Output.json(entries)
                return
            }
            if entries.isEmpty {
                print("No boxes.")
                return
            }
            for entry in entries {
                for line in entry.lines {
                    print(line)
                }
            }
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show one box's state without starting or changing anything.",
            discussion: """
                A stopped box reports "stopped" and its record; a running one is asked through \
                its supervisor: its state (starting, ready, stopping), the supervisor's process \
                id, agent-vm version and path, when it started, the shared project, how many \
                programs exec and box shell run in it now, and its guest daemon. "unresponsive" \
                means something holds the box but its supervisor does not answer. With --json, \
                the same entry as `box list --json`.
                """)

        @Argument(help: "The box name.")
        var name: String

        @OptionGroup var options: StoreOptions

        func run() throws {
            let entry = List.Entry(try options.boxStore.box(named: name))
            if options.json {
                try Output.json(entry)
                return
            }
            for line in entry.lines {
                print(line)
            }
        }
    }

    struct Start: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Start a box in the background and wait until it is ready (a running box is left as is).")

        @Argument(help: "The box name.")
        var name: String

        @OptionGroup var options: StoreOptions

        func run() throws {
            let box = try options.boxStore.box(named: name)
            // Starting a running box succeeds, so clients can simply make sure a box is up.
            if box.isRunning, let status = try? ControlClient.request(.status, path: box.controlSocketPath), status.state == .ready {
                if options.json {
                    try Output.json(status)
                } else {
                    print("Box \(box.name) is already running (supervisor pid \(status.pid ?? 0))")
                }
                return
            }
            let clock = ContinuousClock()
            let began = clock.now
            let response = try BoxLauncher.start(box, executable: try AskpassEntry.executablePath()) { state in
                Events.emit(ProgressEvent(.progress, "  \(state)", step: state, box: box.name), json: options.json)
            }
            if options.json {
                try Output.json(response)
                return
            }
            let elapsed = clock.now - began
            print("Box \(box.name) is ready (\(elapsed.formatted(.units(allowed: [.seconds], width: .narrow))), agent-vm-guest \(response.guestVersion ?? "?"), supervisor pid \(response.pid ?? 0))")
            print("  run programs with: agent-vm exec --box \(box.name) -- <program>")
        }
    }

    struct Stop: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Shut a box down cleanly and end its supervisor.")

        @Argument(help: "The box name.")
        var name: String

        @OptionGroup var options: StoreOptions

        func run() throws {
            let box = try options.boxStore.box(named: name)
            // Only for programs: a person sees the result line.
            if options.json && box.isRunning {
                Events.emit(ProgressEvent(.progress, "Stopping box \(box.name)", step: "shutdown", box: box.name), json: true)
            }
            try BoxLauncher.stop(box)
            if !options.json {
                print("Stopped box \(box.name)")
            }
        }
    }

    struct View: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show a running box's screen in a window on this Mac.",
            discussion: """
                The box's supervisor opens the window (or brings it to the front); closing it \
                leaves the box running. View only by default: keys and clicks do not reach the \
                box. With --interactive they do, as in a VM app. The screen shows the box's \
                desktop (Finder, system dialogs, permission prompts); programs run with exec do \
                not appear on it, so use `box shell` and `box execlog` to follow those. A box \
                started over SSH or by a service has no window server and cannot show one.
                """)

        @Argument(help: "The running box.")
        var name: String

        @Flag(name: .long, help: "Let keyboard and mouse reach the box.")
        var interactive = false

        @Flag(name: .customLong("type-password"), help: "Then type the box account's password into the focused field in the box (implies --interactive).")
        var typePassword = false

        @Option(name: .long, help: .hidden)
        var type: String?

        @OptionGroup var options: StoreOptions

        func validate() throws {
            if typePassword && type != nil {
                throw ValidationError("--type-password and --type do not go together")
            }
        }

        func run() throws {
            let interactive = self.interactive || typePassword || type != nil
            let box = try options.boxStore.box(named: name)
            guard box.isRunning else {
                throw AgentVMError.boxNotRunning(box.name)
            }
            // Supervisors from before `view` answer their status without guest features.
            let status = try ControlClient.request(.status, path: box.controlSocketPath)
            guard status.guestFeatures != nil else {
                throw AgentVMError.supervisorRefused("box \(box.name) was started by an older agent-vm; restart it (`agent-vm box stop \(box.name)`, then `box start`) to view its screen")
            }
            let response = try ControlClient.request(ControlRequest(op: .view, interactive: interactive), path: box.controlSocketPath)
            guard response.ok else {
                throw AgentVMError.supervisorRefused(response.error ?? "no reason given")
            }
            if typePassword || type != nil {
                // The password stays in the box folder: the supervisor reads it there.
                let typed = try ControlClient.request(ControlRequest(op: .type, text: type), path: box.controlSocketPath, timeout: 70)
                guard typed.ok else {
                    throw AgentVMError.supervisorRefused(typed.error ?? "no reason given")
                }
            }
            if options.json {
                try Output.json(response)
                return
            }
            print("Showing box \(box.name)\(interactive ? "" : " (view only; --interactive to use keyboard and mouse)")\(typePassword ? "; typed the password" : "")")
        }
    }

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a stopped box and its disk.")

        @Argument(help: "The box name.")
        var name: String

        @OptionGroup var options: StoreOptions

        func run() throws {
            try options.boxStore.delete(named: name)
            if !options.json {
                print("Deleted box \(name)")
            }
        }
    }

    struct Network: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show or change what a box may reach.",
            discussion: """
                Rules can change while the box runs (the proxy rereads them at once); the mode \
                decides the box's network card, so it changes only while the box is stopped.
                """)

        @Argument(help: "The box name.")
        var name: String

        @Option(name: .long, help: "New mode: allowlist, off or open.")
        var net: BoxNetwork.Mode?

        @Option(name: .long, help: "Add a rule (repeatable).")
        var allow: [String] = []

        @Option(name: .long, help: "Remove a rule, exactly as listed (repeatable).")
        var disallow: [String] = []

        @Flag(name: .long, help: "Remove every rule first.")
        var clear = false

        @OptionGroup var options: StoreOptions

        static func describe(_ network: BoxNetwork) -> String {
            switch network.mode {
            case .open:
                return "open (NAT: the internet and your local network, not logged)"
            case .off:
                return "off (every connection refused and logged)"
            case .allowlist:
                return network.allow.isEmpty
                    ? "allowlist, nothing allowed yet (add hosts with `agent-vm box network <name> --allow ...`)"
                    : "allowlist: \(network.allow.joined(separator: ", "))"
            }
        }

        func run() throws {
            var box = try options.boxStore.box(named: name)
            let current = box.record.effectiveNetwork
            if net != nil || !allow.isEmpty || !disallow.isEmpty || clear {
                var updated = current
                if let net {
                    updated.mode = net
                }
                if clear {
                    updated.allow = []
                }
                for rule in disallow {
                    guard let index = updated.allow.firstIndex(of: rule) else {
                        throw ValidationError("\(rule) is not one of the box's rules: \(updated.allow.joined(separator: ", "))")
                    }
                    updated.allow.remove(at: index)
                }
                for rule in allow where !updated.allow.contains(rule) {
                    updated.allow.append(rule)
                }
                box = try options.boxStore.updateNetwork(named: name, to: updated)
                if box.isRunning {
                    let response = try ControlClient.request(.reload, path: box.controlSocketPath)
                    guard response.ok else {
                        throw AgentVMError.supervisorRefused(response.error ?? "the supervisor did not reload the rules")
                    }
                }
            }
            if options.json {
                try Output.json(box.record.effectiveNetwork)
                return
            }
            print("Box \(box.name) network: \(Self.describe(box.record.effectiveNetwork))")
        }
    }

    struct Shell: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Open a login shell in a running box on this terminal.",
            discussion: """
                The same as `agent-vm exec --tty --box <name> -- <the account's shell> -l`, over \
                the box's private channel (no SSH, no network). Exit the shell to return; its \
                status becomes ours.
                """)

        @Argument(help: "The running box.")
        var name: String

        @Option(name: .long, help: "Account to log in as (default: the box user; root works too).")
        var user: String?

        @Option(name: .long, help: "Share this project folder into the box at the same path and start there.")
        var project: String?

        @Flag(name: .customLong("read-only"), help: "Share the project read only.")
        var readOnly = false

        @OptionGroup var options: StoreOptions

        func validate() throws {
            if readOnly && project == nil {
                throw ValidationError("--read-only applies to --project")
            }
            if isatty(STDIN_FILENO) != 1 {
                throw ValidationError("box shell needs a terminal on stdin; use `agent-vm exec` to run commands from a script")
            }
        }

        func run() throws {
            // The account's own shell: the guest daemon sets SHELL from the account.
            ExecRunner(store: options.boxStore, box: name, user: user, cwd: nil, project: project, readOnly: readOnly,
                       added: [:], argv: ["/bin/sh", "-c", "exec \"$SHELL\" -l"], terminal: true).run()
        }
    }

    struct ExecLogCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "execlog",
            abstract: "Show what agent-vm exec and box shell ran in a box.",
            discussion: """
                One entry per program: when it started, how long it ran, its exit status, the \
                account and the command. The log is kept on this Mac (Boxes/<name>/exec.jsonl), \
                out of the box's reach, until the box is deleted. It never holds the \
                programs' environment.
                """)

        @Argument(help: "The box name.")
        var name: String

        @Option(name: .long, help: "Only the last N programs.")
        var last: Int?

        @OptionGroup var options: StoreOptions

        func validate() throws {
            if let last, last < 0 {
                throw ValidationError("--last takes a count of 0 or more")
            }
        }

        func run() throws {
            let box = try options.boxStore.box(named: name)
            let records = ExecLog(url: box.execLogURL).records(last: last)
            if options.json {
                try Output.json(records)
                return
            }
            if records.isEmpty {
                print("Nothing run in box \(box.name) yet.")
                return
            }
            for record in records {
                let outcome: String
                if let status = record.status {
                    outcome = "status \(status)"
                } else {
                    outcome = "no end recorded"
                }
                let duration = record.seconds.map { String(format: "%.1f s", $0) } ?? "-"
                var line = "\(Output.time(record.started))  \(outcome.padding(toLength: 15, withPad: " ", startingAt: 0))  "
                line += "\(duration.padding(toLength: 9, withPad: " ", startingAt: 0))  \(record.user ?? "?")"
                if record.terminal == true {
                    line += " (terminal)"
                }
                line += "  \(Output.shellQuoted(record.argv))"
                if let project = record.project {
                    line += "  [project \(project)\(record.readOnly == true ? ", read only" : "")]"
                }
                if let prompts = record.prompts, !prompts.isEmpty {
                    let what = record.stoppedOnPrompt == true ? "stopped while waiting" : "waited"
                    line += "  (\(what) on a permission prompt for \(prompts.joined(separator: ", ")))"
                }
                print(line)
            }
        }
    }

    struct NetLog: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "netlog",
            abstract: "Show a box's network log: every connection the proxy allowed or refused.")

        @Argument(help: "The box name.")
        var name: String

        @Option(name: .long, help: "Only the last N entries.")
        var last: Int?

        @Flag(name: .long, help: "Only refused and failed connections.")
        var denied = false

        @OptionGroup var options: StoreOptions

        func validate() throws {
            if let last, last < 0 {
                throw ValidationError("--last takes a count of 0 or more")
            }
        }

        func run() throws {
            let box = try options.boxStore.box(named: name)
            var entries = NetworkLog(url: box.networkLogURL).entries()
            if denied {
                entries = entries.filter { $0.decision != .allowed }
            }
            if let last, entries.count > last {
                entries = Array(entries.suffix(last))
            }
            if options.json {
                try Output.json(entries)
                return
            }
            if entries.isEmpty {
                print("No connections logged for box \(box.name).")
                return
            }
            for entry in entries {
                let decision = entry.decision.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)
                var line = "\(Output.time(entry.time))  \(decision)  \(entry.method) \(entry.host):\(entry.port)"
                if let rule = entry.rule {
                    line += "  [\(rule)]"
                }
                if let reason = entry.reason {
                    line += "  \(reason)"
                }
                if let up = entry.bytesUp, let down = entry.bytesDown {
                    line += "  \(up) up, \(down) down"
                }
                print(line)
            }
        }
    }

    struct Packs: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the host packs usable as --allow pack:<name>.")

        @Flag(name: .long, help: "Print machine-readable JSON instead of text.")
        var json = false

        struct Entry: Encodable {
            var name: String
            var hosts: [String]
        }

        func run() throws {
            if json {
                try Output.json(NetworkPacks.all.keys.sorted().map { Entry(name: $0, hosts: NetworkPacks.all[$0]!) })
                return
            }
            for name in NetworkPacks.all.keys.sorted() {
                print("pack:\(name)")
                print("    \(NetworkPacks.all[name]!.joined(separator: ", "))")
            }
        }
    }

    struct Serve: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run a box in the foreground as its supervisor (box start does this in the background).",
            shouldDisplay: false)

        @Argument(help: "The box name.")
        var name: String

        @OptionGroup var options: StoreOptions

        @MainActor
        func run() async throws {
            // Control clients that go away mid-write must not end the supervisor.
            signal(SIGPIPE, SIG_IGN)
            let box = try options.boxStore.box(named: name)
            // In a login session main runs AppKit's loop (see Main): the supervisor is then an
            // application without a Dock icon, and `box view` can show the box's screen.
            let windows = Self.runsAppKit
            let supervisor = BoxSupervisor(box: box, windows: windows) { line in
                let formatter = ISO8601DateFormatter()
                print("\(formatter.string(from: Date())) \(line)")
                fflush(stdout)
            }
            guard windows else {
                try await supervisor.run()
                return
            }
            // No App Nap for a background application that serves a VM, its proxy and execs.
            let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "running box \(box.name)")
            let delegate = SupervisorApplicationDelegate { supervisor.requestStop() }
            NSApplication.shared.delegate = delegate
            defer {
                withExtendedLifetime((activity, delegate)) {}
            }
            try await supervisor.run()
        }

        /// Set by main when it runs AppKit's loop for this supervisor.
        @MainActor static var runsAppKit = false

        /// `agent-vm box serve <name>` in a login session (with a window server).
        static func shouldRunAppKit(_ arguments: [String]) -> Bool {
            return Array(arguments.dropFirst().prefix(2)) == ["box", "serve"] && BoxSupervisor.canShowWindows
        }
    }
}
