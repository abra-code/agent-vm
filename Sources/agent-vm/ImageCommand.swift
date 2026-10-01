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
        subcommands: [Create.self, List.self, Info.self, Delete.self, Setup.self, Update.self, UpdateGuest.self, FetchIPSW.self]
    )

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Build an image: install macOS from a restore image, or start from another image.",
            discussion: """
                With --ipsw, macOS is installed and set up with no clicks (about 6 minutes). With \
                --from, a ready image is cloned and the recipes applied to the clone (minutes). \
                Several --recipe options put several tool sets into one image, in the order \
                given; --input and --set go to every recipe that declares the name. SIGINT or SIGTERM stops the build at \
                the next safe point, shuts the guest down and marks the image failed (canceled); \
                agent-vm then exits with 128 + the signal.
                """)

        @Argument(help: "Name of the new image (lower-case letters, digits, \".\", \"_\", \"-\").")
        var name: String

        @Option(name: .long, help: ArgumentHelp("The macOS restore image (.ipsw) to install: a path, the file name of one `image fetch-ipsw` downloaded (see `image fetch-ipsw --list`), or latest for the newest of those. A bare name is looked for in the current directory first.", valueName: "path|name|latest"))
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

        @Option(name: .long, help: "A JSON recipe of steps to run in the image (see Docs/image-recipes.md); repeatable, applied in the order given.")
        var recipe: [String] = []

        @Option(name: .customLong("input"), help: ArgumentHelp("A file a recipe asks for, streamed into the image while it is built (repeatable).", valueName: "name=path"))
        var inputs: [String] = []

        @Option(name: .customLong("set"), help: ArgumentHelp("A value for a recipe's parameter (repeatable).", valueName: "name=value"))
        var settings: [String] = []

        @OptionGroup var options: StoreOptions

        func validate() throws {
            guard (ipsw == nil) != (from == nil) else {
                throw ValidationError("give either --ipsw (install macOS) or --from (start from a ready image)")
            }
            if recipe.isEmpty && !(inputs.isEmpty && settings.isEmpty) {
                throw ValidationError("--input and --set give values to a recipe's inputs and parameters; add --recipe")
            }
            for pair in inputs + settings where !pair.contains("=") || pair.hasPrefix("=") {
                throw ValidationError("\(pair): give name=value")
            }
            if from != nil {
                guard user == nil, guestDaemon == nil else {
                    throw ValidationError("--user and --guest-daemon come from the base image with --from")
                }
                guard !recipe.isEmpty || commandLineTools == true else {
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
            let recipes = try ImageRecipe.binding(
                try recipe.map { try ImageRecipe.load(from: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)) },
                inputs: try Self.pairs(inputs, option: "--input"), parameters: try Self.pairs(settings, option: "--set"))
            // With --json, progress goes to stderr as JSON lines, so stdout holds only the record.
            let builder = ImageBuilder(store: options.imageStore, events: Events.handler(json: json))
            // SIGINT or SIGTERM stops the build at the next safe point, with the guest shut down.
            let signals = BuildCancellation.watchingSignals()
            defer { signals.stop() }
            builder.cancellation = signals.cancellation
            let image: GoldenImage
            do {
                image = try await build(builder, recipes: recipes)
            } catch let AgentVMError.canceled(signal) {
                ImageCommand.reportCanceled(name, signal: signal, store: options.imageStore, json: json)
                throw ExitCode(128 + signal)
            }
            if json {
                try Output.json(image.record)
                return
            }
            print("Image \(image.name) is ready: \(image.directory.path)")
        }

        @MainActor
        private func build(_ builder: ImageBuilder, recipes: [ImageRecipe]) async throws -> GoldenImage {
            // The Command Line Tools: what the command line says, else yes when a recipe asks
            // for them, no when the recipes that say anything say no.
            let asked = recipes.compactMap(\.commandLineTools)
            let recipesWantTools: Bool? = asked.isEmpty ? nil : asked.contains(true)
            let image: GoldenImage
            if let from {
                image = try await builder.derive(ImageDeriveOptions(
                    name: name,
                    base: from,
                    recipes: recipes,
                    commandLineTools: commandLineTools ?? recipesWantTools ?? false,
                    cpuCount: cpus,
                    memoryBytes: memoryGB.map { UInt64($0) << 30 },
                    diskBytes: diskGB.map { UInt64($0) << 30 },
                    guestDaemon: try ImageCommand.localGuestDaemon()))
            } else {
                image = try await builder.build(ImageBuildOptions(
                    name: name,
                    restoreImage: try await RestoreImageCache(root: SessionStore.defaultRoot()).resolve(ipsw ?? ""),
                    cpuCount: cpus ?? ImageBuildOptions.defaultCPUCount,
                    memoryBytes: memoryGB.map { UInt64($0) << 30 } ?? ImageBuildOptions.defaultMemoryBytes,
                    diskBytes: diskGB.map { UInt64($0) << 30 } ?? ImageBuildOptions.defaultDiskBytes,
                    userName: user ?? "agent",
                    askpassProgram: try AskpassEntry.executablePath(),
                    guestDaemon: try guestDaemonURL(),
                    commandLineTools: commandLineTools ?? recipesWantTools ?? true,
                    recipes: recipes))
            }
            return image
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

    /// Says what a cancel left behind: the image failed (to delete), or unchanged.
    static func reportCanceled(_ name: String, signal: Int32, store: ImageStore, json: Bool) {
        let cause = AgentVMError.canceled(signal: signal).description
        let text: String
        if let image = try? store.image(named: name), image.record.state == .ready {
            text = "Image \(name) is unchanged: \(cause)"
        } else if (try? store.image(named: name)) != nil {
            text = "Image \(name) is marked failed (\(BuildCancellation.failure)): \(cause); delete it with `agent-vm image delete \(name)`"
        } else {
            text = "Image \(name) was not created: \(cause)"
        }
        if json {
            Events.emit(ProgressEvent(.notice, text, image: name), json: true)
        } else {
            FileHandle.standardError.write(Data((text + "\n").utf8))
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
            let builder = ImageBuilder(store: options.imageStore, events: Events.handler(json: json))
            let image = try await builder.setUp(named: name)
            if json {
                try Output.json(image.record)
                return
            }
            let granted = image.record.fullDiskAccess?.granted == true
            print("Image \(image.name) is set up\(granted ? "" : "; agent-vm-guest has no Full Disk Access yet (run image setup again to grant it)")")
        }
    }

    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "update",
            abstract: "Bring ready images up to date in place: macOS, the tools their recipes installed, and the guest daemon.",
            discussion: """
                macOS: installs the update Apple offers within the image's major version \
                (softwareupdate in the guest, unattended; about 15 minutes, and about 15 GB \
                of disk the image then no longer shares with its older boxes), then a newer \
                Command Line Tools package when the image has the tools. Tools: runs the \
                `update` steps of the recipes the image keeps, in the order they were applied, \
                and each recipe's checks again, with the parameters the image recorded; --set \
                changes one (a pinned version, say) and records it. Guest daemon: puts this \
                agent-vm's agent-vm-guest into the image when it has another one, and boots once \
                more to check it (what `image update-guest` does). With none of --macos, --tools \
                and --guest, all three. The update works on a copy of the image's disk and puts it in \
                place only when every step and check passed: a failure or a cancel leaves the \
                image as it was, still ready. Boxes made from the image earlier keep what they \
                have; `box list` says "needs recreate" for them. Several images are updated one \
                after another, in the order given; every name is checked before the first boot, \
                and the first failure stops the rest. With --json: the image's record, or an \
                array of them for several names (on a failure, the images updated before it). \
                SIGINT or SIGTERM stops at the next safe point; agent-vm exits with 128 + the signal.
                """)

        @Argument(help: ArgumentHelp("The images to update.", valueName: "image"))
        var names: [String]

        @Flag(name: .customLong("macos"), help: "Update macOS (and the Command Line Tools).")
        var macOS = false

        @Flag(name: .long, help: "Run the update steps of the image's recipes.")
        var tools = false

        @Flag(name: .long, help: "Replace the image's agent-vm-guest with this agent-vm's, when they differ.")
        var guest = false

        @Option(name: .customLong("set"), help: ArgumentHelp("A new value for a parameter of the image's recipes, for the tools update (repeatable).", valueName: "name=value"))
        var settings: [String] = []

        @OptionGroup var options: StoreOptions

        func validate() throws {
            for pair in settings where !pair.contains("=") || pair.hasPrefix("=") {
                throw ValidationError("\(pair): give name=value")
            }
            if (macOS || guest) && !tools && !settings.isEmpty {
                throw ValidationError("--set changes a recipe's parameter for the tools update; add --tools, or leave out --macos and --guest")
            }
        }

        @MainActor
        func run() async throws {
            let json = options.json
            let builder = ImageBuilder(store: options.imageStore, events: Events.handler(json: json))
            let names = names.reduce(into: [String]()) { unique, name in
                if !unique.contains(name) {
                    unique.append(name)
                }
            }
            let parameters = try Create.pairs(settings, option: "--set")
            // No flag: everything.
            let both = !macOS && !tools && !guest
            let guestDaemon = guest || both ? try ImageCommand.localGuestDaemon() : nil
            // A mistyped last name should not surface after the first images took minutes each.
            for name in names {
                try builder.checkUpdate(ImageUpdateOptions(name: name, macOS: macOS || both, tools: tools || both, parameters: parameters, guestDaemon: guestDaemon))
            }
            let signals = BuildCancellation.watchingSignals()
            defer { signals.stop() }
            builder.cancellation = signals.cancellation
            var records: [ImageRecord] = []
            for (index, name) in names.enumerated() {
                let result: ImageUpdateResult
                do {
                    result = try await builder.update(ImageUpdateOptions(name: name, macOS: macOS || both, tools: tools || both, parameters: parameters, guestDaemon: guestDaemon))
                } catch {
                    var canceledBy: Int32?
                    if case let AgentVMError.canceled(signal) = error {
                        canceledBy = signal
                        ImageCommand.reportCanceled(name, signal: signal, store: options.imageStore, json: json)
                    }
                    let skipped = names[(index + 1)...]
                    if !skipped.isEmpty {
                        let text = "\(canceledBy == nil ? "Stopped" : "Canceled") at image \(name); not updated: \(skipped.joined(separator: ", "))"
                        if json {
                            Events.emit(ProgressEvent(.notice, text, image: name), json: true)
                        } else {
                            FileHandle.standardError.write(Data((text + "\n").utf8))
                        }
                    }
                    if json && names.count > 1 {
                        try Output.json(records)
                    }
                    if let canceledBy {
                        throw ExitCode(128 + canceledBy)
                    }
                    throw error
                }
                records.append(result.image.record)
                if !json {
                    print(Self.summary(result))
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

        /// One line for a person: what changed, or that nothing did.
        static func summary(_ result: ImageUpdateResult) -> String {
            let record = result.image.record
            guard result.changed else {
                return "Image \(record.name) is up to date: macOS \(record.macOSVersion) (\(record.macOSBuild))"
            }
            var parts: [String] = []
            if let previous = result.previousMacOSBuild {
                parts.append("macOS \(record.macOSVersion) (\(record.macOSBuild), was \(previous))")
            }
            if !result.recipes.isEmpty {
                parts.append("tools of \(result.recipes.joined(separator: ", "))")
            }
            if let previous = result.previousGuestVersion {
                parts.append("agent-vm-guest \(record.guestVersion ?? "?") (was \(previous))")
            }
            if parts.isEmpty {
                parts.append("the Command Line Tools")
            }
            return "Image \(record.name) is updated (revision \(record.revision ?? 0)): \(parts.joined(separator: "; ")). Boxes made from it before need `agent-vm box recreate`."
        }
    }

    struct UpdateGuest: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "update-guest",
            abstract: "Deprecated: use `image update --guest`. Put this agent-vm's guest daemon into ready images.",
            discussion: """
                Deprecated, and removed in a later version: `agent-vm image update <image> \
                --guest` does the same on a copy of the image, so a failure leaves the image as \
                it was, and `agent-vm image update <image>` updates macOS and the tools too. \
                Boots the image, replaces its agent-vm-guest with the one next to agent-vm when \
                they differ, and boots it once more to check the new one (a minute or two). \
                Needed when a newer agent-vm brings guest features (`image list` names what an \
                image lacks); boxes made from the image earlier keep their daemon, so create \
                them again. Images built with `--from` get the current daemon automatically. \
                Several images are updated one after another, in the order given; every name is \
                checked before the first boot, and the first failure stops the rest (a daemon \
                that does not start marks its image failed, and would mark the next one too). \
                With --json: the image's record, or an array of them for several names (on a failure, the images updated before it). \
                SIGINT or SIGTERM stops at the next safe point: the image is shut down, and stays \
                ready unless its daemon was already being replaced; agent-vm exits with 128 + the signal.
                """,
            shouldDisplay: false)

        @Argument(help: ArgumentHelp("The images to update.", valueName: "image"))
        var names: [String]

        @OptionGroup var options: StoreOptions

        static let deprecation = "note: image update-guest is deprecated and will be removed; use `agent-vm image update <image> --guest`"

        @MainActor
        func run() async throws {
            let json = options.json
            if json {
                Events.emit(ProgressEvent(.notice, Self.deprecation, image: nil), json: true)
            } else {
                FileHandle.standardError.write(Data((Self.deprecation + "\n").utf8))
            }
            let builder = ImageBuilder(store: options.imageStore, events: Events.handler(json: json))
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
            // SIGINT or SIGTERM stops at the next safe point: the image being updated is shut
            // down cleanly (and left as it was when its daemon was not replaced yet), the rest
            // are skipped.
            let signals = BuildCancellation.watchingSignals()
            defer { signals.stop() }
            builder.cancellation = signals.cancellation
            var records: [ImageRecord] = []
            for (index, name) in names.enumerated() {
                let image: GoldenImage
                do {
                    image = try await builder.updateGuest(named: name, guestDaemon: guestDaemon)
                } catch {
                    var canceledBy: Int32?
                    if case let AgentVMError.canceled(signal) = error {
                        canceledBy = signal
                        ImageCommand.reportCanceled(name, signal: signal, store: options.imageStore, json: json)
                    }
                    let skipped = names[(index + 1)...]
                    if !skipped.isEmpty {
                        let text = "\(canceledBy == nil ? "Stopped" : "Canceled") at image \(name); not updated: \(skipped.joined(separator: ", "))"
                        if json {
                            Events.emit(ProgressEvent(.notice, text, image: name), json: true)
                        } else {
                            FileHandle.standardError.write(Data((text + "\n").utf8))
                        }
                    }
                    // The images before this one are updated; a program should not have to
                    // list the store to learn which.
                    if json && names.count > 1 {
                        try Output.json(records)
                    }
                    if let canceledBy {
                        throw ExitCode(128 + canceledBy)
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
        static let configuration = CommandConfiguration(
            abstract: "List images.",
            discussion: """
                Quick: it reads each image's record and measures nothing. `agent-vm image info \
                <name>` adds the image's space on disk: all of it, what no box or other image \
                shares, and for an image built with --from what it added over its base.
                """)

        @OptionGroup var options: StoreOptions

        /// An image's record with its folder and what it lacks added as more keys, so a program
        /// reading the records as before sees no change; `image info` adds its space and its
        /// growth over its base. Those two measure the disk (a scan of the folder's files, and a
        /// map of two disks' extents, about 0.3 s each), which a list of every image should not.
        struct Entry: Encodable {
            var record: ImageRecord
            var path: String
            var diskUsage: DiskUsage?
            var addedOverBase: Added?

            private enum Keys: String, CodingKey {
                case path
                case diskUsage
                case addedOverBase
                case needs
            }

            func encode(to encoder: Encoder) throws {
                try record.encode(to: encoder)
                var container = encoder.container(keyedBy: Keys.self)
                try container.encode(path, forKey: .path)
                try container.encodeIfPresent(diskUsage, forKey: .diskUsage)
                try container.encodeIfPresent(addedOverBase, forKey: .addedOverBase)
                try container.encode(record.needs, forKey: .needs)
            }

            /// The entry for a person: a line with the essentials, the folder (and with sizes,
            /// the space), then what the image lacks and why it failed.
            var lines: [String] {
                let record = self.record
                let state = record.state.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)
                var line = "\(record.name)  \(state)  macOS \(record.macOSVersion) (\(record.macOSBuild))  \(record.cpuCount) CPUs  \(record.memoryBytes >> 30) GB  created \(Output.time(record.createdAt))"
                if let updatedAt = record.updatedAt {
                    line += "  updated \(Output.time(updatedAt))"
                }
                if let base = record.derivedFrom {
                    line += "  from \"\(base.image)\" image"
                }
                if let recipe = record.recipe {
                    let own = (record.recipes ?? []).filter { $0.inheritedFrom == nil }
                    if own.count > 1 {
                        line += "  recipes \(own.map { $0.name ?? String($0.digest.prefix(12)) }.joined(separator: ", "))"
                    } else {
                        line += "  recipe \(recipe.description ?? String(recipe.digest.prefix(12)))"
                    }
                    if let parameters = recipe.parameters, !parameters.isEmpty {
                        line += " [\(parameters.keys.sorted().map { "\($0)=\(parameters[$0] ?? "")" }.joined(separator: ", "))]"
                    }
                }
                var lines = [line]
                if let diskUsage {
                    lines += Output.placeLines(URL(fileURLWithPath: path), diskUsage, others: "other images or boxes", delete: "image delete")
                } else {
                    lines.append("    \(path)")
                }
                if let added = addedOverBase {
                    lines.append("    \(Output.size(added.bytes)) added over base \"\(added.image)\" image")
                }
                for need in record.needs {
                    switch (need.kind, need.reason) {
                    case (.guestUpdate, _):
                        lines.append("    agent-vm-guest lacks \((need.missing ?? []).joined(separator: ", ")); `agent-vm image update \(record.name) --guest` adds it")
                    case (.fullDiskAccess, .notGranted?):
                        lines.append("    agent-vm-guest has no Full Disk Access: programs in boxes that open Desktop, Documents or Downloads wait on a hidden prompt; `agent-vm image setup \(record.name)`")
                    case (.fullDiskAccess, _):
                        lines.append("    Full Disk Access for agent-vm-guest is not checked\(record.fullDiskAccess == nil ? "" : " for its current version"); `agent-vm image setup \(record.name)`")
                    }
                }
                if let failure = record.failure {
                    lines.append("    failed: \(failure)")
                }
                return lines
            }
        }

        /// What a derived image's disk holds that its base's does not.
        struct Added: Encodable {
            var image: String
            var bytes: Int64
        }

        /// The growth of a derived image over its base, when the base is still there and is the
        /// one it was built from: a base created after the image was rebuilt since, and shares
        /// nothing with it.
        static func added(_ image: GoldenImage, among images: [GoldenImage]) -> Added? {
            guard let name = image.record.derivedFrom?.image,
                  let base = images.first(where: { $0.name == name }), base.record.createdAt <= image.record.createdAt,
                  let bytes = DiskUsage.addedBytes(image.diskURL, over: base.diskURL) else {
                return nil
            }
            return Added(image: name, bytes: bytes)
        }

        func run() throws {
            let (images, problems) = try options.imageStore.list()
            for problem in problems {
                FileHandle.standardError.write(Data("warning: \(problem)\n".utf8))
            }
            let entries = images.map { Entry(record: $0.record, path: $0.directory.path) }
            if options.json {
                try Output.json(entries)
                return
            }
            if entries.isEmpty {
                print("No images.")
                return
            }
            for entry in entries {
                for line in entry.lines {
                    print(line)
                }
            }
        }
    }

    struct Info: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show one image, with its space on disk.",
            discussion: """
                The image's `image list` entry, plus its space: all of it, and the part no box \
                or other image shares, which is what `image delete` frees. For an image built \
                with --from, also what its disk added over the image it was built from. With \
                --json, the list entry with `diskUsage` (`bytes`, and `unsharedBytes` unless the \
                volume does not report it) and `addedOverBase` (`image`, `bytes`). Measuring \
                takes a moment: about 0.1 s per disk, and 0.3 s more for the growth over a base.
                """)

        @Argument(help: "The image name.")
        var name: String

        @OptionGroup var options: StoreOptions

        func run() throws {
            let image = try options.imageStore.image(named: name)
            var added: List.Added?
            if image.record.derivedFrom != nil {
                // The base is found among all images, as `image list` found it.
                let (images, _) = try options.imageStore.list()
                added = List.added(image, among: images)
            }
            let entry = List.Entry(record: image.record, path: image.directory.path,
                                   diskUsage: DiskUsage.of(image.directory), addedOverBase: added)
            if options.json {
                try Output.json(entry)
                return
            }
            for line in entry.lines {
                print(line)
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
