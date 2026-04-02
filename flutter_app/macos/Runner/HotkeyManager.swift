import Cocoa
import ApplicationServices

class HotkeyManager {
    static let shared = HotkeyManager()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var pendingHotkey: String?

    private init() {
        // Re-register the global monitor when Accessibility permission is granted
        // while the app is already running (user visits System Settings mid-session).
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(accessibilityChanged),
            name: NSNotification.Name("com.apple.accessibility.api"),
            object: nil
        )
    }

    @objc private func accessibilityChanged() {
        if AXIsProcessTrusted(), let hotkey = pendingHotkey {
            register(hotkey: hotkey)
        }
    }

    func register(hotkey: String) {
        unregister()
        pendingHotkey = hotkey
        guard let (modifiers, key) = parseHotkey(hotkey) else { return }

        // Global monitor requires Accessibility permission.
        // Pass prompt=true so macOS shows the system dialog if not yet granted.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true as AnyObject] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts) {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard self?.matches(event, modifiers: modifiers, key: key) == true else { return }
                DispatchQueue.main.async {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first(where: { !($0 is NSPanel) })?.makeKeyAndOrderFront(nil)
                }
            }
        }

        // Local monitor (hide while app is focused) works without Accessibility.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard self?.matches(event, modifiers: modifiers, key: key) == true else { return event }
            NSApp.hide(nil)
            return nil  // consume event
        }
    }

    func unregister() {
        pendingHotkey = nil
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor  { NSEvent.removeMonitor(m); localMonitor  = nil }
    }

    private func matches(_ event: NSEvent, modifiers: NSEvent.ModifierFlags, key: String) -> Bool {
        let eventMods = event.modifierFlags.intersection([.command, .shift, .control, .option])
        let eventKey  = event.charactersIgnoringModifiers?.lowercased() ?? ""
        return eventMods == modifiers && eventKey == key
    }

    // Parses "cmd+shift+t" → (ModifierFlags, "t")
    private func parseHotkey(_ s: String) -> (NSEvent.ModifierFlags, String)? {
        let parts = s.lowercased().split(separator: "+").map(String.init)
        var modifiers: NSEvent.ModifierFlags = []
        var key = ""
        for part in parts {
            switch part {
            case "cmd", "command":   modifiers.insert(.command)
            case "shift":            modifiers.insert(.shift)
            case "ctrl", "control":  modifiers.insert(.control)
            case "alt", "option":    modifiers.insert(.option)
            case "space":            key = " "
            default:                 key = part
            }
        }
        return key.isEmpty ? nil : (modifiers, key)
    }
}
