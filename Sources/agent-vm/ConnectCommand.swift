// Sources/agent-vm/ConnectCommand.swift
//
// `agent-vm connect`, also installed as `avm` (a symlink; Main dispatches on the name it was
// started as): pick a box, start it when stopped, share this folder, and run an agent from the
// catalog, a login shell or a command in it on this terminal. `to` is the default subcommand,
// since a command with subcommands of its own takes no positional argument otherwise: `avm dev1`
// is `avm to dev1`. ConnectRunner does the work.

import AgentVMKit
import ArgumentParser
import Darwin
import Foundation

struct ConnectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "connect",
        abstract: "Pick a box and run an agent, a shell or a command in it on this terminal, with this folder shared (also installed as avm).",
        discussion: ConnectHelp.discussion(name: "agent-vm connect"),
        subcommands: [Connect.To.self, Connect.List.self, Connect.Agents.self],
        defaultSubcommand: Connect.To.self)
}

/// The root when started as `avm`. Asynchronous as AgentVMCommand is, so Main parses either root
/// the same way.
struct AVMCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "avm",
        abstract: "Run an agent, a shell or a command in an agent-vm box on this terminal, with this folder shared.",
        discussion: ConnectHelp.discussion(name: "avm"),
        version: AgentVM.version,
        subcommands: [Connect.To.self, Connect.List.self, Connect.Agents.self],
        defaultSubcommand: Connect.To.self)
}

enum ConnectHelp {
    static func discussion(name: String) -> String {
        let forms = [
            ("", "choose a box, then what to run"),
            (" <box>", "that box"),
            (" <box> --agent claude", "Claude Code in that box"),
            (" <box> --shell", "a login shell"),
            (" <box> -- make test", "a command"),
            (" --box <box>", "a box named list, agents, to, help"),
            (" list [--json]", "the boxes, the remembered choice"),
            (" agents [--json]", "the agents, and their secrets"),
            (" ... --dry-run", "print the steps instead of taking them"),
        ]
        let width = forms.map { name.count + $0.0.count }.max()! + 2
        let lines = forms.map { form, what in
            "  " + (name + form).padding(toLength: width, withPad: " ", startingAt: 0) + what
        }.joined(separator: "\n")
        return """
            \(name) [<box>] chooses a box from a list (or takes the one named), starts it when \
            it is stopped, shares the current folder into it at the same path (--project \
            another one, --no-project none), and runs what you choose there on this terminal: \
            an agent from the catalog (Claude Code, Codex, opencode; --agent <id>), a login \
            shell (--shell), or a command (after --). Exit it to come back. A box that was \
            started keeps running afterwards; stop it with agent-vm box stop <box>.

            When none of an agent's secrets (an API key or token) is set, \(name) offers to \
            set one in the Keychain; when the box does not allow the agent's hosts, it asks \
            to allow them.

            A folder shared read-write is snapshotted first. Afterwards \(name) reports what \
            changed, flagging files that run code later on this Mac, and asks: keep the \
            changes, show every change, or undo them all. --read-only shares the folder read \
            only (nothing can change, so no snapshot); --no-snapshot shares it read-write \
            without one (nothing to undo then).

            Forms:
            \(lines)

            In the lists: arrows (or Control-P, Control-N) move, typing filters, Enter \
            chooses, Escape clears the filter and then quits. The choices are remembered per \
            folder and preselected next time. Exit status: the program's; 1 when connecting \
            failed; 64 for a usage error or no terminal; 75 when no VM slot is free; 130 when \
            a choice was canceled.
            """
    }
}

/// What to run and what to share.
struct ConnectOptions: ParsableArguments {
    @Option(name: .long, help: "Run this agent from the catalog (`avm agents` lists them).")
    var agent: String?

    @Flag(name: .long, help: "Run a login shell.")
    var shell = false

    @Option(name: .long, help: "Share this folder instead of the current one.")
    var project: String?

    @Flag(name: .customLong("no-project"), help: "Share no folder; the program starts in the box user's home folder.")
    var noProject = false

    @Flag(name: .customLong("read-only"), help: "Share the folder read only (no snapshot is taken then).")
    var readOnly = false

    @Flag(name: .customLong("no-snapshot"), help: "Do not snapshot a folder shared read-write, so there is nothing to undo afterwards.")
    var noSnapshot = false

    @Option(name: .customLong("secret"), parsing: .singleValue, help: SecretOptions.help)
    var secrets: [String] = []

    @Option(name: .long, parsing: .singleValue, help: "Environment variable for the program: NAME=VALUE, or NAME to pass on this one's value (repeatable).")
    var env: [String] = []

    @Flag(name: .customLong("dry-run"), help: "Print the steps instead of taking them; changes nothing.")
    var dryRun = false

    @Argument(parsing: .postTerminator, help: "A command to run instead of an agent or a login shell, after --.")
    var command: [String] = []

    /// Usage errors (64): options that do not go together, and the --secret and --env forms.
    func check() throws {
        if [agent != nil, shell, !command.isEmpty].filter({ $0 }).count > 1 {
            throw ValidationError("--agent, --shell and a command after -- do not go together: choose one")
        }
        if project != nil && noProject {
            throw ValidationError("--project and --no-project do not go together")
        }
        if readOnly && noProject {
            throw ValidationError("--read-only and --no-project do not go together: --read-only shares a folder read only")
        }
        try SecretOptions.validate(secrets)
        do {
            _ = try ExecEnvironment.overrides(base: [:], files: [], entries: env, host: ProcessInfo.processInfo.environment)
        } catch let error as AgentVMError {
            throw ValidationError(error.description)
        }
    }

    /// What the command line says to run; nil: choose in the launch picker. An agent named
    /// with --agent is looked up by the runner.
    var namedLaunch: ConnectLaunch? {
        if shell {
            return .shell
        }
        return command.isEmpty ? nil : .command(command)
    }
}

enum Connect {
    struct To: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "to",
            abstract: "Connect to a box (the default: `avm dev1` is `avm to dev1`).")

        @Argument(help: "The box (default: choose from a list).")
        var name: String?

        @Option(name: .long, help: "The box, when its name is also one of avm's words (list, agents, to, help).")
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

    struct Agents: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List the agents connect can run, and whether their secrets are set.",
            discussion: """
                The built-in agents come from agents.json next to agent-vm; your own are \
                Agents/<id>.json in the agent-vm store, the same object without "id". One named \
                like a built-in agent replaces it. Exit status 1 when the built-in file or your \
                folder cannot be used.
                """)

        @Flag(name: .long, help: "Print machine-readable JSON instead of text.")
        var json = false

        func run() throws {
            try ConnectRunner(options: ConnectOptions(), root: SessionStore.defaultRoot(), invokedAs: Main.invokedName).agents(json: json)
        }
    }
}
