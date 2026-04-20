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

    struct ShellShortcutHintState {
        let showProjectHints: Bool
        let showSessionHints: Bool

        var arguments: [String: Any] {
            [
                "showProjectHints": showProjectHints,
                "showSessionHints": showSessionHints,
            ]
        }
    }

    static func shellShortcutHintState(
        modifierFlags: NSEvent.ModifierFlags,
        firstResponderIsTerminal: Bool
    ) -> ShellShortcutHintState {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard firstResponderIsTerminal else {
            return ShellShortcutHintState(showProjectHints: false, showSessionHints: false)
        }
        return ShellShortcutHintState(
            showProjectHints: flags.contains(.command),
            showSessionHints: flags.contains(.control)
        )
    }

    private func pushShellShortcutHints(modifierFlags: NSEvent.ModifierFlags) {
        let hintState = Self.shellShortcutHintState(
            modifierFlags: modifierFlags,
            firstResponderIsTerminal: Self.isTerminalFocusedResponder(firstResponder)
        )
        windowChannel?.invokeMethod("setShellShortcutHints", arguments: hintState.arguments)
    }

    struct ShellShortcutPayload {
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

    static func shellShortcutPayload(
        eventType: NSEvent.EventType,
        modifierFlags: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?,
        superHandled: Bool,
        firstResponderIsTerminal: Bool
    ) -> ShellShortcutPayload? {
        guard !superHandled, firstResponderIsTerminal, eventType == .keyDown else { return nil }
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = charactersIgnoringModifiers ?? ""

        if flags == .command && chars == "n" {
            return ShellShortcutPayload(action: "newProject", index: nil)
        }
        if flags == .command && chars == "t" {
            return ShellShortcutPayload(action: "newSession", index: nil)
        }
        if flags == [.command, .shift] && chars.lowercased() == "r" {
            return ShellShortcutPayload(action: "renameCurrentSession", index: nil)
        }
        if flags == .command && chars == "r" {
            return ShellShortcutPayload(action: "renameCurrentProject", index: nil)
        }
        if flags == .command, let digit = Int(chars), (1...9).contains(digit) {
            return ShellShortcutPayload(action: "selectProjectByNumber", index: digit - 1)
        }
        if flags == .control, let digit = Int(chars), (1...9).contains(digit) {
            return ShellShortcutPayload(action: "selectSessionByNumber", index: digit - 1)
        }
        return nil
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
        let superHandled = super.performKeyEquivalent(with: event)
        if let payload = Self.shellShortcutPayload(
            eventType: event.type,
            modifierFlags: event.modifierFlags,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            superHandled: superHandled,
            firstResponderIsTerminal: Self.isTerminalFocusedResponder(firstResponder)
        ) {
            windowChannel?.invokeMethod("performShellAction", arguments: payload.arguments)
            windowChannel?.invokeMethod(
                "setShellShortcutHints",
                arguments: ["showProjectHints": false, "showSessionHints": false]
            )
            return true
        }
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
        pushShellShortcutHints(modifierFlags: event.modifierFlags)
        super.flagsChanged(with: event)
    }

    override func resignKey() {
        windowChannel?.invokeMethod(
            "setShellShortcutHints",
            arguments: ["showProjectHints": false, "showSessionHints": false]
        )
        super.resignKey()
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        pasteChannel?.invokeMethod("pasteText", arguments: ["text": text])
    }
}
