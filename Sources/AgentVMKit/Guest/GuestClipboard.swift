// Sources/AgentVMKit/Guest/GuestClipboard.swift
//
// The clipboard buttons of a box's window (BoxViewer): "Send Clipboard" puts the text on this
// Mac's clipboard on the clipboard of the box user's desktop, "Get Clipboard" puts the text
// on the box's clipboard on this Mac's. One copy per click, plain text only: nothing is shared
// in between, and the box never reads this Mac's clipboard by itself. Both are ordinary guest
// requests run as the box user, so they need nothing new in agent-vm-guest:
//
// - macOS: pbcopy and pbpaste. What the guest daemon runs as the box user runs in their desktop
//   session (launchctl asuser), on the pasteboard the desktop's apps use (measured).
// - Linux, a Wayland desktop other than GNOME (KDE Plasma): wl-copy and wl-paste, through the
//   protocol Wayland compositors offer clipboard tools. Plasma does not give its X programs
//   (Xwayland) what a Wayland program copied unless an X window has the focus, so X is no way
//   in there (measured).
// - Linux, GNOME or an X desktop (XFCE): xclip, on the desktop's X display. GNOME offers no
//   clipboard protocol to tools, and Wayland lets only the focused window set the clipboard,
//   but GNOME shares one clipboard between its Wayland programs and its X server beside them
//   (Xwayland), either way and whatever has the focus (measured on GNOME 50).
//
// Where the desktop is (DISPLAY and XAUTHORITY, or WAYLAND_DISPLAY and XDG_RUNTIME_DIR, and
// which desktop it is, XDG_CURRENT_DESKTOP) is read from the environment of the box user's own
// programs: XFCE leaves it out of systemd's user environment. The desktop recipes install the
// tool their desktop needs.
//
// The text lasts only as long as the program that offers it, and the guest daemon ends a
// program's whole process group when the program exits: xclip and wl-copy run in a session of
// their own (setsid) and offer the text until something else is copied in the box. GNOME keeps
// a copy of the clipboard by itself; XFCE does not (measured).

import AppKit
import Foundation

public struct GuestClipboard {
    /// The guest's system, which says how its clipboard is reached.
    let guest: GuestKind
    /// The box user, whose desktop's clipboard it is.
    let user: String
    let run: GuestDesktop.Run

    typealias Captured = (report: ExitReport, stdout: String, stderr: String)

    /// The most text either way, in UTF-8 bytes: what a guest command's output may hold.
    static let maximumBytes = GuestClient.captureLimit

    /// Why a copy did not happen, as the window says it.
    struct Failure: Error, Equatable, CustomStringConvertible {
        var description: String
    }

    /// Puts `text` on the box user's clipboard.
    @MainActor
    func put(_ text: String) async throws {
        guard text.utf8.count <= Self.maximumBytes else {
            throw Failure(description: "the text on this Mac's clipboard is over \(Self.maximumBytes >> 20) MB")
        }
        let session = guest == .linux ? try await desktopSession() : nil
        let request = session.map { Self.putRequest(user: user, session: $0) } ?? GuestRequest(op: .exec, argv: ["/usr/bin/pbcopy"], user: user)
        let result = try await run(request, Data(text.utf8))
        guard result.report == ExitReport(status: 0) else {
            throw failure(result, session: session, what: "put the text on the clipboard in the box")
        }
    }

    /// The text on the box user's clipboard, made harmless to paste as copying from an agent
    /// is (ClipboardGate.sanitized); empty when it holds no text.
    @MainActor
    func text() async throws -> String {
        let session = guest == .linux ? try await desktopSession() : nil
        let request = session.map { Self.textRequest(user: user, session: $0) } ?? GuestRequest(op: .exec, argv: ["/usr/bin/pbpaste"], user: user)
        let result: Captured
        do {
            result = try await run(request, nil)
        } catch GuestProtocolError.malformed(let reason) where reason.contains("printed more than") {
            throw Failure(description: "the clipboard in the box holds over \(Self.maximumBytes >> 20) MB of text")
        }
        if Self.isEmptyClipboard(result) {
            return ""
        }
        guard result.report == ExitReport(status: 0) else {
            throw failure(result, session: session, what: "read the clipboard in the box")
        }
        return ClipboardGate.sanitized(result.stdout)
    }

