// Sources/agent-vm/RecipeCommand.swift
//
// `agent-vm recipe`: what helps to write an image recipe. `check` says in a second what a build
// would refuse, and warns about what is known to fail later; it needs no virtual machine and no
// store, so it also runs inside a sandbox.

import AgentVMKit
import ArgumentParser
import Foundation

struct RecipeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recipe",
        abstract: "Check image recipes before building with them.",
        discussion: """
            A recipe says what to install in an image besides macOS (`agent-vm image create \
            --recipe`). `recipe check` reads recipe files as a build would and reports what it \
            would refuse, without starting a virtual machine.
            """,
        subcommands: [Check.self]
    )

    struct Check: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Say what a build would refuse in these recipes, and warn about what is known to fail later.",
            discussion: """
                Each file is read exactly as `image create --recipe` reads it, and several files \
                are checked as one build would take them, so a recipe that passes here is one a \
                build accepts. The first mistake of each file is reported. With --input or --set, \
                the values are checked as a build checks them; without either, a missing input or \
                parameter is not a mistake, so a recipe can be checked before its files exist.

                Warnings are about recipes that load but are known to fail or mislead when the \
                image is built or updated: sudo in a step, no checks, a variable that nothing \
                declares, an input used where it is no longer there. They are read from the \
                commands' text, so they are guesses, and they never stop a build.

                The exit status is 0 when every recipe loads, 1 when one does not; with \
                --strict, warnings also give 1. Nothing is built: only a build proves that the \
                steps work.
                """)

        @Argument(help: "Recipe files, in the order a build would run them.")
        var files: [String]

        @Option(name: .customLong("input"), help: "A recipe input, NAME=PATH (repeatable), checked as a build would check it.")
        var inputs: [String] = []

        @Option(name: .customLong("set"), help: "A recipe parameter, NAME=VALUE (repeatable), checked as a build would check it.")
        var settings: [String] = []

        @Flag(name: .long, help: "Exit with 1 when there are warnings too.")
        var strict = false

        @Flag(name: .long, help: "Print machine-readable JSON instead of text.")
        var json = false

        func validate() throws {
            guard !files.isEmpty else {
                throw ValidationError("give at least one recipe file")
            }
            // As `image create` refuses them: a value without a name or without "=" is not
            // checked as an empty value, which a build would never get.
            for pair in inputs + settings where !pair.contains("=") || pair.hasPrefix("=") {
                throw ValidationError("\(pair): give name=value")
            }
        }

        func run() throws {
            let result = RecipeCheck.check(paths: files, inputs: try ImageCommand.Create.pairs(inputs, option: "--input"),
                                           parameters: try ImageCommand.Create.pairs(settings, option: "--set"))
            if json {
                try Output.json(result)
            } else {
                for report in result.recipes {
                    for line in Self.lines(for: report) {
                        print(Printable.line(line))
                    }
                }
                if let error = result.error {
                    print(Printable.line("error: \(error)"))
                }
            }
            if result.hasErrors || (strict && result.hasWarnings) {
                throw ExitCode(1)
            }
        }

        /// A line for the recipe, then one for each warning and note.
        static func lines(for report: RecipeCheck.Report) -> [String] {
            if let error = report.error {
                return ["\(report.path): error: \(error)"]
            }
            func counted(_ count: Int, _ one: String, _ many: String) -> String {
                return count == 0 ? "no \(many)" : count == 1 ? "1 \(one)" : "\(count) \(many)"
            }
            let contents = [counted(report.steps ?? 0, "step", "steps"), counted(report.updateSteps ?? 0, "update step", "update steps"),
                            counted(report.checks ?? 0, "check", "checks")].joined(separator: ", ")
            let verdict = report.warnings.isEmpty ? "ok" : "ok, \(counted(report.warnings.count, "warning", "warnings"))"
            var lines = ["\(report.path): \(verdict) (\(report.name ?? "recipe"): \(contents))"]
            lines += report.warnings.map { "  warning (\($0.place)): \($0.message)" }
            lines += report.notes.map { "  note (\($0.place)): \($0.message)" }
            return lines
        }
    }
}
