import Foundation
import AppKit

/// Singleton wrapper around ghostty_app_t (Ghostty v1.3.1 API).
///
/// Rendering model: libghostty calls wakeup_cb from any thread when it has
/// work to do. We coalesce rapid wakeups into a single main-thread dispatch
/// that calls ghostty_app_tick() then redraws all registered drawable surfaces.
/// No CVDisplayLink is used — rendering is entirely event-driven.
class GhosttyApp {
    static let shared = GhosttyApp()

    private(set) var app: ghostty_app_t?

    // Surfaces that should be redrawn on wakeup (active/visible only)
    private var drawableSurfaces: Set<ghostty_surface_t> = []
    private let surfaceLock = NSLock()

    // Coalescing: prevents main-queue buildup under rapid wakeup bursts
    private let pendingLock = NSLock()
    private var wakeupPending = false

    private init() {}

    // MARK: - Surface registration

    func registerSurface(_ s: ghostty_surface_t) {
        surfaceLock.lock()
        defer { surfaceLock.unlock() }
        drawableSurfaces.insert(s)
    }

    func unregisterSurface(_ s: ghostty_surface_t) {
        surfaceLock.lock()
        defer { surfaceLock.unlock() }
        drawableSurfaces.remove(s)
    }

    /// Called by GhosttyTerminalView.setActive(_:) to pause/resume draws for offstage tabs.
    func setSurfaceDrawable(_ s: ghostty_surface_t, drawable: Bool) {
        surfaceLock.lock()
        defer { surfaceLock.unlock() }
        if drawable { drawableSurfaces.insert(s) }
        else        { drawableSurfaces.remove(s) }
    }

    // MARK: - Wakeup (called from any thread by libghostty)

    func scheduleWakeup() {
        // Coalesce: if a dispatch is already pending, skip — it will tick and draw
        pendingLock.lock()
        let schedule = !wakeupPending
        wakeupPending = true
        pendingLock.unlock()
        guard schedule else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingLock.lock()
            self.wakeupPending = false
            self.pendingLock.unlock()

            guard let app = self.app else { return }
            ghostty_app_tick(app)

            self.surfaceLock.lock()
            let surfaces = Array(self.drawableSurfaces)
            self.surfaceLock.unlock()
            for s in surfaces { ghostty_surface_draw(s) }
        }
    }

    // MARK: - Setup

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

        // Wire font settings from the app's settings dialog.
        // Flutter SharedPreferences stores values in UserDefaults with the "flutter." prefix.
        // These reflect settings saved in the previous session; changes take effect after restart.
        let defaults = UserDefaults.standard
        // Map settings dialog keys → actual CoreText font family names
        let fontKey = defaults.string(forKey: "flutter.terminal_font_family") ?? "MesloLGSNF"
        let fontFamilyMap: [String: String] = [
            "MesloLGSNF":     "MesloLGS NF",
            "JetBrainsMono":  "JetBrains Mono",
            "monospace":      "monospace",
        ]
        let fontFamily = fontFamilyMap[fontKey] ?? fontKey
        let fontSizeRaw = defaults.double(forKey: "flutter.terminal_font_size")
        let fontSize = fontSizeRaw > 0 ? fontSizeRaw : 14.0
        let snippet = "font-family = \"\(fontFamily)\"\nfont-size = \(fontSize)\n"
        let tempPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("tether_ghostty_font.conf")
        if (try? snippet.write(toFile: tempPath, atomically: true, encoding: .utf8)) != nil {
            tempPath.withCString { ghostty_config_load_file(cfg, $0) }
        }

        ghostty_config_finalize(cfg)

        var rtCfg = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { ptr in
                guard let ptr else { return }
                Unmanaged<GhosttyApp>.fromOpaque(ptr).takeUnretainedValue().scheduleWakeup()
            },
            action_cb: { app, target, action in
                DispatchQueue.main.async {
                    GhosttyApp.shared.handleAction(app: app!, target: target, action: action)
                }
                return true
            },
            read_clipboard_cb: { _, loc, state in
                guard loc == GHOSTTY_CLIPBOARD_STANDARD else { return false }
                guard NSPasteboard.general.string(forType: .string) != nil else { return false }
                return false
            },
            confirm_read_clipboard_cb: { _, str, state, request in },
            write_clipboard_cb: { _, loc, content, len, confirm in
                guard loc == GHOSTTY_CLIPBOARD_STANDARD else { return }
                guard let content = content, len > 0 else { return }
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
                    NotificationCenter.default.post(name: .ghosttyChildExited, object: nil)
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
    static let ghosttyTitleChanged = Notification.Name("GhosttyTitleChanged")
    static let ghosttyChildExited  = Notification.Name("GhosttyChildExited")
}
