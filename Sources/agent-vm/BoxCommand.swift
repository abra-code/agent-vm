// Sources/agent-vm/BoxCommand.swift
//
// `agent-vm box ...`: boxes are copy-on-write clones of a golden image, each run by its own
// supervisor process (`box serve`, started detached by `box start`).

import AgentVMKit
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
            network. See `box network`, `box netlog` and `box packs`.
            """,
        subcommands: [Create.self, List.self, Start.self, Stop.self, Delete.self, Network.self, NetLog.self, Packs.self, Serve.self]
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

        struct Entry: Encodable {
            var box: BoxRecord
            var running: Bool
        }

        func run() throws {
            let (boxes, problems) = try options.boxStore.list()
            for problem in problems {
                FileHandle.standardError.write(Data("warning: \(problem)\n".utf8))
            }
            if options.json {
                try Output.json(boxes.map { Entry(box: $0.record, running: $0.isRunning) })
                return
            }
            if boxes.isEmpty {
                print("No boxes.")
                return
            }
            for box in boxes {
                let record = box.record
                let state = (box.isRunning ? "running" : "stopped").padding(toLength: 8, withPad: " ", startingAt: 0)
                print("\(record.name)  \(state)  image \(record.image) (macOS \(record.macOSBuild))  \(record.cpuCount) CPUs  \(record.memoryBytes >> 30) GB  network \(record.effectiveNetwork.mode.rawValue)")
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
                if !options.json {
                    print("  \(state)")
                }
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
            try BoxLauncher.stop(box)
            if !options.json {
                print("Stopped box \(box.name)")
            }
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
                        throw AgentVMError.guestRefused(response.error ?? "the supervisor did not reload the rules")
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

        func run() throws {
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
            let supervisor = BoxSupervisor(box: box) { line in
                let formatter = ISO8601DateFormatter()
                print("\(formatter.string(from: Date())) \(line)")
                fflush(stdout)
            }
            try await supervisor.run()
        }
    }
}
