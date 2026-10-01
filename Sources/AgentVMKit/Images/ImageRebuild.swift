// Sources/AgentVMKit/Images/ImageRebuild.swift
//
// `agent-vm image rebuild`: builds an image again under its own name, from a fresh start (a
// restore image, or a ready image) and the recipes the image keeps in its `Recipes/` folder,
// with the parameters it recorded. What `image update` cannot do in place is done this way: a
// new major macOS, a new Xcode, a base that moved on, or a disk that gathered years of updates.
//
// The new image is built beside the old one as `<name>.rebuild`, with everything `image
// create` does. The old image stays ready and usable until the new one is: then the two
// folders change places in one atomic step (renamex_np with RENAME_SWAP) and the old one is
// deleted. A failure, a cancel or a kill before that step leaves the image as it was; the
// unfinished `<name>.rebuild` is removed by the next rebuild (or `image delete`).
//
// Which recipes run again: every recipe that ran on the image's disk and that the new start
// does not already hold. From a restore image that is all of them, so an image that was built
// in layers comes back as one image; from a ready image it is those the base's own list lacks.

import Darwin
import Foundation

public struct ImageRebuildOptions: Sendable {
    public var name: String
    /// The ready image to start from. nil with `restoreImage`; nil without it means the image
    /// this one was built from.
    public var base: String?
    /// The restore image to install macOS from, instead of starting from an image.
    public var restoreImage: URL?
    /// Files for the recipes' inputs (`--input`), by name; an input not given is read from
    /// where it was when the image was built, when that file is still there.
    public var inputs: [String: String]
    /// New values for the recipes' parameters (`--set`), over the recorded ones.
    public var parameters: [String: String]
    public var guestDaemon: URL
    public var askpassProgram: String

    public init(name: String, base: String? = nil, restoreImage: URL? = nil, inputs: [String: String] = [:],
                parameters: [String: String] = [:], guestDaemon: URL, askpassProgram: String) {
        self.name = name
        self.base = base
        self.restoreImage = restoreImage
        self.inputs = inputs
        self.parameters = parameters
        self.guestDaemon = guestDaemon
        self.askpassProgram = askpassProgram
    }
}

/// What a rebuild will do, decided without booting anything.
public struct ImageRebuildPlan: Sendable {
    /// The image as it is now.
    public var image: GoldenImage
    /// The name the new image is built under, beside the old one.
    public var buildName: String
    /// The image it starts from; nil when macOS is installed from the restore image.
    public var base: String?
    /// The recipes to run, in order, with their inputs and parameters.
    public var recipes: [ImageRecipe]
    public var commandLineTools: Bool
}

extension ImageStore {
    static let rebuildSuffix = ".rebuild"
    /// In a finished `<name>.rebuild`: the name of the image it is to replace.
    static let rebuildMarkerName = ".rebuild-of"

    /// The name an image is rebuilt under.
    public static func rebuildName(for name: String) -> String {
        return name + rebuildSuffix
    }

    func rebuildMarker(_ built: GoldenImage) -> URL {
        return built.directory.appendingPathComponent(Self.rebuildMarkerName)
    }

    /// What an earlier rebuild of `name` left at its build name, before a new one starts.
    enum RebuildLeftover {
        /// Nothing, or something that was removed: build.
        case none
        /// A finished build that never took the image's place: only the exchange is left.
        case finished(GoldenImage)
    }

