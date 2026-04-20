import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
    private var pasteChannel: FlutterMethodChannel?
    private var windowChannel: FlutterMethodChannel?

    static func shouldUsePasteChannelFallback(
        eventType: NSEvent.EventType,
        modifierFlags: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?,
        superHandled: Bool
    ) -> Bool {
        guard !superHandled, eventType == .keyDown else { return false }
        return modifierFlags.intersection(.deviceIndependentFlagsMask) == .command &&
            charactersIgnoringModifiers == "v"
    }

    static func isTerminalFocusedResponder(_ responder: NSResponder?) -> Bool {
        responder is TerminalShortcutFocusable
    }

    static func isEditableTextResponder(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        if let textView = responder as? NSTextView {
            return textView.isFieldEditor || textView.isEditable
        }
        return responder is NSText
    }

    struct DesktopShortcutHintState {
        let showProjectHints: Bool
        let showSessionHints: Bool

        var arguments: [String: Any] {
            [
                "showProjectHints": showProjectHints,
                "showSessionHints": showSessionHints,
            ]
        }
    }

    static func desktopShortcutHintState(
        modifierFlags: NSEvent.ModifierFlags,
        firstResponder: NSResponder?,
        hasAttachedSheet: Bool
    ) -> DesktopShortcutHintState {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        let canShowHints = !hasAttachedSheet && !isEditableTextResponder(firstResponder)
        guard canShowHints else {
            return DesktopShortcutHintState(showProjectHints: false, showSessionHints: false)
        }
        return DesktopShortcutHintState(
            showProjectHints: flags.contains(.command),
            showSessionHints: flags.contains(.control)
        )
    }

    private func pushDesktopShortcutHints(modifierFlags: NSEvent.ModifierFlags) {
        let hintState = Self.desktopShortcutHintState(
            modifierFlags: modifierFlags,
            firstResponder: firstResponder,
            hasAttachedSheet: attachedSheet != nil
        )
        windowChannel?.invokeMethod("setShellShortcutHints", arguments: hintState.arguments)
    }

    private func clearDesktopShortcutHints() {
        windowChannel?.invokeMethod(
            "setShellShortcutHints",
            arguments: ["showProjectHints": false, "showSessionHints": false]
        )
    }

    struct DesktopActionPayload: Equatable {
        let action: String
        let index: Int?

        var arguments: [String: Any] {
            var value: [String: Any] = ["action": action]
            if let index {
                value["index"] = index
            }
            return value
        }
    }

    enum DesktopShortcutRouting: Equatable {
        case dispatch(DesktopActionPayload)
        case suppress
        case ignore
    }

    static func desktopActionPayload(
        eventType: NSEvent.EventType,
        modifierFlags: NSEvent.ModifierFlags,
        characters: String?,
        charactersIgnoringModifiers: String?
    ) -> DesktopActionPayload? {
        guard eventType == .keyDown else { return nil }
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = charactersIgnoringModifiers?.lowercased() ?? ""
        let typedChars = characters?.lowercased() ?? ""

        if flags == [.command, .shift] {
            if chars == "r" {
                return DesktopActionPayload(action: "renameCurrentSession", index: nil)
            }
            if chars == "=" || typedChars == "+" {
                return DesktopActionPayload(action: "increaseFontSize", index: nil)
            }
        }

        if flags == .command {
            if chars == "n" {
                return DesktopActionPayload(action: "newProject", index: nil)
            }
            if chars == "t" {
                return DesktopActionPayload(action: "newSession", index: nil)
            }
            if chars == "w" {
                return DesktopActionPayload(action: "closeCurrentSession", index: nil)
            }
            if chars == "r" {
                return DesktopActionPayload(action: "renameCurrentProject", index: nil)
            }
            if chars == "f" {
                return DesktopActionPayload(action: "showSearch", index: nil)
            }
            if chars == "b" {
                return DesktopActionPayload(action: "toggleSidebar", index: nil)
            }
            if chars == "=" || typedChars == "+" {
                return DesktopActionPayload(action: "increaseFontSize", index: nil)
            }
            if chars == "-" {
                return DesktopActionPayload(action: "decreaseFontSize", index: nil)
            }
            if chars == "0" {
                return DesktopActionPayload(action: "resetFontSize", index: nil)
            }
            if let digit = Int(chars), (1...9).contains(digit) {
                return DesktopActionPayload(action: "selectProjectByNumber", index: digit - 1)
            }
        }

        if flags == .control, let digit = Int(chars), (1...9).contains(digit) {
            return DesktopActionPayload(action: "selectSessionByNumber", index: digit - 1)
        }

        return nil
    }

    static func desktopShortcutRouting(
        eventType: NSEvent.EventType,
        modifierFlags: NSEvent.ModifierFlags,
        characters: String?,
        charactersIgnoringModifiers: String?,
        firstResponder: NSResponder?,
        hasAttachedSheet: Bool
    ) -> DesktopShortcutRouting {
        guard let payload = desktopActionPayload(
            eventType: eventType,
            modifierFlags: modifierFlags,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers
        ) else {
            return .ignore
        }

        if hasAttachedSheet || isEditableTextResponder(firstResponder) {
            return .suppress
        }

        return .dispatch(payload)
    }

    override func awakeFromNib() {
        let flutterViewController = FlutterViewController()
        let windowFrame = self.frame
        self.contentViewController = flutterViewController
        self.setFrame(windowFrame, display: true)

        RegisterGeneratedPlugins(registry: flutterViewController)

        // Register TerminalPlugin (PlatformView factory + input channel)
        TerminalApp.shared.setup()
        TerminalPlugin.register(with: flutterViewController.registrar(forPlugin: "TerminalPlugin"))

        // Paste channel: forwards Cmd+V / paste: selector to Dart
        pasteChannel = FlutterMethodChannel(
            name: "dev.tether/paste",
            binaryMessenger: flutterViewController.engine.binaryMessenger
        )

        // Window channel: global hotkey management
        windowChannel = FlutterMethodChannel(
            name: "dev.tether/window",
            binaryMessenger: flutterViewController.engine.binaryMessenger
        )
        windowChannel?.setMethodCallHandler { call, result in
            switch call.method {
            case "setGlobalHotkey":
                if let args = call.arguments as? [String: Any],
                   let hotkey = args["hotkey"] as? String {
                    HotkeyManager.shared.register(hotkey: hotkey)
                }
                result(nil)
            case "clearGlobalHotkey":
                HotkeyManager.shared.unregister()
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        super.awakeFromNib()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        switch Self.desktopShortcutRouting(
            eventType: event.type,
            modifierFlags: event.modifierFlags,
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            firstResponder: firstResponder,
            hasAttachedSheet: attachedSheet != nil
        ) {
        case .dispatch(let payload):
            windowChannel?.invokeMethod("performDesktopAction", arguments: payload.arguments)
            clearDesktopShortcutHints()
            return true
        case .suppress:
            clearDesktopShortcutHints()
            return true
        case .ignore:
            break
        }

        let superHandled = super.performKeyEquivalent(with: event)
        if Self.shouldUsePasteChannelFallback(
            eventType: event.type,
            modifierFlags: event.modifierFlags,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            superHandled: superHandled
        ) {
            if let text = NSPasteboard.general.string(forType: .string) {
                pasteChannel?.invokeMethod("pasteText", arguments: ["text": text])
                return true
            }
        }
        return superHandled
    }

    override func flagsChanged(with event: NSEvent) {
        pushDesktopShortcutHints(modifierFlags: event.modifierFlags)
        super.flagsChanged(with: event)
    }

    override func resignKey() {
        clearDesktopShortcutHints()
        super.resignKey()
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        pasteChannel?.invokeMethod("pasteText", arguments: ["text": text])
    }
}
