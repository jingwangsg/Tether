import Cocoa
import Carbon.HIToolbox

// C-compatible callback required by Carbon's InstallEventHandler.
// Must be a free function (not closure/method) — only free functions satisfy @convention(c).
private func carbonHotkeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    DispatchQueue.main.async {
        if NSApp.isActive {
            NSApp.hide(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { !($0 is NSPanel) })?.makeKeyAndOrderFront(nil)
        }
    }
    return noErr
}

class HotkeyManager {
    static let shared = HotkeyManager()

    private var carbonHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private init() {
        // Install Carbon event handler once for the lifetime of the app.
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotkeyHandler,
            1, &eventType, nil, &eventHandlerRef
        )
    }

    func register(hotkey: String) {
        unregister()
        guard let (keyCode, carbonMods) = parseHotkey(hotkey) else { return }

        // "TTHR" — private 4-char signature; id=1 since we only ever have one hotkey.
        let hotKeyID = EventHotKeyID(signature: OSType(0x5454_4852), id: 1)
        RegisterEventHotKey(keyCode, carbonMods, hotKeyID,
                            GetApplicationEventTarget(), 0, &carbonHotKeyRef)
    }

    func unregister() {
        if let ref = carbonHotKeyRef { UnregisterEventHotKey(ref); carbonHotKeyRef = nil }
    }

    // Parses "alt+z" → (carbonKeyCode: 6, carbonModifiers: optionKey).
    private func parseHotkey(_ s: String) -> (UInt32, UInt32)? {
        let parts = s.lowercased().split(separator: "+").map(String.init)
        var mods: UInt32 = 0
        var keyStr = ""
        for part in parts {
            switch part {
            case "cmd", "command":  mods |= UInt32(cmdKey)
            case "shift":           mods |= UInt32(shiftKey)
            case "ctrl", "control": mods |= UInt32(controlKey)
            case "alt", "option":   mods |= UInt32(optionKey)
            default:                keyStr = part
            }
        }
        guard !keyStr.isEmpty, let kc = carbonKeyCode(for: keyStr) else { return nil }
        return (kc, mods)
    }

    // US-layout physical key codes (Carbon/HIToolbox).
    private func carbonKeyCode(for key: String) -> UInt32? {
        let table: [String: UInt32] = [
            "a":0,  "s":1,  "d":2,  "f":3,  "h":4,  "g":5,
            "z":6,  "x":7,  "c":8,  "v":9,  "b":11, "q":12,
            "w":13, "e":14, "r":15, "y":16, "t":17,
            "1":18, "2":19, "3":20, "4":21, "6":22, "5":23,
            "=":24, "9":25, "7":26, "-":27, "8":28, "0":29,
            "]":30, "o":31, "u":32, "[":33, "i":34, "p":35,
            "l":37, "j":38, "'":39, "k":40, ";":41, "\\":42,
            ",":43, "/":44, "n":45, "m":46, ".":47,
            " ":49, "space":49,
        ]
        return table[key]
    }
}
