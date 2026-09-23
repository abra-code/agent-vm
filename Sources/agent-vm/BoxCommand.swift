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
            supervisor process; `agent-vm exec --box <name> -- <program>` runs programs in it. \
            Networking is NAT for now: a box can reach the internet and your local network.
            """,
        subcommands: [Create.self, List.self, Start.self, Stop.self, Delete.self, Serve.self]
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
                                                  cpuCount: cpus, memoryBytes: memoryGB.map { UInt64($0) << 30 })
            if options.json {
                try Output.json(box.record)
                return
            }
            print("Created box \(box.name) from image \(image.name): \(box.directory.path)")
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
                print("\(record.name)  \(state)  image \(record.image) (macOS \(record.macOSBuild))  \(record.cpuCount) CPUs  \(record.memoryBytes >> 30) GB")
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