    /// The record in a folder, whatever image it names.
    private func recordAsWritten(in directory: URL) -> ImageRecord? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(Self.recordName)) else {
            return nil
        }
        return try? SessionStore.decoder.decode(ImageRecord.self, from: data)
    }

    /// Clears the build name for a rebuild of `image`. A finished build (ready, marked as
    /// this image's, and newer than it) is returned for the exchange; its record may already
    /// carry the image's name, when a kill came just before the exchange. A ready image that
    /// merely has the build name (somebody's own, with no marker) is never touched: the
    /// rebuild is refused. Everything else goes: an unfinished or failed build, and the old
    /// image a kill left there after the exchange (older than the image now in place).
    func clearRebuildLeftover(of image: GoldenImage) throws -> RebuildLeftover {
        let buildName = Self.rebuildName(for: image.name)
        let directory = imagesDirectory.appendingPathComponent(buildName, isDirectory: true)
        guard FileSystem.exists(directory.path) else {
            return .none
        }
        if let record = recordAsWritten(in: directory), record.state == .ready {
            let left = GoldenImage(record: record, directory: directory)
            let marker = try? String(contentsOf: rebuildMarker(left), encoding: .utf8)
            if marker == image.name, record.createdAt > image.record.createdAt, record.name == buildName || record.name == image.name {
                return .finished(left)
            }
            if marker == nil, record.name == buildName {
                throw AgentVMError.imageExists(name: buildName, state: record.state.rawValue)
            }
        }
        try delete(named: buildName)
        return .none
    }

    /// Marks a finished build as the one to take `name`'s place.
    func markRebuilt(_ built: GoldenImage, of name: String) throws {
        do {
            try Data(name.utf8).write(to: rebuildMarker(built), options: .atomic)
        } catch {
            throw AgentVMError.system(operation: "write \(rebuildMarker(built).path)", code: FileSystem.posixCode(error))
        }
    }

    /// Puts a finished build in the image's place: the build's record takes the image's name,
    /// the two folders change places in one atomic step, and the old image is deleted. The
    /// caller holds both of the old image's locks. Returns the image as it is now.
    func replace(_ image: GoldenImage, with built: GoldenImage) throws -> GoldenImage {
        guard let builtLock = try tryLock(built) else {
            throw AgentVMError.imageBusy(built.name)
        }
        defer { builtLock.release() }
        // Under the lock: nothing else is finishing this build.
        guard let record = recordAsWritten(in: built.directory), record.state == .ready else {
            throw AgentVMError.wrongImageState(name: built.directory.lastPathComponent, state: "not ready", operation: "put in place of \(image.name)")
        }
        let current = GoldenImage(record: record, directory: built.directory)
        // The record first, so the folder is whole the moment it has the image's name. Until
        // the exchange a list warns about a record under another folder's name, for a moment;
        // a kill in that moment is mended by the next rebuild (`clearRebuildLeftover`).
        try update(current) { $0.name = image.name }
        guard renamex_np(current.directory.path, image.directory.path, UInt32(RENAME_SWAP)) == 0 else {
            let code = errno
            _ = try? update(current) { $0.name = current.directory.lastPathComponent }
            throw AgentVMError.system(operation: "put \(current.directory.path) in place of \(image.directory.path)", code: code)
        }
        // The new image is in place; the old one is now at the build's path. Left there by a
        // failure, it is removed by the next rebuild, or by `image delete`.
        try? FileManager.default.removeItem(at: image.directory.appendingPathComponent(Self.rebuildMarkerName))
        try? FileSystem.removeTree(current.directory.path)
        return try self.image(named: image.name)
    }
}

extension ImageBuilder {
    /// How long a finished rebuild waits for the old image's lock (a box being cloned from it
    /// holds it for a moment).
    static let replacePatience: Duration = .seconds(120)

