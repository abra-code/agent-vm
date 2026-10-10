// Sources/AgentVMKit/Images/ImageUpdate.swift
//
// `agent-vm image update`: brings a ready image up to date in place. macOS takes the update
// `softwareupdate` offers within its major version (measured on a macOS 27.0 guest: 27.0.1 in
// about 14 minutes, unattended, with the account's password on standard input; the guest
// restarts by itself, its daemon answers again on the new build, and Full Disk Access for the
// daemon is kept). Tools are refreshed by the `update` steps of the recipes the image keeps.
//
// The update never touches the image's own files until it has succeeded. It boots a
// copy-on-write copy of the disk and the auxiliary storage in `Images/<name>/Update/`; when
// every step and check passed and the guest shut down, the folder is renamed to
// `Update.commit` (one atomic step) and its files take the image's files' place
// (`ImageStore.settle`, which also finishes a commit that a killed agent-vm left halfway). A
// failure, a cancel or a kill before that rename leaves the image as it was, still ready.
// The image stays usable meanwhile: boxes and images can be cloned from it while its copy is
// updated (they get the image as it was), since only the making of the copy and the final
// moves hold the image's own lock.
//
// A macOS update rewrites about 15 GB of the disk (measured), which the image then no longer
// shares with boxes and images cloned from it earlier.
//
// A Linux image is updated the same way, on a copy of its disk and its firmware variables. Its
// system update is the distribution's own (apt-get update, dist-upgrade, autoremove, clean):
// seconds to a few minutes, and what changed is told by comparing the list of installed
// packages before and after. When it installed a kernel newer than the one running, the copy
// is booted once more before it takes the image's place, as after a replaced guest daemon, so
// an image whose new kernel does not come up is never the one boxes are made from.

import Darwin
import Foundation
import Virtualization

public struct ImageUpdateOptions: Sendable {
    public var name: String
    /// The system's own updates. For a macOS image: the macOS update Apple offers, and the
    /// Command Line Tools' when the image has them. For a Linux image: the distribution's
    /// package updates.
    public var system: Bool
    /// Run the `update` steps of the recipes the image keeps.
    public var tools: Bool
    /// New values for the recipes' parameters (`--set`), recorded with the image.
    public var parameters: [String: String]
    /// The agent-vm-guest to put in the image when it has another one (nil: leave the image's).
    public var guestDaemon: URL?
    /// Newer versions of recipes the image keeps (`--recipe`), each taking the place of the
    /// kept one of its name: its update steps and checks run, and the image keeps it from then
    /// on.
    public var recipes: [URL]
    /// Run the recipes as the image keeps them: no newer version of a built-in recipe takes a
    /// kept one's place by itself (`--kept-recipes`). What `recipes` names still does.
    public var keptRecipes: Bool
    /// With `system`, for a Linux image: the page size its kernel is to have from now on
    /// (`--page-size`). nil leaves an image the size its record names, and gives one whose
    /// record names none (built before the size was kept) its system's default.
    public var pageBytes: Int?

    public init(name: String, system: Bool, tools: Bool, parameters: [String: String] = [:], guestDaemon: URL? = nil, recipes: [URL] = [],
                keptRecipes: Bool = false, pageBytes: Int? = nil) {
        self.name = name
        self.system = system
        self.tools = tools
        self.parameters = parameters
        self.guestDaemon = guestDaemon
        self.recipes = recipes
        self.keptRecipes = keptRecipes
        self.pageBytes = pageBytes
    }
}

/// What `image update` did to one image.
public struct ImageUpdateResult: Sendable {
    public var image: GoldenImage
    /// Whether the image's disk changed (its `revision` went up).
    public var changed: Bool
    /// The build before a macOS update, when one was installed.
    public var previousMacOSBuild: String?
    /// The names of the recipes whose update steps ran.
    public var recipes: [String]
    /// The image's agent-vm-guest version before it was replaced, when it was.
    public var previousGuestVersion: String?
    /// A Linux image: how many packages the system update installed, removed or changed; nil
    /// when it changed none or was not asked for.
    public var systemPackages: Int? = nil
    /// A Linux image: the kernel before the update, when the update installed another one.
    public var previousKernel: String? = nil
    /// The names of the kept recipes a newer version took the place of.
    public var replacedRecipes: [String] = []
}

/// A macOS update as `softwareupdate --list` offers it.
public struct MacOSUpdate: Equatable, Sendable {
    public var label: String
    public var version: String
    public var build: String

    /// The newest macOS update of `major` in `softwareupdate --list` output, which lists
    /// entries as "* Label: macOS 27.0.1-26A434" (a release name may follow "macOS"). Updates
    /// to another major version are left alone: they are a new image's job.
    public static func offered(inListOutput output: String, major: Int) -> MacOSUpdate? {
        let updates = output.split(whereSeparator: \.isNewline).compactMap { line -> MacOSUpdate? in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("* Label: macOS ") else {
                return nil
            }
            let label = String(text.dropFirst("* Label: ".count))
            guard let last = label.split(separator: " ").last else {
                return nil
            }
            let parts = last.split(separator: "-", maxSplits: 1)
            guard parts.count == 2, parts[0].first?.isNumber == true, parts[0].allSatisfy({ $0.isNumber || $0 == "." }),
                  !parts[1].isEmpty, parts[1].allSatisfy({ $0.isLetter || $0.isNumber }) else {
                return nil
            }
            return MacOSUpdate(label: label, version: String(parts[0]), build: String(parts[1]))
        }
        return updates.filter { numbers($0.version).first == major }
            .max { numbers($0.version).lexicographicallyPrecedes(numbers($1.version)) }
    }

    static func numbers(_ version: String) -> [Int] {
        return version.split(separator: ".").compactMap { Int($0) }
    }

    /// Installs `label` and restarts, as an administrator named on the command line whose
    /// password is read from standard input (Apple silicon asks for a volume owner).
    static func installRequest(label: String, user: String) -> GuestRequest {
        return GuestRequest(op: .exec, argv: ["/usr/sbin/softwareupdate", "--install", label, "--restart", "--agree-to-license",
                                              "--user", user, "--stdinpass", "--verbose"], cwd: "/", user: "root")
    }

    static var listRequest: GuestRequest {
        return GuestRequest(op: .exec, argv: ["/bin/sh", "-c", "/usr/sbin/softwareupdate --list 2>&1"], cwd: "/", user: "root")
    }

    static var versionRequest: GuestRequest {
        return GuestRequest(op: .exec, argv: ["/bin/sh", "-c", "/usr/bin/sw_vers -productVersion && /usr/bin/sw_vers -buildVersion"], cwd: "/")
    }
}

