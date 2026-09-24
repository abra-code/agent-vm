// Sources/AgentVMKit/Guest/GuestDaemon.swift
//
// Where agent-vm-guest lives inside an image and how launchd runs it: a root LaunchDaemon
// started at boot (before any login), restarted if it exits, logging to /var/log. Measured on
// macOS 27 guests: a copied, linker-signed binary runs this way without quarantine or approval.

import Foundation

public enum GuestDaemon {
    public static let label = "com.abracode.agent-vm.guest"
    public static let executablePath = "/usr/local/libexec/agent-vm-guest"
    public static let plistPath = "/Library/LaunchDaemons/\(label).plist"
    public static let logPath = "/var/log/agent-vm-guest.log"

    /// Where the files are copied (over SSH) before the install command moves them into place.
    static let stagedExecutable = "/tmp/agent-vm-guest"
    static let stagedPlist = "/tmp/\(label).plist"

    /// The LaunchDaemon property list; `user` is the account exec runs as by default.
    public static func launchdPlist(user: String) throws -> Data {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath, "serve", "--user", user],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// Run as root (through sudo) after both files are staged: put them in place with root
    /// ownership, and load the daemon.
    static var installCommand: String {
        return [
            "/bin/mkdir -p /usr/local/libexec",
            "/usr/bin/install -m 755 -o root -g wheel \(stagedExecutable) \(executablePath)",
            "/usr/bin/install -m 644 -o root -g wheel \(stagedPlist) \(plistPath)",
            "/bin/rm -f \(stagedExecutable) \(stagedPlist)",
            "/bin/launchctl bootstrap system \(plistPath)",
        ].joined(separator: " && ")
    }

    /// Run as root through the daemon, with the new executable on stdin: put it in place and
    /// print its SHA-256. The running daemon keeps its old file (a rename does not touch it) and
    /// the new one runs from the next boot. A copy cut short (the host gone, so cat sees an early
    /// end of input) never replaces the old one: its SHA-256 must be `digest` before the rename,
    /// and the rename is on disk before the answer.
    static func replaceCommand(digest: String) -> String {
        return [
            "/bin/cat > \(executablePath).new",
            "/bin/echo '\(digest)  \(executablePath).new' | /usr/bin/shasum -a 256 -c -s",
            "/bin/chmod 755 \(executablePath).new",
            "/usr/sbin/chown root:wheel \(executablePath).new",
            "/bin/mv -f \(executablePath).new \(executablePath)",
            "/bin/sync",
            "/usr/bin/shasum -a 256 \(executablePath)",
        ].joined(separator: " && ")
    }

    /// Run as root through the daemon: stop Remote Login now and keep it off after reboots.
    /// Afterwards the daemon is the only way into the guest.
    static let disableSSHCommand = "/bin/launchctl disable system/com.openssh.sshd; /bin/launchctl bootout system/com.openssh.sshd 2>/dev/null; exit 0"
}
