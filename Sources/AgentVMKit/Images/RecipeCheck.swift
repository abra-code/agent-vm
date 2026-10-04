// Sources/AgentVMKit/Images/RecipeCheck.swift
//
// `agent-vm recipe check`: what a build would say about recipe files, without a virtual machine
// and without a store, so a recipe can be checked in a second, as often as needed, and inside
// a sandbox.
//
// Errors are the loader's own (`ImageRecipe.load`, `ImageRecipe.binding`): what passes here is
// what a build accepts, and nothing else. The loader stops at a file's first mistake, so there
// is one error per recipe per run.
//
// Warnings are new, and only here: what loads but is known to fail or mislead when the image is
// built or updated. Each is a rule Docs/image-recipes.md states. They read the commands' text,
// so they are guesses: each says what it saw and where, and none ever fails a build.

import Foundation

public enum RecipeCheck {
    public struct Finding: Codable, Equatable, Sendable {
        /// A stable name for the rule: sudo, no-checks, undeclared-input, undeclared-parameter,
        /// unused-input, unused-parameter, input-in-update, input-in-check, secret-parameter;
        /// and the note no-update.
        public var code: String
        /// Where: "step 3", "update step 1", "check 2", "input xcode", "parameter token", or
        /// "the recipe".
        public var place: String
        public var message: String
    }

    /// An input or a parameter as the recipe declares it.
    public struct Declared: Codable, Equatable, Sendable {
        public var name: String
        public var description: String?
        /// Parameters only.
        public var `default`: String?
    }

    /// What is known about one file. Everything but `path` and `error` is absent when the file
    /// does not load. A file that loads and is refused for another reason (given twice, a value
    /// it lacks) has both its description and `error`: read `error` first.
    public struct Report: Codable, Equatable, Sendable {
        /// As given on the command line.
        public var path: String
        public var name: String?
        public var description: String?
        public var digest: String?
        public var steps: Int?
        public var updateSteps: Int?
        public var checks: Int?
        public var inputs: [Declared]?
        public var parameters: [Declared]?
        /// Why a build would refuse the file; absent when it would not.
        public var error: String?
        public var warnings: [Finding] = []
        /// Worth knowing, never a failure, also with --strict.
        public var notes: [Finding] = []
    }

    public struct Result: Codable, Equatable, Sendable {
        public var recipes: [Report]
        /// What a build would refuse about the recipes together (an input or a parameter that
        /// none of them declares).
        public var error: String?

        public var hasErrors: Bool {
            return error != nil || recipes.contains { $0.error != nil }
        }

        public var hasWarnings: Bool {
            return recipes.contains { !$0.warnings.isEmpty }
        }
    }