    /// What `rebuild` would do, and everything it would refuse without booting anything: no
    /// such image, no start to build from, a kept recipe that no longer loads, an input whose
    /// file is gone, a `--set` or `--input` no recipe takes.
    public func rebuildPlan(_ options: ImageRebuildOptions) throws -> ImageRebuildPlan {
        let image = try store.image(named: options.name)
        func refuse(_ reason: String) -> AgentVMError {
            return AgentVMError.invalidRecipe(path: image.directory.path, reason: reason)
        }
        guard image.record.state == .ready || image.record.state == .failed else {
            throw AgentVMError.wrongImageState(name: image.name, state: image.record.state.rawValue, operation: "rebuild")
        }
        let buildName = ImageStore.rebuildName(for: image.name)
        guard ImageStore.isValidName(buildName) else {
            throw refuse("the name is too long to rebuild: the new image is built as \(buildName), and an image name has at most 63 characters")
        }
        guard options.base == nil || options.restoreImage == nil else {
            throw refuse("give a restore image or an image to start from, not both")
        }

        // Where it starts.
        var base: GoldenImage?
        if options.restoreImage == nil {
            guard let baseName = options.base ?? image.record.derivedFrom?.image else {
                throw refuse("\(image.name) was installed from a restore image: give --ipsw (a restore image to install), or --from (a ready image to start from)")
            }
            guard baseName != image.name else {
                throw refuse("an image cannot be rebuilt from itself")
            }
            do {
                base = try store.image(named: baseName)
            } catch AgentVMError.imageNotFound where options.base == nil {
                throw refuse("the image it was built from, \(baseName), is gone: give --from (a ready image to start from) or --ipsw (a restore image to install)")
            }
            if let base, base.record.state != .ready {
                throw AgentVMError.wrongImageState(name: base.name, state: base.record.state.rawValue, operation: "build an image from")
            }
        }

        // Which recipes ran on the disk, with what the image recorded about each.
        var kept: [(info: ImageRecord.RecipeInfo, recipe: ImageRecipe)] = []
        if let infos = image.record.recipes {
            for info in infos {
                guard let folder = info.folder else {
                    throw refuse("its record lists a recipe without its folder (\(info.name ?? String(info.digest.prefix(12))))")
                }
                var recipe = try ImageRecipe.load(from: image.recipesURL.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(ImageStore.recipeName))
                recipe.name = info.name ?? recipe.name
                kept.append((info, recipe))
            }
        } else if let info = image.record.recipe {
            // Built before images kept every recipe: its own one is beside the record (without
            // the files it copies), and what ran on its base is not recorded here.
            guard base != nil else {
                throw refuse(image.record.derivedFrom == nil
                    ? "it was built before agent-vm kept recipes with their files; create a new image with `agent-vm image create`"
                    : "it was built from \(image.record.derivedFrom?.image ?? "another image") before agent-vm kept every recipe, so what ran on its base is not known: rebuild it with --from, or create a new image with all the recipes")
            }
            kept.append((info, try ImageRecipe.load(from: image.recipeURL)))
        }
        // A restore image brings nothing from the base. When the base had a recipe (the record
        // says so) and the list holds none of the base's, it was built on a base from before
        // images kept every recipe: installing anew would drop what that recipe installed.
        if base == nil, let from = image.record.derivedFrom, from.recipeDigest != nil,
           !(image.record.recipes ?? []).contains(where: { $0.inheritedFrom != nil }) {
            throw refuse("it was built from \(from.image) before agent-vm kept every recipe, so what ran on its base is not known: rebuild it with --from, or create a new image with all the recipes")
        }
        // What the start already holds does not run again: a recipe with a digest in the
        // start's list, and what the image inherited from that very image (the start may hold
        // a newer version of that recipe by now, and the old one must not run over it).
        let held = Set((base?.record.recipes ?? base?.record.recipe.map { [$0] } ?? []).map(\.digest))
        let replayed = kept.filter { !held.contains($0.info.digest) && (base == nil || $0.info.inheritedFrom != base?.name) }
        if let base, replayed.isEmpty {
            throw refuse("\(image.name) keeps no recipe that \(base.name) lacks: the rebuilt image would be a plain copy of \(base.name)")
        }

        for name in options.inputs.keys.sorted() where !replayed.contains(where: { $0.recipe.inputs.contains { $0.name == name } }) {
            let names = Set(replayed.flatMap { $0.recipe.inputs.map(\.name) }).sorted()
            throw refuse("--input \(name): no recipe to run has that input\(names.isEmpty ? "" : " (they have: \(names.joined(separator: ", ")))")")
        }
        for name in options.parameters.keys.sorted() where !replayed.contains(where: { $0.recipe.parameters.contains { $0.name == name } }) {
            let names = Set(replayed.flatMap { $0.recipe.parameters.map(\.name) }).sorted()
            throw refuse("--set \(name): no recipe to run has that parameter\(names.isEmpty ? "" : " (they have: \(names.joined(separator: ", ")))")")
        }
        let recipes = try replayed.map { info, recipe -> ImageRecipe in
            var inputs: [String: String] = [:]
            for input in recipe.inputs {
                let recorded = info.inputs?.first { $0.name == input.name }
                if let given = options.inputs[input.name] {
                    inputs[input.name] = given
                } else if let path = recorded?.path, FileSystem.exists(path) {
                    inputs[input.name] = path
                } else {
                    let was = recorded.map { " (the image was built with \($0.path ?? $0.file), \($0.bytes >> 20) MB)" } ?? ""
                    throw AgentVMError.invalidRecipe(path: recipe.path, reason: "it needs --input \(input.name)=PATH\(input.description.map { ": \($0)" } ?? "")\(was)")
                }
            }
            var parameters = (info.parameters ?? [:]).filter { pair in recipe.parameters.contains { $0.name == pair.key } }
            for (name, value) in options.parameters where recipe.parameters.contains(where: { $0.name == name }) {
                parameters[name] = value
            }
            return try recipe.binding(inputs: inputs, parameters: parameters)
        }
        let asked = recipes.compactMap(\.commandLineTools)
        return ImageRebuildPlan(image: image, buildName: buildName, base: base?.name, recipes: recipes,
                                commandLineTools: image.record.commandLineTools != nil || asked.contains(true))
    }