/// softwareupdate redraws one line, "Downloading: 42.10%", with carriage returns, so the log
/// would stay silent for minutes. This reads the percentage out of the stream and says when it
/// reaches the next ten.
final class DownloadPercent: @unchecked Sendable {
    private let lock = NSLock()
    private var recent: [UInt8] = []
    private var reported = -10

    /// The percentage to report, when `bytes` brought it into a ten not reported yet.
    func add(_ bytes: [UInt8]) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        recent.append(contentsOf: bytes)
        if recent.count > 256 {
            recent.removeFirst(recent.count - 256)
        }
        // The last "Downloading: <number>%" that arrived whole.
        let pieces = String(decoding: recent, as: UTF8.self).components(separatedBy: "Downloading: ").dropFirst()
        guard let value = pieces.reversed().lazy.compactMap({ piece -> Double? in
            guard let end = piece.firstIndex(of: "%") else {
                return nil
            }
            return Double(piece[..<end])
        }).first, value >= 0 else {
            return nil
        }
        // Capped first: "inf" and "1e400" are numbers too, and Int() traps on them.
        let percent = Int(min(100, value))
        guard percent / 10 > reported / 10 else {
            return nil
        }
        reported = percent
        return percent
    }
}

extension ImageBuilder {
    /// Free space on the Mac an update is refused below: a macOS update rewrites about 15 GB.
    static let minimumFreeBytesForMacOSUpdate: Int64 = 20 << 30
    static let minimumFreeBytesForToolsUpdate: Int64 = 5 << 30
    /// A Linux system update rewrites what the packages hold: hundreds of MB, seldom more.
    static let minimumFreeBytesForLinuxUpdate: Int64 = 3 << 30
    /// How long the download and preparation may go without any output, and how long the
    /// restart may take to bring the new build up (measured: 2 minutes).
    static let macOSUpdateSilenceSeconds = 3600
    static let macOSRestartTimeout: Duration = .seconds(2700)
    /// How long a finished update waits for the image's lock before it gives up.
    static let commitPatience: Duration = .seconds(120)
    /// How long the second boot of a replaced guest daemon waits for a virtual machine slot.
    static let slotPatience: Duration = .seconds(900)

    /// One recipe the image keeps, ready to run its update steps, or only its checks.
    struct ToolsPlan {
        /// Its place in the record's `recipes`.
        var index: Int
        var recipe: ImageRecipe
        /// It has no update steps: its checks run after the others' updates, since those
        /// can change what it installed (Homebrew's upgrade reaches Node and Python).
        var checksOnly = false
        /// It was given with `--recipe` and is not the one the image keeps: kept in its place
        /// once the update is in place.
        var replaces = false
        /// It replaces the kept one by itself: the newer version of a recipe that came with
        /// agent-vm.
        var builtIn = false
    }

    /// What `update` would refuse without booting anything: no such image, one that is not
    /// ready, a kept recipe that no longer loads, a `--set` no recipe with update steps takes.
    /// For a command that updates several images, so the last one's mistake does not surface
    /// after the first took its minutes.
    public func checkUpdate(_ options: ImageUpdateOptions) throws {
        let image = try updatableImage(named: options.name, operation: "update", inPlace: false)
        if options.tools {
            _ = try toolsPlans(image, set: options.parameters, replacing: options.recipes, builtIn: options.keptRecipes ? nil : builtInRecipes)
        } else if let recipe = options.recipes.first {
            throw AgentVMError.invalidRecipe(path: recipe.path, reason: "--recipe replaces a recipe the image keeps, for the tools update (add --tools, or leave out --system and --guest)")
        }
        // A Linux image's daemon is built only where the Linux toolchain is installed.
        if let guestDaemon = options.guestDaemon {
            try Self.requireLocalDaemon(guestDaemon, guest: image.record.effectiveGuest)
        }
        // A page size the image's system has no kernel for, before a copy is booted to find out.
        if let pageBytes = options.pageBytes, image.record.effectiveGuest == .linux, pageBytes != image.record.linux?.pageSize {
            guard let base = LinuxBase.known(for: image.record.linux) else {
                throw AgentVMError.linuxBase("--page-size \(pageBytes >> 10)k: this agent-vm knows no other kernel for \(image.record.systemShort)")
            }
            _ = try base.kernel(pageBytes: pageBytes)
        }
    }

