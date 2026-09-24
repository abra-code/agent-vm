// Sources/AgentVMKit/Boxes/BoxViewer.swift
//
// A window on a box's screen (`agent-vm box view`), shown by the box's supervisor: the virtual
// machine lives in that process, and Virtualization draws a machine only in a view of the same
// process. View only unless asked otherwise: a clear layer over the screen takes every key and
// click, so looking cannot change anything in the box. Closing the window leaves the box
// running. The supervisor has no Dock icon and no menu, so nothing in the window can quit it
// (quitting would pull the plug on the guest).
//
// Only a supervisor in a login session can show windows: one started over SSH or by a service
// has no window server, and runs without AppKit.

import AppKit
import CoreGraphics
import Virtualization

@MainActor
final class BoxViewer: NSObject, NSWindowDelegate {
    private let name: String
    private let machine: MacMachine
    /// The guest account's password, typed by the Type Password button (interactive only).
    private let password: String?
    /// A line of instructions under the title bar.
    private let note: String?
    private let onClose: (@MainActor () -> Void)?
    private var window: NSWindow?
    private var screen: BoxScreen?
    private var shield: InputShield?
    private var typeButton: NSButton?
    private var noteLabel: NSTextField?

    init(name: String, machine: MacMachine, password: String? = nil, note: String? = nil, onClose: (@MainActor () -> Void)? = nil) {
        self.name = name
        self.machine = machine
        self.password = password
        self.note = note
        self.onClose = onClose
    }

    /// Whether this process runs in a login session with a window server (not over SSH, not as a
    /// background service): only then can a supervisor run AppKit and show a box's screen.
    nonisolated static var canShowWindows: Bool {
        return CGSessionCopyCurrentDictionary() != nil
    }

    /// Shows the window (creating it the first time) in front, view only or interactive.
    func show(interactive: Bool) {
        let window = self.window ?? makeWindow()
        guard let screen, let shield else {
            return
        }
        shield.isHidden = interactive
        screen.viewOnly = !interactive
        screen.capturesSystemKeys = interactive
        typeButton?.isEnabled = interactive
        window.title = interactive ? "agent-vm box \(name)" : "agent-vm box \(name) - view only"
        NSApplication.shared.setActivationPolicy(.accessory)
        // In front even though the supervisor is not the active application (the user is in
        // Terminal, or in the app that ran box view).
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.orderFrontRegardless()
        window.makeFirstResponder(interactive ? screen : shield)
        if interactive {
            window.makeKey()
            NSApplication.shared.activate()
        }
    }

    private func makeWindow() -> NSWindow {
        let size = NSSize(width: CGFloat(MacMachineSpec.displayWidth), height: CGFloat(MacMachineSpec.displayHeight))
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        let screen = BoxScreen(frame: content.bounds)
        screen.autoresizingMask = [.width, .height]
        machine.attach(screen)
        content.addSubview(screen)
        let shield = InputShield(frame: content.bounds)
        shield.autoresizingMask = [.width, .height]
        content.addSubview(shield)

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.contentView = content
        window.contentAspectRatio = size
        window.isReleasedWhenClosed = false
        window.delegate = self
        // A smaller start on a small screen; the guest's display keeps its size and is scaled.
        if let visible = NSScreen.main?.visibleFrame, visible.width < size.width + 80 || visible.height < size.height + 80 {
            let scale = min((visible.width - 80) / size.width, (visible.height - 80) / size.height)
            window.setContentSize(NSSize(width: size.width * scale, height: size.height * scale))
        }
        window.center()
        if password != nil || note != nil {
            window.addTitlebarAccessoryViewController(makeAccessory())
        }
        self.window = window
        self.screen = screen
        self.shield = shield
        return window
    }