    /// Builds the image again and puts it in the old one's place (see the top of this file).
    /// Returns the image as it is now.
    public func rebuild(_ options: ImageRebuildOptions) async throws -> GoldenImage {
        let plan = try rebuildPlan(options)
        let old = plan.image
        subject = old.name
        // Held throughout, like an update: one command changes an image at a time, and lists
        // show the image as being changed.
        guard let changeLock = try store.tryLockForChange(old) else {
            throw AgentVMError.imageBusy(old.name)
        }
        defer { changeLock.release() }

        var built: GoldenImage
        switch try store.clearRebuildLeftover(of: old) {
        case let .finished(left):
            log("\(plan.buildName) is already built (\(left.record.createdAt.formatted(.iso8601))): only putting it in place")
            if options.restoreImage != nil || options.base != nil || !options.inputs.isEmpty || !options.parameters.isEmpty {
                notice("  note: the options given are not used: that build is finished. To build again with them, delete it first: `agent-vm image delete \(plan.buildName)`")
            }
            built = left
        case .none:
            // Events, and the wallpaper the image shows, name the image and not its build name.
            shownName = old.name
            defer { shownName = nil }
            log("Rebuilding \(old.name) as \(plan.buildName), \(plan.base.map { "from \($0)" } ?? "from \(options.restoreImage?.lastPathComponent ?? "a restore image")"); \(old.name) stays usable until it is replaced")
            if plan.recipes.isEmpty {
                log("  no recipes to run")
            } else {
                log("  recipes: \(plan.recipes.map(\.name).joined(separator: ", "))")
            }
            if let restoreImage = options.restoreImage {
                built = try await build(ImageBuildOptions(
                    name: plan.buildName, restoreImage: restoreImage, cpuCount: old.record.cpuCount, memoryBytes: old.record.memoryBytes,
                    diskBytes: old.record.diskBytes, userName: old.record.userName, askpassProgram: options.askpassProgram,
                    guestDaemon: options.guestDaemon, commandLineTools: plan.commandLineTools, recipes: plan.recipes))
            } else if let base = plan.base {
                let baseRecord = try store.image(named: base).record
                // A disk only grows, and by a few GB at least: the old size when that is one.
                let grown = old.record.diskBytes >= baseRecord.diskBytes + Self.minimumDiskGrowth
                built = try await derive(ImageDeriveOptions(
                    name: plan.buildName, base: base, recipes: plan.recipes, commandLineTools: plan.commandLineTools,
                    cpuCount: old.record.cpuCount, memoryBytes: old.record.memoryBytes,
                    diskBytes: grown ? old.record.diskBytes : nil, guestDaemon: options.guestDaemon))
            } else {
                throw AgentVMError.invalidRecipe(path: old.directory.path, reason: "no restore image and no image to start from")
            }
            try store.markRebuilt(built, of: old.name)
        }

        progress("replace", "Putting the rebuilt image in place of \(old.name)")
        let deadline = ContinuousClock.now + Self.replacePatience
        var lock: ImageStore.Lock?
        while lock == nil {
            lock = try store.tryLock(old)
            if lock == nil {
                guard ContinuousClock.now < deadline else {
                    notice("  note: \(old.name) is in use, so the rebuilt image stays beside it as \(plan.buildName); `agent-vm image rebuild \(old.name)` puts it in place without building again")
                    throw AgentVMError.imageBusy(old.name)
                }
                try checkCanceled()
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { lock?.release() }
        return try store.replace(old, with: built)
    }
}
