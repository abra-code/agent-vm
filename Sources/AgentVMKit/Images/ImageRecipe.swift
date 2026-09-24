// Sources/AgentVMKit/Images/ImageRecipe.swift
//
// What goes into an image besides macOS: a JSON recipe, so installing Homebrew, Node or an
// agent's command-line tool needs no change to agent-vm. Steps run in order during the image
// build, through the guest daemon, with the build's internet access (NAT). The format is
// described in Docs/image-recipes.md:
//
//   {
//     "version": 1,
//     "description": "Node and the agent CLIs",
//     "commandLineTools": true,
//     "steps": [
//       { "name": "Homebrew folder", "user": "root", "run": "mkdir -p /opt/homebrew && chown $AGENT_VM_BOX_USER /opt/homebrew" },
//       { "name": "gitconfig", "copy": "files/gitconfig", "to": "~/.gitconfig", "mode": "0644" }
//     ],
//     "checks": ["git --version"]
//   }
//
// Unknown keys are refused, so a misspelled key is an error rather than a silently skipped step.
// A recipe can also declare inputs (files given at build time with --input NAME=PATH and
// streamed into the guest, such as an Xcode .xip too big for a copy step and not
// downloadable without an Apple ID) and parameters (values given with --set NAME=VALUE, such
// as which simulator runtimes to install); steps see both as environment variables.

import CryptoKit
import Foundation

public struct ImageRecipe: Equatable, Sendable {
    public static let currentVersion = 1

    public struct Step: Equatable, Sendable {
        public enum Action: Equatable, Sendable {
            /// A shell command, run with /bin/bash -c.
            case run(String)
            /// A file from the recipe's folder, copied into the guest.
            case copy(source: URL, destination: String, mode: String)
        }

        public var name: String
        public var action: Action
        /// "root", or nil for the box user.
        public var user: String?
        public var environment: [String: String]
        /// Seconds the step may go without any output before the build gives up.
        public var timeoutSeconds: Int
        /// Copy steps: the SHA-256 of the source when the recipe was read, so a file edited
        /// during the build is refused rather than recorded under the wrong digest.
        public var sourceDigest: String? = nil
    }

    /// A file the recipe needs from whoever builds the image (`--input NAME=PATH`).
    public struct Input: Equatable, Sendable {
        public var name: String
        public var description: String?
    }

    /// A value the builder may set (`--set NAME=VALUE`); without a default it must be set.
    public struct Parameter: Equatable, Sendable {
        public var name: String
        public var description: String?
        public var defaultValue: String?
    }

    public var description: String?
    /// nil: the default (install them).
    public var commandLineTools: Bool?
    public var steps: [Step]
    /// Commands run as the box user after the steps; each must exit 0.
    public var checks: [String]
    /// SHA-256 of the recipe file and every file it copies, in order.
    public var digest: String
    /// The recipe file's text, kept with the image.
    public var text: String
    /// The recipe file, for messages.
    public var path: String = ""
    /// Declared inputs and parameters, sorted by name.
    public var inputs: [Input] = []
    public var parameters: [Parameter] = []
    /// Set by `binding(inputs:parameters:)`: each input's file on this Mac, and every
    /// parameter's value (given or default).
    public var inputFiles: [String: URL] = [:]
    public var parameterValues: [String: String] = [:]

    public static let defaultTimeoutSeconds = 1800
    public static let maxCopyBytes = 256 << 20

