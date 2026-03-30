import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
    private var pasteChannel: FlutterMethodChannel?

    override func awakeFromNib() {
        let flutterViewController = FlutterViewController()
        let windowFrame = self.frame
        self.contentViewController = flutterViewController
        self.setFrame(windowFrame, display: true)

        RegisterGeneratedPlugins(registry: flutterViewController)

        // Initialize ghostty and register plugin
        GhosttyApp.shared.setup()
        GhosttyPlugin.register(with: flutterViewController.registrar(forPlugin: "GhosttyPlugin"))

        pasteChannel = FlutterMethodChannel(
            name: "dev.tether/paste",
            binaryMessenger: flutterViewController.engine.binaryMessenger
        )

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
}
