// Sources/AgentVMKit/Guest/GuestWallpaper.swift
//
// A plain wallpaper that names the box or image on screen, so a window on a box (box view)
// says which one it shows. agent-vm draws it on the Mac: dark gray, the name large in the
// middle, a line or two of detail under it, at the box display's size. agent-vm-guest
// `wallpaper` (feature `wallpaper`) sets it in the guest from inside the box user's desktop
// session, through NSWorkspace: AppleScript (System Events, Finder) would ask for Automation
// permission, and outside the session the call reports success and changes nothing (measured).

import AppKit
import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum GuestWallpaper {
    /// Largest PNG agent-vm-guest takes on stdin; a drawn wallpaper is about 40 KB.
    static let maximumBytes = 16 << 20

    /// The folder in the box user's home that holds the wallpaper (one file, named by its
    /// SHA-256, so a new picture is a new URL the desktop cannot mistake for the old one).
    static let folder = "Library/Application Support/agent-vm"

    // MARK: - Drawing (on the Mac)

    /// A PNG of `title` over `lines`, centered on dark gray, `width` by `height` pixels. A
    /// title too wide for the screen is drawn smaller.
    static func png(title: String, lines: [String], width: Int = MacMachineSpec.displayWidth,
                    height: Int = MacMachineSpec.displayHeight) throws -> Data {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AgentVMError.system(operation: "draw the wallpaper", code: ENOMEM)
        }
        context.setFillColor(gray: 0.18, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let maximumWidth = CGFloat(width) * 0.9
        var titleSize: CGFloat = 72
        var titleLine = line(title, font: .emphasizedSystem, size: titleSize, gray: 0.92)
        while titleSize > 16 && lineWidth(titleLine) > maximumWidth {
            titleSize -= 4
            titleLine = line(title, font: .emphasizedSystem, size: titleSize, gray: 0.92)
        }
        let rows = [titleLine] + lines.enumerated().map { index, text in
            line(text, font: .system, size: index == 0 ? 22 : 18, gray: 0.60)
        }
        let gap: CGFloat = 14
        let heights = rows.map(lineHeight)
        let total = heights.reduce(0, +) + gap * CGFloat(rows.count - 1)
        // Core Graphics counts y up from the bottom; start at the top of the centered block.
        var top = (CGFloat(height) + total) / 2
        for (row, rowHeight) in zip(rows, heights) {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let rowWidth = CGFloat(CTLineGetTypographicBounds(row, &ascent, &descent, nil))
            context.textPosition = CGPoint(x: (CGFloat(width) - rowWidth) / 2, y: top - ascent)
            CTLineDraw(row, context)
            top -= rowHeight + gap
        }

        guard let image = context.makeImage() else {
            throw AgentVMError.system(operation: "draw the wallpaper", code: ENOMEM)
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw AgentVMError.system(operation: "encode the wallpaper", code: EINVAL)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw AgentVMError.system(operation: "encode the wallpaper", code: EINVAL)
        }
        return data as Data
    }

    /// The wallpaper of a box: its name, then what it was cloned from.
    public static func png(for box: BoxRecord) throws -> Data {
        return try png(title: box.name, lines: ["agent-vm box", "image \(box.image)  -  macOS \(box.macOSVersion) (\(box.macOSBuild))"])
    }

    /// The wallpaper of an image, which its boxes show until they set their own.
    public static func png(for image: ImageRecord) throws -> Data {
        return try png(title: image.name, lines: ["agent-vm image", "macOS \(image.macOSVersion) (\(image.macOSBuild))"])
    }

    private static func line(_ text: String, font: CTFontUIFontType, size: CGFloat, gray: CGFloat) -> CTLine {
        // The system UI fonts always exist; Helvetica stands in should one ever be missing.
        let face = CTFontCreateUIFontForLanguage(font, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): face,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1),
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    private static func lineWidth(_ line: CTLine) -> CGFloat {
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private static func lineHeight(_ line: CTLine) -> CGFloat {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        return ascent + descent
    }

    // MARK: - Setting it (in the guest)

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
            throw AgentVMError.guestCommandFailed(command: "wallpaper", status: 0, output: "stdin is not a PNG of at most \(maximumBytes >> 20) MB")
        }
        // sudo -u keeps root's HOME; the account database has the user's.
        guard let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir.map({ String(cString: $0) }) else {
            throw AgentVMError.system(operation: "look up the home folder", code: errno)
        }
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            throw AgentVMError.guestCommandFailed(command: "wallpaper", status: 0, output: "no screens: not in the user's desktop session")
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
            throw AgentVMError.guestCommandFailed(command: "wallpaper", status: 0, output: "the desktop did not take \(url.path) within \(confirmSeconds) s")
        }
        let previous = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in previous where name.hasPrefix("wallpaper-") && name.hasSuffix(".png") && name != url.lastPathComponent {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        return (.set, url.path)
    }
}
