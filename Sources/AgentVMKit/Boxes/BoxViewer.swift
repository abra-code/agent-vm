// Sources/AgentVMKit/Boxes/BoxViewer.swift
//
// A window on a box's screen (`agent-vm box view`), shown by the box's supervisor: the virtual
// machine lives in that process, and Virtualization draws a machine only in a view of the same
// process. View only unless asked otherwise: a clear layer over the screen takes every key and
// click, so looking cannot change anything in the box. Closing the window leaves the box
// running. The supervisor has no Dock icon and no menu, so nothing in the window can quit it
// (quitting would pull the plug on the guest). The Send button copies files or folders from
// this Mac into the guest account's Downloads folder (GuestSend), in either mode: it is not
// input to the guest's screen. So do the two clipboard buttons of a box's window, which copy
// text between this Mac's clipboard and the box user's, one click at a time (GuestClipboard).
//
// The window can be resized and made full screen. A view-only window scales the screen and
// keeps its shape, so looking still changes nothing. An interactive one gives the guest's
// display its own size once a resize ends, one pixel per point as at the 1280 by 800 start, so
// the desktop gets the room and its text keeps its size (a Linux desktop cannot tell it is on a
// Retina screen: its display reports no physical size, measured). Closing the window gives the
// display back its start size, so a box nobody looks at is as every start leaves it.
//
// Only a supervisor in a login session can show windows: one started over SSH or by a service
// has no window server, and runs without AppKit.

import AppKit
import CoreGraphics
import Virtualization

@MainActor
final class BoxViewer: NSObject, NSWindowDelegate {
    private let name: String
    /// What the window shows: "box", or "image" for `image setup` and `image view`.
    private let kind: String
    private let machine: GuestMachine
    /// The guest's system: what the Send button packs with, and how the guest unpacks it.
    private let guest: GuestKind
    /// Gives the guest account's password, typed by the Type Password button (interactive
    /// only). Asked when the button is pressed, away from the main actor: read from the
    /// Keychain, it can wait for the person's answer to a question from macOS.
    private let password: (@Sendable () throws -> String)?
    /// A line of instructions under the title bar.
    private let note: String?
    private let onClose: (@MainActor () -> Void)?
    /// Where sends are recorded (the supervisor's or the image build's log).
    private let log: (@MainActor (String) -> Void)?
    /// Told of each file or folder the Send button copied into the guest.
    private let sent: (@MainActor (BoxEventLog.Item) -> Void)?
    /// The box user's clipboard, for the clipboard buttons; nil for a window without them (an
    /// image's).
    private let clipboard: GuestClipboard?
    private var window: NSWindow?
    private var screen: BoxScreen?
    private var shield: InputShield?
    private var typeButton: NSButton?
    private var sendButton: NSButton?
    private var noteLabel: NSTextField?
    private var sendLabel: NSTextField?
    private var clipboardButtons: [NSButton] = []
    /// A clipboard button's copy is under way: neither button starts another meanwhile.
    private var copyingClipboard = false
    /// The send under way, if any; its button then stops it.
    private var currentSend: GuestSend?
    /// Sends are under way (set before the first one starts, so the button never opens a
    /// second panel meanwhile).
    private var sending = false
    /// Stop was pressed or the window closed: no further item starts.
    private var stopRequested = false
    /// The fit of window and display waiting for a resize to settle (fitSoon).
    private var pendingFit: Task<Void, Never>?
    /// A move into or out of full screen is under way: its intermediate sizes are not fitted.
    private var changingFullScreen = false
    /// The next fit gives a view-only window the display's shape: after it was shown or left
    /// full screen, not after a resize the person made (a window tiled to half the screen stays).
    private var reshapePending = false
    /// This window gave the display a size other than the start size, which closing it gives
    /// back. A window that never did changes nothing when it closes.
    private var gaveSize = false

    /// The guest display's size at every start, which closing the window gives back.
    static let startSize = CGSize(width: MacMachineSpec.displayWidth, height: MacMachineSpec.displayHeight)
    /// The smallest content of the window, and so the smallest display it gives the guest.
    static let minimumSize = NSSize(width: 800, height: 500)