    /// Updates a ready image in place (see the top of this file). Returns the image as it is
    /// now; `changed` is false when there was nothing to update, and the image is untouched.
    public func update(_ options: ImageUpdateOptions) async throws -> ImageUpdateResult {
        var image = try updatableImage(named: options.name, operation: "update", inPlace: false)
        subject = image.name
        // Held throughout: one command changes an image at a time.
        guard let changeLock = try store.tryLockForChange(image) else {
            throw AgentVMError.imageBusy(image.name)
        }
        defer { changeLock.release() }
        // The image's own lock is held only while the copy is made, and again while it is put
        // in place: in between, boxes can be made from the image as it is.
        // A box being cloned from the image holds it for a moment: wait for that.
        var cloning: ImageStore.Lock? = try await lockToCommit(image)
        defer { cloning?.release() }
        // Before the free space is measured: an update that was killed may have left gigabytes
        // in `Update/`. The record is read again under the lock.
        image = try store.settle(image, updating: true)
        guard image.record.state == .ready else {
            throw AgentVMError.wrongImageState(name: image.name, state: image.record.state.rawValue, operation: "update")
        }
        let guest = image.record.effectiveGuest
        let minimumFree: Int64
        switch (guest, options.system) {
        case (.macOS, true):
            minimumFree = Self.minimumFreeBytesForMacOSUpdate
        case (.linux, _):
            minimumFree = Self.minimumFreeBytesForLinuxUpdate
        case (.macOS, false):
            minimumFree = Self.minimumFreeBytesForToolsUpdate
        }
        try Self.checkHost(HostFacts.current(storeRoot: store.root), minimumFree: minimumFree)
        // A macOS update is given the account's password, minutes in.
        if options.system, guest == .macOS {
            try image.requireAccountPassword(keychain: store.passwords)
        }
        // Read before anything boots: a recipe that no longer loads, or a --set no recipe
        // takes, fails in a second.
        let plans = try options.tools ? toolsPlans(image, set: options.parameters, replacing: options.recipes, builtIn: options.keptRecipes ? nil : builtInRecipes) : []
        for plan in plans where plan.replaces {
            log(plan.builtIn
                ? "Recipe \(plan.recipe.name): this agent-vm has a newer one than \(image.name) keeps; it is used, and kept when the update succeeds (--kept-recipes runs the old one)"
                : "Recipe \(plan.recipe.name): the one given with --recipe is used, and kept when the update succeeds")
        }
        if !options.tools, let recipe = options.recipes.first {
            throw AgentVMError.invalidRecipe(path: recipe.path, reason: "--recipe replaces a recipe the image keeps, for the tools update (add --tools, or leave out --system and --guest)")
        }
        if let guestDaemon = options.guestDaemon {
            try Self.requireLocalDaemon(guestDaemon, guest: guest)
        }
        if !options.tools, let name = options.parameters.keys.sorted().first {
            throw AgentVMError.invalidRecipe(path: image.recipesURL.path, reason: "--set \(name) changes a recipe's parameter; it needs the tools update (add --tools, or leave out --system and --guest)")
        }

        let work = image.updateURL
        do {
            try FileSystem.makeDirectories(work.path)
            try BoxStore.cloneFile(image.diskURL, to: work.appendingPathComponent(ImageStore.diskName))
            // What the guest writes besides its disk.
            switch guest {
            case .macOS:
                try BoxStore.cloneFile(image.auxiliaryStorageURL, to: work.appendingPathComponent(ImageStore.auxiliaryStorageName))
            case .linux:
                try BoxStore.cloneFile(image.efiVariableStoreURL, to: work.appendingPathComponent(ImageStore.efiVariableStoreName))
            }
        } catch {
            try? FileSystem.removeTree(work.path)
            throw error
        }
        cloning?.release()
        cloning = nil
        var record = image.record
        let began = ContinuousClock.now
        var changed = false
        var previousBuild: String?
        var updatedRecipes: [String] = []
        var previousGuest: String?
        var systemPackages: Int?
        var previousKernel: String?
        var bootedAgain = false
        do {
            let files = image.machineFiles.working(in: work)
            // A Linux guest's console goes to the image's console.log, for both boots of the
            // update: what a boot that failed printed outlives the copy it ran on.
            let console: ConsoleLog? = guest == .linux ? try ConsoleLog(url: image.consoleLogURL) : nil
            defer { console?.close() }
            let extras = LinuxMachineExtras(console: console?.writeHandle)
            var machine = try makeMachine(for: image, files: files, extras: extras)
            try checkCanceled()
            if guest == .linux, LinuxPageNote.hasSmallPages(image.record.linux) {
                try checkHostMemory(memoryBytes: image.record.memoryBytes, what: "the update of \(image.name)")
            }
            progress("boot", "Booting a copy of \(image.name)\(image.record.updateSeconds.map { " (the last update took \(Int($0.rounded())) s)" } ?? "")",
                     expectedSeconds: image.record.updateSeconds)
            try await start(machine, of: image)
            do {
                let hello = try await waitForDaemon(machine, attempts: 180, guest: guest)
                log("  agent-vm-guest \(hello.version ?? "?") answers over vsock")
                // A newer kernel than the one running is installed: the copy is booted once
                // more, to see that it comes up, before it takes the image's place.
                var bootsNewKernel = false
                var ranKernel: String?
                switch (guest, options.system) {
                case (.macOS, true):
                    if let installed = try await updateMacOS(machine, image: image) {
                        previousBuild = record.macOSBuild
                        record.macOSVersion = installed.version
                        record.macOSBuild = installed.build
                        changed = true
                    }
                    if let label = try await updateCommandLineTools(machine, installed: record.commandLineTools) {
                        record.commandLineTools = label
                        changed = true
                    }
                case (.linux, true):
                    // Another kernel first, and a boot on it: the updates then run on the
                    // kernel the image keeps, and as little as can be on the one that goes.
                    var sealed: Set<String>?
                    if let kernel = try await kernelToInstall(machine, record: record, pageBytes: options.pageBytes) {
                        // What was sealed is looked at before the kernel goes in: its packages
                        // are the update's too, and what they undid must fail it.
                        sealed = try await passingChecks(LinuxSetup.sealChecks(distribution: record.linux?.distribution ?? "debian"), machine: machine)
                        let switched = try await switchKernel(kernel, machine: machine, files: files, image: image, record: record, extras: extras)
                        machine = switched.machine
                        previousKernel = switched.previous
                        record.linux?.kernel = switched.running
                        record.linux?.pageSize = kernel.pageBytes
                        bootedAgain = true
                        changed = true
                    }
                    let outcome = try await updateLinuxSystem(machine, record: record, sealed: sealed)
                    if outcome.packages > 0 {
                        systemPackages = outcome.packages
                        record.commandLineTools = outcome.tools ?? record.commandLineTools
                        changed = true
                    }
                    bootsNewKernel = outcome.kernelNeedsBoot
                    ranKernel = outcome.kernel
                    // What a box of the image boots, when no newer kernel is waiting (a second
                    // boot records its own). Kept only with an update that changed something.
                    if !bootsNewKernel {
                        record.linux?.kernel = outcome.kernel
                        record.linux?.pageSize = outcome.pageSize
                    }
                case (_, false):
                    // A tools update in a Linux image downloads too, and the daemon answers
                    // before the network card has its address.
                    if guest == .linux, !plans.isEmpty {
                        try await runLinuxSteps([LinuxSetup.waitForNetwork], machine: machine, offset: 0, count: 1)
                    }
                }
                let updates = plans.filter { !$0.checksOnly }
                for (position, plan) in updates.enumerated() {
                    try await runUpdate(plan.recipe, machine: machine, boxUser: record.userName, position: (position + 1, updates.count), guest: guest)
                    record.recipes?[plan.index].parameters = plan.recipe.parameterValues.isEmpty ? nil : plan.recipe.parameterValues
                    updatedRecipes.append(plan.recipe.name)
                    changed = true
                }
                for plan in plans where plan.replaces {
                    record.recipes?[plan.index].digest = plan.recipe.digest
                    record.recipes?[plan.index].description = plan.recipe.description
                    record.recipes?[plan.index].parameters = plan.recipe.parameterValues.isEmpty ? nil : plan.recipe.parameterValues
                    changed = true
                }
                // Every other recipe's checks, once all updates ran: an update that breaks
                // what another recipe installed fails here, and is not kept.
                let checked = plans.filter(\.checksOnly)
                for (position, plan) in checked.enumerated() {
                    progress("tools-check", "Checking \(plan.recipe.name) (\(position + 1) of \(checked.count))\(plan.recipe.description.map { ": \($0)" } ?? "")",
                             index: position + 1, count: checked.count)
                    try await runSteps([], checks: plan.recipe.checks, variables: plan.recipe.variables(for: guest), machine: machine, boxUser: record.userName)
                }
                // Last, so the system and the recipes were updated under the daemon that was there.
                var replaced: (digest: String, requirement: String?, replaced: Bool)?
                if let guestDaemon = options.guestDaemon {
                    replaced = try await replaceGuestDaemon(guestDaemon, machine: machine, guest: guest)
                }
                if guest == .macOS, changed, replaced?.replaced != true {
                    // An update can change what macOS grants the daemon; boxes need to know.
                    record.fullDiskAccess = try await probedFullDiskAccess(machine, record: record, image: image.name)
                }
                try await shutDownAfterUpdate(machine, guest: guest)
                let newDaemon = replaced.flatMap { $0.replaced ? (digest: $0.digest, requirement: $0.requirement) : nil }
                if newDaemon != nil || bootsNewKernel {
                    if newDaemon != nil {
                        previousGuest = record.guestVersion ?? "?"
                    }
                    bootedAgain = true
                    record = try await checkSecondBoot(files, image: image, record: record, newDaemon: newDaemon, extras: extras)
                    if let ranKernel, record.linux?.kernel != ranKernel {
                        // The kernel the image had before the update, when this one changed it twice.
                        previousKernel = previousKernel ?? ranKernel
                    }
                    if newDaemon != nil || previousKernel != nil {
                        changed = true
                    } else {
                        // The newest kernel file is not the one the system boots (another
                        // flavor installed beside it, say). Nothing changed by this boot: an
                        // image that is otherwise current must not get a new revision, and
                        // its boxes a "needs recreate", at every update.
                        notice("  note: \(image.name) has a kernel newer than the one it boots (\(record.linux?.kernel ?? "?")), and boots the same one after the update")
                    }
                }
            } catch {
                let error = canceledError(error)
                await stopAfterFailure(machine)
                throw error
            }
            let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            // What this run looked at, and how long a run without a macOS install takes.
            // Of a tools update only, and not one that also replaced the daemon or checked a new
            // kernel (a second boot, and maybe a wait for a slot): the time a client shows
            // before a wait it chose.
            let seconds = options.tools && previousBuild == nil && !bootedAgain && systemPackages == nil
                ? Self.seconds(ContinuousClock.now - began).rounded() : nil
            func stamp(_ record: inout ImageRecord) {
                if options.system {
                    // Each guest has its own stamp for its system.
                    switch guest {
                    case .macOS:
                        record.macOSCheckedAt = now
                    case .linux:
                        record.systemCheckedAt = now
                    }
                }
                if options.tools {
                    record.toolsCheckedAt = now
                }
                if let seconds {
                    record.updateSeconds = seconds
                }
            }
            guard changed else {
                try FileSystem.removeTree(work.path)
                log("Nothing to update in \(image.name)")
                // Only the record, when this run looked at the system or the tools: the
                // image's files are as they were.
                if options.system || options.tools {
                    // The page size the image's kernel was seen to have is kept even so: a
                    // record that names none would get the system's default kernel at the next
                    // update, also after `--page-size` asked for the one the image has.
                    let pages = options.system && guest == .linux ? record.linux?.pageSize : nil
                    let lock = try await lockToCommit(image)
                    defer { lock.release() }
                    image = try store.update(try store.image(named: image.name)) { record in
                        stamp(&record)
                        if let pages {
                            record.linux?.pageSize = pages
                        }
                    }
                }
                return ImageUpdateResult(image: image, changed: false, previousMacOSBuild: nil, recipes: [], previousGuestVersion: nil)
            }
            progress("commit", "Putting the updated disk in place")
            let own = (record.recipes ?? []).filter { $0.inheritedFrom == nil }
            if !own.isEmpty {
                record.recipe = ImageRecord.RecipeInfo.combined(own)
            }
            record.revision = (record.revision ?? 0) + 1
            record.updatedAt = now
            stamp(&record)
            let lock = try await lockToCommit(image)
            defer { lock.release() }
            try store.commitUpdate(image, record: record)
            // After the disk and the record: a run killed here leaves the old recipe in the
            // folder under the new digest. The next tools update sees what the folder holds
            // and replaces it again (toolsPlans).
            for plan in plans where plan.replaces {
                guard let folder = record.recipes?[plan.index].folder else {
                    continue
                }
                do {
                    try Self.replaceKeptRecipe(plan.recipe, in: image.recipesURL, folder: folder)
                    log("  \(image.name) keeps the new \(plan.recipe.name) recipe")
                } catch {
                    notice("  note: \(image.name) was updated with the new \(plan.recipe.name) recipe but still keeps the old one (\(error)); \(plan.builtIn ? "the next tools update replaces it again" : "give --recipe again at the next tools update")")
                }
            }
        } catch {
            // Nothing of the image itself was touched: it stays ready, as it was.
            try? FileSystem.removeTree(work.path)
            // Past the rename the update is decided: the next command on the image finishes it.
            if FileSystem.exists(image.updateCommitURL.path) {
                notice("  note: the update succeeded but could not be put in place (\(error)); the next agent-vm command that uses \(image.name) finishes it")
            } else {
                log("  \(image.name) is unchanged")
            }
            throw error
        }
        image = try store.image(named: image.name)
        return ImageUpdateResult(image: image, changed: true, previousMacOSBuild: previousBuild, recipes: updatedRecipes, previousGuestVersion: previousGuest,
                                 systemPackages: systemPackages, previousKernel: previousKernel,
                                 replacedRecipes: plans.filter(\.replaces).map(\.recipe.name))
    }

