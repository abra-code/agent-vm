// Sources/agent-vm/ImageCommand.swift
//
// `agent-vm image ...`: golden images, the installed and set-up macOS guests that boxes will
// be cloned from.

import AgentVMKit
import ArgumentParser
import Foundation

struct ImageCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "image",
        abstract: "Build and manage golden macOS images.",
        discussion: """
            An image is macOS installed from a restore image (.ipsw) and set up with no clicks: \
            macOS 27's guest provisioning creates an administrator account, logs it in \
            automatically and turns on Remote Login. agent-vm then installs its guest daemon \
            (agent-vm-guest, found next to agent-vm), checks it over vsock, turns Remote Login \
            off again and shuts the guest down. Starting virtual machines needs the binaries \
            built by Scripts/build.sh (see `agent-vm doctor`).
            """,
        subcommands: [Create.self, List.self, Delete.self, Setup.self, UpdateGuest.self]
    )

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Build an image: install macOS from a restore image, or start from another image.",
            discussion: """
                With --ipsw, macOS is installed and set up with no clicks (about 6 minutes). With \
                --from, a ready image is cloned and the recipe applied to the clone (minutes, and \
                one base image can carry several tool sets).
                """)

        @Argument(help: "Name of the new image (lower-case letters, digits, \".\", \"_\", \"-\").")
        var name: String

        @Option(name: .long, help: "The macOS restore image (.ipsw) to install.")
        var ipsw: String?

        @Option(name: .long, help: "A ready image to start from instead of a restore image.")
        var from: String?

        @Option(name: .long, help: "Virtual CPUs (default \(ImageBuildOptions.defaultCPUCount), or the base image's).")
        var cpus: Int?

        @Option(name: .customLong("memory-gb"), help: "Memory in GB (default \(ImageBuildOptions.defaultMemoryBytes >> 30), or the base image's).")
        var memoryGB: Int?

        @Option(name: .customLong("disk-gb"), help: "Disk size in GB (default \(ImageBuildOptions.defaultDiskBytes >> 30); a sparse file that takes only what the guest writes). With --from: a larger disk than the base's (default: the base's).")
        var diskGB: Int?

        @Option(name: .long, help: "Account name created in the guest (default agent). Not with --from.")
        var user: String?

        @Option(name: .customLong("guest-daemon"), help: "The agent-vm-guest executable to install (default: the one next to agent-vm). Not with --from.")
        var guestDaemon: String?

        @Flag(name: .customLong("command-line-tools"), inversion: .prefixedNo,
              help: "Install Xcode's Command Line Tools (clang, swift, git, python3; about 530 MB, needs the internet). Default: yes for --ipsw, or what the recipe says; with --from, only if the base lacks them.")
        var commandLineTools: Bool?

        @Option(name: .long, help: "A JSON recipe of steps to run in the image (see Docs/image-recipes.md).")
        var recipe: String?

        @Option(name: .customLong("input"), help: ArgumentHelp("A file the recipe asks for, streamed into the image while it is built (repeatable).", valueName: "name=path"))
        var inputs: [String] = []

        @Option(name: .customLong("set"), help: ArgumentHelp("A value for one of the recipe's parameters (repeatable).", valueName: "name=value"))
        var settings: [String] = []

        @OptionGroup var options: StoreOptions

        func validate() throws {
            guard (ipsw == nil) != (from == nil) else {
                throw ValidationError("give either --ipsw (install macOS) or --from (start from a ready image)")
            }
            if recipe == nil && !(inputs.isEmpty && settings.isEmpty) {
                throw ValidationError("--input and --set give values to a recipe's inputs and parameters; add --recipe")
            }
            for pair in inputs + settings where !pair.contains("=") || pair.hasPrefix("=") {
                throw ValidationError("\(pair): give name=value")
            }
            if from != nil {
                guard user == nil, guestDaemon == nil else {
                    throw ValidationError("--user and --guest-daemon come from the base image with --from")
                }
                guard recipe != nil || commandLineTools == true else {
                    throw ValidationError("with --from, give --recipe (or --command-line-tools): otherwise the new image would be a plain copy")
                }
            }
            for (value, limit, option) in [(cpus, 256, "--cpus"), (memoryGB, 4096, "--memory-gb"), (diskGB, 65536, "--disk-gb")] {
                if let value, !(1...limit).contains(value) {
                    throw ValidationError("\(option) must be between 1 and \(limit)")
                }
            }
        }

        @MainActor
        func run() async throws {
            let json = options.json
            // Checked before anything is built: a bad recipe fails in a second, not after install.
            let loadedRecipe = try recipe.map {
                try ImageRecipe.load(from: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath))
                    .binding(inputs: try Self.pairs(inputs, option: "--input"), parameters: try Self.pairs(settings, option: "--set"))
            }
            let builder = ImageBuilder(store: options.imageStore) { line in
                // With --json, progress goes to stderr so stdout holds only the record.
                if json {
                    FileHandle.standardError.write(Data((line + "\n").utf8))
                } else {
                    print(line)
                }
            }
            let image: GoldenImage
            if let from {
                image = try await builder.derive(ImageDeriveOptions(
                    name: name,
                    base: from,
                    recipe: loadedRecipe,
                    commandLineTools: commandLineTools ?? loadedRecipe?.commandLineTools ?? false,
                    cpuCount: cpus,
                    memoryBytes: memoryGB.map { UInt64($0) << 30 },
                    diskBytes: diskGB.map { UInt64($0) << 30 },
                    guestDaemon: try ImageCommand.localGuestDaemon()))
            } else {
                image = try await builder.build(ImageBuildOptions(
                    name: name,
                    restoreImage: URL(fileURLWithPath: ((ipsw ?? "") as NSString).expandingTildeInPath),
                    cpuCount: cpus ?? ImageBuildOptions.defaultCPUCount,
                    memoryBytes: memoryGB.map { UInt64($0) << 30 } ?? ImageBuildOptions.defaultMemoryBytes,
                    diskBytes: diskGB.map { UInt64($0) << 30 } ?? ImageBuildOptions.defaultDiskBytes,
                    userName: user ?? "agent",
                    askpassProgram: try AskpassEntry.executablePath(),
                    guestDaemon: try guestDaemonURL(),
                    commandLineTools: commandLineTools ?? loadedRecipe?.commandLineTools ?? true,
                    recipe: loadedRecipe))
            }
            if json {
                try Output.json(image.record)
                return
            }
            print("Image \(image.name) is ready: \(image.directory.path)")
        }

        /// "name=value" pairs as a map; a name given twice is refused.
        static func pairs(_ list: [String], option: String) throws -> [String: String] {
            var result: [String: String] = [:]
            for pair in list {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = String(parts[0])
                guard result[name] == nil else {
                    throw ValidationError("\(option) \(name) is given twice")
                }
                result[name] = parts.count > 1 ? String(parts[1]) : ""
            }
            return result
        }

        private func guestDaemonURL() throws -> URL {
            if let guestDaemon {
                return URL(fileURLWithPath: (guestDaemon as NSString).expandingTildeInPath)
            }
            return try ImageCommand.localGuestDaemon()
        }
    }

    /// The agent-vm-guest built with this agent-vm, next to it.
    static func localGuestDaemon() throws -> URL {
        return URL(fileURLWithPath: try AskpassEntry.executablePath()).deletingLastPathComponent().appendingPathComponent("agent-vm-guest")
    }

    struct Setup: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "setup",
            abstract: "Do an image's one-time steps in its own interface: Full Disk Access for the guest daemon.",
            discussion: """
                Boots the image with its screen in an interactive window on this Mac. System \
                Settings opens on Full Disk Access, and Finder shows agent-vm-guest: drag it into \
                the list, turn it on, and press Type Password when macOS asks for the \
                administrator password. The window notices the grant. Do any other one-time steps \
                the image needs, then close the window: the image shuts down, and boxes made from \
                it afterwards inherit what was done. Without Full Disk Access, a program in a box \
                that opens the account's Desktop, Documents or Downloads waits on a prompt that \
                nobody sees. Needs a login session on this Mac (not SSH).
                """)

        @Argument(help: "The image to set up.")
        var name: String

        @OptionGroup var options: StoreOptions

        /// `agent-vm image setup ...` runs AppKit's loop from main, for the window.
        static func shouldRunAppKit(_ arguments: [String]) -> Bool {
            return Array(arguments.dropFirst().prefix(2)) == ["image", "setup"] && BoxSupervisor.canShowWindows
        }

        @MainActor
        func run() async throws {
            let json = options.json
            let builder = ImageBuilder(store: options.imageStore) { line in
                if json {
                    FileHandle.standardError.write(Data((line + "\n").utf8))
                } else {
                    print(line)
                }
            }
            let image = try await builder.setUp(named: name)
            if json {
                try Output.json(image.record)
                return
            }
            let granted = image.record.fullDiskAccess?.granted == true
            print("Image \(image.name) is set up\(granted ? "" : "; agent-vm-guest has no Full Disk Access yet (run image setup again to grant it)")")
        }
    }

    struct UpdateGuest: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "update-guest",
            abstract: "Put this agent-vm's guest daemon into ready images.",
            discussion: """
                Boots the image, replaces its agent-vm-guest with the one next to agent-vm when \
                they differ, and boots it once more to check the new one (a minute or two). \
                Needed when a newer agent-vm brings guest features (`image list` names what an \
                image lacks); boxes made from the image earlier keep their daemon, so create \
                them again. Images built with `--from` get the current daemon automatically. \
                Several images are updated one after another, in the order given; every name is \
                checked before the first boot, and the first failure stops the rest (a daemon \
                that does not start marks its image failed, and would mark the next one too). \
                With --json: the image's record, or an array of them for several names (on a failure, the images updated before it).
                """)

        @Argument(help: ArgumentHelp("The images to update.", valueName: "image"))
        var names: [String]

        @OptionGroup var options: StoreOptions

        @MainActor
        func run() async throws {
            let json = options.json
            let builder = ImageBuilder(store: options.imageStore) { line in
                if json {
                    FileHandle.standardError.write(Data((line + "\n").utf8))
                } else {
                    print(line)
                }
            }
            let names = names.reduce(into: [String]()) { unique, name in
                if !unique.contains(name) {
                    unique.append(name)
                }
            }
            let guestDaemon = try ImageCommand.localGuestDaemon()
            // A mistyped last name should not surface after the first images took minutes each.
            for name in names {
                _ = try builder.updatableImage(named: name)
            }
            var records: [ImageRecord] = []
            for (index, name) in names.enumerated() {
                let image: GoldenImage
                do {
                    image = try await builder.updateGuest(named: name, guestDaemon: guestDaemon)
                } catch {
                    let skipped = names[(index + 1)...]
                    if !skipped.isEmpty {
                        FileHandle.standardError.write(Data("Stopped at image \(name); not updated: \(skipped.joined(separator: ", "))\n".utf8))
                    }
                    // The images before this one are updated; a program should not have to
                    // list the store to learn which.
                    if json && names.count > 1 {
                        try Output.json(records)
                    }
                    throw error
                }
                records.append(image.record)
                if !json {
                    print("Image \(image.name) has agent-vm-guest \(image.record.guestVersion ?? "?") (\((image.record.guestFeatures ?? []).joined(separator: ", ")))")
                }
            }
            if json {
                if records.count == 1 {
                    try Output.json(records[0])
                } else {
                    try Output.json(records)
                }
            }
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List images.")

        @OptionGroup var options: StoreOptions

        /// An image's record with its folder and space added as two more keys, so a program
        /// reading the records as before sees no change.
        struct Entry: Encodable {
            var record: ImageRecord
            var path: String
            var diskUsage: DiskUsage

            private enum Keys: String, CodingKey {
                case path
                case diskUsage
            }

            func encode(to encoder: Encoder) throws {
                try record.encode(to: encoder)
                var container = encoder.container(keyedBy: Keys.self)
                try container.encode(path, forKey: .path)
                try container.encode(diskUsage, forKey: .diskUsage)
            }
        }

        func run() throws {
            let (images, problems) = try options.imageStore.list()
            for problem in problems {
                FileHandle.standardError.write(Data("warning: \(problem)\n".utf8))
            }
            if options.json {
                try Output.json(images.map { image in
                    Entry(record: image.record, path: image.directory.path, diskUsage: DiskUsage.of(image.directory))
                })
                return
            }
            if images.isEmpty {
                print("No images.")
                return
            }
            for image in images {
                let record = image.record
                let state = record.state.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)
                var line = "\(record.name)  \(state)  macOS \(record.macOSVersion) (\(record.macOSBuild))  \(record.cpuCount) CPUs  \(record.memoryBytes >> 30) GB  created \(Output.time(record.createdAt))"
                if let base = record.derivedFrom {
                    line += "  from \(base.image)"
                }
                if let recipe = record.recipe {
                    line += "  recipe \(recipe.description ?? String(recipe.digest.prefix(12)))"
                    if let parameters = recipe.parameters, !parameters.isEmpty {
                        line += " [\(parameters.keys.sorted().map { "\($0)=\(parameters[$0] ?? "")" }.joined(separator: ", "))]"
                    }
                }
                print(line)
                for place in Output.placeLines(image.directory, DiskUsage.of(image.directory), others: "other images or boxes", delete: "image delete") {
                    print(place)
                }
                let missing = GuestFeature.all.filter { !(record.guestFeatures ?? []).contains($0) }
                if record.state == .ready && !missing.isEmpty {
                    print("    agent-vm-guest lacks \(missing.joined(separator: ", ")); `agent-vm image update-guest \(record.name)` adds it")
                }
                if record.state == .ready {
                    switch record.hasFullDiskAccess {
                    case true?:
                        break
                    case false?:
                        print("    agent-vm-guest has no Full Disk Access: programs in boxes that open Desktop, Documents or Downloads wait on a hidden prompt; `agent-vm image setup \(record.name)`")
                    case nil:
                        print("    Full Disk Access for agent-vm-guest is not checked\(record.fullDiskAccess == nil ? "" : " for its current version"); `agent-vm image setup \(record.name)`")
                    }
                }
                if let failure = record.failure {
                    print("    failed: \(failure)")
                }
            }
        }
    }

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete an image and its disk. Refused while another agent-vm process uses it.")

        @Argument(help: "The image name.")
        var name: String

        @OptionGroup var options: StoreOptions

        func run() throws {
            try options.imageStore.delete(named: name)
            if !options.json {
                print("Deleted image \(name)")
            }
        }
    }
}

/// agent-vm doubles as ssh's askpass program while an image is built (see GuestSSH).
enum AskpassEntry {
    /// Answers ssh and exits when this process was started as askpass; returns otherwise.
    static func handleIfAskpass() {
        switch GuestSSH.askpassAnswer(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment) {
        case .notAskpass:
            return
        case .refuse:
            exit(1)
        case let .password(password):
            FileHandle.standardOutput.write(Data((password + "\n").utf8))
            exit(0)
        }
    }

    /// This executable's absolute path, for SSH_ASKPASS.
    static func executablePath() throws -> String {
        guard let url = Bundle.main.executableURL else {
            throw AgentVMError.system(operation: "find the agent-vm executable", code: ENOENT)
        }
        return url.resolvingSymlinksInPath().path
    }
}