    /// Puts `text` on this Mac's clipboard as plain text, marked with where it came from
    /// (org.nspasteboard.source, which clipboard managers read).
    public static func putOnMac(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("com.abracode.agent-vm", forType: NSPasteboard.PasteboardType("org.nspasteboard.source"))
    }

    private func failure(_ result: Captured, session: DesktopSession?, what: String) -> Failure {
        // Only what the tool said: a read's stdout is the clipboard's text, which the window and
        // the log never show.
        let output = Printable.lines(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines), limit: 300)
        switch (result.report.shellStatus, session) {
        case let (127, session?):
            let tool = session.usesWayland ? "wl-clipboard" : "xclip"
            return Failure(description: "could not \(what): the box has no \(tool), which the desktop recipes install since agent-vm 0.8.8 (update the image with `agent-vm image update <image> --tools`, then `agent-vm box recreate`, or install \(tool) in the box as root)")
        case (124, _):
            return Failure(description: "could not \(what): the program that offers the text in the box did not answer within 10 seconds")
        default:
            return Failure(description: "could not \(what) (status \(result.report.shellStatus))\(output.isEmpty ? "" : ": \(output)")")
        }
    }

    // MARK: - Linux

    /// Where a Linux desktop's programs reach it: X (a display and the file that lets them in),
    /// Wayland (a socket in the runtime folder), or both, and which desktop it is.
    struct DesktopSession: Hashable {
        var display: String?
        var authority: String?
        var wayland: String?
        var runtime: String?
        var desktop: String?

        /// Through Wayland's protocol for clipboard tools (wl-clipboard), on a Wayland desktop
        /// that offers it: every one but GNOME. Else through X (xclip).
        var usesWayland: Bool {
            return wayland != nil && runtime != nil && !(desktop ?? "").split(separator: ":").contains("GNOME")
        }

        /// What the tool is given to find the desktop.
        var environment: [String: String] {
            var environment: [String: String] = [:]
            if usesWayland {
                environment["WAYLAND_DISPLAY"] = wayland
                environment["XDG_RUNTIME_DIR"] = runtime
            } else {
                environment["DISPLAY"] = display
                environment["XAUTHORITY"] = authority
            }
            return environment
        }
    }

    /// The desktop session of the box user, from the environment of their programs.
    @MainActor
    private func desktopSession() async throws -> DesktopSession {
        let result = try await run(Self.sessionProbe(user: user), nil)
        guard let session = Self.session(fromProbe: result.stdout) else {
            throw Failure(description: "found no desktop in the box: none of \(user)'s programs names an X or Wayland display")
        }
        return session
    }

    static let probedVariables = ["DISPLAY", "XAUTHORITY", "WAYLAND_DISPLAY", "XDG_RUNTIME_DIR", "XDG_CURRENT_DESKTOP"]

    /// Lists the desktop's variables in the environment of each of the box user's programs:
    /// "/proc/<pid>/environ:" and the variable, each ended by a NUL. Other accounts' programs
    /// cannot be read and are passed over, so the status says nothing.
    static func sessionProbe(user: String) -> GuestRequest {
        let pattern = "^(\(probedVariables.joined(separator: "|")))="
        return GuestRequest(op: .exec, argv: ["/bin/sh", "-c", "exec /bin/grep -s -z -H -E '\(pattern)' /proc/[0-9]*/environ"], user: user)
    }

    /// The session most of the box user's programs name, from `sessionProbe`'s output; nil
    /// when none names a display on this machine. The box's own programs set these variables,
    /// so they choose where the text goes, as they could choose what is on the clipboard in the
    /// box anyway; a value that does not look like one is left out.
    static func session(fromProbe output: String) -> DesktopSession? {
        var found: [Substring: DesktopSession] = [:]
        for record in output.split(separator: "\0") {
            guard record.hasPrefix("/proc/"), let colon = record.firstIndex(of: ":"), record[..<colon].hasSuffix("/environ"),
                  let equals = record[colon...].firstIndex(of: "=") else {
                continue
            }
            let process = record[..<colon]
            let value = String(record[record.index(after: equals)...])
            var session = found[process] ?? DesktopSession()
            switch record[record.index(after: colon)..<equals] {
            case "DISPLAY" where isLocalDisplay(value):
                session.display = value
            case "XAUTHORITY" where isPath(value):
                session.authority = value
            case "WAYLAND_DISPLAY" where isWaylandName(value):
                session.wayland = value
            case "XDG_RUNTIME_DIR" where isPath(value):
                session.runtime = value
            case "XDG_CURRENT_DESKTOP" where Printable.isToken(value.replacingOccurrences(of: ":", with: "-")):
                session.desktop = value
            default:
                break
            }
            found[process] = session
        }
        var counts: [DesktopSession: Int] = [:]
        for session in found.values where session.display != nil || session.usesWayland {
            counts[session, default: 0] += 1
        }
        // The most named; among as many, the first in a fixed order, so the answer does not
        // change from one call to the next.
        let order = { (session: DesktopSession) in
            [session.display, session.authority, session.wayland, session.runtime, session.desktop].map { $0 ?? "" }.joined(separator: "\0")
        }
        return counts.sorted { order($0.key) < order($1.key) }.max { $0.value < $1.value }?.key
    }

    /// ":0" or ":1.0": an X server on this machine, never one over the network.
    static func isLocalDisplay(_ display: String) -> Bool {
        let parts = display.dropFirst().split(separator: ".", omittingEmptySubsequences: false)
        return display.hasPrefix(":") && (1...2).contains(parts.count)
            && parts.allSatisfy { !$0.isEmpty && $0.count <= 4 && $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    /// "wayland-0": a socket's name in the runtime folder.
    static func isWaylandName(_ name: String) -> Bool {
        return !name.contains("/") && Printable.isToken(name)
    }

    static func isPath(_ path: String) -> Bool {
        return path.hasPrefix("/") && path.utf8.count < 1024 && !path.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    /// The tool takes the text from stdin and, once it has it, goes on in the background to
    /// offer it: in a session of its own, so it outlives the request (setsid -w waits for the
    /// part that reads stdin, and returns its status).
    static func putRequest(user: String, session: DesktopSession) -> GuestRequest {
        let tool = session.usesWayland ? ["/usr/bin/wl-copy", "--type", "text/plain;charset=utf-8"] : ["/usr/bin/xclip", "-selection", "clipboard", "-i"]
        return GuestRequest(op: .exec, argv: ["/usr/bin/setsid", "-w"] + tool, env: session.environment, user: user)
    }

    /// The tool prints the clipboard's text; a program that offers it and never answers is
    /// given 10 seconds.
    static func textRequest(user: String, session: DesktopSession) -> GuestRequest {
        let tool = session.usesWayland ? ["/usr/bin/wl-paste", "--no-newline", "--type", "text"] : ["/usr/bin/xclip", "-selection", "clipboard", "-o"]
        return GuestRequest(op: .exec, argv: ["/usr/bin/timeout", "10"] + tool, env: session.environment, user: user)
    }

    /// The tool found nothing on the clipboard, or nothing as text (measured): xclip says
    /// "Error: target STRING not available", wl-paste "Nothing is copied" or "No suitable type
    /// of content copied". pbpaste prints nothing and succeeds.
    static func isEmptyClipboard(_ result: Captured) -> Bool {
        guard result.report == ExitReport(status: 1), result.stdout.isEmpty else {
            return false
        }
        return ["not available", "Nothing is copied", "No suitable type"].contains { result.stderr.contains($0) }
    }
}
