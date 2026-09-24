// Sources/AgentVMKit/Guest/GuestDesktop.swift
//
// Keeps the box user's desktop from locking (no screen saver, no display sleep, no screen
// lock), so a window on a box or image never asks for the password. Part of it is stored per
// machine: the screen saver setting is a per-host preference, and the screen lock lives in the
// guest's keybag, so a box (a clone with its own machine identifier) starts with them back on
// (measured). Image builds apply it, and so does a box's supervisor when its screen is first
// shown.

import Foundation

enum GuestDesktop {
    /// Runs one request in the guest as the caller can (image builder or supervisor), with
    /// optional stdin.
    typealias Run = @MainActor (GuestRequest, Data?) async throws -> (report: ExitReport, stdout: String, stderr: String)

    /// The account's user id in the guest.
    @MainActor
    static func userID(_ user: String, run: Run) async throws -> String {
        let id = try await run(GuestRequest(op: .exec, argv: ["/usr/bin/id", "-u", user], cwd: "/", user: "root"), nil)
        let uid = id.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.report == ExitReport(status: 0), !uid.isEmpty else {
            throw AgentVMError.guestCommandFailed(command: "id -u \(user)", status: id.report.shellStatus, output: id.stderr)
        }
        return uid
    }

    /// Turns the screen saver, display sleep and screen lock off for `user`; nil when all of
    /// it took, else why not. The screen lock is changed in the user's desktop session (outside
    /// it, sysadminctl fails), so this first waits up to `desktopWait` seconds for the login.
    @MainActor
    static func keepUnlocked(user: String, password: String, desktopWait: Int = 60, run: Run) async throws -> String? {
        let uid = try await userID(user, run: run)
        var desktop = false
        for attempt in 0...desktopWait {
            let session = try await run(GuestRequest(op: .exec, argv: ["/bin/launchctl", "print", "gui/\(uid)"], cwd: "/", user: "root"), nil)
            if session.report == ExitReport(status: 0) {
                desktop = true
                break
            }
            if attempt < desktopWait {
                try await Task.sleep(for: .seconds(1))
            }
        }
        guard desktop else {
            return "\(user) is not logged in to the desktop; the screen lock stays as it is"
        }
        let sleep = try await run(GuestRequest(op: .exec, argv: ["/usr/bin/pmset", "-a", "displaysleep", "0"], cwd: "/", user: "root"), nil)
        let saver = try await run(GuestRequest(op: .exec, argv: ["/usr/bin/defaults", "-currentHost", "write", "com.apple.screensaver",
                                                                "idleTime", "-int", "0"], user: user), nil)
        // The password goes in on stdin, never in a command line outside the guest.
        let script = "IFS= read -r password; exec /bin/launchctl asuser \(uid) /usr/bin/sudo -u \(user) /usr/sbin/sysadminctl -screenLock off -password \"$password\""
        let lock = try await run(GuestRequest(op: .exec, argv: ["/bin/sh", "-c", script], cwd: "/", user: "root"), Data((password + "\n").utf8))
        // Setting it prints nothing either way; its status says whether it took.
        let status = try await run(GuestRequest(op: .exec, argv: ["/bin/launchctl", "asuser", uid, "/usr/bin/sudo", "-u", user,
                                                                 "/usr/sbin/sysadminctl", "-screenLock", "status"], cwd: "/", user: "root"), nil)
        let unlocked = (status.stderr + status.stdout).contains("screenLock is off")
        if sleep.report == ExitReport(status: 0) && saver.report == ExitReport(status: 0) && unlocked {
            return nil
        }
        return "could not turn off everything that locks the screen: \((lock.stderr + status.stderr + saver.stderr + sleep.stderr).trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}
