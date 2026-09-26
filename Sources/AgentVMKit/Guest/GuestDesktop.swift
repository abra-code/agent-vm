// Sources/AgentVMKit/Guest/GuestDesktop.swift
//
// Keeps the box user's desktop from locking (no screen saver, no display sleep, no screen
// lock), so a window on a box or image never asks for the password. Part of it is stored per
// machine: the screen saver setting is a per-host preference, and the screen lock lives in the
// guest's keybag, so a box (a clone with its own machine identifier) starts with them back on
// (measured). Image builds apply it, and so does a box's supervisor when its screen is first
// shown. Also the desktop's looks and weight: a wallpaper naming the box or image
// (GuestWallpaper), and hidden widgets (each set once, not per machine: they live in the
// user's preferences, which a box inherits from its image).

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

    /// `defaults` for `user`, run in their desktop session (`launchctl asuser`) so it talks to
    /// their own cfprefsd. Run as the user straight from the guest daemon, it reaches the system
    /// cfprefsd, which during an image's first boot treats the account's preferences as
    /// non-persistent and refuses the write ("Could not write domain"; measured on macOS 27,
    /// apparently because it started before macOS created the account). The caller waits for
    /// the desktop first.
    @MainActor
    static func defaults(_ arguments: [String], user: String, uid: String, run: Run) async throws -> (report: ExitReport, stdout: String, stderr: String) {
        return try await run(GuestRequest(op: .exec, argv: ["/bin/launchctl", "asuser", uid, "/usr/bin/sudo", "-u", user, "/usr/bin/defaults"] + arguments,
                                          cwd: "/", user: "root"), nil)
    }

    /// Turns the screen saver, display sleep and screen lock off for `user`; nil when all of
    /// it took, else why not. The screen lock is changed in the user's desktop session (outside
    /// it, sysadminctl fails), so this first waits up to `desktopWait` seconds for the login.
    @MainActor
    static func keepUnlocked(user: String, password: String, desktopWait: Int = 60, run: Run) async throws -> String? {
        let uid = try await userID(user, run: run)
        guard try await waitForDesktop(uid: uid, seconds: desktopWait, run: run) else {
            return "\(user) is not logged in to the desktop; the screen lock stays as it is"
        }
        let sleep = try await run(GuestRequest(op: .exec, argv: ["/usr/bin/pmset", "-a", "displaysleep", "0"], cwd: "/", user: "root"), nil)
        let saver = try await defaults(["-currentHost", "write", "com.apple.screensaver", "idleTime", "-int", "0"], user: user, uid: uid, run: run)
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

    /// Whether the user with id `uid` is logged in to the desktop (the automatic login), waiting
    /// up to `seconds` for it.
    @MainActor
    static func waitForDesktop(uid: String, seconds: Int, run: Run) async throws -> Bool {
        for attempt in 0...seconds {
            let session = try await run(GuestRequest(op: .exec, argv: ["/bin/launchctl", "print", "gui/\(uid)"], cwd: "/", user: "root"), nil)
            if session.report == ExitReport(status: 0) {
                return true
            }
            if attempt < seconds {
                try await Task.sleep(for: .seconds(1))
            }
        }
        return false
    }

    /// Hides the desktop widgets for `user`, from their next login: System Settings' Desktop &
    /// Dock > Show Widgets, off for the desktop and for Stage Manager. macOS puts a few widgets
    /// on a new account's desktop, and at every login about 20 widget programs start with them,
    /// 256 MB together; hidden, about 3 start, 70 MB (measured). Nil when they are hidden, else
    /// why not.
    ///
    /// Emptying the widget layout saves a little more (1 program, 35 MB), but the layout is in
    /// NotificationCenter's container, which only a program with Full Disk Access may open, and
    /// a new image's daemon has none (macOS refuses silently, without a prompt; measured).
    @MainActor
    static func hideWidgets(user: String, uid: String, run: Run) async throws -> String? {
        var failures: [String] = []
        for key in ["StandardHideWidgets", "StageManagerHideWidgets"] {
            let result = try await defaults(["write", "com.apple.WindowManager", key, "-bool", "true"], user: user, uid: uid, run: run)
            if result.report != ExitReport(status: 0) {
                failures.append("\(key): \((result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        return failures.isEmpty ? nil : "could not hide the widgets: \(failures.joined(separator: "; "))"
    }

    /// Makes `png` the wallpaper of `user`'s desktop through agent-vm-guest `wallpaper` (feature
    /// `wallpaper`), run in their desktop session. Returns what it did, or throws with the
    /// guest's reason; the caller waits for the desktop first.
    @MainActor
    static func setWallpaper(_ png: Data, user: String, uid: String, run: Run) async throws -> GuestWallpaper.Outcome {
        let request = GuestRequest(op: .exec, argv: ["/bin/launchctl", "asuser", uid, "/usr/bin/sudo", "-u", user,
                                                     GuestDaemon.executablePath, "wallpaper"], cwd: "/", user: "root")
        let result = try await run(request, png)
        let word = result.stdout.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        guard result.report == ExitReport(status: 0), let outcome = GuestWallpaper.Outcome(rawValue: word) else {
            throw AgentVMError.guestCommandFailed(command: "agent-vm-guest wallpaper", status: result.report.shellStatus,
                                                  output: (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return outcome
    }

    /// A desktop that names its machine and runs few widgets: `png` as the wallpaper (skipped,
    /// with a note, when the guest daemon lacks the feature; with no note when `png` is nil),
    /// and the widgets hidden. With `widgetsOnce` (boxes) the widgets are hidden only along
    /// with a new wallpaper, that is on the box's first start, so someone who shows them again
    /// in System Settings keeps them. Returns lines for the log.
    @MainActor
    static func prepare(user: String, png: Data?, features: [String], widgetsOnce: Bool, desktopWait: Int = 60, run: Run) async throws -> [String] {
        let uid = try await userID(user, run: run)
        guard try await waitForDesktop(uid: uid, seconds: desktopWait, run: run) else {
            return ["note: \(user) is not logged in to the desktop; the widgets and wallpaper stay as they are"]
        }
        var lines: [String] = []
        var newWallpaper = false
        if let png, features.contains(GuestFeature.wallpaper) {
            do {
                let outcome = try await setWallpaper(png, user: user, uid: uid, run: run)
                newWallpaper = outcome == .set
                switch outcome {
                case .set:
                    lines.append("Wallpaper set")
                case .unchanged:
                    lines.append("Wallpaper already set")
                case .kept:
                    lines.append("Wallpaper kept: someone chose another one in the box")
                }
            } catch {
                lines.append("note: could not set the wallpaper: \(error)")
            }
        } else if png != nil {
            lines.append("note: this agent-vm-guest predates wallpapers; boxes made after `agent-vm image update-guest` on their image get one")
        }
        if !widgetsOnce || newWallpaper {
            let widgets = try await hideWidgets(user: user, uid: uid, run: run)
            lines.append(widgets.map { "note: \($0)" } ?? "Widgets hidden from the next login")
        }
        return lines
    }
}
