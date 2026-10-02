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
            Network modes: allowlist (default) - only listed hosts (or, with the rule public, any \
            public host name), through a proxy on this Mac that logs every attempt; off - \
            nothing; open - NAT to the internet and your local network. See `box network`, `box netlog` and `box packs`. `box shell` opens a shell in \
            the box on this terminal, `box view` shows its screen in a window, `box send` \
            copies files from this Mac into its Downloads folder, `box execlog` \
            shows what exec and shell ran there, `box status` shows its state without \
            starting anything, and `box info` adds the space it takes on disk.
            """,
        subcommands: [Create.self, Recreate.self, List.self, Status.self, Info.self, Start.self, GC.self, SyncClock.self, Stop.self, Delete.self, Shell.self, View.self, ExecLogCommand.self, Network.self, NetLog.self, Send.self,
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

        @Option(name: .long, help: "Allow a host (github.com), subdomains (*.example.com), host:port, pack:<name>, or public (any public host name, logged; public:port for another port) (repeatable).")
        var allow: [String] = []

        @Flag(name: .long, help: "A box for one session: once it stops, it is not started again, and `box gc` (run by box list, box start and doctor) deletes it.")
        var disposable = false

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
                                                  network: BoxNetwork(mode: net, allow: allow), disposable: disposable)
            if options.json {
                try Output.json(box.record)
                return
            }
            print("Created \(disposable ? "disposable " : "")box \(box.name) from image \(image.name): \(box.directory.path)")
            print("  network: \(Network.describe(box.record.effectiveNetwork))")
            print("  start it with: agent-vm box start \(box.name)")
        }
    }

    struct Recreate: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete a stopped box and create it again with the same settings.",
            discussion: """
                The new box is a fresh clone of the image (its current state: after `image \
                update-guest`, with the new agent-vm-guest), with the box's CPUs, memory, network \
                rules and disposable flag, a new identity, and empty logs. Everything written in \
                the old box is gone. --image switches to another image.
                """)

        @Argument(help: "The box name.")
        var name: String

        @Option(name: .long, help: "The image to clone (default: the box's own).")
        var image: String?

        @OptionGroup var options: StoreOptions

        func run() throws {
            let old = try options.boxStore.box(named: name)
            let image = try options.imageStore.image(named: image ?? old.record.image)
            let box = try options.boxStore.recreate(name: name, from: image, imageStore: options.imageStore)
            if options.json {
                try Output.json(box.record)
                return
            }
            print("Recreated \(box.record.disposable == true ? "disposable " : "")box \(box.name) from image \(image.name): \(box.directory.path)")
            print("  network: \(Network.describe(box.record.effectiveNetwork))")
            print("  start it with: agent-vm box start \(box.name)")
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List boxes and whether they run.")

        @OptionGroup var options: StoreOptions

        /// A box as `box list`, `box status` and `box info` print it: the record, whether a
        /// supervisor holds it, its folder, and the status fields (BoxStatus) as more keys.
        /// Only `box info` measures the box's space (`sizes`): a scan of the folder's files,
        /// about 0.1 s per box, which a list and a quick status check should not pay.
        struct Entry: Encodable {
            var box: BoxRecord
            var running: Bool
            var path: String
            var diskUsage: DiskUsage?
            var status: BoxStatus
            /// What it lacks next to its image (BoxNeed): `recreate` after `image update`,
            /// `image update-guest` or a rebuild of the image.
            var needs: [BoxNeed]

            /// `image`: the box's image's record now, nil when it is gone.
            init(_ box: Box, image: ImageRecord?, sizes: Bool = false) {
                self.status = BoxStatus.of(box)
                self.box = box.record
                self.needs = box.record.needs(image: image)
                // Held by a supervisor (or, briefly, by another command changing the box).
                self.running = status.state != .stopped
                self.path = box.directory.path
                self.diskUsage = sizes ? DiskUsage.of(box.directory) : nil
            }

            private enum Keys: String, CodingKey {
                case box
                case running
                case path
                case diskUsage
                case needs
                case passwordStorage
            }

            func encode(to encoder: Encoder) throws {
                try status.encode(to: encoder)
                var container = encoder.container(keyedBy: Keys.self)
                try container.encode(box, forKey: .box)
                try container.encode(running, forKey: .running)
                try container.encode(path, forKey: .path)
                try container.encodeIfPresent(diskUsage, forKey: .diskUsage)
                try container.encode(needs, forKey: .needs)
                // Where the account's password is: keychain or file.
                try container.encode(box.passwordID == nil ? AccountPassword.Storage.file : .keychain, forKey: .passwordStorage)
            }

            /// Every image's record by name, for the entries' needs; images that cannot be
            /// read are left out (their boxes then need nothing).
            static func images(_ store: ImageStore) -> [String: ImageRecord] {
                let images = (try? store.list().images) ?? []
                return Dictionary(images.map { ($0.name, $0.record) }, uniquingKeysWith: { first, _ in first })
            }

            /// The box's image's record, for one entry.
            static func image(of box: Box, in store: ImageStore) -> ImageRecord? {
                return try? store.image(named: box.record.image).record
            }

            /// The entry for a person: a line with the essentials, then indented details.
            var lines: [String] {
                // padding(toLength:) truncates: "unresponsive" is longer than the column.
                let name = status.state.rawValue
                let state = name.padding(toLength: max(8, name.count), withPad: " ", startingAt: 0)
                var lines = ["\(box.name)  \(state)  image \(box.image) (macOS \(box.macOSBuild))  \(box.cpuCount) CPUs  \(box.memoryBytes >> 30) GB  network \(box.effectiveNetwork.mode.rawValue)\(box.disposable == true ? "  disposable" : "")"]
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
                    if let version = status.guestVersion, status.state == .running {
                        let features = status.guestFeatures ?? []
                        lines.append("    agent-vm-guest \(version)\(features.isEmpty ? "" : " (\(features.joined(separator: ", ")))")")
                    }
                    if let project = status.project {
                        lines.append("    project \(project)\(status.projectReadOnly == true ? " (read only)" : "")")
                    }
                    if let owner = status.ownerPid {
                        lines.append("    stops when process \(owner) exits")
                    }
                    if let execs = status.activeExecs, execs > 0 {
                        lines.append("    \(execs) program\(execs == 1 ? "" : "s") running through exec or box shell")
                    }
                }
                for need in needs where need.kind == .recreate {
                    let why: String
                    switch need.reason {
                    case .imageUpdated?:
                        why = "image \(box.image) was updated since this box was made\(need.macOSBuild.map { $0 == box.macOSBuild ? "" : " (macOS \($0) now)" } ?? "")"
                    case .imageRebuilt?:
                        why = "image \(box.image) was built again since this box was made"
                    default:
                        why = "image \(box.image) has a different agent-vm-guest\(need.guestVersion.map { " (\($0))" } ?? "") from the one this box was made with"
                    }
                    lines.append("    needs recreate: \(why); `agent-vm box recreate \(box.name)` makes it again (what it keeps is lost)")
                }
                guard let diskUsage else {
                    return lines + ["    \(path)"]
                }
                return lines + Output.placeLines(URL(fileURLWithPath: path), diskUsage, others: "its image or other boxes", delete: "box delete")
            }
        }

        func run() throws {
            GC.collect(options.boxStore)
            let (boxes, problems) = try options.boxStore.list()
            for problem in problems {
                Stderr.write("warning: \(problem)\n")
            }
            let images = Entry.images(options.imageStore)
            let entries = boxes.map { Entry($0, image: images[$0.record.image]) }
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
                means something holds the box but its supervisor does not answer. It also says \
                when the box needs recreating: its image was updated or built again since, or \
                its agent-vm-guest is no longer the one the box was made with. With --json, the same entry as `box list --json`, with \
                `needs`. It measures nothing; `box info` adds the \
                box's space on disk.
                """)

        @Argument(help: "The box name.")
        var name: String

        @OptionGroup var options: StoreOptions

        func run() throws {
            let box = try options.boxStore.box(named: name)
            let entry = List.Entry(box, image: List.Entry.image(of: box, in: options.imageStore))
            if options.json {
                try Output.json(entry)
                return
            }
            for line in entry.lines {
                print(line)
            }
        }
    }

    struct Info: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show one box, with its space on disk.",
            discussion: """
                The box's `box status`, plus its space: all of it, and the part no image or \
                other box shares, which is what `box delete` frees (what the box wrote, plus \
                image blocks the image rewrote after the box was made). With --json, the status \
                entry with `diskUsage` (`bytes`, and `unsharedBytes` unless the volume does not \
                report it). Measuring takes a moment: about 0.1 s per disk.
                """)

        @Argument(help: "The box name.")
        var name: String

        @OptionGroup var options: StoreOptions

        func run() throws {
            let box = try options.boxStore.box(named: name)
            let entry = List.Entry(box, image: List.Entry.image(of: box, in: options.imageStore), sizes: true)
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

        @Option(name: .customLong("owner-pid"), help: "Stop the box when this process (of yours) exits, for example the application that started it. Ignored when the box already runs.")
        var ownerPid: Int32?

        @OptionGroup var options: StoreOptions

        func validate() throws {
            if let ownerPid, !OwnerWatch.isUsableOwner(ownerPid) {
                throw ValidationError("--owner-pid \(ownerPid): no such process of yours")
            }
        }

        func run() throws {
            let box = try options.boxStore.box(named: name)
            if box.isTombstoned && !box.isRunning {
                GC.collect(options.boxStore)
                throw AgentVMError.boxDisposed(box.name)
            }
            // The others: a disposable box created long ago but never started is this one's to start.
            GC.collect(options.boxStore, except: box.name)
            // Starting a running box succeeds, so clients can simply make sure a box is up.
            if box.isRunning, let status = try? ControlClient.request(.status, path: box.controlSocketPath), status.state == .ready {
                if options.json {
                    try Output.json(BoxStatus.from(status))
                } else {
                    let owner = status.ownerPid.map { ", stops when process \($0) exits" } ?? ""
                    print("Box \(box.name) is already running (supervisor pid \(status.pid ?? 0)\(owner))\(ownerPid == nil ? "" : "; --owner-pid is ignored")")
                }
                return
            }
            let clock = ContinuousClock()
            let began = clock.now
            let response: ControlResponse
            do {
                response = try BoxLauncher.start(box, executable: try AskpassEntry.executablePath(), ownerPid: ownerPid) { state in
                    // The supervisor's "ready" is a box that is running, as box status says it.
                    let step = state == ControlResponse.State.ready.rawValue ? BoxStatus.State.running.rawValue : state
                    // A box that was stopping is waited for, then started again.
                    let text = state == ControlResponse.State.stopping.rawValue ? "  waiting for the box to stop" : "  \(step)"
                    Events.emit(ProgressEvent(.progress, text, step: step, box: box.name), json: options.json)
                }
            } catch AgentVMError.boxDisposed(let name) {
                // A disposable box that was stopping has stopped for good.
                GC.collect(options.boxStore)
                throw AgentVMError.boxDisposed(name)
            }
            if options.json {
                try Output.json(BoxStatus.from(response))
                return
            }
            let elapsed = clock.now - began
            print("Box \(box.name) is running (\(elapsed.formatted(.units(allowed: [.seconds], width: .narrow))), agent-vm-guest \(response.guestVersion ?? "?"), supervisor pid \(response.pid ?? 0))")
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
                Rules can change while the box runs: the proxy rereads them at once, and closes \
                every open connection the new rules no longer allow. The mode \
                decides the box's network card, so it changes only while the box is stopped. \
                Rules: a host (github.com), subdomains (*.example.com), host:port, pack:<name>, or \
                public - any public host name (not an IP address or a local name), still logged, \
                and never an address on this Mac or your local network; public:port allows \
                another port than 443 and 80.
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

        /// The first supervisor that knows the public rule.
        static let publicRuleVersion = "0.2.2"

        /// An older supervisor reads "public" as a host of that name, which nothing is called:
        /// refused, so the rule is not saved looking as if it worked.
        static func checkSupervisorKnowsPublic(_ box: Box, adding rules: [String]) throws {
            guard box.isRunning, rules.contains(where: { AllowRule.parse($0)?.anyPublicHost == true }) else {
                return
            }
            let status = BoxStatus.of(box)
            // Stopped since, or not answering: the reload below reports that.
            guard status.state != .stopped && status.state != .unresponsive else {
                return
            }
            guard let version = status.supervisorVersion, version.compare(publicRuleVersion, options: .numeric) != .orderedAscending else {
                throw AgentVMError.supervisorRefused("box \(box.name) was started by an agent-vm older than \(publicRuleVersion), which does not know the public rule; stop it (`agent-vm box stop \(box.name)`), add the rule, then start it again")
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
                try Self.checkSupervisorKnowsPublic(box, adding: allow)
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

        @Option(name: .customLong("secret"), parsing: .singleValue, help: SecretOptions.help)
        var secrets: [String] = []

        @OptionGroup var options: StoreOptions

        func validate() throws {
            if readOnly && project == nil {
                throw ValidationError("--read-only applies to --project")
            }
            try SecretOptions.validate(secrets)
            if isatty(STDIN_FILENO) != 1 {
                throw ValidationError("box shell needs a terminal on stdin; use `agent-vm exec` to run commands from a script")
            }
        }

        func run() throws {
            // The account's own shell: the guest daemon sets SHELL from the account.
            ExecRunner(store: options.boxStore, box: name, user: user, cwd: nil, project: project, readOnly: readOnly,
                       added: SecretOptions.resolve(secrets), argv: ["/bin/sh", "-c", "exec \"$SHELL\" -l"], terminal: true).run()
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
            abstract: "Show a box's network log: every connection the proxy allowed or refused.",
            discussion: """
                Connections are listed in the order they were made. An allowed one shows its \
                bytes once it has ended; while it is open, the bytes it had carried when the \
                proxy last noted them (once a minute). Allowed connections are kept in a file of \
                their own (Boxes/<name>/network-allowed.jsonl, refusals in network.jsonl), so a \
                box that floods the log with refused requests cannot push them out.
                """)

        @Argument(help: "The box name.")
        var name: String

        @Option(name: .long, help: "Only the last N entries.")
        var last: Int?

        @Flag(name: .long, help: "Only refused and failed connections.")
        var denied = false

        @Flag(name: .shortAndLong, help: "Keep printing connections as they are logged (after the last 10, or --last N), until the box stops. With --json, one JSON object per line.")
        var follow = false

        @OptionGroup var options: StoreOptions

        /// How often --follow looks for new lines and checks that the box still runs.
        static let followInterval: useconds_t = 250_000

        func validate() throws {
            if let last, last < 0 {
                throw ValidationError("--last takes a count of 0 or more")
            }
        }

        func run() throws {
            let box = try options.boxStore.box(named: name)
            if follow {
                try runFollowing(box)
                return
            }
            let entries = NetworkLog(url: box.networkLogURL).entries(last: last, liveSince: Self.liveSince(box), includeAllowed: !denied, matching: matching)
            if options.json {
                try Output.json(entries)
                return
            }
            if entries.isEmpty {
                print("No connections logged for box \(box.name).")
                return
            }
            for entry in entries {
                print(Self.text(entry))
            }
        }

        /// --follow: what is logged (its end), then each new entry as it comes, until the box
        /// stops. The box is checked before each read, so the lines a stopping box logged last
        /// are printed before the command ends.
        private func runFollowing(_ box: Box) throws {
            let follower = NetworkLogFollower(url: box.networkLogURL, includeAllowed: !denied)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            var first = true
            while true {
                let running = box.isRunning
                let entries: [NetworkLog.Entry]
                if first {
                    entries = follower.start(last: last ?? 10, liveSince: Self.liveSince(box), matching: matching)
                    first = false
                } else {
                    entries = follower.read().filter(matching)
                }
                for entry in entries {
                    if options.json {
                        // As it is, like every other JSON output: JSON's own escapes, no "?".
                        Swift.print(String(decoding: try encoder.encode(entry), as: UTF8.self))
                    } else {
                        print(Self.text(entry))
                    }
                }
                guard running else {
                    return
                }
                usleep(Self.followInterval)
            }
        }

        func matching(_ entry: NetworkLog.Entry) -> Bool {
            return !denied || entry.decision != .allowed
        }

        /// A connection logged as open before this time is not open any more: the supervisor
        /// that served it stopped before logging its end. The time is when the running
        /// supervisor started; all time when none runs; none when the supervisor does not answer.
        static func liveSince(_ box: Box) -> Date {
            let status = BoxStatus.of(box)
            switch status.state {
            case .stopped:
                return .distantFuture
            case .starting, .running, .stopping:
                return status.startedAt ?? .distantPast
            case .unresponsive:
                return .distantPast
            }
        }

        static func text(_ entry: NetworkLog.Entry) -> String {
            let decision = entry.decision.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)
            var line = "\(Output.time(entry.time))  \(decision)  \(entry.method) \(entry.host):\(entry.port)"
            if let rule = entry.rule {
                line += "  [\(rule)]"
            }
            if let reason = entry.reason {
                line += "  \(reason)"
            }
            // The bytes of a line logged while the connection ran are not its total.
            let bytes = entry.bytesUp.flatMap { up in entry.bytesDown.map { "\(up) up, \($0) down" } }
            if entry.open == true {
                line += "  open" + (bytes.map { ", \($0) so far" } ?? "")
            } else if entry.endNotLogged {
                line += "  end not logged (the box stopped)" + (bytes.map { "; \($0) before that" } ?? "")
            } else if let bytes {
                line += "  \(bytes)"
            }
            return line
        }
    }

    struct Packs: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List the host packs usable as --allow pack:<name>.",
            discussion: """
                The built-in packs come from packs.json next to agent-vm. Your own are \
                Packs/<name>.json in the store, each {"description": "...", "hosts": \
                ["example.com", "*.example.org", "example.net:8443"]}; one named like a built-in \
                pack replaces it. Boxes name packs, so an edited pack applies when a box starts \
                or its rules change (box network). A pack file that cannot be used is listed with \
                why, and boxes naming it are refused.
                """)

        @Flag(name: .long, help: "Print machine-readable JSON instead of text.")
        var json = false

        struct Entry: Encodable {
            var name: String
            /// Absent for a pack file that cannot be used (see `problem`).
            var hosts: [String]?
            var description: String?
            /// built-in or user.
            var source: String
            var path: String
            /// A user pack named like a built-in one, which it replaces.
            var replacesBuiltIn: Bool?
            var problem: String?
        }

        func run() throws {
            let packs = try NetworkPacks.load(store: SessionStore.defaultRoot())
            var entries = packs.packs.values.map {
                Entry(name: $0.name, hosts: $0.hosts, description: $0.description, source: $0.source.rawValue, path: $0.path,
                      replacesBuiltIn: $0.replacesBuiltIn ? true : nil)
            }
            entries += packs.problems.map { Entry(name: $0.key, source: NetworkPack.Source.user.rawValue, path: $0.value.path, problem: $0.value.reason) }
            entries.sort { $0.name < $1.name }
            if json {
                try Output.json(entries)
                return
            }
            for entry in entries {
                let origin = entry.source == NetworkPack.Source.user.rawValue
                    ? "yours, \(entry.path)\(entry.replacesBuiltIn == true ? ", replaces the built-in one" : "")"
                    : "built-in"
                print("pack:\(entry.name)  (\(origin))")
                if let problem = entry.problem {
                    print("    cannot be used: \(problem)")
                    continue
                }
                if let description = entry.description {
                    print("    \(description)")
                }
                print("    \((entry.hosts ?? []).joined(separator: ", "))")
            }
        }
    }

    struct SyncClock: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "sync-clock",
            abstract: "Set a running box's clock to this Mac's now.",
            discussion: """
                The supervisor does this by itself when the box starts, every 5 minutes, and \
                right after this Mac wakes from sleep: on the allowlist network a box has no \
                network time, and its clock falls behind. Needs an image whose agent-vm-guest has \
                the time-sync feature.
                """)

        @Argument(help: "The running box.")
        var name: String

        @OptionGroup var options: StoreOptions

        func run() throws {
            let box = try options.boxStore.box(named: name)
            guard box.isRunning else {
                throw AgentVMError.boxNotRunning(box.name)
            }
            // A supervisor before 0.2.1 cannot decode the operation and answers with a decoding
            // error, so its version is checked first.
            let status = try ControlClient.request(.status, path: box.controlSocketPath)
            guard let version = status.supervisorVersion, version.compare("0.2.1", options: .numeric) != .orderedAscending else {
                throw AgentVMError.supervisorRefused("box \(box.name) was started by an agent-vm older than 0.2.1; restart it (`agent-vm box stop \(box.name)`, then `box start`) to set its clock")
            }
            let response = try ControlClient.request(ControlRequest(op: .syncClock), path: box.controlSocketPath)
            guard response.ok, let offset = response.clockOffset else {
                throw AgentVMError.supervisorRefused(response.error ?? "no offset in the answer")
            }
            if options.json {
                try Output.json(response)
                return
            }
            print(String(format: "Set the clock of box %@ (it was %.1f s %@)", box.name, abs(offset), offset >= 0 ? "behind" : "ahead"))
        }
    }

    struct GC: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "gc",
            abstract: "Delete disposable boxes that have stopped.",
            discussion: """
                Deletes every disposable box (`box create --disposable`) whose supervisor left a \
                tombstone when it stopped, and every one created more than \(Int(BoxStore.unstartedDisposableAge / 60)) minutes \
                ago that is not running (never started, or its supervisor died). A running box is \
                never touched. `box list`, `box start` and `doctor` run it first.
                """)

        @OptionGroup var options: StoreOptions

        struct Result: Encodable {
            var deleted: [String]
            var problems: [String]
        }

        func run() throws {
            let (deleted, problems) = options.boxStore.collectGarbage()
            if options.json {
                try Output.json(Result(deleted: deleted, problems: problems))
                return
            }
            for name in deleted {
                print("Deleted disposable box \(name)")
            }
            for problem in problems {
                Stderr.write("warning: \(problem)\n")
            }
            if deleted.isEmpty && problems.isEmpty {
                print("No disposable boxes to delete.")
            }
        }

        /// For the commands that collect first: says on stderr what was deleted, so stdout
        /// keeps its own output (JSON included).
        static func collect(_ store: BoxStore, except name: String? = nil) {
            let (deleted, problems) = store.collectGarbage(except: name)
            for name in deleted {
                Stderr.write("note: deleted disposable box \(name), which had stopped\n")
            }
            for problem in problems {
                Stderr.write("warning: \(problem)\n")
            }
        }
    }

    struct Serve: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run a box in the foreground as its supervisor (box start does this in the background).",
            shouldDisplay: false)

        @Argument(help: "The box name.")
        var name: String

        @Option(name: .customLong("owner-pid"), help: "Stop the box when this process exits.")
        var ownerPid: Int32?

        @OptionGroup var options: StoreOptions

        @MainActor
        func run() async throws {
            // Control clients that go away mid-write must not end the supervisor.
            signal(SIGPIPE, SIG_IGN)
            let box = try options.boxStore.box(named: name)
            // In a login session main runs AppKit's loop (see Main): the supervisor is then an
            // application without a Dock icon, and `box view` can show the box's screen.
            let windows = Self.runsAppKit
            let supervisor = BoxSupervisor(box: box, windows: windows, ownerPid: ownerPid) { line in
                let formatter = ISO8601DateFormatter()
                // One line per entry, whatever a guest's answer quoted in it holds.
                print("\(formatter.string(from: Date())) \(Printable.line(line, limit: 4000))")
                fflush(stdout)
            }
            guard windows else {
                try await Self.run(supervisor)
                return
            }
            // No App Nap for a background application that serves a VM, its proxy and execs.
            let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "running box \(box.name)")
            let delegate = SupervisorApplicationDelegate { supervisor.requestStop() }
            NSApplication.shared.delegate = delegate
            defer {
                withExtendedLifetime((activity, delegate)) {}
            }
            try await Self.run(supervisor)
        }

        /// Runs the supervisor. Why it failed is the log's last entry and may quote a guest's
        /// answer of several lines: written as one line here, as the entries above it are,
        /// instead of as the error is printed for a person.
        @MainActor
        private static func run(_ supervisor: BoxSupervisor) async throws {
            do {
                try await supervisor.run()
            } catch let error as AgentVMError {
                // Main gives this one its own exit status.
                if case .noFreeVMSlot = error {
                    throw error
                }
                Stderr.write("Error: \(Printable.line(error.description, limit: 4000))\n")
                throw ExitCode.failure
            }
        }

        /// Set by main when it runs AppKit's loop for this supervisor.
        @MainActor static var runsAppKit = false

        /// `agent-vm box serve <name>` in a login session (with a window server).
        static func shouldRunAppKit(_ arguments: [String]) -> Bool {
            return Array(arguments.dropFirst().prefix(2)) == ["box", "serve"] && BoxSupervisor.canShowWindows
        }
    }
}
