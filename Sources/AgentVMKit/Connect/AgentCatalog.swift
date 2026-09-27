// Sources/AgentVMKit/Connect/AgentCatalog.swift
//
// The agents `agent-vm connect` (avm) offers to run: what each is called, the command that
// starts it, the hosts it needs, the secrets that sign it in, and variables it wants. The
// built-in entries come from agents.json next to the agent-vm executable (Resources/agents.json
// in the repository; Scripts/build.sh puts it there), so an entry can change without a rebuild.
// The user's own are Agents/<id>.json in the store: one named like a built-in entry replaces it
// in place, others follow the built-in ones. Loading never throws: a broken user file costs
// only its agent, and a broken built-in file leaves the user's entries and a login shell.

import Foundation

public struct AgentEntry: Equatable, Sendable {
    public struct Secret: Equatable, Sendable {
        /// The variable the program reads.
        public var env: String
        /// The Keychain name, when it differs from `env`.
        public var secret: String?
        /// What it is, for a person.
        public var label: String

        /// The secret's name in the Keychain.
        public var name: String {
            return secret ?? env
        }

        public init(env: String, secret: String? = nil, label: String) {
            self.env = env
            self.secret = secret
            self.label = label
        }
    }

    public enum SecretsNeeded: String, Sendable {
        /// The agent needs one of its secrets to sign in (or a login made inside the box).
        case one
        /// It runs without them.
        case optional
    }

    public enum Source: String, Sendable, Codable {
        case builtIn = "built-in"
        case user
    }

    public var id: String
    public var name: String
    public var command: [String]
    public var allow: [String]
    public var secrets: [Secret]
    public var secretsNeeded: SecretsNeeded
    public var env: [String: String]
    /// How to log in inside a kept box instead of a secret.
    public var login: String?
    /// How to install it in a box that lacks it.
    public var install: String?
    public var note: String?
    public var source: Source
    /// The file it came from.
    public var path: String
    /// A user entry with a built-in entry's id, which it replaces.
    public var replacesBuiltIn: Bool

    public init(id: String, name: String, command: [String], allow: [String] = [], secrets: [Secret] = [],
                secretsNeeded: SecretsNeeded = .optional, env: [String: String] = [:], login: String? = nil,
                install: String? = nil, note: String? = nil, source: Source = .builtIn, path: String = "",
                replacesBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.command = command
        self.allow = allow
        self.secrets = secrets
        self.secretsNeeded = secretsNeeded
        self.env = env
        self.login = login
        self.install = install
        self.note = note
        self.source = source
        self.path = path
        self.replacesBuiltIn = replacesBuiltIn
    }
}

public struct AgentCatalog: Sendable {
    public struct Problem: Sendable, Equatable {
        public var path: String
        public var reason: String

        public init(path: String, reason: String) {
            self.path = path
            self.reason = reason
        }
    }

    /// The usable entries: the built-in ones in the file's order (user replacements in their
    /// place), then the user's new ones by id.
    public var entries: [AgentEntry]
    /// User files that cannot be used, by id.
    public var problems: [String: Problem]
    /// Why the built-in file cannot be used, when it cannot.
    public var builtInProblem: Problem?
    /// Why the user's folder cannot be listed, when it cannot.
    public var userFolderProblem: Problem?

    public static let fileName = "agents.json"
    /// A catalog file to use instead of the one next to the executable (tests, development).
    public static let fileEnvironment = "AGENT_VM_AGENTS_FILE"
    /// The login shell's id in the launch picker and in remembered choices; no agent may use it.
    public static let shellID = "shell"

    public init(entries: [AgentEntry], problems: [String: Problem] = [:], builtInProblem: Problem? = nil,
                userFolderProblem: Problem? = nil) {
        self.entries = entries
        self.problems = problems
        self.builtInProblem = builtInProblem
        self.userFolderProblem = userFolderProblem
    }

