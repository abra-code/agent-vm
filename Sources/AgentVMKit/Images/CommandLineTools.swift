// Sources/AgentVMKit/Images/CommandLineTools.swift
//
// Xcode's Command Line Tools (clang, swift, git, make, python3) installed into an image with
// no clicks. `xcode-select --install` opens a dialog; the non-interactive route (measured on
// macOS 27 guests) is a flag file that makes `softwareupdate --list` offer the tools, then
// `softwareupdate -i <label> --agree-to-license`. About 530 MB, about 2 minutes.

import Foundation

public enum CommandLineTools {
    /// While this file exists, softwareupdate lists the Command Line Tools as installable.
    static let onDemandFlag = "/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"

    /// Lists what softwareupdate offers, with the tools included.
    static var listRequest: GuestRequest {
        return GuestRequest(op: .exec, argv: ["/bin/sh", "-c", "/usr/bin/touch \(onDemandFlag) && /usr/sbin/softwareupdate --list 2>&1"], cwd: "/", user: "root")
    }

    static func installRequest(label: String) -> GuestRequest {
        return GuestRequest(op: .exec, argv: ["/usr/sbin/softwareupdate", "--install", label, "--agree-to-license"], cwd: "/", user: "root")
    }

    static var cleanupRequest: GuestRequest {
        return GuestRequest(op: .exec, argv: ["/bin/rm", "-f", onDemandFlag], cwd: "/", user: "root")
    }

    /// Run as the box user: every line must succeed. swift's output is captured before it is
    /// cut to one line, since a pipeline's status is only its last command's.
    static var verifyRequest: GuestRequest {
        return GuestRequest(op: .exec, argv: ["/bin/sh", "-c", "/usr/bin/xcode-select -p && /usr/bin/git --version && swift=$(/usr/bin/swift --version 2>&1) && printf '%s\\n' \"$swift\" | /usr/bin/head -1 && /usr/bin/python3 --version"])
    }

    /// The newest "Command Line Tools" label in `softwareupdate --list` output, which lists
    /// entries as "* Label: Command Line Tools for Xcode 27.0-27.0". Releases win over betas
    /// ("Command Line Tools beta 3 for Xcode ..."); a beta is chosen only when nothing else is
    /// offered.
    static func label(fromListOutput output: String) -> String? {
        let labels = output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("* Label: ") else {
                return nil
            }
            let label = String(text.dropFirst("* Label: ".count))
            return label.hasPrefix("Command Line Tools") ? label : nil
        }
        let releases = labels.filter { !$0.lowercased().contains("beta") }
        return (releases.isEmpty ? labels : releases).max { version(of: $0).lexicographicallyPrecedes(version(of: $1)) }
    }

    /// The numbers in a label, in order ("... for Xcode 27.0-27.0" gives [27, 0, 27, 0]).
    static func version(of label: String) -> [Int] {
        return label.split { !$0.isNumber }.compactMap { Int($0) }
    }
}
