// Sources/agent-vm/SecretCommand.swift
//
// `agent-vm secret ...`: API keys and tokens in the login Keychain (SecretStore), for
// `exec --secret NAME` and `box shell --secret NAME`. Values come from stdin, never from the
// command line, and never appear in agent-vm's output or logs.

import AgentVMKit
import ArgumentParser
import Darwin
import Foundation

struct SecretCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "secret",
        abstract: "Keep API keys and tokens in the Keychain for programs in boxes.",
        discussion: """
            Secrets are generic passwords in your login Keychain (service agent-vm, account \
            NAME). `agent-vm exec --secret NAME` puts one in the program's environment as NAME, \
            `--secret VAR=NAME` as VAR. macOS ties each secret to the agent-vm that stored it: \
            a differently signed agent-vm (an ad hoc build is a new one after every rebuild) \
            makes macOS ask before reading it; answer Always Allow, or store it again.
            """,
        subcommands: [Set.self, Delete.self, List.self]
    )

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Store a secret; its value is read from stdin (typed without echo on a terminal).",
            discussion: """
                From a pipe or a file, the whole input is the value, less one final line end: \
                `printf %s "$KEY" | agent-vm secret set ANTHROPIC_API_KEY`, or \
                `op read ... | agent-vm secret set ...`. Typed on a terminal, a value is at most \
                1023 bytes (the terminal's line limit); longer ones, up to 64 KB, come through a \
                pipe. An existing secret is replaced.
                """)

        @Argument(help: "The secret's name (letters, digits and _): also the environment variable exec sets.")
        var name: String

        func validate() throws {
            guard SecretStore.isValidName(name) else {
                throw ValidationError("\(name) is not a usable secret name: letters, digits and \"_\", not starting with a digit")
            }
        }

        func run() throws {
            let value = try Self.readValue(name)
            try SecretStore().set(name, value: value)
            print("Stored secret \(name) in the Keychain")
        }

        /// The value from stdin: typed without echo on a terminal, else all of it less one
        /// final line end.
        static func readValue(_ name: String) throws -> Data {
            if isatty(STDIN_FILENO) == 1 {
                var buffer = [CChar](repeating: 0, count: SecretStore.maxValueBytes + 2)
                guard readpassphrase("Value of secret \(name): ", &buffer, buffer.count, RPP_REQUIRE_TTY) != nil else {
                    throw AgentVMError.system(operation: "read the value", code: errno)
                }
                let data = Data(buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) })
                buffer.withUnsafeMutableBytes { raw in
                    _ = memset_s(raw.baseAddress, raw.count, 0, raw.count)
                }
                return data
            }
            var data = Data()
            var chunk = [UInt8](repeating: 0, count: 65536)
            // Until the end, or until even less a final "\r\n" it is too long: stopping at the
            // limit would take a line end that arrives there, with more to follow, as the end.
            while data.count <= SecretStore.maxValueBytes + 2 {
                let got = read(STDIN_FILENO, &chunk, chunk.count)
                if got < 0 && errno == EINTR {
                    continue
                }
                guard got >= 0 else {
                    throw AgentVMError.system(operation: "read the value from stdin", code: errno)
                }
                if got == 0 {
                    break
                }
                data.append(contentsOf: chunk[0..<got])
            }
            if data.last == 10 {
                data.removeLast()
                if data.last == 13 {
                    data.removeLast()
                }
            }
            return data
        }
    }

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a secret from the Keychain.")

        @Argument(help: "The secret's name.")
        var name: String

        func validate() throws {
            guard SecretStore.isValidName(name) else {
                throw ValidationError("\(name) is not a usable secret name: letters, digits and \"_\", not starting with a digit")
            }
        }

        func run() throws {
            try SecretStore().delete(name)
            print("Deleted secret \(name)")
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List the secrets' names (never their values), and whether each can be read without macOS asking.")

        @Flag(name: .long, help: "Print machine-readable JSON instead of text.")
        var json = false

        func run() throws {
            let entries = try SecretStore().list()
            if json {
                try Output.json(entries)
                return
            }
            if entries.isEmpty {
                print("No secrets.")
                return
            }
            for entry in entries {
                print(entry.readable ? entry.name : "\(entry.name)  (stored by another build of agent-vm or another program: macOS asks before this one reads it, unless Always Allow was chosen)")
            }
        }
    }
}

/// `--secret NAME` and `--secret VAR=NAME` on exec and box shell.
enum SecretOptions {
    static let help = ArgumentHelp("Put a Keychain secret (`agent-vm secret set`) in the program's environment: NAME, or VAR=NAME to name the variable (repeatable; wins over --env).",
                                   valueName: "name")

    /// Checks the forms (a usage error otherwise).
    static func validate(_ specs: [String]) throws {
        for spec in specs {
            do {
                _ = try SecretStore.option(spec)
            } catch {
                throw ValidationError("\(error)")
            }
        }
    }

    /// The variables, read from the Keychain (macOS may ask first). A secret that is missing or
    /// cannot be read ends the command with status 125, naming the secret.
    static func resolve(_ specs: [String]) -> [String: String] {
        var variables: [String: String] = [:]
        let store = SecretStore()
        for spec in specs {
            do {
                let (variable, secret) = try SecretStore.option(spec)
                let value = try store.read(secret)
                // As `secret set` requires; another program may have stored something else.
                guard let text = String(data: value, encoding: .utf8), !value.contains(0) else {
                    throw AgentVMError.invalidSecret(name: secret, reason: "the value is not text (UTF-8 without NUL characters)")
                }
                variables[variable] = text
            } catch {
                Stderr.write("agent-vm: \(error)\n")
                Darwin.exit(ExecRunner.ownFailureStatus)
            }
        }
        return variables
    }
}
