import Foundation
import AppKit

/// Singleton wrapper around the terminal app (ghostty_app_t C API).
///
/// Rendering model: the terminal library calls wakeup_cb from any thread when it has
/// work to do. We coalesce rapid wakeups into a single main-thread dispatch
/// that calls ghostty_app_tick() then redraws all registered drawable surfaces.
/// No CVDisplayLink is used — rendering is entirely event-driven.
class TerminalApp {
    static let shared = TerminalApp()

    private(set) var app: ghostty_app_t?
    var focusSetterForTesting: ((ghostty_app_t, Bool) -> Void)?
    var drawHandlerForTesting: ((ghostty_surface_t) -> Void)?

    // Surfaces that should be redrawn on wakeup (active/visible only)
    private var drawableSurfaces: Set<ghostty_surface_t> = []
    private var surfacesByUserdata: [UnsafeMutableRawPointer: ghostty_surface_t] = [:]
    private let surfaceLock = NSLock()

    // Coalescing: prevents main-queue buildup under rapid wakeup bursts
    private let pendingLock = NSLock()
    private var wakeupPending = false

    private init() {}

    // MARK: - Surface registration

    func registerSurface(
        _ s: ghostty_surface_t,
        userdata: UnsafeMutableRawPointer? = nil
    ) {
        surfaceLock.lock()
        defer { surfaceLock.unlock() }
        drawableSurfaces.insert(s)
        if let userdata = userdata {
            surfacesByUserdata[userdata] = s
        }
    }

    func unregisterSurface(
        _ s: ghostty_surface_t,
        userdata: UnsafeMutableRawPointer? = nil
    ) {
        surfaceLock.lock()
        defer { surfaceLock.unlock() }
        drawableSurfaces.remove(s)
        if let userdata = userdata, surfacesByUserdata[userdata] == s {
            surfacesByUserdata.removeValue(forKey: userdata)
        }
    }

    /// Called by TerminalView.setActive(_:) to pause/resume draws for offstage tabs.
    func setSurfaceDrawable(_ s: ghostty_surface_t, drawable: Bool) {
        surfaceLock.lock()
        defer { surfaceLock.unlock() }
        if drawable { drawableSurfaces.insert(s) }
        else        { drawableSurfaces.remove(s) }
    }

    func surface(forUserdata userdata: UnsafeMutableRawPointer?) -> ghostty_surface_t? {
        guard let userdata else { return nil }
        surfaceLock.lock()
        defer { surfaceLock.unlock() }
        return surfacesByUserdata[userdata]
    }

    @discardableResult
    func completeClipboardRequest(
        surfaceUserdata: UnsafeMutableRawPointer?,
        text: UnsafePointer<CChar>?,
        state: UnsafeMutableRawPointer?,
        confirmed: Bool
    ) -> Bool {
        guard let surface = surface(forUserdata: surfaceUserdata) else {
            print("[TerminalApp] missing surface for clipboard request")
            return false
        }
        guard let text else {
            print("[TerminalApp] missing clipboard text for request")
            return false
        }
        guard let state else {
            print("[TerminalApp] missing clipboard state for request")
            return false
        }

        ghostty_surface_complete_clipboard_request(surface, text, state, confirmed)
        return true
    }

