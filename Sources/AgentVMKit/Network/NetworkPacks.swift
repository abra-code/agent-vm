// Sources/AgentVMKit/Network/NetworkPacks.swift
//
// Host packs ("pack:github"): named host lists, so a box can be opened for a purpose without
// spelling out every host. The built-in ones come from packs.json next to the agent-vm
// executable (Resources/packs.json in the repository; Scripts/build.sh puts it there, and an
// app that embeds agent-vm ships it beside it), so a host can change without a rebuild. The
// user's own are Packs/<name>.json in the store; one named like a built-in pack replaces it.
// Boxes name packs, so an edited pack applies when a box starts or its rules change.

import Foundation

public struct NetworkPack: Sendable, Equatable {
    public enum Source: String, Sendable, Codable {
        case builtIn = "built-in"
        case user
    }

    public var name: String
    public var hosts: [String]
    public var description: String?
    public var source: Source
    /// The file it came from.
    public var path: String
    /// A user pack named like a built-in one, which it replaces.
    public var replacesBuiltIn: Bool
}

public struct NetworkPacks: Sendable {
    /// Usable packs by name.
    public var packs: [String: NetworkPack]
    /// User pack files that cannot be used, by pack name: a box naming one is refused, never
    /// given the built-in pack of that name instead.
    public var problems: [String: Problem]

    public struct Problem: Sendable, Equatable {
        public var path: String
        public var reason: String
    }

    public static let fileName = "packs.json"
    /// A packs file to use instead of the one next to the executable (tests, development).
    public static let fileEnvironment = "AGENT_VM_PACKS_FILE"