    /// The kernel a system update installs in place of the image's, nil when it keeps the one
    /// it has. `pageBytes` is the page size asked for; with none, an image whose record names
    /// no page size (it was built before sizes were kept) gets its system's default. A notice
    /// says so when the running kernel has another size.
    private func kernelToInstall(_ machine: GuestMachine, record: ImageRecord, pageBytes: Int?) async throws -> LinuxKernel? {
        let pages = try await guestCapture(machine, Self.rootRequest(LinuxSetup.pageSize), readTimeout: 120)
        guard pages.report == ExitReport(status: 0) else {
            throw AgentVMError.guestCommandFailed(command: "read the kernel's page size", status: pages.report.shellStatus, output: Printable.line(pages.stderr, limit: 300))
        }
        let pageSize = LinuxPageSize.parsed(pages.stdout)
        let base = LinuxBase.known(for: record.linux)
        guard let wanted = pageBytes ?? (record.linux?.pageSize == nil ? base?.defaultPageBytes : nil), wanted != pageSize else {
            return nil
        }
        guard let base else {
            throw AgentVMError.linuxBase("--page-size \(wanted >> 10)k: this agent-vm knows no other kernel for \(record.systemShort)")
        }
        let kernel = try base.kernel(pageBytes: wanted)
        notice("  note: \(record.systemShort)'s kernel with \(LinuxPageSize.name(wanted)) pages takes the place of the one with \(pageSize.map(LinuxPageSize.name) ?? "?") pages")
        return kernel
    }

