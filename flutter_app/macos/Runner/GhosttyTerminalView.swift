import AppKit
import FlutterMacOS

/// NSView embedding a ghostty_surface_t (PTY + Metal renderer).
///
/// Keyboard input is handled entirely at the AppKit level (NOT via Flutter):
///   - mouseDown: → become first responder so AppKit delivers keyDown to us
///   - keyDown: → special keys (arrows, backspace, etc.) via ghostty_surface_key()
///   - NSTextInputClient.insertText: → printable chars via ghostty_surface_text()
///
/// This mirrors Demo 3's approach and bypasses Flutter's keyboard system,
/// which does not reliably deliver events when a PlatformView has AppKit focus.
class GhosttyTerminalView: NSView {
    private let sessionId: String
    private let command: String?
    private let cwd: String?

    private(set) var surface: ghostty_surface_t?
    var eventSink: FlutterEventSink?

    private var titleObserver: NSObjectProtocol?
    private var exitObserver: NSObjectProtocol?

    // Accumulates text from NSTextInputClient.insertText() during a keyDown call.
    // nil = not inside a keyDown; [] = inside keyDown but no text yet.
    private var keyTextAccumulator: [String]? = nil

    // IME composing state: true while there is marked (pre-edit) text.
    // When composing, individual keyDown events must NOT be forwarded to the
    // terminal — only the final insertText: commit should be sent.
    private var isComposing = false

    init(sessionId: String, command: String?, cwd: String?, eventSink: FlutterEventSink? = nil) {
        self.sessionId = sessionId
        self.command = command
        self.cwd = cwd
        self.eventSink = eventSink
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, surface == nil else { return }
        createSurface()
    }

    private func createSurface() {
        guard let app = GhosttyApp.shared.app else {
            print("[GhosttyTerminalView] GhosttyApp not ready"); return
        }

        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform.macos.nsview = Unmanaged.passUnretained(self).toOpaque()
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = Double(window?.backingScaleFactor ?? 1.0)

        let isSSH = command?.hasPrefix("ssh ") ?? false
        // For SSH + remote cwd: embed cd directly in the command string.
        // Ghostty C API always runs cfg.command via /bin/bash -c "..." (embedded.zig:529-535),
        // so shell quoting is fully respected — no initial_input needed, cd is invisible.
        // Format mirrors tether-server's resolve_ssh_command.
        let effectiveCommand: String?
        if isSSH, let cwd, !cwd.isEmpty {
            let escapedCwd = cwd
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            effectiveCommand = "\(command!) -t \"cd \(escapedCwd) && exec \\$SHELL -l\""
        } else {
            effectiveCommand = command
        }
        // working_directory is local-only; SSH sessions use a remote cwd
        let effectiveCwd: String? = isSSH ? nil : cwd

        // Nest withCString closures so all C pointers are alive through ghostty_surface_new
        surface = withOptCString(effectiveCommand) { cmdPtr in
            cfg.command = cmdPtr
            return withOptCString(effectiveCwd) { cwdPtr in
                cfg.working_directory = cwdPtr
                return ghostty_surface_new(app, &cfg)
            }
        }

        guard let s = surface else {
            print("[GhosttyTerminalView] ghostty_surface_new failed"); return
        }
        ghostty_surface_set_size(s, UInt32(bounds.width), UInt32(bounds.height))
        GhosttyApp.shared.registerSurface(s)
        ghostty_surface_draw(s)  // render initial frame
        observeNotifications()
    }

    /// Calls body(ptr) with a C string pointer for s, or body(nil) when s is nil/empty.
    private func withOptCString<T>(_ s: String?, body: (UnsafePointer<CChar>?) -> T) -> T {
        guard let s, !s.isEmpty else { return body(nil) }
        return s.withCString(body)
    }

    private func observeNotifications() {
        titleObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyTitleChanged, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let surfacePtr = note.userInfo?["surface"] as? OpaquePointer,
                  OpaquePointer(self.surface) == surfacePtr,
                  let title = note.userInfo?["title"] as? String
            else { return }
            self.eventSink?(["type": "title", "value": title])
        }

        exitObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyChildExited, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            if let surfacePtr = note.userInfo?["surface"] as? OpaquePointer {
                guard OpaquePointer(self.surface) == surfacePtr else { return }
            }
            self.eventSink?(["type": "exited"])
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let s = surface, newSize.width > 0, newSize.height > 0 else { return }
        ghostty_surface_set_size(s, UInt32(newSize.width), UInt32(newSize.height))
        ghostty_surface_draw(s)
    }

    // layout() is called by AppKit after the layout pass completes — bounds are final here.
    // This catches the case where setFrameSize fires before the surface exists (surface is nil
    // → setFrameSize is a no-op), so the surface gets its first correct size from layout().
    override func layout() {
        super.layout()
        guard let s = surface, bounds.width > 0, bounds.height > 0 else { return }
        ghostty_surface_set_size(s, UInt32(bounds.width), UInt32(bounds.height))
        ghostty_surface_draw(s)
        inputContext?.invalidateCharacterCoordinates()
    }

    // MARK: - AppKit keyboard handling

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard let s = surface else { return }
        let action: ghostty_input_action_e = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        self.interpretKeyEvents([event])

        if let list = keyTextAccumulator, !list.isEmpty {
            isComposing = false  // IME committed
            for text in list {
                _ = sendKeyEvent(s, action: action, event: event, text: text)
            }
        } else if !isComposing {
            // Skip while IME has marked text — individual key presses are
            // buffered by the IME and will be delivered via insertText: on commit.
            _ = sendKeyEvent(s, action: action, event: event, text: ghosttyCharacters(event))
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let s = surface else { return }
        _ = sendKeyEvent(s, action: GHOSTTY_ACTION_RELEASE, event: event, text: nil)
    }

    override func doCommand(by selector: Selector) {
        // Prevent NSBeep for unhandled commands (e.g. arrow keys, escape)
    }

    private func sendKeyEvent(_ s: ghostty_surface_t,
                              action: ghostty_input_action_e,
                              event: NSEvent,
                              text: String?) -> Bool {
        var ev = ghostty_input_key_s()
        ev.action = action
        ev.keycode = UInt32(event.keyCode)
        ev.mods = modsFromEvent(event)
        // consumed_mods: everything except control and command (per Ghostty source)
        let flags = event.modifierFlags
        var consumedRaw: UInt32 = 0
        if flags.contains(.shift)  { consumedRaw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.option) { consumedRaw |= GHOSTTY_MODS_ALT.rawValue }
        ev.consumed_mods = ghostty_input_mods_e(rawValue: consumedRaw)
        // unshifted_codepoint: char with no modifiers applied
        if #available(macOS 10.15, *) {
            if let chars = event.characters(byApplyingModifiers: []),
               let cp = chars.unicodeScalars.first {
                ev.unshifted_codepoint = cp.value
            }
        }
        ev.composing = false

        // Only attach text if first byte >= 0x20 (non-control, non-PUA)
        if let t = text, !t.isEmpty,
           let first = t.utf8.first, first >= 0x20 {
            return t.withCString { ptr in
                ev.text = ptr
                return ghostty_surface_key(s, ev)
            }
        } else {
            ev.text = nil
            return ghostty_surface_key(s, ev)
        }
    }

    /// Equivalent of Ghostty's NSEvent.ghosttyCharacters — returns text for printable keys.
    /// Returns nil for PUA function keys (arrows, F-keys). Returns stripped text for control chars.
    private func ghosttyCharacters(_ event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                if #available(macOS 10.15, *) {
                    return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
                }
                return nil
            }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return nil }
        }
        return characters
    }

    private func modsFromEvent(_ event: NSEvent) -> ghostty_input_mods_e {
        let flags = event.modifierFlags
        var raw: UInt32 = 0
        if flags.contains(.shift)   { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option)  { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
    }

    // MARK: - MethodChannel input (paste from Flutter PasteService)

    func sendText(_ text: String) {
        guard let s = surface else { return }
        ghostty_surface_text(s, text, UInt(text.utf8.count))
    }

    func setActive(_ active: Bool) {
        guard let s = surface else { return }
        GhosttyApp.shared.setSurfaceDrawable(s, drawable: active)
    }

    func setEventSink(_ sink: FlutterEventSink?) {
        eventSink = sink
    }

    // MARK: - Cleanup

    deinit {
        titleObserver.map { NotificationCenter.default.removeObserver($0) }
        exitObserver.map  { NotificationCenter.default.removeObserver($0) }
        surface.map { GhosttyApp.shared.unregisterSurface($0) }
        surface.map { ghostty_surface_free($0) }
    }
}

// MARK: - NSTextInputClient (printable characters + IME)
extension GhosttyTerminalView: NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let chars: String
        if let attr = string as? NSAttributedString { chars = attr.string }
        else if let str = string as? String { chars = str }
        else { return }

        // If called during keyDown, accumulate for key event
        if keyTextAccumulator != nil {
            keyTextAccumulator!.append(chars)
            return
        }
        // Otherwise: direct programmatic insertion (paste, IME)
        guard let s = surface else { return }
        ghostty_surface_text(s, chars, UInt(chars.utf8.count))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let str: String
        if let attr = string as? NSAttributedString { str = attr.string }
        else if let s = string as? String { str = s }
        else { return }
        isComposing = !str.isEmpty
    }
    func unmarkText() { isComposing = false }
    func selectedRange() -> NSRange { .init(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { .init(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { isComposing }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        // Return the view's bottom-left corner in screen coordinates.
        // This gives the IMK a valid mach port target for its candidate window,
        // preventing the "error messaging the mach port for IMKCFRunLoopWakeUpReliable" log.
        guard let window = window else { return .zero }
        let localRect = NSRect(x: 0, y: 0, width: 0, height: 0)
        let windowRect = convert(localRect, to: nil)
        return window.convertToScreen(windowRect)
    }
    func characterIndex(for point: NSPoint) -> Int { 0 }
}