    init(name: String, kind: String = "box", machine: GuestMachine, guest: GuestKind = .macOS, password: (@Sendable () throws -> String)? = nil, note: String? = nil, onClose: (@MainActor () -> Void)? = nil,
         log: (@MainActor (String) -> Void)? = nil, sent: (@MainActor (BoxEventLog.Item) -> Void)? = nil, clipboard: GuestClipboard? = nil) {
        self.clipboard = clipboard
        self.sent = sent
        self.name = name
        self.kind = kind
        self.machine = machine
        self.guest = guest
        self.password = password
        self.note = note
        self.onClose = onClose
        self.log = log
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
        window.title = Self.title(kind: kind, name: name, interactive: interactive)
        // Any shape for an interactive window, whose size the display takes (the increments
        // clear the aspect ratio); a view-only one gets the display's shape back in fit().
        if interactive {
            window.contentResizeIncrements = NSSize(width: 1, height: 1)
        }
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
        fitSoon(reshaping: true)
    }

    private func makeWindow() -> NSWindow {
        let size = machine.displaySize ?? Self.startSize
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        let screen = BoxScreen(frame: content.bounds)
        machine.attach(screen)
        content.addSubview(screen)
        let shield = InputShield(frame: content.bounds)
        content.addSubview(shield)
        // Virtualization's view turns its autoresizing mask off (measured), so a mask kept the
        // screen at its first size whatever the window did: constraints hold both to the content.
        for view in [screen, shield] {
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                view.topAnchor.constraint(equalTo: content.topAnchor),
                view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.contentView = content
        window.contentMinSize = Self.minimumSize
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.addTitlebarAccessoryViewController(makeAccessory())
        // The bar under the title takes its height from the content (measured): give it back,
        // so the screen starts at its own size.
        window.setContentSize(size)
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

    /// Fits window and display to each other once resizing has settled: a full-screen change
    /// reports several sizes, and a drag is fitted when it ends.
    private func fitSoon(reshaping: Bool = false) {
        if reshaping {
            reshapePending = true
        }
        pendingFit?.cancel()
        pendingFit = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else {
                return
            }
            self?.fit()
        }
    }

    /// An interactive window gives the guest's display its size; a view-only one keeps the
    /// display's shape when resized, and takes it when reshapePending says so, unless it fills a
    /// screen. A closed window fits nothing: one closed in full screen leaves it after
    /// windowWillClose gave the display back (measured).
    private func fit() {
        guard let window, window.isVisible, let content = window.contentView, let screen, !changingFullScreen, !window.inLiveResize,
              let display = machine.displaySize else {
            return
        }
        let reshape = reshapePending
        reshapePending = false
        let size = content.bounds.size
        if !screen.viewOnly {
            let wanted = CGSize(width: size.width.rounded(.down), height: size.height.rounded(.down))
            if wanted != display {
                resizeScreen(wanted)
            }
        } else if !window.styleMask.contains(.fullScreen) {
            window.contentAspectRatio = display
            if reshape, let frame = Self.frame(window.frame, content: size, shapedLike: display, visible: window.screen?.visibleFrame) {
                window.setFrame(frame, display: true)
            }
        }
    }

    private func resizeScreen(_ size: CGSize) {
        do {
            try machine.resizeDisplay(size)
            gaveSize = size != Self.startSize
            log?("Screen: \(Int(size.width)) by \(Int(size.height))")
        } catch {
            log?("Screen: \(error)")
        }
    }

    /// The frame that gives a window's `content` the shape of `display`: the width and the top
    /// edge stay, unless the new height would not fit in `visible`, which then sets it, with the
    /// bottom edge kept on `visible`. Nil when the shape is already right.
    static func frame(_ frame: NSRect, content: NSSize, shapedLike display: CGSize, visible: NSRect?) -> NSRect? {
        guard display.width > 0, display.height > 0, content.width > 0 else {
            return nil
        }
        // The title bar and the bar under it.
        let chrome = frame.height - content.height
        var size = NSSize(width: content.width, height: (content.width * display.height / display.width).rounded())
        if let visible, size.height + chrome > visible.height {
            size.height = visible.height - chrome
            size.width = (size.height * display.width / display.height).rounded()
        }
        guard abs(size.width - content.width) >= 1 || abs(size.height - content.height) >= 1 else {
            return nil
        }
        var shaped = NSRect(x: frame.minX, y: frame.maxY - size.height - chrome, width: size.width, height: size.height + chrome)
        if let visible, shaped.minY < visible.minY {
            shaped.origin.y = visible.minY
        }
        return shaped
    }

    /// Under the title bar: at the left the note and Type Password, which the note speaks of;
    /// at the right what a send or a clipboard button did, the clipboard buttons and Send.
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
        // Takes the room between the two groups, so Send stays at the trailing edge.
        let space = NSView()
        space.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        space.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        bar.addArrangedSubview(space)
        let sending = NSTextField(labelWithString: "")
        sending.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        sending.lineBreakMode = .byTruncatingMiddle
        sending.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sending.isHidden = true
        bar.addArrangedSubview(sending)
        sendLabel = sending
        if clipboard != nil {
            clipboardButtons = [
                Self.barButton("Send Clipboard", symbol: "arrow.right.doc.on.clipboard", target: self, action: #selector(clipboardToBox(_:)),
                               toolTip: "Puts the text on this Mac's clipboard on the clipboard in the box"),
                Self.barButton("Get Clipboard", symbol: "doc.on.clipboard", target: self, action: #selector(clipboardFromBox(_:)),
                               toolTip: "Puts the text on the clipboard in the box on this Mac's clipboard, with control and invisible characters removed"),
            ]
            clipboardButtons.forEach(bar.addArrangedSubview)
        }
        let send = NSButton(title: Self.sendTitle, target: self, action: #selector(sendFiles(_:)))
        send.controlSize = .small
        send.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        send.toolTip = "Copies files or folders from this Mac into the Downloads folder in the box. Nothing there is replaced: a name in use gets a number."
        send.setContentHuggingPriority(.required, for: .horizontal)
        send.image = NSImage(systemSymbolName: "arrow.up.doc", accessibilityDescription: nil)
        send.imagePosition = .imageLeading
        bar.addArrangedSubview(send)
        sendButton = send
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = bar
        accessory.layoutAttribute = .bottom
        return accessory
    }

    /// A small button of the bar under the title bar, with a symbol before its title.
    private static func barButton(_ title: String, symbol: String, target: AnyObject, action: Selector, toolTip: String) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        button.toolTip = toolTip
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        return button
    }