    /// The built-in file: $AGENT_VM_AGENTS_FILE, else agents.json next to this executable.
    public static func builtInURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let override = environment[fileEnvironment], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent(fileName)
    }

    /// Where the user's entries live in the store at `root`.
    public static func userDirectory(store root: URL) -> URL {
        return root.appendingPathComponent("Agents", isDirectory: true)
    }

    /// The built-in entries and the store's user entries; problems are recorded, never thrown.
    public static func load(store root: URL, builtIn: URL? = builtInURL()) -> AgentCatalog {
        var entries: [AgentEntry] = []
        var builtInProblem: Problem?
        if let builtIn {
            do {
                entries = try readBuiltIn(builtIn)
            } catch let error as EntryError {
                builtInProblem = Problem(path: builtIn.path, reason: error.reason)
            } catch {
                builtInProblem = Problem(path: builtIn.path, reason: error.localizedDescription)
            }
        } else {
            builtInProblem = Problem(path: fileName, reason: "cannot find the agent-vm executable, so not the file next to it")
        }

        var problems: [String: Problem] = [:]
        var userFolderProblem: Problem?
        let directory = userDirectory(store: root)
        var files: [String] = []
        do {
            files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch CocoaError.fileReadNoSuchFile {
        } catch {
            userFolderProblem = Problem(path: directory.path, reason: "cannot list the folder (\(error.localizedDescription))")
        }
        var added: [AgentEntry] = []
        for file in files.sorted() where file.hasSuffix(".json") && !file.hasPrefix(".") {
            let id = String(file.dropLast(".json".count))
            let path = directory.appendingPathComponent(file).path
            do {
                guard isValidID(id) else {
                    throw EntryError("an agent's file is named <id>.json, the id lower-case letters, digits, \".\", \"_\" and \"-\"")
                }
                guard id != shellID else {
                    throw EntryError("\"\(shellID)\" is the login shell's id")
                }
                let data: Data
                do {
                    data = try Data(contentsOf: URL(fileURLWithPath: path))
                } catch {
                    throw EntryError("cannot read it (\(error.localizedDescription))")
                }
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw EntryError("not a JSON object")
                }
                if let named = object["id"] {
                    guard let named = named as? String, named == id else {
                        throw EntryError("\"id\" must be the file's name, \(id)")
                    }
                }
                var entry = try parse(object, id: id, path: path)
                entry.source = .user
                if let index = entries.firstIndex(where: { $0.id == id }) {
                    entry.replacesBuiltIn = true
                    entries[index] = entry
                } else {
                    added.append(entry)
                }
            } catch let error as EntryError {
                let key = id.lowercased()
                // A broken replacement does not give way to the built-in entry.
                entries.removeAll { $0.id == key }
                problems[key] = Problem(path: path, reason: error.reason)
            } catch {
                let key = id.lowercased()
                entries.removeAll { $0.id == key }
                problems[key] = Problem(path: path, reason: error.localizedDescription)
            }
        }
        return AgentCatalog(entries: entries + added, problems: problems, builtInProblem: builtInProblem,
                            userFolderProblem: userFolderProblem)
    }

    public func entry(id: String) -> AgentEntry? {
        return entries.first { $0.id == id }
    }

    /// The `--secret` specs for `entry`: the first of its secrets (in the catalog's order) that
    /// is in `set` (Keychain names), as `ENV` or `ENV=NAME`.
    public static func secretArguments(for entry: AgentEntry, set: [String]) -> [String] {
        guard let secret = entry.secrets.first(where: { set.contains($0.name) }) else {
            return []
        }
        return [secret.secret.map { "\(secret.env)=\($0)" } ?? secret.env]
    }

    /// The entry's variables as `--env NAME=VALUE` specs, by name.
    public static func envArguments(for entry: AgentEntry) -> [String] {
        return entry.env.keys.sorted().map { "\($0)=\(entry.env[$0]!)" }
    }

    /// The entry's allow rules that `rules` lack (exact text).
    public static func missingRules(for entry: AgentEntry, in rules: [String]) -> [String] {
        var missing: [String] = []
        for rule in entry.allow where !rules.contains(rule) && !missing.contains(rule) {
            missing.append(rule)
        }
        return missing
    }

    // MARK: - Reading

    struct EntryError: Error {
        var reason: String

        init(_ reason: String) {
            self.reason = reason
        }
    }

    /// The pack name rule: lower-case letters, digits, ".", "_" and "-", 1-64, not starting
    /// with ".".
    static func isValidID(_ id: String) -> Bool {
        return NetworkPacks.isValidName(id)
    }

    /// `{"version": 1, "agents": [{"id": ..., ...}, ...]}`.
    static func readBuiltIn(_ url: URL) throws -> [AgentEntry] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw EntryError("cannot read it (\(error.localizedDescription)); Scripts/build.sh puts \(fileName) next to agent-vm")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EntryError("not a JSON object")
        }
        // A JSON true would read as 1.
        guard let version = object["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.intValue == 1 else {
            throw EntryError("\"version\" must be 1")
        }
        guard let list = object["agents"] as? [Any] else {
            throw EntryError("\"agents\" must be a list of agents")
        }
        var entries: [AgentEntry] = []
        for (index, value) in list.enumerated() {
            guard let item = value as? [String: Any] else {
                throw EntryError("agent \(index + 1): not an object")
            }
            guard let id = item["id"] as? String, isValidID(id) else {
                throw EntryError("agent \(index + 1): \"id\" must be lower-case letters, digits, \".\", \"_\" and \"-\"")
            }
            guard id != shellID else {
                throw EntryError("\(id): \"\(shellID)\" is the login shell's id")
            }
            guard !entries.contains(where: { $0.id == id }) else {
                throw EntryError("\(id): listed twice")
            }
            do {
                entries.append(try parse(item, id: id, path: url.path))
            } catch let error as EntryError {
                throw EntryError("\(id): \(error.reason)")
            }
        }
        return entries
    }

    /// One agent's object; unknown keys are ignored (a newer file for an older agent-vm).
    static func parse(_ object: [String: Any], id: String, path: String) throws -> AgentEntry {
        guard let name = object["name"] as? String, !name.isEmpty, name.count <= 64,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw EntryError("\"name\" must be text of 1 to 64 characters")
        }
        guard let command = object["command"] as? [String], !command.isEmpty,
              command.allSatisfy({ !$0.isEmpty && !$0.contains("\u{0}") }) else {
            throw EntryError("\"command\" must be a list of words")
        }
        guard command[0].hasPrefix("/") || !command[0].contains("/") else {
            throw EntryError("\"command\" must start with a command name or an absolute path")
        }
        var allow: [String] = []
        if let value = object["allow"] {
            guard let rules = value as? [String] else {
                throw EntryError("\"allow\" must be a list of hosts or packs")
            }
            for rule in rules {
                guard isAllowRule(rule) else {
                    throw EntryError("\"allow\": \(rule) is not a host name, *.domain, host:port or pack:<name>")
                }
            }
            allow = rules
        }
        var secrets: [AgentEntry.Secret] = []
        if let value = object["secrets"] {
            guard let list = value as? [Any] else {
                throw EntryError("\"secrets\" must be a list")
            }
            for item in list {
                guard let secret = item as? [String: Any] else {
                    throw EntryError("\"secrets\": each is an object with \"env\" and \"label\"")
                }
                guard let env = secret["env"] as? String, ExecEnvironment.isValidName(env) else {
                    throw EntryError("\"secrets\": \"env\" must be a variable name (letters, digits and _, not starting with a digit)")
                }
                var keychainName: String?
                if let value = secret["secret"] {
                    guard let text = value as? String, SecretStore.isValidName(text) else {
                        throw EntryError("\"secrets\": \(env): \"secret\" must be a secret name (letters, digits and _, not starting with a digit)")
                    }
                    keychainName = text
                }
                guard let label = secret["label"] as? String, !label.isEmpty else {
                    throw EntryError("\"secrets\": \(env): \"label\" must be text")
                }
                secrets.append(AgentEntry.Secret(env: env, secret: keychainName, label: label))
            }
        }
        var secretsNeeded = AgentEntry.SecretsNeeded.optional
        if let value = object["secretsNeeded"] {
            guard let text = value as? String, let parsed = AgentEntry.SecretsNeeded(rawValue: text) else {
                throw EntryError("\"secretsNeeded\" must be \"one\" or \"optional\"")
            }
            secretsNeeded = parsed
        }
        if secretsNeeded == .one && secrets.isEmpty {
            throw EntryError("\"secretsNeeded\" is \"one\" but there are no \"secrets\"")
        }
        var env: [String: String] = [:]
        if let value = object["env"] {
            guard let variables = value as? [String: Any] else {
                throw EntryError("\"env\" must be an object of variables")
            }
            for (key, value) in variables {
                guard ExecEnvironment.isValidName(key) else {
                    throw EntryError("\"env\": \(key) is not a variable name (letters, digits and _, not starting with a digit)")
                }
                guard let text = value as? String, !text.contains("\u{0}") else {
                    throw EntryError("\"env\": \(key) must be text")
                }
                env[key] = text
            }
        }
        var texts: [String: String] = [:]
        for key in ["login", "install", "note"] {
            if let value = object[key] {
                guard let text = value as? String else {
                    throw EntryError("\"\(key)\" must be text")
                }
                texts[key] = text
            }
        }
        return AgentEntry(id: id, name: name, command: command, allow: allow, secrets: secrets, secretsNeeded: secretsNeeded,
                          env: env, login: texts["login"], install: texts["install"], note: texts["note"], source: .builtIn,
                          path: path, replacesBuiltIn: false)
    }

    /// A host rule as `box create --allow` takes it, or a pack; never `public` (an agent names
    /// its hosts).
    static func isAllowRule(_ rule: String) -> Bool {
        let lower = rule.lowercased()
        if lower.hasPrefix("pack:") {
            return NetworkPacks.isValidName(String(lower.dropFirst("pack:".count)))
        }
        guard let parsed = AllowRule.parse(rule) else {
            return false
        }
        return !parsed.anyPublicHost
    }
}
