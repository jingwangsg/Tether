import Foundation
import AppKit

// Minimal GhosttyApp singleton for demo3 (Ghostty v1.3.1 API)
class GhosttyApp {
    static let shared = GhosttyApp()
    private(set) var app: ghostty_app_t?

    private init() {}

    func setup() {
        guard app == nil else { return }

        let initResult = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard initResult == GHOSTTY_SUCCESS else {
            print("[GhosttyApp] ghostty_init failed: \(initResult)")
            return
        }

        guard let cfg = ghostty_config_new() else {
            print("[GhosttyApp] ghostty_config_new failed")
            return
        }
        ghostty_config_load_default_files(cfg)
        ghostty_config_finalize(cfg)

        var rtCfg = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: { _ in },
            action_cb: { app, target, action in
                print("[GhosttyApp] action tag=\(action.tag.rawValue)")
                return true
            },
            read_clipboard_cb: { _, loc, state in
                guard loc == GHOSTTY_CLIPBOARD_STANDARD else { return false }
                guard let str = NSPasteboard.general.string(forType: .string) else { return false }
                str.withCString { cStr in
                    ghostty_surface_complete_clipboard_request(nil, cStr, state, false)
                }
                return true
            },
            confirm_read_clipboard_cb: { _, _, _, _ in },
            write_clipboard_cb: { _, loc, content, len, confirm in
                guard loc == GHOSTTY_CLIPBOARD_STANDARD,
                      let content = content, len > 0 else { return }
                for i in 0..<len {
                    let item = content[i]
                    guard let mime = item.mime, String(cString: mime) == "text/plain",
                          let data = item.data else { continue }
                    let text = String(cString: data)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    break
                }
            },
            close_surface_cb: { _, _ in
                NSApp.terminate(nil)
            }
        )

        guard let newApp = ghostty_app_new(&rtCfg, cfg) else {
            ghostty_config_free(cfg)
            print("[GhosttyApp] ghostty_app_new failed")
            return
        }
        ghostty_config_free(cfg)
        app = newApp
        print("[GhosttyApp] ready")
    }
}