    /// Installs `kernel` in place of the image's (LinuxSetup.kernelSwitch), shuts the copy down
    /// and boots it again, and fails unless it then runs a kernel with that page size. Returns
    /// the machine that runs now, the kernel that ran before and the one that runs. A machine
    /// this started and that fails here is stopped here.
    private func switchKernel(_ kernel: LinuxKernel, machine: GuestMachine, files: MachineFiles, image: GoldenImage, record: ImageRecord,
                              extras: LinuxMachineExtras) async throws -> (machine: GuestMachine, previous: String, running: String) {
        func version(_ machine: GuestMachine) async throws -> String {
            let result = try await guestCapture(machine, Self.rootRequest(LinuxSetup.kernel), readTimeout: 120)
            guard result.report == ExitReport(status: 0) else {
                throw AgentVMError.guestCommandFailed(command: "read the kernel's version", status: result.report.shellStatus, output: Printable.line(result.stderr, limit: 300))
            }
            return try LinuxSetup.token(result.stdout, what: "kernel version")
        }
        let previous = try await version(machine)
        let steps = [LinuxSetup.waitForNetwork] + LinuxSetup.kernelSwitch(kernel, distribution: record.linux?.distribution ?? "debian")
        try await runLinuxSteps(steps, machine: machine, offset: 0, count: steps.count)
        try await shutDownAfterUpdate(machine, guest: .linux)
        try checkCanceled()
        progress("check-boot", "Booting again on the kernel with \(LinuxPageSize.name(kernel.pageBytes)) pages")
        let next = try await startAgain(files, image: image, extras: extras)
        do {
            _ = try await waitForDaemon(next, attempts: 180, guest: .linux)
            let running = try await version(next)
            let pages = try await guestCapture(next, Self.rootRequest(LinuxSetup.pageSize), readTimeout: 120)
            guard pages.report == ExitReport(status: 0), LinuxPageSize.parsed(pages.stdout) == kernel.pageBytes else {
                throw AgentVMError.guestCommandFailed(command: "check the kernel", status: pages.report.shellStatus,
                                                      output: "the updated image boots kernel \(running) with pages of \(Printable.line(pages.stdout.trimmingCharacters(in: .whitespacesAndNewlines), limit: 16)) bytes, not \(kernel.pageBytes)")
            }
            log("  kernel \(running), \(LinuxPageSize.name(kernel.pageBytes)) pages")
            return (next, previous, running)
        } catch {
            let error = canceledError(error)
            await stopAfterFailure(next)
            throw error
        }
    }