    /// Under the title bar: the note, and the Type Password button.
    private func makeAccessory() -> NSTitlebarAccessoryViewController {
        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        if let note {
            let label = NSTextField(wrappingLabelWithString: note)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            bar.addArrangedSubview(label)
            noteLabel = label
        }
        if password != nil {
            let button = NSButton(title: "Type Password", target: self, action: #selector(typePassword(_:)))
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
            button.toolTip = "Types the box account's password into the focused field in the box (for login windows and administrator prompts)"
            button.setContentHuggingPriority(.required, for: .horizontal)
            bar.addArrangedSubview(button)
            typeButton = button
        }
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = bar
        accessory.layoutAttribute = .bottom
        return accessory
    }

    /// Whether keys and clicks reach the guest (the window was last shown interactive).
    var isInteractive: Bool {
        return screen.map { !$0.viewOnly } ?? false
    }

    /// Replaces the note under the title bar (a window made with a note).
    func setNote(_ text: String) {
        noteLabel?.stringValue = text
    }

    @objc private func typePassword(_ sender: Any?) {
        guard let password else {
            return
        }
        Task { @MainActor in
            try? await self.type(password)
        }
    }

    /// Types `text` into the guest as key presses on a US keyboard (the guest's layout), into
    /// whatever has the focus there. Letters, digits, space, return and a few punctuation marks.
    func type(_ text: String) async throws {
        guard let window, let screen else {
            throw AgentVMError.supervisorRefused("the window of box \(name) is not open")
        }
        // Through the window, as typed keys arrive, to the screen as first responder.
        window.makeFirstResponder(screen)
        // A view-only window gives the keys back to the shield, or the person's own keys would
        // reach the guest from then on.
        defer {
            if screen.viewOnly, let shield {
                window.makeFirstResponder(shield)
            }
        }
        let keys = try text.map { character in
            guard let key = GuestKeys.key(for: character) else {
                throw AgentVMError.supervisorRefused("cannot type \"\(character)\" into box \(name)")
            }
            return (character, key)
        }
        for (character, key) in keys {
            let modifiers: NSEvent.ModifierFlags = key.shift ? [.shift] : []
            if key.shift {
                window.sendEvent(try Self.event(.flagsChanged, modifiers: .shift, characters: "", keyCode: GuestKeys.shift, window: window))
            }
            let characters = String(character)
            window.sendEvent(try Self.event(.keyDown, modifiers: modifiers, characters: characters, keyCode: key.code, window: window))
            window.sendEvent(try Self.event(.keyUp, modifiers: modifiers, characters: characters, keyCode: key.code, window: window))
            if key.shift {
                window.sendEvent(try Self.event(.flagsChanged, modifiers: [], characters: "", keyCode: GuestKeys.shift, window: window))
            }
            // The guest reads a keyboard, not a stream: give each key its own report.
            try await Task.sleep(for: .milliseconds(15))
        }
    }

    private static func event(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags, characters: String, keyCode: UInt16,
                              window: NSWindow) throws -> NSEvent {
        // From a Core Graphics keyboard event, as a real key press is: the screen view reads the
        // key from it (an NSEvent made with keyEvent(with:...) alone reached nothing, measured).
        let source = CGEventSource(stateID: .privateState)
        guard let cgEvent = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: type != .keyUp) else {
            throw AgentVMError.supervisorRefused("cannot make a key event")
        }
        if type == .flagsChanged {
            cgEvent.type = .flagsChanged
        }
        // As a physical left Shift sets them: the generic mask plus the left-Shift device bit
        // (0x2); with the generic mask alone the guest saw no Shift (measured).
        cgEvent.flags = modifiers.contains(.shift) ? CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | 0x2 | 0x100) : CGEventFlags(rawValue: 0x100)
        guard let event = NSEvent(cgEvent: cgEvent) else {
            throw AgentVMError.supervisorRefused("cannot make a key event")
        }
        _ = characters
        _ = window
        return event
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a background process; the window is kept for the next box view.
        NSApplication.shared.setActivationPolicy(.prohibited)
        onClose?()
    }
}

/// US keyboard key codes (the guest's layout) for what the viewer types.
enum GuestKeys {
    static let shift: UInt16 = 56

    static func key(for character: Character) -> (code: UInt16, shift: Bool)? {
        if let lower = letters[Character(character.lowercased())], character.isLetter {
            return (lower, character.isUppercase)
        }
        if let code = plain[character] {
            return (code, false)
        }
        if let code = shifted[character] {
            return (code, true)
        }
        return nil
    }

    private static let letters: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    ]
    private static let plain: [Character: UInt16] = [
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "=": 24, "-": 27, "/": 44, ".": 47, ",": 43, ";": 41, "'": 39, " ": 49, "\r": 36, "\n": 36,
    ]
    private static let shifted: [Character: UInt16] = [
        "_": 27, "+": 24, ">": 47, "<": 43, ":": 41, "\"": 39, "?": 44, "!": 18, "@": 19,
    ]
}

/// The box's screen. Virtualization gives it a tracking area of its own, which sends it pointer
/// moves (and enters and exits) while the window is key, whatever view lies on top: the shield
/// cannot catch those, so in view-only mode they stop here.
private final class BoxScreen: VZVirtualMachineView {
    var viewOnly = true

    override func mouseMoved(with event: NSEvent) {
        if !viewOnly {
            super.mouseMoved(with: event)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        if !viewOnly {
            super.mouseEntered(with: event)
        }
    }

    override func mouseExited(with event: NSEvent) {
        if !viewOnly {
            super.mouseExited(with: event)
        }
    }
}

/// Covers the screen in view-only mode: it takes clicks and keys and does nothing with them.
private final class InputShield: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        return isHidden ? nil : super.hitTest(point)
    }

    override var acceptsFirstResponder: Bool {
        return !isHidden
    }

    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func keyDown(with event: NSEvent) {}
    override func keyUp(with event: NSEvent) {}
    override func flagsChanged(with event: NSEvent) {}

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Shortcuts stop here too (the supervisor has no menu for them anyway).
        return !isHidden
    }
}

/// The supervisor as an AppKit application: a quit (a logout, for one) stops the box cleanly,
/// the way SIGTERM does, and the process ends when the guest is down.
public final class SupervisorApplicationDelegate: NSObject, NSApplicationDelegate {
    private let stop: @MainActor () -> Void

    public init(stop: @escaping @MainActor () -> Void) {
        self.stop = stop
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            stop()
        }
        return .terminateLater
    }
}
