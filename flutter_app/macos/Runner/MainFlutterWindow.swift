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

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        pasteChannel?.invokeMethod("pasteText", arguments: ["text": text])
    }
}