    // MARK: - Wakeup (called from any thread by the terminal library)

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
            for s in surfaces { self.drawSurface(s) }
        }
    }

    private func setAppFocus(_ focused: Bool) {
        guard let app else { return }
        if let focusSetterForTesting {
            focusSetterForTesting(app, focused)
            return
        }
        ghostty_app_set_focus(app, focused)
    }

    private func drawSurface(_ surface: ghostty_surface_t) {
        if let drawHandlerForTesting {
            drawHandlerForTesting(surface)
            return
        }
        ghostty_surface_draw(surface)
    }

    private func writeTestLog(event: String, fields: [String: Any]) {
        TerminalTestLogger(sessionId: "__app__").write(event: event, fields: fields)
    }

    private func redrawDrawableSurfaces() {
        surfaceLock.lock()
        let surfaces = Array(drawableSurfaces)
        surfaceLock.unlock()
        for surface in surfaces {
            drawSurface(surface)
        }
    }

    // MARK: - Setup

    func setup() {
        guard app == nil else { return }

        let initResult = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard initResult == GHOSTTY_SUCCESS else {
            print("[TerminalApp] ghostty_init failed: \(initResult)")
            return
        }

        guard let cfg = ghostty_config_new() else {
            print("[TerminalApp] ghostty_config_new failed")
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
            .appendingPathComponent("tether_font.conf")
        if (try? snippet.write(toFile: tempPath, atomically: true, encoding: .utf8)) != nil {
            tempPath.withCString { ghostty_config_load_file(cfg, $0) }
        }

        ghostty_config_finalize(cfg)

        var rtCfg = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { ptr in
                guard let ptr else { return }
                Unmanaged<TerminalApp>.fromOpaque(ptr).takeUnretainedValue().scheduleWakeup()
            },
            action_cb: { app, target, action in
                DispatchQueue.main.async {
                    TerminalApp.shared.handleAction(app: app!, target: target, action: action)
                }
                return true
            },
            read_clipboard_cb: { surfaceUserdata, loc, state in
                guard loc == GHOSTTY_CLIPBOARD_STANDARD else { return false }
                guard let text = NSPasteboard.general.string(forType: .string) else { return false }
                return text.withCString { cString in
                    TerminalApp.shared.completeClipboardRequest(
                        surfaceUserdata: surfaceUserdata,
                        text: cString,
                        state: state,
                        confirmed: false
                    )
                }
            },
            confirm_read_clipboard_cb: { surfaceUserdata, str, state, _ in
                _ = TerminalApp.shared.completeClipboardRequest(
                    surfaceUserdata: surfaceUserdata,
                    text: str,
                    state: state,
                    confirmed: true
                )
            },
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
                    NotificationCenter.default.post(name: .terminalChildExited, object: nil)
                }
            }
        )

        guard let newApp = ghostty_app_new(&rtCfg, cfg) else {
            ghostty_config_free(cfg)
            print("[TerminalApp] ghostty_app_new failed")
            return
        }
        ghostty_config_free(cfg)
        app = newApp
        setAppFocus(NSApp.isActive)

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive(notification:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(applicationDidResignActive(notification:)),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        print("[TerminalApp] ready")
    }

    @objc private func applicationDidBecomeActive(notification: NSNotification) {
        setAppFocus(true)
        writeTestLog(event: "app_focus_changed", fields: ["focused": true])
    }

    @objc private func applicationDidResignActive(notification: NSNotification) {
        setAppFocus(false)
        writeTestLog(event: "app_focus_changed", fields: ["focused": false])
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
                name: .terminalTitleChanged,
                object: nil,
                userInfo: ["surface": OpaquePointer(surface), "title": title]
            )

        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface
            else { return }
            NotificationCenter.default.post(
                name: .terminalChildExited,
                object: nil,
                userInfo: ["surface": OpaquePointer(surface)]
            )

        case GHOSTTY_ACTION_START_SEARCH:
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface
            else { return }
            let needle = action.action.start_search.needle.flatMap {
                String(cString: $0, encoding: .utf8)
            }
            NotificationCenter.default.post(
                name: .terminalSearchStarted,
                object: nil,
                userInfo: [
                    "surface": OpaquePointer(surface),
                    "needle": needle as Any,
                ]
            )

        case GHOSTTY_ACTION_END_SEARCH:
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface
            else { return }
            NotificationCenter.default.post(
                name: .terminalSearchEnded,
                object: nil,
                userInfo: ["surface": OpaquePointer(surface)]
            )

        case GHOSTTY_ACTION_SEARCH_TOTAL:
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface
            else { return }
            let total = action.action.search_total.total >= 0
                ? Int(action.action.search_total.total)
                : nil
            NotificationCenter.default.post(
                name: .terminalSearchTotalChanged,
                object: nil,
                userInfo: [
                    "surface": OpaquePointer(surface),
                    "total": total as Any,
                ]
            )

        case GHOSTTY_ACTION_SEARCH_SELECTED:
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface
            else { return }
            let selected = action.action.search_selected.selected >= 0
                ? Int(action.action.search_selected.selected)
                : nil
            NotificationCenter.default.post(
                name: .terminalSearchSelectionChanged,
                object: nil,
                userInfo: [
                    "surface": OpaquePointer(surface),
                    "selected": selected as Any,
                ]
            )

        case GHOSTTY_ACTION_SCROLLBAR:
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface
            else { return }
            NotificationCenter.default.post(
                name: .terminalScrollbarChanged,
                object: nil,
                userInfo: [
                    "surface": OpaquePointer(surface),
                    "total": action.action.scrollbar.total,
                    "offset": action.action.scrollbar.offset,
                    "len": action.action.scrollbar.len,
                ]
            )

        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface
            else { return }
            let title = action.action.desktop_notification.title.flatMap {
                String(cString: $0, encoding: .utf8)
            } ?? "Notification"
            let body = action.action.desktop_notification.body.flatMap {
                String(cString: $0, encoding: .utf8)
            } ?? ""
            NotificationCenter.default.post(
                name: .terminalDesktopNotification,
                object: nil,
                userInfo: [
                    "surface": OpaquePointer(surface),
                    "title": title,
                    "body": body,
                ]
            )

        default:
            break
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let a = app { ghostty_app_free(a) }
    }
}

extension Notification.Name {
    static let terminalTitleChanged = Notification.Name("TerminalTitleChanged")
    static let terminalChildExited  = Notification.Name("TerminalChildExited")
    static let terminalSearchStarted = Notification.Name("TerminalSearchStarted")
    static let terminalSearchEnded = Notification.Name("TerminalSearchEnded")
    static let terminalSearchTotalChanged = Notification.Name("TerminalSearchTotalChanged")
    static let terminalSearchSelectionChanged = Notification.Name("TerminalSearchSelectionChanged")
    static let terminalScrollbarChanged = Notification.Name("TerminalScrollbarChanged")
    static let terminalDesktopNotification = Notification.Name("TerminalDesktopNotification")
    static let terminalDesktopNotificationActivated = Notification.Name("TerminalDesktopNotificationActivated")
}