    /// "AgentVM box - work", "AgentVM image - dev"; a window that takes no keys says so.
    static func title(kind: String, name: String, interactive: Bool) -> String {
        return "AgentVM \(kind) - \(name)\(interactive ? "" : " (view only)")"
    }

    /// Whether keys and clicks reach the guest (the window was last shown interactive).
    var isInteractive: Bool {
        return screen.map { !$0.viewOnly } ?? false
    }

    /// Replaces the note under the title bar (a window made with a note).
    func setNote(_ text: String) {
        noteLabel?.stringValue = text
    }

    static let sendTitle = "Send..."

    /// Send: picks files or folders on this Mac and sends them; while a send runs, stops it.
    @objc private func sendFiles(_ sender: Any?) {
        if sending {
            stopSending()
            return
        }
        guard let window else {
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Send"
        panel.message = "Select files or folders to copy to Downloads in \(kind == "box" ? name : "\(kind) \(name)")"
        panel.beginSheetModal(for: window) { [weak self] response in
            let urls = panel.urls
            MainActor.assumeIsolated {
                if response == .OK, !urls.isEmpty {
                    self?.send(urls)
                }
            }
        }
    }

    private func stopSending() {
        guard sending else {
            return
        }
        stopRequested = true
        currentSend?.cancel()
    }

    /// Sends each of `urls` in turn, on a fresh connection to the guest daemon; a failure or a
    /// stop ends the rest.
    private func send(_ urls: [URL]) {
        sending = true
        stopRequested = false
        sendButton?.title = "Stop Sending"
        Task { @MainActor in
            defer {
                currentSend = nil
                sending = false
                sendButton?.title = Self.sendTitle
            }
            for (index, url) in urls.enumerated() where !stopRequested {
                let item = url.lastPathComponent
                let what = urls.count > 1 ? "\(item) (\(index + 1) of \(urls.count))" : item
                let sender = GuestSend(source: url, guest: guest)
                currentSend = sender
                setSendStatus("Sending \(what)")
                do {
                    let connection = try await machine.connect(toPort: GuestProtocol.port)
                    defer { connection.close() }
                    let descriptor = connection.descriptor
                    let received = try await Task.detached {
                        try sender.run(descriptor: descriptor) { event in
                            Task { @MainActor in
                                self.show(event, of: sender, what: what)
                            }
                        }
                    }.value
                    currentSend = nil
                    let renamed = received == item ? "" : " as \(received)"
                    setSendStatus("Sent \(what) to Downloads\(renamed)")
                    log?("Send: \(url.path) to Downloads\(renamed)")
                    sent?(BoxEventLog.Item(name: item, received: received == item ? nil : received, bytes: BoxEventLog.fileSize(url.path)))
                } catch {
                    currentSend = nil
                    if sender.isCanceled {
                        let detail = (error as? GuestSend.Failure)?.message == "stopped" ? "" : " (\(error))"
                        setSendStatus("Stopped sending \(what)\(detail)")
                        log?("Send: \(url.path) stopped\(detail)")
                    } else {
                        setSendStatus("Could not send \(what): \(error)", failed: true)
                        log?("Send: \(url.path) failed: \(error)")
                    }
                    return
                }
            }
        }
    }

    /// A send's progress, if that send is still the current one (events arrive out of order
    /// with the send's end).
    private func show(_ event: GuestSend.Event, of sender: GuestSend, what: String) {
        guard currentSend === sender else {
            return
        }
        switch event {
        case let .progress(sent, total):
            setSendStatus("Sending \(what): \(GuestSend.byteCount(sent)) of \(GuestSend.byteCount(max(total, sent)))")
        case let .waiting(service):
            let click = isInteractive ? "" : " (the window is view only: open it with --interactive to answer)"
            setSendStatus("Sending \(what): waiting for access to \(service); answer the prompt in the box\(click)", failed: true)
        }
    }

    private func setSendStatus(_ text: String, failed: Bool = false) {
        sendLabel?.stringValue = text
        sendLabel?.textColor = failed ? .systemRed : .secondaryLabelColor
        sendLabel?.toolTip = text
        sendLabel?.isHidden = text.isEmpty
    }

    /// Send Clipboard: the text on this Mac's clipboard goes on the box user's clipboard.
    @objc private func clipboardToBox(_ sender: Any?) {
        guard let clipboard, !copyingClipboard else {
            return
        }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            setSendStatus("This Mac's clipboard has no text", failed: true)
            return
        }
        copyClipboard("Clipboard to box") {
            try await clipboard.put(text)
            return "copied \(Self.characters(text)) to the clipboard in the box"
        }
    }

