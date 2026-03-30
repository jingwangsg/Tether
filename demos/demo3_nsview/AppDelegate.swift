// Demo 3 — Ghostty terminal in a standalone AppKit window (Ghostty v1.3.1)
// Build: ./build.sh
import AppKit

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var termView: GhosttyNSView!

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        GhosttyApp.shared.setup()

        let rect = NSRect(x: 100, y: 100, width: 800, height: 600)
        window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Demo 3 — Ghostty NSView"

        termView = GhosttyNSView()
        window.contentView = termView

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
