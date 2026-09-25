// Sources/agent-vm/ExecCommand.swift
//
// `agent-vm exec --box <name> -- <program> [arguments...]`: runs a program in a running box
// with stdin, stdout and stderr streamed, signals forwarded, and its exit status as ours
// (128 + signal number when a signal ended it). Wraps any stdio program, including ACP agents
// and MCP servers launched by another application.

import AgentVMKit
import ArgumentParser
import Darwin
import Foundation

struct ExecCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "exec",
        abstract: "Run a program in a running box.",
        discussion: """
            stdin, stdout and stderr are streamed; SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGUSR1 \
            and SIGUSR2 are forwarded to the program's process group; the exit status is the \
            program's (128 + the signal number when a signal ended it; 127 when the program is \
            not found, 126 when it cannot be started, 125 when agent-vm itself fails, for \
            example because the box is not running). If agent-vm exec is \
            killed, the program gets SIGHUP, then SIGKILL 3 seconds later. The program runs \
            as the box user in their home folder unless --user or --cwd say otherwise. With \
            --project, the folder appears in the box at the same path and the program starts \
            there; the box keeps it until another project replaces it or the box stops. \
            --env NAME (no value) passes on the value agent-vm itself was given, and \
            --env-file reads NAME=VALUE lines, so API keys stay off the command line; \
            anything running in the box can read them. With --tty the program gets a \
            terminal in the box (its output all arrives on stdout), keys such as Control-C \
            go to it as typed, and SIGHUP or SIGTERM to agent-vm end the session. Each \
            run is recorded in the box's exec log (`box execlog`): the command, account, \
            folders, times and status, never the environment. A program that waits on a \
            permission prompt on the box's screen, where nobody sees it, is reported on stderr \
            and in the exec log at once; with --prompts stop (the default when stdin is not a \
            terminal) agent-vm stops that program, so the caller is not left hanging.
            """
    )

    @Option(name: .long, help: "The running box.")
    var box: String

    @Option(name: .long, help: "Account to run as in the guest (default: the box user).")
    var user: String?

    @Option(name: .long, help: "Working folder in the guest (default: the project, else the account's home).")
    var cwd: String?

    @Option(name: .long, help: "Share this project folder into the box at the same path (one project per box at a time).")
    var project: String?

    @Flag(name: .customLong("read-only"), help: "Share the project read only.")
    var readOnly = false

    @Flag(name: [.customShort("t"), .long], help: "Run the program on a terminal in the box, with this terminal in raw mode (for shells, editors, agents with a full-screen interface).")
    var tty = false

    @Option(name: .long, parsing: .singleValue, help: "Environment variable for the program: NAME=VALUE, or NAME to pass on the value agent-vm was given (repeatable).")
    var env: [String] = []

    @Option(name: .customLong("env-file"), parsing: .singleValue, help: "File of NAME=VALUE lines (or NAME to pass on) for the program's environment (repeatable; --env wins).")
    var envFile: [String] = []

    @Option(name: .long, help: "When a program waits on a permission prompt nobody sees: wait (for an answer in `box view --interactive`) or stop that program. Default: stop when stdin is not a terminal, else wait.")
    var prompts: PromptPolicy?

    @Argument(parsing: .captureForPassthrough, help: "The program and its arguments, after --.")
    var command: [String] = []

    @OptionGroup var options: StoreOptions

    func validate() throws {
        guard !command.isEmpty else {
            throw ValidationError("give the program to run after --, for example: agent-vm exec --box dev -- uname -a")
        }
        if readOnly && project == nil {
            throw ValidationError("--read-only applies to --project")
        }
        if tty && isatty(STDIN_FILENO) != 1 {
            throw ValidationError("--tty needs a terminal on stdin")
        }
    }

    func run() throws {
        // Read once, since an --env-file may be a pipe, and before the box: a missing variable
        // or a bad file is a usage error (64), like the checks in validate().
        let added: [String: String]
        do {
            added = try ExecEnvironment.overrides(base: [:], files: envFile, entries: env, host: ProcessInfo.processInfo.environment)
        } catch let error as AgentVMError {
            throw ValidationError(error.description)
        }
        let argv = command.first == "--" ? Array(command.dropFirst()) : command
        guard !argv.isEmpty else {
            throw ValidationError("give the program to run after --")
        }
        ExecRunner(store: options.boxStore, box: box, user: user, cwd: cwd, project: project, readOnly: readOnly,
                   added: added, argv: argv, terminal: tty, prompts: prompts ?? .default).run()
    }
}

extension PromptPolicy: ExpressibleByArgument {}