    /// Get Clipboard: the text on the box user's clipboard goes on this Mac's clipboard.
    @objc private func clipboardFromBox(_ sender: Any?) {
        guard let clipboard, !copyingClipboard else {
            return
        }
        copyClipboard("Clipboard from box") {
            let text = try await clipboard.text()
            guard !text.isEmpty else {
                throw GuestClipboard.Failure(description: "the clipboard in the box has no text")
            }
            GuestClipboard.putOnMac(text)
            return "copied \(Self.characters(text)) to this Mac's clipboard"
        }
    }

    /// Runs one clipboard button's copy, with both buttons off until it ends, and says how it
    /// went in the window and the log (never the text).
    private func copyClipboard(_ what: String, _ body: @escaping @MainActor () async throws -> String) {
        copyingClipboard = true
        clipboardButtons.forEach { $0.isEnabled = false }
        Task { @MainActor in
            defer {
                copyingClipboard = false
                clipboardButtons.forEach { $0.isEnabled = true }
            }
            do {
                let done = try await body()
                setSendStatus("\(what): \(done)")
                log?("\(what): \(done)")
            } catch {
                setSendStatus("\(what): \(error)", failed: true)
                log?("\(what): \(error)")
            }
        }
    }

    /// "1 character", "42 characters".
    nonisolated static func characters(_ text: String) -> String {
        return text.count == 1 ? "1 character" : "\(text.count) characters"
    }

    @objc private func typePassword(_ sender: Any?) {
        guard let password else {
            return
        }
        Task { @MainActor in
            do {
                try await self.type(try await Task.detached { try password() }.value)
            } catch {
                self.log?("Type Password: \(error)")
                self.setSendStatus("Type Password: \(error)", failed: true)
            }
        }
    }

    /// Types `text` into the guest as key presses on a US keyboard (the guest's layout), into
    /// whatever has the focus there. Letters, digits, space, return and a few punctuation marks.
    func type(_ text: String) async throws {
        guard let window, let screen else {
            throw AgentVMError.supervisorRefused("the window of \(kind) \(name) is not open")
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
                throw AgentVMError.supervisorRefused("cannot type \"\(character)\" into \(kind) \(name)")
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

    func windowDidResize(_ notification: Notification) {
        // A drag is fitted when it ends; other resizes (the zoom button, a double click on the
        // title bar) at once.
        if window?.inLiveResize == false {
            fitSoon()
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        fitSoon()
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        changingFullScreen = true
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        changingFullScreen = false
        fitSoon()
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        changingFullScreen = false
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        changingFullScreen = true
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        changingFullScreen = false
        fitSoon(reshaping: true)
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        changingFullScreen = false
    }

    func windowWillClose(_ notification: Notification) {
        pendingFit?.cancel()
        pendingFit = nil
        // Nobody looks any more: a display this window resized goes back to the size every start
        // gives it.
        if gaveSize {
            resizeScreen(Self.startSize)
        }
        // Nobody sees a send's progress or its Stop button any more (and closing an image setup
        // window shuts the guest down): stop it.
        stopSending()
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
