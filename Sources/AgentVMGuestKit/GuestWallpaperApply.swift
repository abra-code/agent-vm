// Sources/AgentVMGuestKit/GuestWallpaperApply.swift
//
// The guest half of the wallpaper that names a box or image on screen: agent-vm-guest
// `wallpaper` (feature `wallpaper`) sets a PNG, drawn on the Mac, as the wallpaper from inside
// the box user's desktop session, through NSWorkspace: AppleScript (System Events, Finder)
// would ask for Automation permission, and outside the session the call reports success and
// changes nothing (measured).

import AppKit
import CryptoKit
import Foundation

public enum GuestWallpaper {
    /// Largest PNG agent-vm-guest takes on stdin; a drawn wallpaper is about 40 KB.
    static let maximumBytes = 16 << 20

    /// The folder in the box user's home that holds the wallpaper (one file, named by its
    /// SHA-256, so a new picture is a new URL the desktop cannot mistake for the old one).
    static let folder = "Library/Application Support/agent-vm"

    /// Why `apply` could not set the picture, for the daemon's stderr.
    package struct Failure: Error, Equatable, CustomStringConvertible {
        package var reason: String

        package var description: String {
            return Printable.lines("`wallpaper` failed in the guest (status 0): \(reason)", limit: 8000)
        }
    }

    /// What `apply` did: `set` the picture, found it `unchanged` (already the wallpaper), or
    /// `kept` a wallpaper someone chose in the box.
    public enum Outcome: String, Sendable {
        case set
        case unchanged
        case kept
    }

    /// The picture macOS shows on a new account's desktop.
    static let defaultPicture = "/System/Library/CoreServices/DefaultDesktop.heic"

    /// Makes `png` the wallpaper of every screen for the calling user, who must be in their
    /// desktop session (`launchctl asuser`). Writes it to `folder` in the user's home, sets it,
    /// waits up to `confirmSeconds` for the desktop to report it, then deletes the previous
    /// picture. Unchanged when it already is the wallpaper. Only macOS's default picture and
    /// an earlier one of agent-vm's are replaced: a wallpaper someone chose in the box is kept.
    @MainActor
    public static func apply(_ png: Data, confirmSeconds: Int = 10) async throws -> (outcome: Outcome, path: String) {
        guard png.count <= maximumBytes, png.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) else {
            throw Failure(reason: "stdin is not a PNG of at most \(maximumBytes >> 20) MB")
        }
        // sudo -u keeps root's HOME; the account database has the user's.
        guard let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir.map({ String(cString: $0) }) else {
            throw GuestSystemError(operation: "look up the home folder", code: errno)
        }
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            throw Failure(reason: "no screens: not in the user's desktop session")
        }
        let directory = URL(fileURLWithPath: home).appendingPathComponent(folder, isDirectory: true)
        let digest = SHA256.hash(data: png).prefix(8).map { String(format: "%02x", $0) }.joined()
        let url = directory.appendingPathComponent("wallpaper-\(digest).png")
        let isCurrent = { screens.allSatisfy { NSWorkspace.shared.desktopImageURL(for: $0)?.standardizedFileURL == url.standardizedFileURL } }
        if FileManager.default.fileExists(atPath: url.path) && isCurrent() {
            return (.unchanged, url.path)
        }
        let replaceable = screens.allSatisfy { screen in
            guard let current = NSWorkspace.shared.desktopImageURL(for: screen)?.standardizedFileURL else {
                return true
            }
            let name = current.lastPathComponent
            return current.path == defaultPicture
                || (current.deletingLastPathComponent().path == directory.standardizedFileURL.path && name.hasPrefix("wallpaper-") && name.hasSuffix(".png"))
        }
        guard replaceable else {
            return (.kept, url.path)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: url, options: .atomic)
        for screen in screens {
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
        }
        // The desktop takes it over a moment or two; before that it still reports the old one.
        var confirmed = isCurrent()
        for _ in 0..<(confirmSeconds * 4) where !confirmed {
            try await Task.sleep(for: .milliseconds(250))
            confirmed = isCurrent()
        }
        guard confirmed else {
            throw Failure(reason: "the desktop did not take \(url.path) within \(confirmSeconds) s")
        }
        let previous = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in previous where name.hasPrefix("wallpaper-") && name.hasSuffix(".png") && name != url.lastPathComponent {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        return (.set, url.path)
    }
}
