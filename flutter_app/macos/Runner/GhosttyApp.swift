import Foundation
import AppKit

/// Singleton wrapper around ghostty_app_t (Ghostty v1.3.1 API).
class GhosttyApp {
    static let shared = GhosttyApp()

    private(set) var app: ghostty_app_t?

    private init() {}

    func setup() {
        guard app == nil else { return }

        // ghostty_init(argc, argv) — pass real command-line args
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
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { _ in
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .ghosttyWakeup, object: nil)
                }
            },
            action_cb: { app, target, action in
                DispatchQueue.main.async {
                    GhosttyApp.shared.handleAction(app: app!, target: target, action: action)
                }
                return true
            },
            read_clipboard_cb: { _, loc, state in
                guard loc == GHOSTTY_CLIPBOARD_STANDARD else { return false }
                guard let str = NSPasteboard.general.string(forType: .string) else { return false }
                // We need a surface to complete the request — surface comes from target in action_cb.
                // For now, read is handled passively via state pointer.
                // TODO: Route through surface from calling context
                return false
            },
            confirm_read_clipboard_cb: { _, str, state, request in
                // No confirmation UI — just complete it
            },
            write_clipboard_cb: { _, loc, content, len, confirm in
                guard loc == GHOSTTY_CLIPBOARD_STANDARD else { return }
                guard let content = content, len > 0 else { return }
                // First text/plain item
                for i in 0..<len {
                    let item = content[i]
                    guard let mime = item.mime, String(cString: mime) == "text/plain" else { continue }
                    guard let data = item.data else { continue }
                    let text = String(cString: data)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    break
                }
            },
            close_surface_cb: { _, processAlive in
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .ghosttyChildExited,
                        object: nil
                    )
                }
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

    func handleAction(app: ghostty_app_t, target: ghostty_target_s, action: ghostty_action_s) {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface,
                  let titlePtr = action.action.set_title.title,
                  let title = String(cString: titlePtr, encoding: .utf8)
            else { return }
            NotificationCenter.default.post(
                name: .ghosttyTitleChanged,
                object: nil,
                userInfo: ["surface": OpaquePointer(surface), "title": title]
            )

        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface
            else { return }
            NotificationCenter.default.post(
                name: .ghosttyChildExited,
                object: nil,
                userInfo: ["surface": OpaquePointer(surface)]
            )

        default:
            break
        }
    }

    deinit {
        if let a = app { ghostty_app_free(a) }
    }
}

extension Notification.Name {
    static let ghosttyWakeup      = Notification.Name("GhosttyWakeup")
    static let ghosttyTitleChanged = Notification.Name("GhosttyTitleChanged")
    static let ghosttyChildExited  = Notification.Name("GhosttyChildExited")
}
