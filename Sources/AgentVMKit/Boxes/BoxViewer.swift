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
    private var window: NSWindow?
    private var screen: BoxScreen?
    private var shield: InputShield?

    init(name: String, machine: MacMachine) {
        self.name = name
        self.machine = machine
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
        self.window = window
        self.screen = screen
        self.shield = shield
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a background process; the window is kept for the next box view.
        NSApplication.shared.setActivationPolicy(.prohibited)
    }
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
