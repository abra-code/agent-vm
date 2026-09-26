// Sources/AgentVMKit/Guest/ExecEnvironment.swift
//
// The variables `agent-vm exec` adds to a program's environment: `--env NAME=VALUE`, `--env
// NAME` (the value agent-vm itself was given, the way to hand an API key to an agent without
// writing it on the command line) and `--env-file` (NAME=VALUE lines). Values go straight to the
// guest daemon in the exec request; agent-vm does not log them or write them anywhere.

import Foundation

public enum ExecEnvironment {
    /// Environment files larger than this are refused: the whole exec request must fit in one
    /// protocol frame.
    public static let maximumFileSize = 256 * 1024

    /// A variable name a shell can use: a letter or "_", then letters, digits and "_".
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first == "_" || isASCIILetter(first) else {
            return false
        }
        return name.unicodeScalars.allSatisfy { $0 == "_" || isASCIILetter($0) || ("0"..."9").contains($0) }
    }

    /// One `--env` entry: NAME=VALUE as given, or NAME with the value from `host` (normally
    /// agent-vm's own environment), which must have it.
    public static func entry(_ text: String, host: [String: String]) throws -> (name: String, value: String) {
        if let equals = text.firstIndex(of: "=") {
            guard equals != text.startIndex else {
                throw AgentVMError.invalidEnvironment("--env needs NAME=VALUE or the NAME of a variable to pass on, got \(text)")
            }
            return (String(text[..<equals]), String(text[text.index(after: equals)...]))
        }
        guard isValidName(text) else {
            throw AgentVMError.invalidEnvironment("--env needs NAME=VALUE or the NAME of a variable to pass on, got \(text)")
        }
        guard let value = host[text] else {
            throw AgentVMError.invalidEnvironment("--env \(text): \(text) is not set in agent-vm's environment")
        }
        return (text, value)
    }

    /// The variables in an environment file: one NAME=VALUE per line, the value taken as is to
    /// the end of the line (no quotes or escapes, as `docker run --env-file`); a line with only
    /// NAME passes on the value from `host`. Blank lines and lines starting with "#" are skipped,
    /// and so are leading spaces and a trailing carriage return. The file is read once, so it may
    /// be a pipe: `--env-file <(op read ...)` hands over keys without writing them to disk.
    public static func file(at path: String, host: [String: String]) throws -> [(name: String, value: String)] {
        var info = stat()
        guard stat(path, &info) == 0 else {
            throw AgentVMError.invalidEnvironment("cannot read environment file \(path): \(String(cString: strerror(errno)))")
        }
        guard info.st_mode & S_IFMT != S_IFDIR else {
            throw AgentVMError.invalidEnvironment("environment file \(path) is a folder")
        }
        var data = Data()
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            // Until the end or one byte over the limit; a pipe may return less than asked.
            while data.count <= maximumFileSize {
                guard let chunk = try handle.read(upToCount: maximumFileSize + 1 - data.count), !chunk.isEmpty else {
                    break
                }
                data.append(chunk)
            }
        } catch {
            throw AgentVMError.invalidEnvironment("cannot read environment file \(path): \(error.localizedDescription)")
        }
        guard data.count <= maximumFileSize else {
            throw AgentVMError.invalidEnvironment("environment file \(path) is larger than \(maximumFileSize / 1024) KB")
        }
        // A NUL would end the value early in the guest's C environment, without a word.
        guard let text = String(data: data, encoding: .utf8), !text.unicodeScalars.contains("\0") else {
            throw AgentVMError.invalidEnvironment("environment file \(path) is not UTF-8 text")
        }
        var entries: [(name: String, value: String)] = []
        // By scalars: as Characters, "\r\n" is one and a split at "\n" would not see it.
        for (index, scalars) in text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var trimmed = String(scalars)
            if trimmed.unicodeScalars.last == "\r" {
                trimmed.unicodeScalars.removeLast()
            }
            let line = trimmed.drop(while: { $0 == " " || $0 == "\t" })
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            let name = line.firstIndex(of: "=").map { String(line[..<$0]) } ?? String(line)
            guard isValidName(name) else {
                // The name only: the line may hold a value, which must not reach an error message.
                throw AgentVMError.invalidEnvironment("environment file \(path), line \(index + 1): expected NAME=VALUE with a name of letters, digits and \"_\"")
            }
            do {
                entries.append(try entry(String(line), host: host))
            } catch {
                throw AgentVMError.invalidEnvironment("environment file \(path), line \(index + 1): \(name) is not set in agent-vm's environment")
            }
        }
        return entries
    }

    /// The program's added variables: `base` (the proxy settings of a proxied box), then the
    /// files in order, then the `--env` entries, a later value replacing an earlier one.
    public static func overrides(base: [String: String], files: [String], entries: [String], host: [String: String]) throws -> [String: String] {
        var environment = base
        for path in files {
            for (name, value) in try file(at: path, host: host) {
                environment[name] = value
            }
        }
        for text in entries {
            let (name, value) = try entry(text, host: host)
            environment[name] = value
        }
        return environment
    }

    /// The TERM for a program on a terminal in the box: the Mac's own when the guest knows it,
    /// else xterm-256color. Both run macOS, so the Mac's terminal database (terminfo) stands in
    /// for the guest's; a terminal with its own type (Ghostty, kitty) falls back.
    public static func terminalType(host: String?, terminfo: String = "/usr/share/terminfo") -> String {
        let fallback = "xterm-256color"
        guard let host, let first = host.unicodeScalars.first, first.isASCII, !host.contains("/"), host != "..", host != "." else {
            return fallback
        }
        let folder = String(first.value, radix: 16)
        return FileSystem.exists("\(terminfo)/\(folder)/\(host)") ? host : fallback
    }

    /// Variables that say which terminal this is, passed with a terminal (`exec --tty`, `box
    /// shell`) as ssh's SendEnv would: programs choose 24-bit color, links, the enhanced
    /// keyboard and synchronized output by them (measured with Claude Code, Codex and opencode).
    /// Markers only: variables holding paths on the Mac (GHOSTTY_RESOURCES_DIR, TERMINFO) mean
    /// nothing in the box.
    public static let terminalIdentity = ["COLORTERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "LC_TERMINAL", "LC_TERMINAL_VERSION"]

    /// A /bin/sh script for the guest that installs the terminfo entry on stdin (`infocmp -x`
    /// output from the Mac) as `name` into the account's ~/.terminfo, unless it is there; nil
    /// for a name that is not a plain terminal name (one that starts with "-" would be read as
    /// an option by infocmp on the Mac).
    public static func terminfoInstallScript(name: String) -> String? {
        guard !name.isEmpty, name.count <= 64,
              name.unicodeScalars.allSatisfy({ isASCIILetter($0) || ("0"..."9").contains($0) || "-_.+".unicodeScalars.contains($0) }),
              name != ".", name != "..", let first = name.unicodeScalars.first, first != "-" else {
            return nil
        }
        let folder = String(first.value, radix: 16)
        return "[ -e \"$HOME/.terminfo/\(folder)/\(name)\" ] && exit 0; /bin/mkdir -p \"$HOME/.terminfo\" && /usr/bin/tic -x -o \"$HOME/.terminfo\" /dev/stdin"
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }
}
