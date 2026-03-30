import AppKit
import Foundation
import CoreVideo

/// NSView that embeds a ghostty_surface_t. (Ghostty v1.3.1 API)
class GhosttyNSView: NSView {
    private var surface: ghostty_surface_t?
    private var displayLink: CVDisplayLink?

    override init(frame: NSRect) {
        super.init(frame: frame)
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
            print("[GhosttyNSView] GhosttyApp not ready"); return
        }

        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform.macos.nsview = Unmanaged.passUnretained(self).toOpaque()
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = Double(window?.backingScaleFactor ?? 1.0)

        guard let s = ghostty_surface_new(app, &cfg) else {
            print("[GhosttyNSView] ghostty_surface_new failed"); return
        }
        surface = s
        ghostty_surface_set_size(s, UInt32(bounds.width), UInt32(bounds.height))
        startDisplayLink()
    }

    private func startDisplayLink() {
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let dl = displayLink else { return }
        let cb: CVDisplayLinkOutputCallback = { _, _, _, _, _, ctx in
            guard let ctx = ctx else { return kCVReturnSuccess }
            let view = Unmanaged<GhosttyNSView>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { view.surface.map { ghostty_surface_draw($0) } }
            return kCVReturnSuccess
        }
        CVDisplayLinkSetOutputCallback(dl, cb, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(dl)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        surface.map { ghostty_surface_set_size($0, UInt32(newSize.width), UInt32(newSize.height)) }
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard surface != nil else { return }
        _ = inputContext?.handleEvent(event)
    }
}

// MARK: - NSTextInputClient
extension GhosttyNSView: NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        guard let s = surface else { return }
        let text: String
        if let attrStr = string as? NSAttributedString {
            text = attrStr.string
        } else if let str = string as? String {
            text = str
        } else { return }
        ghostty_surface_text(s, text, UInt(text.utf8.count))
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}
    func unmarkText() {}
    func selectedRange() -> NSRange { .init(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { .init(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { false }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { .zero }
    func characterIndex(for point: NSPoint) -> Int { 0 }
}
