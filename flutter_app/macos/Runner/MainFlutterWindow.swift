import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
    private var pasteChannel: FlutterMethodChannel?
    private var windowChannel: FlutterMethodChannel?

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
        if event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "v" {
            if let text = NSPasteboard.general.string(forType: .string) {
                pasteChannel?.invokeMethod("pasteText", arguments: ["text": text])
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        pasteChannel?.invokeMethod("pasteText", arguments: ["text": text])
    }
}
