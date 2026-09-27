// Sources/agent-vm/ConnectCommand.swift
//
// `agent-vm connect`, also installed as `avm` (a symlink; Main dispatches on the name it was
// started as): pick a box, start it when stopped, share this folder, and run a login shell or a
// command in it on this terminal. `to` is the default subcommand, since a command with
// subcommands of its own takes no positional argument otherwise: `avm dev1` is `avm to dev1`.
// ConnectRunner does the work.

import AgentVMKit
import ArgumentParser
import Darwin
import Foundation

struct ConnectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "connect",
        abstract: "Pick a box and run a shell or a command in it on this terminal, with this folder shared (also installed as avm).",
        discussion: ConnectHelp.discussion(name: "agent-vm connect"),
        subcommands: [Connect.To.self, Connect.List.self],
        defaultSubcommand: Connect.To.self)
}

/// The root when started as `avm`. Asynchronous as AgentVMCommand is, so Main parses either root
/// the same way.
struct AVMCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "avm",
        abstract: "Run a shell or a command in an agent-vm box on this terminal, with this folder shared.",
        discussion: ConnectHelp.discussion(name: "avm"),
        version: AgentVM.version,
        subcommands: [Connect.To.self, Connect.List.self],
        defaultSubcommand: Connect.To.self)
}

enum ConnectHelp {
    static func discussion(name: String) -> String {
        return """
            \(name) [<box>] chooses a box from a list (or takes the one named), starts it when \
            it is stopped, shares the current folder into it at the same path (--project \
            another one, --no-project none), and runs a login shell there on this terminal \
            (or a command, after --). Exit the shell to come back. A box that was started \
            keeps running afterwards; stop it with agent-vm box stop <box>.

            Forms:
              \(name)                    choose a box, then a login shell
              \(name) <box>              that box
              \(name) <box> -- make test a command instead of the shell
              \(name) --box <box>        a box named list, to or help
              \(name) list [--json]      the boxes it offers, and the remembered choice
              \(name) ... --dry-run      print the steps instead of taking them

            In the list: arrows (or Control-P, Control-N) move, typing filters, Enter chooses, \
            Escape clears the filter and then quits. The choice is remembered per folder \
            and preselected next time. Exit status: the program's; 1 when connecting failed; \
            64 for a usage error or no terminal; 75 when no VM slot is free; 130 when the \
            choice was canceled.
            """
    }
}

/// What to run and what to share.
struct ConnectOptions: ParsableArguments {
    @Flag(name: .long, help: "Run a login shell (the default).")
    var shell = false

    @Option(name: .long, help: "Share this folder instead of the current one.")
    var project: String?

    @Flag(name: .customLong("no-project"), help: "Share no folder; the program starts in the box user's home folder.")
    var noProject = false

    @Option(name: .customLong("secret"), parsing: .singleValue, help: SecretOptions.help)
    var secrets: [String] = []

    @Option(name: .long, parsing: .singleValue, help: "Environment variable for the program: NAME=VALUE, or NAME to pass on this one's value (repeatable).")
    var env: [String] = []

    @Flag(name: .customLong("dry-run"), help: "Print the steps instead of taking them; changes nothing.")
    var dryRun = false

    @Argument(parsing: .postTerminator, help: "A command to run instead of a login shell, after --.")
    var command: [String] = []

    /// Usage errors (64): options that do not go together, and the --secret and --env forms.
    func check() throws {
        if shell && !command.isEmpty {
            throw ValidationError("--shell and a command after -- do not go together")
        }
        if project != nil && noProject {
            throw ValidationError("--project and --no-project do not go together")
        }
        try SecretOptions.validate(secrets)
        do {
            _ = try ExecEnvironment.overrides(base: [:], files: [], entries: env, host: ProcessInfo.processInfo.environment)
        } catch let error as AgentVMError {
            throw ValidationError(error.description)
        }
    }

    var launch: ConnectLaunch {
        return command.isEmpty ? .shell : .command(command)
    }
}

enum Connect {
    struct To: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "to",
            abstract: "Connect to a box (the default: `avm dev1` is `avm to dev1`).")

        @Argument(help: "The box (default: choose from a list).")
        var name: String?

        @Option(name: .long, help: "The box, when its name is also one of avm's words (list, to, help).")
        var box: String?

        @OptionGroup var options: ConnectOptions

        func validate() throws {
            if name != nil && box != nil {
                throw ValidationError("name the box once: as <name> or with --box")
            }
            try options.check()
        }

        func run() throws {
            ConnectRunner(options: options, root: SessionStore.defaultRoot(), invokedAs: Main.invokedName).run(boxName: name ?? box)
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List the boxes connect offers, and the choice remembered for this folder.")

        @Flag(name: .long, help: "Print machine-readable JSON instead of text.")
        var json = false

        @Option(name: .long, help: "The folder whose remembered choice is shown (default: the current one).")
        var project: String?

        func run() throws {
            try ConnectRunner(options: ConnectOptions(), root: SessionStore.defaultRoot(), invokedAs: Main.invokedName).list(json: json, project: project)
        }
    }
}