    /// Reads and checks a recipe; `copy` sources are resolved against the recipe's folder and
    /// must be regular files inside it.
    public static func load(from url: URL) throws -> ImageRecipe {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AgentVMError.invalidRecipe(path: url.path, reason: "cannot read it: \(error.localizedDescription)")
        }
        return try parse(data, folder: url.deletingLastPathComponent(), path: url.path)
    }

    static func parse(_ data: Data, folder: URL, path: String) throws -> ImageRecipe {
        func fail(_ reason: String) -> AgentVMError {
            return AgentVMError.invalidRecipe(path: path, reason: reason)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw fail("it is not UTF-8 text")
        }
        let root: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw fail("the top level must be a JSON object")
            }
            root = object
        } catch let error as AgentVMError {
            throw error
        } catch {
            throw fail("it is not valid JSON: \(error.localizedDescription)")
        }
        try requireKnownKeys(root, ["version", "description", "commandLineTools", "steps", "checks", "inputs", "parameters"], at: "the recipe", fail)
        guard let version = integer(root["version"]) else {
            throw fail("\"version\" is missing (use \(currentVersion))")
        }
        guard version == currentVersion else {
            throw fail("version \(version) is not supported; this agent-vm reads version \(currentVersion)")
        }
        let description = try optionalString(root, "description", at: "the recipe", fail)
        var commandLineTools: Bool?
        if let value = root["commandLineTools"] {
            guard let flag = value as? Bool, CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() else {
                throw fail("\"commandLineTools\" must be true or false")
            }
            commandLineTools = flag
        }

        var steps: [Step] = []
        let rawSteps = root["steps"] ?? []
        guard let stepList = rawSteps as? [Any] else {
            throw fail("\"steps\" must be a list")
        }
        var hasher = SHA256()
        hasher.update(data: data)
        let canonicalFolder = (try? FileSystem.canonicalPath(folder.path)) ?? folder.path
        for (index, rawStep) in stepList.enumerated() {
            let place = "step \(index + 1)"
            guard let step = rawStep as? [String: Any] else {
                throw fail("\(place) must be a JSON object")
            }
            try requireKnownKeys(step, ["name", "run", "copy", "to", "mode", "user", "env", "timeoutSeconds"], at: place, fail)
            let name = try optionalString(step, "name", at: place, fail) ?? place
            let user = try optionalString(step, "user", at: place, fail)
            guard user == nil || user == "root" else {
                throw fail("\(place): \"user\" can only be \"root\" (leave it out for the box user)")
            }
            var environment: [String: String] = [:]
            if let rawEnvironment = step["env"] {
                guard let map = rawEnvironment as? [String: Any], map.values.allSatisfy({ $0 is String }) else {
                    throw fail("\(place): \"env\" must map names to strings")
                }
                for (key, value) in map {
                    guard key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
                        throw fail("\(place): \(key) is not an environment variable name")
                    }
                    environment[key] = value as? String
                }
            }
            var timeout = defaultTimeoutSeconds
            if let rawTimeout = step["timeoutSeconds"] {
                guard let seconds = integer(rawTimeout), (1...86400).contains(seconds) else {
                    throw fail("\(place): \"timeoutSeconds\" must be a whole number of seconds from 1 to 86400")
                }
                timeout = seconds
            }
            let run = try optionalString(step, "run", at: place, fail)
            let copy = try optionalString(step, "copy", at: place, fail)
            let action: Step.Action
            var sourceDigest: String?
            switch (run, copy) {
            case let (command?, nil):
                guard step["to"] == nil, step["mode"] == nil else {
                    throw fail("\(place): \"to\" and \"mode\" belong to copy steps")
                }
                guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw fail("\(place): \"run\" is empty")
                }
                action = .run(command)
            case let (nil, source?):
                guard let destination = try optionalString(step, "to", at: place, fail), destination.hasPrefix("/") || destination.hasPrefix("~/"),
                      destination != "/", destination != "~/", !destination.hasSuffix("/") else {
                    throw fail("\(place): a copy step needs \"to\", a file path that is absolute or starts with ~/")
                }
                let mode = try optionalString(step, "mode", at: place, fail) ?? "0644"
                guard mode.range(of: "^0?[0-7]{3}$", options: .regularExpression) != nil else {
                    throw fail("\(place): \"mode\" must be octal, like \"0644\" or \"0755\"")
                }
                let file = try copySource(source, folder: canonicalFolder, place: place, fail)
                let contents: Data
                do {
                    contents = try Data(contentsOf: file)
                } catch {
                    throw fail("\(place): cannot read \(source): \(error.localizedDescription)")
                }
                hasher.update(data: contents)
                sourceDigest = sha256(contents)
                action = .copy(source: file, destination: destination, mode: mode)
            case (nil, nil):
                throw fail("\(place) needs \"run\" or \"copy\"")
            default:
                throw fail("\(place) has both \"run\" and \"copy\"; use two steps")
            }
            steps.append(Step(name: name, action: action, user: user, environment: environment, timeoutSeconds: timeout, sourceDigest: sourceDigest))
        }

        let rawChecks = root["checks"] ?? []
        guard let checks = rawChecks as? [String], checks.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw fail("\"checks\" must be a list of non-empty commands")
        }
        var inputs: [Input] = []
        for (name, declaration) in try declarations(root, "inputs", fail) {
            try requireKnownKeys(declaration, ["description"], at: "input \(name)", fail)
            inputs.append(Input(name: name, description: try optionalString(declaration, "description", at: "input \(name)", fail)))
        }
        var parameters: [Parameter] = []
        for (name, declaration) in try declarations(root, "parameters", fail) {
            try requireKnownKeys(declaration, ["description", "default"], at: "parameter \(name)", fail)
            parameters.append(Parameter(name: name, description: try optionalString(declaration, "description", at: "parameter \(name)", fail),
                                        defaultValue: try optionalString(declaration, "default", at: "parameter \(name)", fail)))
        }
        if let shared = Set(inputs.map(\.name)).intersection(parameters.map(\.name)).sorted().first {
            throw fail("\(shared) is both an input and a parameter")
        }
        let digest = hex(hasher.finalize())
        return ImageRecipe(description: description, commandLineTools: commandLineTools, steps: steps, checks: checks, digest: digest, text: text,
                           path: path, inputs: inputs, parameters: parameters)
    }

    /// The `inputs` or `parameters` object: names (lower-case letters, digits and "_") to
    /// objects, sorted by name.
    private static func declarations(_ root: [String: Any], _ key: String, _ fail: (String) -> AgentVMError) throws -> [(String, [String: Any])] {
        guard let raw = root[key] else {
            return []
        }
        guard let map = raw as? [String: Any] else {
            throw fail("\"\(key)\" must be a JSON object of names")
        }
        return try map.keys.sorted().map { name in
            guard isValidName(name) else {
                throw fail("\"\(key)\": \(name) is not a usable name (lower-case letters, digits and \"_\", starting with a letter, at most 32)")
            }
            guard let declaration = map[name] as? [String: Any] else {
                throw fail("\"\(key)\": \(name) must be a JSON object")
            }
            return (name, declaration)
        }
    }

    static func isValidName(_ name: String) -> Bool {
        return name.range(of: #"^[a-z][a-z0-9_]{0,31}$"#, options: .regularExpression) != nil
    }

    // MARK: - Inputs and parameters

    /// The recipe with its inputs and parameters given values: `inputs` maps names to paths on
    /// this Mac (a leading ~/ is your home), `parameters` names to values. Every input must be
    /// given and be a readable regular file; a parameter without a default must be set; names
    /// the recipe does not declare are refused.
    public func binding(inputs given: [String: String], parameters set: [String: String]) throws -> ImageRecipe {
        func fail(_ reason: String) -> AgentVMError {
            return AgentVMError.invalidRecipe(path: path, reason: reason)
        }
        var bound = self
        for name in given.keys.sorted() where !inputs.contains(where: { $0.name == name }) {
            throw fail("it has no input \(name)\(inputs.isEmpty ? "" : " (its inputs: \(inputs.map(\.name).joined(separator: ", ")))")")
        }
        for name in set.keys.sorted() where !parameters.contains(where: { $0.name == name }) {
            throw fail("it has no parameter \(name)\(parameters.isEmpty ? "" : " (its parameters: \(parameters.map(\.name).joined(separator: ", ")))")")
        }
        for input in inputs {
            guard let path = given[input.name] else {
                throw fail("it needs --input \(input.name)=PATH\(input.description.map { ": \($0)" } ?? "")")
            }
            let expanded = path.hasPrefix("~/") ? NSString(string: path).expandingTildeInPath : path
            guard let resolved = try? FileSystem.canonicalPath(expanded) else {
                throw fail("input \(input.name): \(path) does not exist")
            }
            var info = stat()
            guard stat(resolved, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, access(resolved, R_OK) == 0 else {
                throw fail("input \(input.name): \(path) is not a readable file")
            }
            bound.inputFiles[input.name] = URL(fileURLWithPath: resolved)
        }
        for parameter in parameters {
            guard let value = set[parameter.name] ?? parameter.defaultValue else {
                throw fail("it needs --set \(parameter.name)=VALUE\(parameter.description.map { ": \($0)" } ?? "")")
            }
            guard !value.contains("\0") else {
                throw fail("parameter \(parameter.name): the value contains a NUL character")
            }
            bound.parameterValues[parameter.name] = value
        }
        return bound
    }

    /// Where an input is put in the guest while the recipe runs; the folder is deleted after.
    public static let guestInputsFolder = "/private/var/tmp/agent-vm-inputs"

    static func guestInputPath(_ name: String, file: URL) -> String {
        return "\(guestInputsFolder)/\(name)/\(file.lastPathComponent)"
    }

    static func inputVariable(_ name: String) -> String {
        return "AGENT_VM_INPUT_" + name.uppercased()
    }

    static func parameterVariable(_ name: String) -> String {
        return "AGENT_VM_PARAM_" + name.uppercased()
    }

    /// The variables every step and check sees: each parameter's value and each input's path
    /// in the guest.
    var variables: [String: String] {
        var result: [String: String] = [:]
        for (name, value) in parameterValues {
            result[Self.parameterVariable(name)] = value
        }
        for (name, file) in inputFiles {
            result[Self.inputVariable(name)] = Self.guestInputPath(name, file: file)
        }
        return result
    }

    /// A copy source: relative to the recipe's folder, a regular file, and still inside that
    /// folder once symlinks are resolved.
    private static func copySource(_ source: String, folder: String, place: String, _ fail: (String) -> AgentVMError) throws -> URL {
        guard !source.hasPrefix("/") else {
            throw fail("\(place): \"copy\" must be relative to the recipe's folder")
        }
        let joined = URL(fileURLWithPath: folder).appendingPathComponent(source).path
        guard let resolved = try? FileSystem.canonicalPath(joined) else {
            throw fail("\(place): \(source) does not exist next to the recipe")
        }
        guard resolved.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/") else {
            throw fail("\(place): \(source) is outside the recipe's folder")
        }
        var info = stat()
        guard stat(resolved, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw fail("\(place): \(source) is not a regular file")
        }
        guard info.st_size <= maxCopyBytes else {
            throw fail("\(place): \(source) is larger than \(maxCopyBytes >> 20) MB; download big files in a run step")
        }
        return URL(fileURLWithPath: resolved)
    }

    static func sha256(_ data: Data) -> String {
        return hex(SHA256.hash(data: data))
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// A copy step's file, read again when the step runs; refused when it no longer matches
    /// what the recipe's digest recorded.
    static func copyContents(_ step: Step, source: URL) throws -> Data {
        let contents: Data
        do {
            contents = try Data(contentsOf: source)
        } catch {
            throw AgentVMError.invalidRecipe(path: source.path, reason: "\(step.name): cannot read it: \(error.localizedDescription)")
        }
        guard sha256(contents) == step.sourceDigest else {
            throw AgentVMError.invalidRecipe(path: source.path, reason: "\(step.name): the file changed after the recipe was read; build the image again")
        }
        return contents
    }

    /// A JSON whole number; JSON true and false (which Foundation also bridges to numbers) are not.
    private static func integer(_ value: Any?) -> Int? {
        guard let value, CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID() else {
            return nil
        }
        return value as? Int
    }

    private static func requireKnownKeys(_ object: [String: Any], _ known: Set<String>, at place: String, _ fail: (String) -> AgentVMError) throws {
        let unknown = object.keys.filter { !known.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw fail("\(place) has unknown \(unknown.count == 1 ? "key" : "keys") \(unknown.map { "\"\($0)\"" }.joined(separator: ", ")) (known: \(known.sorted().joined(separator: ", ")))")
        }
    }

    private static func optionalString(_ object: [String: Any], _ key: String, at place: String, _ fail: (String) -> AgentVMError) throws -> String? {
        guard let value = object[key] else {
            return nil
        }
        guard let text = value as? String else {
            throw fail("\(place): \"\(key)\" must be a string")
        }
        return text
    }

    // MARK: - Guest requests

    /// Set in every step: the box user's account name, for root steps that hand things over.
    public static let boxUserVariable = "AGENT_VM_BOX_USER"

    /// The request that runs a `run` step; `variables` (parameters and inputs) and the box
    /// user's name override the step's own `env`.
    static func runRequest(_ step: Step, command: String, boxUser: String, variables: [String: String] = [:]) -> GuestRequest {
        var environment = step.environment.merging(variables) { _, ours in ours }
        environment[boxUserVariable] = boxUser
        return GuestRequest(op: .exec, argv: ["/bin/bash", "-c", command], env: environment, cwd: nil, user: step.user)
    }

    /// The request that writes stdin to `destination` for a `copy` step (the parent folder is
    /// created; `~/` is the step user's home).
    static func copyRequest(_ step: Step, destination: String, mode: String) -> GuestRequest {
        let script = #"target=$1; case "$target" in "~/"*) target="$HOME/${target#\~/}";; esac; /bin/mkdir -p "$(/usr/bin/dirname "$target")" && /bin/cat > "$target" && /bin/chmod "$2" "$target""#
        return GuestRequest(op: .exec, argv: ["/bin/bash", "-c", script, "copy", destination, mode], cwd: nil, user: step.user)
    }

    /// The request that runs one check as the box user.
    static func checkRequest(_ command: String, variables: [String: String] = [:]) -> GuestRequest {
        return GuestRequest(op: .exec, argv: ["/bin/bash", "-c", command], env: variables.isEmpty ? nil : variables)
    }

    /// The request that writes stdin to `path` as root (an input), readable by every account.
    static func inputRequest(path: String) -> GuestRequest {
        let script = #"/bin/mkdir -p "$(/usr/bin/dirname "$1")" && /bin/chmod 755 "$(/usr/bin/dirname "$1")" && /bin/cat > "$1" && /bin/chmod 644 "$1""#
        return GuestRequest(op: .exec, argv: ["/bin/bash", "-c", script, "input", path], cwd: "/", user: "root")
    }

    /// The request that deletes every input from the guest.
    static let removeInputsRequest = GuestRequest(op: .exec, argv: ["/bin/rm", "-rf", guestInputsFolder], cwd: "/", user: "root")
}