    /// Checks `paths` as one build would take them, in order. `inputs` and `parameters` are
    /// --input and --set: with either given, values are checked as a build checks them (every
    /// input a readable file, every required parameter set); with none, a recipe is checked
    /// before its inputs exist, and a missing value is not a mistake.
    public static func check(paths: [String], inputs: [String: String] = [:], parameters: [String: String] = [:]) -> Result {
        var reports: [Report] = []
        var loaded: [(index: Int, recipe: ImageRecipe)] = []
        for path in paths {
            var report = Report(path: path)
            do {
                let recipe = try ImageRecipe.load(from: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
                fill(&report, from: recipe)
                loaded.append((reports.count, recipe))
            } catch {
                report.error = reason(error)
            }
            reports.append(report)
        }
        var result = Result(recipes: reports)
        // The same recipe twice: said about the second, as a build says it.
        for (position, entry) in loaded.enumerated() where loaded[..<position].contains(where: { $0.recipe.digest == entry.recipe.digest }) {
            result.recipes[entry.index].error = "it is given twice"
        }
        // Values are checked across the recipes, so only when every file is one: a name that
        // an unreadable file declares would be reported as declared by none.
        if !result.hasErrors && !(inputs.isEmpty && parameters.isEmpty) {
            do {
                _ = try ImageRecipe.binding(loaded.map(\.recipe), inputs: inputs, parameters: parameters)
            } catch let AgentVMError.invalidRecipe(path, reason) {
                if let entry = loaded.first(where: { $0.recipe.path == path }) {
                    result.recipes[entry.index].error = reason
                } else {
                    result.error = reason
                }
            } catch {
                result.error = "\(error)"
            }
        }
        return result
    }

    /// The reason alone: the report names the file beside it.
    private static func reason(_ error: Error) -> String {
        if case let AgentVMError.invalidRecipe(_, reason) = error {
            return reason
        }
        return "\(error)"
    }

    private static func fill(_ report: inout Report, from recipe: ImageRecipe) {
        report.name = recipe.name
        report.description = recipe.description
        report.digest = recipe.digest
        report.steps = recipe.steps.count
        report.updateSteps = recipe.updateSteps.count
        report.checks = recipe.checks.count
        report.inputs = recipe.inputs.map { Declared(name: $0.name, description: $0.description, default: nil) }
        report.parameters = recipe.parameters.map { Declared(name: $0.name, description: $0.description, default: $0.defaultValue) }
        let (warnings, notes) = findings(in: recipe)
        report.warnings = warnings
        report.notes = notes
    }

    // MARK: - Warnings

    /// A command of the recipe and where it is.
    private struct Command {
        enum Kind { case step, update, check }
        var kind: Kind
        var place: String
        var text: String
        /// A step with "user": "root": sudo asks root for no password.
        var root = false
    }

    /// The warnings and notes for a recipe that loads, in the recipe's order: steps, update
    /// steps, checks, then what is about the recipe as a whole.
    static func findings(in recipe: ImageRecipe) -> (warnings: [Finding], notes: [Finding]) {
        var commands: [Command] = []
        for (index, step) in recipe.steps.enumerated() {
            if case let .run(text) = step.action {
                commands.append(Command(kind: .step, place: "step \(index + 1)", text: text, root: step.user == "root"))
            }
        }
        for (index, step) in recipe.updateSteps.enumerated() {
            if case let .run(text) = step.action {
                commands.append(Command(kind: .update, place: "update step \(index + 1)", text: text, root: step.user == "root"))
            }
        }
        for (index, text) in recipe.checks.enumerated() {
            commands.append(Command(kind: .check, place: "check \(index + 1)", text: text))
        }

        let inputs = Set(recipe.inputs.map(\.name))
        let parameters = Set(recipe.parameters.map(\.name))
        var usedInputs = Set<String>()
        var usedParameters = Set<String>()
        // A script the recipe copies may be what reads a variable: that is a use, though what
        // the script does with it is not looked at.
        for step in recipe.steps + recipe.updateSteps {
            guard case let .copy(source, _, _) = step.action,
                  let size = (try? FileManager.default.attributesOfItem(atPath: source.path))?[.size] as? Int, size <= copiedScriptLimit,
                  let data = try? Data(contentsOf: source), let text = String(data: data, encoding: .utf8) else {
                continue
            }
            let used = variables(in: text)
            usedInputs.formUnion(used.inputs)
            usedParameters.formUnion(used.parameters)
        }
        var warnings: [Finding] = []
        for command in commands {
            // Not in a root step: there `sudo -u "$AGENT_VM_BOX_USER" ...` is how one command
            // runs as the box user, and root is asked for no password.
            if !command.root && usesSudo(command.text) {
                let instead = command.kind == .check
                    ? "checks run as the box user; test what a root step left behind without it"
                    : "use \"user\": \"root\" for the step"
                warnings.append(Finding(code: "sudo", place: command.place,
                                        message: "it runs sudo, which asks for a password and fails without a terminal; \(instead)"))
            }
            let used = variables(in: command.text)
            for variable in used.misspelled.sorted() {
                let isInput = variable.hasPrefix("AGENT_VM_INPUT_")
                warnings.append(Finding(code: isInput ? "undeclared-input" : "undeclared-parameter", place: command.place,
                                        message: "it uses \(variable), which is never set and will be empty: the variable's name is all capitals (\(variable.uppercased()))"))
            }
            for name in used.inputs.sorted() {
                let variable = ImageRecipe.inputVariable(name)
                guard inputs.contains(name) else {
                    warnings.append(Finding(code: "undeclared-input", place: command.place,
                                            message: "it uses \(variable), and the recipe declares no input \(name); the variable will be empty"))
                    continue
                }
                usedInputs.insert(name)
                switch command.kind {
                case .step:
                    break
                case .update:
                    warnings.append(Finding(code: "input-in-update", place: command.place,
                                            message: "it uses \(variable), and inputs are deleted after the build: image update runs this step without the file"))
                case .check:
                    warnings.append(Finding(code: "input-in-check", place: command.place,
                                            message: "it uses \(variable), and inputs are deleted after the build: the check runs again at every image update, without the file"))
                }
            }
            for name in used.parameters.sorted() {
                guard parameters.contains(name) else {
                    warnings.append(Finding(code: "undeclared-parameter", place: command.place,
                                            message: "it uses \(ImageRecipe.parameterVariable(name)), and the recipe declares no parameter \(name); the variable will be empty"))
                    continue
                }
                usedParameters.insert(name)
            }
        }
        for name in inputs.subtracting(usedInputs).sorted() {
            warnings.append(Finding(code: "unused-input", place: "input \(name)",
                                    message: "no step uses \(ImageRecipe.inputVariable(name)), yet every build must give the file"))
        }
        for name in parameters.subtracting(usedParameters).sorted() {
            warnings.append(Finding(code: "unused-parameter", place: "parameter \(name)",
                                    message: "no step or check uses \(ImageRecipe.parameterVariable(name))"))
        }
        for name in parameters.sorted() where looksLikeASecret(name) {
            warnings.append(Finding(code: "secret-parameter", place: "parameter \(name)",
                                    message: "its name suggests a secret, and a parameter's value is recorded with the image and visible to every user of the Mac while it builds; never pass a secret as a parameter"))
        }
        if recipe.checks.isEmpty {
            warnings.append(Finding(code: "no-checks", place: "the recipe",
                                    message: "it has no checks, so nothing proves that it worked; add a command for each tool it installs (\"node --version\")"))
        }
        var notes: [Finding] = []
        if !recipe.steps.isEmpty && recipe.updateSteps.isEmpty {
            notes.append(Finding(code: "no-update", place: "the recipe",
                                 message: "it has no update steps, so image update will not bring what it installs up to date"))
        }
        return (warnings, notes)
    }

    /// A copied file larger than this is not read for the variables it uses: it is no script.
    static let copiedScriptLimit = 1 << 20

    /// `sudo` as a word of its own: at the start, or after a space or one of the characters a
    /// shell puts before a command; not "pseudo", not "sudoers". By its full path only when
    /// something follows it: "/usr/bin/sudo make install" runs it, "ls /usr/bin/sudo" does not.
    static func usesSudo(_ command: String) -> Bool {
        let before = #"(^|[\s;&|(){}`!"'])"#
        return command.range(of: before + #"sudo($|[\s;&|)])"#, options: .regularExpression) != nil
            || command.range(of: before + #"/usr/bin/sudo\s+[^\s;&|)]"#, options: .regularExpression) != nil
    }

    /// The inputs and parameters whose variables a command names, by declared name (lower
    /// case). A variable is taken up to its last letter, digit or "_", as a shell reads it.
    /// `misspelled`: variables written with a lower-case letter (AGENT_VM_PARAM_release), whole;
    /// a shell tells them from the ones agent-vm sets, which are all capitals, so they name
    /// nothing.
    static func variables(in command: String) -> (inputs: Set<String>, parameters: Set<String>, misspelled: Set<String>) {
        var inputs = Set<String>()
        var parameters = Set<String>()
        var misspelled = Set<String>()
        guard let pattern = try? NSRegularExpression(pattern: "AGENT_VM_(INPUT|PARAM)_([A-Za-z0-9_]+)") else {
            return (inputs, parameters, misspelled)
        }
        let text = command as NSString
        for match in pattern.matches(in: command, range: NSRange(location: 0, length: text.length)) {
            let written = text.substring(with: match.range(at: 2))
            guard written == written.uppercased() else {
                misspelled.insert(text.substring(with: match.range))
                continue
            }
            let name = written.lowercased()
            if text.substring(with: match.range(at: 1)) == "INPUT" {
                inputs.insert(name)
            } else {
                parameters.insert(name)
            }
        }
        return (inputs, parameters, misspelled)
    }

    /// A parameter name with a word that names a secret ("api_key", "token", "db_password").
    /// Words are what "_" separates, so "monkey" and "tokenizer" are not.
    static func looksLikeASecret(_ name: String) -> Bool {
        let secretWords: Set<String> = ["token", "tokens", "password", "passwd", "secret", "secrets", "key", "keys", "apikey", "credential", "credentials"]
        return name.split(separator: "_").contains { secretWords.contains(String($0)) }
    }
}