    /// Starts the update's copy again. Between two boots the update holds no virtual machine
    /// slot, and a box started in that moment can take the last one: this waits for a slot
    /// rather than lose the update.
    private func startAgain(_ files: MachineFiles, image: GoldenImage, extras: LinuxMachineExtras) async throws -> GuestMachine {
        let deadline = ContinuousClock.now + Self.slotPatience
        var waiting = false
        while true {
            // A new machine for every try: one that was refused is not started again.
            let machine = try makeMachine(for: image, files: files, extras: extras)
            do {
                try await start(machine, of: image)
                return machine
            } catch AgentVMError.noFreeVMSlot where ContinuousClock.now < deadline {
                if !waiting {
                    waiting = true
                    notice("  note: no free virtual machine slot for the next boot; waiting for one (up to \(Self.slotPatience.components.seconds / 60) minutes)")
                }
                try checkCanceled()
                try await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Installs the distribution's package updates in a Linux image (LinuxSetup.systemUpdate).
    /// Returns how many packages changed, whether a newer kernel than the running one is
    /// installed now, the kernel that ran and its page size, and the compiler package's label
    /// when the image has it. What the first build sealed and the update undid (an ssh server
    /// back as a dependency, a timer on again) fails the update; what a recipe changed on
    /// purpose before it does not: a check counts only when it passed before the update.
    /// `sealed`: the checks that passed before another kernel was installed in this update,
    /// when one was; they are then the ones that count.
    private func updateLinuxSystem(_ machine: GuestMachine, record: ImageRecord, sealed: Set<String>? = nil) async throws
        -> (packages: Int, kernelNeedsBoot: Bool, kernel: String, tools: String?, pageSize: Int?) {
        func answer(_ script: String, _ what: String) async throws -> String {
            let result = try await guestCapture(machine, Self.rootRequest(script), readTimeout: 120)
            guard result.report == ExitReport(status: 0) else {
                throw AgentVMError.guestCommandFailed(command: what, status: result.report.shellStatus, output: Printable.line(result.stderr, limit: 300))
            }
            return result.stdout
        }
        let clock = ContinuousClock()
        let began = clock.now
        let checks = LinuxSetup.sealChecks(distribution: record.linux?.distribution ?? "debian")
        let held: Set<String>
        if let sealed {
            held = sealed
        } else {
            held = try await passingChecks(checks, machine: machine)
        }
        let before = try await answer(LinuxSetup.packageList, "list the packages")
        progress("system-update", "Installing \(record.systemShort)'s package updates")
        let pageSize = LinuxPageSize.parsed(try await answer(LinuxSetup.pageSize, "read the kernel's page size"))
        let steps = [LinuxSetup.waitForNetwork] + LinuxSetup.systemUpdate
        try await runLinuxSteps(steps, machine: machine, offset: 0, count: steps.count)
        let packages = LinuxSetup.packageChanges(before: before, after: try await answer(LinuxSetup.packageList, "list the packages"))
        let holds = try await passingChecks(checks, machine: machine)
        if let undone = checks.first(where: { held.contains($0.name) && !holds.contains($0.name) }) {
            throw AgentVMError.guestCommandFailed(command: "check what the update left", status: 1,
                                                  output: "\"\(undone.name)\" was so before the update and is not after it")
        }
        let running = try LinuxSetup.token(try await answer(LinuxSetup.kernel, "read the kernel's version"), what: "kernel version")
        let needsBoot = LinuxSetup.kernelNeedsBoot(running: running, newest: try await answer(LinuxSetup.newestKernel, "find the newest kernel"))
        var tools: String?
        if packages > 0, record.commandLineTools != nil {
            tools = "\(LinuxSetup.toolsPackage) \(try LinuxSetup.packageVersion(try await answer(LinuxSetup.toolsVersion, "read the compiler's version"), package: LinuxSetup.toolsPackage))"
        }
        if packages == 0 {
            log("  \(record.systemShort) has every update its package lists offer")
        } else {
            log("  \(packages) \(packages == 1 ? "package" : "packages") changed in \(Int(Self.seconds(clock.now - began))) s\(needsBoot ? "; a new kernel is installed" : "")")
        }
        return (packages, needsBoot, running, tools, pageSize)
    }

    /// The names of the checks that pass now.
    private func passingChecks(_ checks: [LinuxSetup.Step], machine: GuestMachine) async throws -> Set<String> {
        var passing = Set<String>()
        for check in checks {
            let result = try await guestCapture(machine, Self.rootRequest(check.script))
            if result.report == ExitReport(status: 0) {
                passing.insert(check.name)
            }
        }
        return passing
    }

    /// The image's own lock, for making the update's copy and for putting the finished update
    /// in place: a box or an image being cloned from it holds the lock for a moment, so this
    /// waits up to `commitPatience`.
    private func lockToCommit(_ image: GoldenImage) async throws -> ImageStore.Lock {
        let deadline = ContinuousClock.now + Self.commitPatience
        while true {
            if let lock = try store.tryLock(image) {
                return lock
            }
            guard ContinuousClock.now < deadline else {
                throw AgentVMError.imageBusy(image.name)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Whether agent-vm-guest has Full Disk Access now, as the record keeps it; a grant the
    /// record had and the guest lost is a notice.
    private func probedFullDiskAccess(_ machine: GuestMachine, record: ImageRecord, image: String) async throws -> ImageRecord.FullDiskAccess {
        let granted = try await hasFullDiskAccess(machine)
        if !granted, record.fullDiskAccess?.granted == true {
            notice("  note: agent-vm-guest lost Full Disk Access in the update (macOS ties it to the daemon's code signature; one signed with a Developer ID keeps it); run `agent-vm image setup \(image)` to grant it again")
        }
        return ImageRecord.FullDiskAccess(granted: granted, guestDigest: record.guestDigest, guestRequirement: record.guestRequirement,
                                          checkedAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)))
    }

    /// Boots the updated copy once more and shuts it down: under its new agent-vm-guest
    /// (`newDaemon`), which must answer with every feature this agent-vm knows, or, for a
    /// Linux image, only to see that it comes up on the kernel the update installed. A macOS
    /// image also has its desktop brought up to date and Full Disk Access probed. Returns the
    /// record with the new daemon, and for Linux the kernel that ran, in it.
    private func checkSecondBoot(_ files: MachineFiles, image: GoldenImage, record: ImageRecord, newDaemon: (digest: String, requirement: String?)?,
                                 extras: LinuxMachineExtras) async throws -> ImageRecord {
        var record = record
        let guest = image.record.effectiveGuest
        try checkCanceled()
        if newDaemon != nil {
            progress("check-guest-daemon", "Booting again to check the new agent-vm-guest")
        } else {
            progress("check-boot", "Booting again to check the new kernel")
        }
        let machine = try await startAgain(files, image: image, extras: extras)
        do {
            let hello = try await waitForDaemon(machine, attempts: 180, guest: guest)
            if newDaemon != nil {
                let missing = GuestFeature.all(for: guest).filter { !(hello.features ?? []).contains($0) }
                guard missing.isEmpty else {
                    throw AgentVMError.guestCommandFailed(command: "hello", status: 0, output: "the new agent-vm-guest lacks \(missing.joined(separator: ", "))")
                }
                // The Linux daemon cannot be asked for its version on the Mac: a stale build
                // of it shows here, and the image keeps the daemon it had.
                guard guest == .macOS || hello.version == AgentVM.version else {
                    throw AgentVMError.hostNotReady("the Linux guest daemon beside agent-vm is version \(Printable.line(hello.version ?? "?", limit: 32)) and agent-vm is \(AgentVM.version); build both with Scripts/build.sh")
                }
            }
            log("  agent-vm-guest \(hello.version ?? "?") answers (\((hello.features ?? []).joined(separator: ", ")))")
            if newDaemon != nil {
                record.guestVersion = hello.version
                record.guestProtocol = hello.v
                record.guestFeatures = hello.features
            }
            switch guest {
            case .macOS:
                await prepareDesktop(image, machine: machine, features: hello.features)
                if let newDaemon {
                    // The grant is asked about before the record names the new daemon: it was the old one's.
                    let had = record
                    record.guestDigest = newDaemon.digest
                    record.guestRequirement = newDaemon.requirement
                    var access = try await probedFullDiskAccess(machine, record: had, image: image.name)
                    access.guestDigest = newDaemon.digest
                    access.guestRequirement = newDaemon.requirement
                    record.fullDiskAccess = access
                }
            case .linux:
                if let newDaemon {
                    record.guestDigest = newDaemon.digest
                    record.guestRequirement = newDaemon.requirement
                }
                // The kernel a box of the image boots from now on.
                let kernel = try await guestCapture(machine, Self.rootRequest(LinuxSetup.kernel))
                if kernel.report == ExitReport(status: 0), let running = try? LinuxSetup.token(kernel.stdout, what: "kernel version") {
                    record.linux?.kernel = running
                    let pages = try await guestCapture(machine, Self.rootRequest(LinuxSetup.pageSize))
                    // A size that cannot be read leaves what the record has: one that names none
                    // would get the system's default kernel at the next update.
                    if pages.report == ExitReport(status: 0), let size = LinuxPageSize.parsed(pages.stdout) {
                        record.linux?.pageSize = size
                    }
                    log("  kernel \(running)\(record.linux?.pageSize.map { ", \(LinuxPageSize.name($0)) pages" } ?? "")")
                }
            }
            try await shutDownAfterUpdate(machine, guest: guest)
            return record
        } catch {
            let error = canceledError(error)
            await stopAfterFailure(machine)
            throw error
        }
    }

    /// What a tools update runs: the image's recipes that have update steps, loaded from its
    /// `Recipes/` folder with the parameters it recorded and `set` over them (a name in `set`
    /// must be a parameter of one of them), and, when there is at least one, every other
    /// recipe that has checks, for its checks alone. Empty when no recipe has update steps.
    ///
    /// `replacing`: recipe files that take the place of the kept recipe of the same name (the
    /// name of the file's folder, as when the image was built). One the image keeps none of, one
    /// for another system, and two of one name are refused; one that is what the image keeps
    /// already replaces nothing.
    ///
    /// `builtIn`: the recipes that came with agent-vm. A kept recipe that is an older version
    /// of one of them, and that `replacing` does not name, is replaced by the installed one.
    func toolsPlans(_ image: GoldenImage, set: [String: String], replacing: [URL] = [], builtIn: BuiltInRecipes? = nil) throws -> [ToolsPlan] {
        var newer: [String: ImageRecipe] = [:]
        let kept = (image.record.recipes ?? []).filter { $0.folder != nil }.compactMap(\.name)
        for url in replacing {
            let recipe = try ImageRecipe.load(from: url)
            try recipe.check(serves: image.record.effectiveGuest, image: image.name)
            guard kept.contains(recipe.name) else {
                let have = kept.isEmpty ? "it keeps none" : "it keeps: \(kept.joined(separator: ", "))"
                throw AgentVMError.invalidRecipe(path: url.path, reason: "\(image.name) keeps no recipe named \(recipe.name) to replace (\(have)); a recipe is named after its folder")
            }
            guard newer.updateValue(recipe, forKey: recipe.name) == nil else {
                throw AgentVMError.invalidRecipe(path: url.path, reason: "--recipe gives two recipes named \(recipe.name)")
            }
        }
        var plans: [ToolsPlan] = []
        for (index, info) in (image.record.recipes ?? []).enumerated() {
            guard let folder = info.folder else {
                continue
            }
            let url = image.recipesURL.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(ImageStore.recipeName)
            var recipe: ImageRecipe
            var replaces = false
            var ours = false
            // What the folder holds decides, not the digest in the record: an update that was
            // killed after the record was written and before the recipe was put in its folder
            // left the old recipe there under the new digest, and it must be replaced again.
            let inFolder = Result { try ImageRecipe.load(from: url) }
            let keptDigest = (try? inFolder.get())?.digest
            // The first kept recipe of the name, should a name be there twice.
            if let name = info.name, let given = newer.removeValue(forKey: name) {
                recipe = given
                replaces = given.digest != info.digest || given.digest != keptDigest
            } else if let name = info.name, let installed = builtIn?.newer(name: name, digest: keptDigest ?? info.digest), installed.guest.serves(image.record.effectiveGuest) {
                recipe = installed
                replaces = true
                ours = true
            } else {
                recipe = try inFolder.get()
            }
            recipe.name = info.name ?? recipe.name
            guard !recipe.updateSteps.isEmpty else {
                if !recipe.checks.isEmpty || replaces {
                    plans.append(ToolsPlan(index: index, recipe: try recipe.bindingForUpdate(recorded: info.parameters ?? [:], set: [:]), checksOnly: true, replaces: replaces, builtIn: ours))
                }
                continue
            }
            plans.append(ToolsPlan(index: index, recipe: try recipe.bindingForUpdate(recorded: info.parameters ?? [:], set: set), replaces: replaces, builtIn: ours))
        }
        let known = Set(plans.filter { !$0.checksOnly }.flatMap { $0.recipe.parameters.map(\.name) })
        if let name = set.keys.sorted().first(where: { !known.contains($0) }) {
            let reason = known.isEmpty
                ? "--set \(name): \(image.name) keeps no recipe with update steps"
                : "--set \(name): no recipe with update steps in \(image.name) has that parameter (they have: \(known.sorted().joined(separator: ", ")))"
            throw AgentVMError.invalidRecipe(path: image.recipesURL.path, reason: reason)
        }
        return plans.contains { !$0.checksOnly || $0.replaces } ? plans : []
    }

    /// Puts `recipe` and the files it copies where the image keeps the recipe of that name,
    /// in the place of what is there: written beside it first, so a failure leaves the old one.
    static func replaceKeptRecipe(_ recipe: ImageRecipe, in recipes: URL, folder: String) throws {
        // The name comes from the image's record: never one that leads out of `recipes`.
        guard !folder.isEmpty, !folder.contains("/"), folder != ".", folder != ".." else {
            throw AgentVMError.invalidRecipe(path: recipes.path, reason: "\(folder) is not the name of a folder in it")
        }
        let target = recipes.appendingPathComponent(folder, isDirectory: true)
        let staged = recipes.appendingPathComponent(".new-" + folder, isDirectory: true)
        let old = recipes.appendingPathComponent(".old-" + folder, isDirectory: true)
        for left in [staged, old] where FileSystem.exists(left.path) {
            try FileSystem.removeTree(left.path)
        }
        do {
            try recipe.write(to: staged)
            // The two change places in one step where the volume can do that, so a run killed
            // here never leaves the image without the recipe's folder.
            if FileSystem.exists(target.path), renamex_np(staged.path, target.path, UInt32(RENAME_SWAP)) == 0 {
                try? FileSystem.removeTree(staged.path)
                return
            }
            if FileSystem.exists(target.path) {
                guard rename(target.path, old.path) == 0 else {
                    throw AgentVMError.system(operation: "move \(target.path) away", code: errno)
                }
            }
            guard rename(staged.path, target.path) == 0 else {
                let code = errno
                _ = rename(old.path, target.path)
                throw AgentVMError.system(operation: "move \(staged.path) into place", code: code)
            }
        } catch {
            try? FileSystem.removeTree(staged.path)
            throw error
        }
        try? FileSystem.removeTree(old.path)
    }

    /// Installs the macOS update Apple offers within the image's major version, and waits for
    /// the guest to come back on the new build. Returns the new version and build, or nil when
    /// none is offered.
    private func updateMacOS(_ machine: GuestMachine, image: GoldenImage) async throws -> (version: String, build: String)? {
        let clock = ContinuousClock()
        let began = clock.now
        progress("macos-check", "Asking Apple for macOS updates")
        let listed = try await guestCapture(machine, MacOSUpdate.listRequest, readTimeout: 600)
        guard listed.report == ExitReport(status: 0) else {
            throw AgentVMError.guestCommandFailed(command: "softwareupdate --list", status: listed.report.shellStatus, output: String(listed.stdout.suffix(400)))
        }
        let before = try await macOSVersion(machine)
        guard let major = MacOSUpdate.numbers(before.version).first,
              let update = MacOSUpdate.offered(inListOutput: listed.stdout, major: major), update.build != before.build else {
            log("  macOS \(before.version) (\(before.build)) is the newest Apple offers")
            return nil
        }
        progress("macos-download", "Updating macOS \(before.version) (\(before.build)) to \(update.version) (\(update.build)): downloading and preparing")
        let password = try image.accountPassword(keychain: store.passwords)
        let label = "softwareupdate --install \(update.label)"
        let emit = LineEmitter(report: report, image: subject)
        let percent = DownloadPercent()
        let report = self.report
        let subject = self.subject
        emit.observer = { bytes in
            guard let reached = percent.add(bytes) else {
                return
            }
            // Past the download, softwareupdate stays in the nineties while it prepares.
            let text = reached >= 90 ? "  \(reached)%: downloaded; preparing the update (several minutes)" : "  \(reached)%"
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    report(ProgressEvent(.progress, text, step: "macos-download", fraction: Double(reached) / 100, image: subject))
                }
            }
        }
        do {
            let ended = try await runStreaming(machine, label, MacOSUpdate.installRequest(label: update.label, user: image.record.userName),
                                               input: Data((password.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").utf8),
                                               readTimeout: Self.macOSUpdateSilenceSeconds, emit: emit)
            guard ended == ExitReport(status: 0) else {
                throw AgentVMError.guestCommandFailed(command: label, status: ended.shellStatus, output: String(emit.tail.suffix(800)))
            }
        } catch let error as AgentVMError {
            if case .guestCommandFailed = error {
                throw error
            }
            if Self.isCancel(error) {
                throw error
            }
            // The restart can take the connection before the exit status arrives: whether the
            // update went in is decided by the build the guest comes back with.
            emit.flush()
            log("  the connection ended while softwareupdate ran (\(error)); waiting for the guest")
        }
        progress("macos-restart", "Restarting to install (a few minutes)")
        let deadline = clock.now + Self.macOSRestartTimeout
        var after = before
        while after.build == before.build {
            try checkCanceled()
            guard clock.now < deadline else {
                throw AgentVMError.guestUnreachable("the guest did not come back on macOS \(update.build) within \(Self.macOSRestartTimeout); softwareupdate said:\n\(String(emit.tail.suffix(800)))")
            }
            // An update may shut the guest down instead of restarting it.
            if !machine.isRunning {
                if let failure = machine.failure {
                    throw AgentVMError.virtualMachine(operation: "install the macOS update", message: failure)
                }
                log("  the guest shut down; starting it again")
                try await machine.start(provisioning: nil)
            }
            try await Task.sleep(for: .seconds(5))
            if let now = try? await macOSVersion(machine, quiet: true) {
                after = now
            }
        }
        // Once more through the usual door: the clock is set, and the daemon is known to answer.
        _ = try await waitForDaemon(machine, attempts: 180)
        log("  macOS \(after.version) (\(after.build)) installed in \(Int(Self.seconds(clock.now - began))) s")
        return after
    }

    /// The guest's macOS version and build. `quiet`: one attempt, for a guest that may be
    /// restarting.
    private func macOSVersion(_ machine: GuestMachine, quiet: Bool = false) async throws -> (version: String, build: String) {
        let request = MacOSUpdate.versionRequest
        let result = try await withGuest(machine, "sw_vers", readTimeout: 15, redeliver: !quiet) { try GuestClient.capture($0, request) }
        let lines = result.stdout.split(whereSeparator: \.isNewline).map(String.init)
        // Recorded in the image and shown by every list: only what a version and a build look like.
        guard result.report == ExitReport(status: 0), lines.count == 2, lines.allSatisfy({ Printable.isToken($0) }) else {
            throw AgentVMError.guestCommandFailed(command: "sw_vers", status: result.report.shellStatus, output: result.stdout + result.stderr)
        }
        return (lines[0], lines[1])
    }

    /// Installs a newer Command Line Tools package when the image has the tools and Apple
    /// offers one; returns its label.
    private func updateCommandLineTools(_ machine: GuestMachine, installed: String?) async throws -> String? {
        guard let installed else {
            return nil
        }
        let listed = try await guestCapture(machine, MacOSUpdate.listRequest, readTimeout: 600)
        guard listed.report == ExitReport(status: 0), let label = CommandLineTools.label(fromListOutput: listed.stdout), label != installed else {
            return nil
        }
        progress("command-line-tools", "Updating the Command Line Tools: \(label)")
        let result = try await guestCapture(machine, CommandLineTools.installRequest(label: label), readTimeout: 1800)
        guard result.report == ExitReport(status: 0) else {
            throw AgentVMError.guestCommandFailed(command: "softwareupdate --install \(label)", status: result.report.shellStatus,
                                                  output: String((result.stdout + result.stderr).suffix(400)))
        }
        let verified = try await guestCapture(machine, CommandLineTools.verifyRequest)
        guard verified.report == ExitReport(status: 0) else {
            throw AgentVMError.guestCommandFailed(command: "check the Command Line Tools", status: verified.report.shellStatus,
                                                  output: (verified.stderr + verified.stdout).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return label
    }

    /// One recipe's update steps, then its checks.
    private func runUpdate(_ recipe: ImageRecipe, machine: GuestMachine, boxUser: String, position: (index: Int, count: Int), guest: GuestKind) async throws {
        let clock = ContinuousClock()
        let began = clock.now
        progress("tools-update", "Updating \(recipe.name) (\(position.index) of \(position.count))\(recipe.description.map { ": \($0)" } ?? "")",
                 index: position.index, count: position.count)
        if !recipe.parameterValues.isEmpty {
            log("  parameters: \(recipe.parameterValues.keys.sorted().map { "\($0)=\(recipe.parameterValues[$0] ?? "")" }.joined(separator: ", "))")
        }
        try await runSteps(recipe.updateSteps, checks: recipe.checks, variables: recipe.variables(for: guest), machine: machine, boxUser: boxUser, kind: "update step")
        log("  \(recipe.name) updated in \(Int(Self.seconds(clock.now - began))) s")
    }

    /// Shuts the updated guest down. A macOS 27 guest sometimes restarts instead of powering
    /// off: one that answers again is asked again, rather than losing the whole update.
    private func shutDownAfterUpdate(_ machine: GuestMachine, guest: GuestKind) async throws {
        let attempts = 3
        for attempt in 1...attempts {
            do {
                try await shutDown(machine, guest: guest)
                return
            } catch let AgentVMError.guestUnreachable(reason) {
                guard attempt < attempts, machine.isRunning, cancellation?.isCanceled != true else {
                    throw AgentVMError.guestUnreachable(reason)
                }
                notice("  note: the guest did not power off (\(reason)); waiting for it to answer and asking again")
                do {
                    _ = try await waitForDaemon(machine, attempts: 180, guest: guest)
                } catch AgentVMError.guestUnreachable where !machine.isRunning && machine.failure == nil && cancellation?.isCanceled != true {
                    // It powered off after all, only later than `shutDown` waits. The wait
                    // that ends at once lets go of what the machine held while it ran.
                    _ = await machine.waitUntilStopped(timeout: .zero)
                    return
                }
            }
        }
    }
}