    /// The built-in packs file: $AGENT_VM_PACKS_FILE, else packs.json next to this executable.
    public static func builtInURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let override = environment[fileEnvironment], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent(fileName)
    }

    /// Where the user's packs live in the store at `root`.
    public static func userDirectory(store root: URL) -> URL {
        return root.appendingPathComponent("Packs", isDirectory: true)
    }

    /// The built-in packs and the store's user packs. A missing or broken built-in file is an
    /// error; a broken user pack is a problem for that pack only.
    public static func load(store root: URL, builtIn: URL? = builtInURL()) throws -> NetworkPacks {
        guard let builtIn else {
            throw AgentVMError.invalidPacks(path: fileName, reason: "cannot find the agent-vm executable, so not the packs file next to it")
        }
        var packs = try readBuiltIn(builtIn)
        var problems: [String: Problem] = [:]
        let directory = userDirectory(store: root)
        // No folder means no user packs; one that cannot be listed is an error, or a user pack
        // replacing a built-in one would silently give way to it.
        var names: [String] = []
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch CocoaError.fileReadNoSuchFile {
        } catch {
            throw AgentVMError.invalidPacks(path: directory.path, reason: "cannot list the folder (\(error.localizedDescription))")
        }
        for file in names.sorted() where file.hasSuffix(".json") && !file.hasPrefix(".") {
            let name = String(file.dropLast(".json".count))
            let path = directory.appendingPathComponent(file).path
            guard isValidName(name) else {
                // "NPM.json" is refused as pack:npm, so it is not listed as the built-in one either.
                packs[name.lowercased()] = nil
                problems[name.lowercased()] = Problem(path: path, reason: "a pack name is lower-case letters, digits, \".\", \"_\" and \"-\"")
                continue
            }
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                let (hosts, description) = try decode(data, name: name)
                packs[name] = NetworkPack(name: name, hosts: hosts, description: description, source: .user, path: path,
                                          replacesBuiltIn: packs[name]?.source == .builtIn)
            } catch let AgentVMError.invalidPacks(_, reason) {
                packs[name] = nil
                problems[name] = Problem(path: path, reason: reason)
            } catch {
                packs[name] = nil
                problems[name] = Problem(path: path, reason: error.localizedDescription)
            }
        }
        return NetworkPacks(packs: packs, problems: problems)
    }

    /// The packs a policy for `network` needs: read only when a rule names a pack, so a
    /// missing packs file does not stop boxes that use none.
    public static func needed(for network: BoxNetwork, store root: URL, builtIn: URL? = builtInURL()) throws -> NetworkPacks {
        guard network.allow.contains(where: { $0.lowercased().hasPrefix("pack:") }) else {
            return NetworkPacks(packs: [:], problems: [:])
        }
        return try load(store: root, builtIn: builtIn)
    }

    /// The hosts of pack `name`; throws for an unknown pack or one whose file is unusable.
    public func hosts(of name: String) throws -> [String] {
        if let problem = problems[name] {
            throw AgentVMError.invalidNetworkRule("pack:\(name)", reason: "\(problem.path): \(problem.reason)")
        }
        guard let pack = packs[name] else {
            throw AgentVMError.invalidNetworkRule("pack:\(name)", reason: "unknown pack; known: \(packs.keys.sorted().joined(separator: ", "))")
        }
        return pack.hosts
    }

    static func isValidName(_ name: String) -> Bool {
        return !name.isEmpty && name.count <= 64 && !name.hasPrefix(".")
            && name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || "._-".contains($0)) }
    }

    /// `{"version": 1, "packs": {"<name>": {"description": "...", "hosts": [...]}}}`.
    static func readBuiltIn(_ url: URL) throws -> [String: NetworkPack] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AgentVMError.invalidPacks(path: url.path, reason: "cannot read it (\(error.localizedDescription)); Scripts/build.sh puts packs.json next to agent-vm")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentVMError.invalidPacks(path: url.path, reason: "not a JSON object")
        }
        // A JSON true would read as 1.
        guard let version = object["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.intValue == 1 else {
            throw AgentVMError.invalidPacks(path: url.path, reason: "\"version\" must be 1")
        }
        guard let entries = object["packs"] as? [String: Any] else {
            throw AgentVMError.invalidPacks(path: url.path, reason: "\"packs\" must be an object of packs by name")
        }
        var packs: [String: NetworkPack] = [:]
        for (name, value) in entries {
            guard isValidName(name) else {
                throw AgentVMError.invalidPacks(path: url.path, reason: "\(name): a pack name is lower-case letters, digits, \".\", \"_\" and \"-\"")
            }
            let (hosts, description) = try parse(value, name: name, path: url.path)
            packs[name] = NetworkPack(name: name, hosts: hosts, description: description, source: .builtIn, path: url.path, replacesBuiltIn: false)
        }
        return packs
    }

    /// A user pack file: `{"description": "...", "hosts": [...]}`.
    static func decode(_ data: Data, name: String) throws -> (hosts: [String], description: String?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw AgentVMError.invalidPacks(path: name, reason: "not JSON")
        }
        return try parse(object, name: name, path: name)
    }

    /// One pack's object: hosts that parse as allow rules, and not `public` (a pack lists hosts;
    /// allowing any public host is for the box's own rules).
    static func parse(_ value: Any, name: String, path: String) throws -> (hosts: [String], description: String?) {
        guard let object = value as? [String: Any] else {
            throw AgentVMError.invalidPacks(path: path, reason: "\(name): a pack is an object with \"hosts\"")
        }
        guard let hosts = object["hosts"] as? [String], !hosts.isEmpty else {
            throw AgentVMError.invalidPacks(path: path, reason: "\(name): \"hosts\" must be a list of host names")
        }
        for host in hosts {
            guard let rule = AllowRule.parse(host), !rule.anyPublicHost else {
                throw AgentVMError.invalidPacks(path: path, reason: "\(name): \(host) is not a host name, *.domain or host:port")
            }
        }
        if let description = object["description"], !(description is String) {
            throw AgentVMError.invalidPacks(path: path, reason: "\(name): \"description\" must be text")
        }
        return (hosts, object["description"] as? String)
    }
}
