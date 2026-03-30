import AppKit
import FlutterMacOS
import CoreVideo

/// NSView embedding a ghostty_surface_t (PTY + Metal renderer).
/// Ghostty v1.3.1 API.
class GhosttyTerminalView: NSView {
    private let sessionId: String
    private let command: String?
    private let cwd: String?

    private(set) var surface: ghostty_surface_t?
    private var displayLink: CVDisplayLink?
    var eventSink: FlutterEventSink?

    private var titleObserver: NSObjectProtocol?
    private var exitObserver: NSObjectProtocol?

    init(sessionId: String, command: String?, cwd: String?, eventSink: FlutterEventSink? = nil) {
        self.sessionId = sessionId
        self.command = command
        self.cwd = cwd
        self.eventSink = eventSink
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, surface == nil else { return }
        createSurface()
    }

    private func createSurface() {
        guard let app = GhosttyApp.shared.app else {
            print("[GhosttyTerminalView] GhosttyApp not ready"); return
        }

        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform.macos.nsview = Unmanaged.passUnretained(self).toOpaque()
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = Double(window?.backingScaleFactor ?? 1.0)

        // Working directory
        if let cwd = cwd, !cwd.isEmpty {
            cwd.withCString { cfg.working_directory = $0 }
        }

        guard let s = ghostty_surface_new(app, &cfg) else {
            print("[GhosttyTerminalView] ghostty_surface_new failed"); return
        }
        surface = s
        ghostty_surface_set_size(s, UInt32(bounds.width), UInt32(bounds.height))
        startDisplayLink()
        observeNotifications()
    }

    private func startDisplayLink() {
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let dl = displayLink else { return }
        let cb: CVDisplayLinkOutputCallback = { _, _, _, _, _, ctx in
            guard let ctx = ctx else { return kCVReturnSuccess }
            let view = Unmanaged<GhosttyTerminalView>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { view.surface.map { ghostty_surface_draw($0) } }
            return kCVReturnSuccess
        }
        CVDisplayLinkSetOutputCallback(dl, cb, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(dl)
    }

    private func observeNotifications() {
        titleObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyTitleChanged, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let surfacePtr = note.userInfo?["surface"] as? OpaquePointer,
                  OpaquePointer(self.surface) == surfacePtr,
                  let title = note.userInfo?["title"] as? String
            else { return }
            self.eventSink?(["type": "title", "value": title])
        }

        exitObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyChildExited, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            // Either surface-specific or global close
            if let surfacePtr = note.userInfo?["surface"] as? OpaquePointer {
                guard OpaquePointer(self.surface) == surfacePtr else { return }
            }
            self.eventSink?(["type": "exited"])
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        surface.map { ghostty_surface_set_size($0, UInt32(newSize.width), UInt32(newSize.height)) }
    }

    // MARK: - Input

    func sendText(_ text: String) {
        guard let s = surface else { return }
        ghostty_surface_text(s, text, UInt(text.utf8.count))
    }

    func setActive(_ active: Bool) {
        guard let dl = displayLink else { return }
        if active {
            if !CVDisplayLinkIsRunning(dl) { CVDisplayLinkStart(dl) }
        } else {
            if CVDisplayLinkIsRunning(dl) { CVDisplayLinkStop(dl) }
        }
    }

    func setEventSink(_ sink: FlutterEventSink?) {
        eventSink = sink
    }

    // MARK: - Cleanup

    deinit {
        displayLink.map { CVDisplayLinkStop($0) }
        titleObserver.map { NotificationCenter.default.removeObserver($0) }
        exitObserver.map  { NotificationCenter.default.removeObserver($0) }
        surface.map { ghostty_surface_free($0) }
    }
}
