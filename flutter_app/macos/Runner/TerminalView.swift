import AppKit
import FlutterMacOS

struct TerminalScrollbarState: Equatable {
    let total: UInt64
    let offset: UInt64
    let len: UInt64
}

struct ScrollbackInfoState: Equatable {
    let totalBytes: UInt64
    let loadedFrom: UInt64
}

struct TerminalAttachOptions: Equatable {
    let offset: UInt64?
    let tailBytes: UInt64?
    let metadataPath: String?
    let role: String
}

enum ScrollbarUpdateDisposition: Equatable {
    case apply(TerminalScrollbarState?)
    case deferred
}

struct ScrollbarActivationCoordinator {
    private(set) var latestState: TerminalScrollbarState?
    private(set) var isActive = true
    private(set) var isCoalescingAfterActivation = false

    mutating func receive(_ state: TerminalScrollbarState?) -> ScrollbarUpdateDisposition {
        latestState = state
        if !isActive || isCoalescingAfterActivation {
            return .deferred
        }
        return .apply(state)
    }

    mutating func setActive(_ active: Bool) -> ScrollbarUpdateDisposition {
        guard active != isActive else { return .deferred }
        isActive = active
        if active {
            isCoalescingAfterActivation = true
            return .apply(latestState)
        }
        isCoalescingAfterActivation = false
        return .deferred
    }

    mutating func flushDeferredActivationState() -> ScrollbarUpdateDisposition {
        guard isCoalescingAfterActivation else { return .deferred }
        isCoalescingAfterActivation = false
        return .apply(latestState)
    }

    mutating func replaceLatestState(_ state: TerminalScrollbarState?) {
        latestState = state
    }
}

struct ScrollSynchronizationResult: Equatable {
    let documentHeight: CGFloat
    let targetOffsetY: CGFloat?
    let lastSentRow: Int?
}

final class TerminalTestLogger {
    private let sessionId: String
    private let fileURL: URL?
    private let queue = DispatchQueue(label: "dev.tether.terminal-test-log")

    init(sessionId: String) {
        self.sessionId = sessionId
        if let rawPath = ProcessInfo.processInfo.environment["TETHER_TERMINAL_TEST_LOG_PATH"],
           !rawPath.isEmpty {
            self.fileURL = URL(fileURLWithPath: rawPath)
            if let parent = self.fileURL?.deletingLastPathComponent() {
                try? FileManager.default.createDirectory(
                    at: parent,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            }
            if let fileURL = self.fileURL, !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
        } else {
            self.fileURL = nil
        }
    }

    func write(event: String, fields: [String: Any] = [:]) {
        guard let fileURL else { return }
        queue.async { [sessionId] in
            var payload = fields
            payload["event"] = event
            payload["session_id"] = sessionId
            payload["timestamp_ms"] = Int(Date().timeIntervalSince1970 * 1000)
            guard JSONSerialization.isValidJSONObject(payload),
                  let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
                  let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.write(contentsOf: Data([0x0A]))
            } catch {
                return
            }
        }
    }
}

/// Platform view wrapper around a Ghostty surface view plus a native NSScrollView.
final class TerminalView: NSView {
    static let copySelector = #selector(NSText.copy(_:))
    static let pasteSelector = #selector(MainFlutterWindow.paste(_:))
    static let pasteAsPlainTextSelector = #selector(NSTextView.pasteAsPlainText(_:))
    static let defaultReplayTailBytes: UInt64 = 1024 * 1024
    static let prefetchTriggerRatio: CGFloat = 0.15
    static let topTriggerDistance: CGFloat = 1
    static let reactivationScrollbarCoalesceDelay: TimeInterval = 0.05
    static let topIndicatorAccessibilityIdentifier = "terminal-top-indicator"
    static let loadingOverlayAccessibilityIdentifier = "terminal-loading-overlay"
    static let scrollViewAccessibilityIdentifier = "terminal-scroll-view"

    private let sessionId: String
    private let serverBaseUrl: String?
    private let authToken: String?
    private let scrollView: NSScrollView
    private let documentView: NSView
    private let topIndicatorView: NSVisualEffectView
    private let topIndicatorLabel: NSTextField
    private let loadingOverlayView: NSVisualEffectView
    private let loadingIndicator: NSProgressIndicator
    private let loadingLabel: NSTextField
    private let testLogger: TerminalTestLogger
    private let exposesDebugAccessibilityState: Bool
    private let prefetchReadyDelay: TimeInterval
    private let testPrefetchTriggerRatioOverride: CGFloat?
    private let testTopTriggerRatioOverride: CGFloat?

    private var eventSink: FlutterEventSink?
    private var surfaceView: TerminalSurfaceView
    private var prefetchSurfaceView: TerminalSurfaceView?

    private var scrollbarCoordinator = ScrollbarActivationCoordinator()
    private var isLiveScrolling = false
    private var isSwappingSurface = false
    private var lastSentRow: Int?
    private var reactivationScrollFlushWorkItem: DispatchWorkItem?
    private var currentScrollbackInfo: ScrollbackInfoState?
    private var prefetchScrollbackInfo: ScrollbackInfoState?
    private var prefetchScrollbarState: TerminalScrollbarState?
    private var loadedStartOffsetBytes: UInt64 = 0
    private var totalScrollbackBytes: UInt64 = 0
    private var isPrefetching = false
    private var prefetchReady = false
    private var prefetchTriggeredAtTop = false
    private var prefetchReadyWorkItem: DispatchWorkItem?

    init(
        sessionId: String,
        serverBaseUrl: String?,
        authToken: String?,
        eventSink: FlutterEventSink? = nil
    ) {
        self.sessionId = sessionId
        self.serverBaseUrl = serverBaseUrl
        self.authToken = authToken
        self.eventSink = eventSink
        self.scrollView = NSScrollView()
        self.documentView = NSView(frame: .zero)
        self.topIndicatorView = NSVisualEffectView()
        self.topIndicatorLabel = NSTextField(labelWithString: "")
        self.loadingOverlayView = NSVisualEffectView()
        self.loadingIndicator = NSProgressIndicator()
        self.loadingLabel = NSTextField(labelWithString: "Loading more history…")
        self.testLogger = TerminalTestLogger(sessionId: sessionId)
        self.exposesDebugAccessibilityState =
            ProcessInfo.processInfo.environment["TETHER_TERMINAL_TEST_MODE"] == "1"
        self.prefetchReadyDelay =
            (Double(ProcessInfo.processInfo.environment["TETHER_TERMINAL_TEST_PREFETCH_DELAY_MS"] ?? "") ?? 0) / 1000
        self.testPrefetchTriggerRatioOverride =
            Self.readCGFloatEnv("TETHER_TERMINAL_TEST_PREFETCH_TRIGGER_RATIO")
        self.testTopTriggerRatioOverride =
            Self.readCGFloatEnv("TETHER_TERMINAL_TEST_TOP_TRIGGER_RATIO")
        self.surfaceView = TerminalSurfaceView(
            sessionId: sessionId,
            serverBaseUrl: serverBaseUrl,
            authToken: authToken,
            eventSink: eventSink,
            attachOptions: TerminalAttachOptions(
                offset: nil,
                tailBytes: Self.defaultReplayTailBytes,
                metadataPath: TerminalView.makeMetadataPath(role: "primary", sessionId: sessionId),
                role: "primary"
            ),
            interactionEnabled: true,
            testLogger: testLogger
        )
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.usesPredominantAxisScrolling = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView = documentView
        scrollView.setAccessibilityElement(true)
        scrollView.setAccessibilityIdentifier(Self.scrollViewAccessibilityIdentifier)
        documentView.addSubview(surfaceView)
        addSubview(scrollView)
        setupOverlayViews()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScrollChange),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillStartLiveScroll),
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidEndLiveScroll),
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidLiveScroll),
            name: NSScrollView.didLiveScrollNotification,
            object: scrollView
        )

        configureCurrentSurface(surfaceView)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        reactivationScrollFlushWorkItem?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        surfaceView.frame.size = scrollView.contentSize
        prefetchSurfaceView?.frame = bounds
        documentView.frame.size.width = scrollView.contentSize.width
        layoutOverlayViews()
        synchronizeScrollView()
        synchronizeSurfaceView()
    }

    @objc private func handleScrollChange(_ notification: Notification) {
        synchronizeSurfaceView()
        updatePrefetchStateFromVisibleRect()
    }

    @objc private func handleWillStartLiveScroll(_ notification: Notification) {
        isLiveScrolling = true
    }

    @objc private func handleDidEndLiveScroll(_ notification: Notification) {
        isLiveScrolling = false
        updatePrefetchStateFromVisibleRect()
    }

    @objc private func handleDidLiveScroll(_ notification: Notification) {
        handleLiveScroll()
        updatePrefetchStateFromVisibleRect()
    }

    private func synchronizeSurfaceView() {
        let visibleRect = scrollView.contentView.documentVisibleRect
        surfaceView.frame.origin = visibleRect.origin
    }

    private func synchronizeScrollView(forceScrollOffset: Bool = false) {
        let result = Self.scrollSynchronizationResult(
            contentHeight: scrollView.contentSize.height,
            cellHeight: surfaceView.cellHeight,
            scrollbarState: scrollbarCoordinator.latestState,
            isLiveScrolling: isLiveScrolling,
            shouldApplyScrollOffset: scrollbarCoordinator.isActive &&
                (forceScrollOffset || !scrollbarCoordinator.isCoalescingAfterActivation)
        )
        documentView.frame.size.height = result.documentHeight
        if let offsetY = result.targetOffsetY {
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: offsetY))
            lastSentRow = result.lastSentRow
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
        updateIndicators()
    }

    private func handleLiveScroll() {
        let visibleRect = scrollView.contentView.documentVisibleRect
        guard let action = Self.scrollActionForLiveScroll(
            documentHeight: documentView.frame.height,
            visibleOriginY: visibleRect.origin.y,
            visibleHeight: visibleRect.height,
            cellHeight: surfaceView.cellHeight,
            lastSentRow: lastSentRow
        ) else { return }

        if let row = Int(action.split(separator: ":").last ?? "") {
            lastSentRow = row
        }
        surfaceView.performAction(action)
    }

    private func setupOverlayViews() {
        topIndicatorView.material = .sidebar
        topIndicatorView.blendingMode = .withinWindow
        topIndicatorView.state = .active
        topIndicatorView.wantsLayer = true
        topIndicatorView.layer?.cornerRadius = 10
        topIndicatorView.setAccessibilityElement(true)
        topIndicatorView.setAccessibilityIdentifier(Self.topIndicatorAccessibilityIdentifier)
        topIndicatorLabel.textColor = .secondaryLabelColor
        topIndicatorLabel.font = .systemFont(ofSize: 11, weight: .medium)
        topIndicatorView.addSubview(topIndicatorLabel)
        addSubview(topIndicatorView)

        loadingOverlayView.material = .menu
        loadingOverlayView.blendingMode = .withinWindow
        loadingOverlayView.state = .active
        loadingOverlayView.wantsLayer = true
        loadingOverlayView.layer?.cornerRadius = 12
        loadingOverlayView.setAccessibilityElement(true)
        loadingOverlayView.setAccessibilityIdentifier(Self.loadingOverlayAccessibilityIdentifier)
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.startAnimation(nil)
        loadingLabel.textColor = .labelColor
        loadingLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        loadingOverlayView.addSubview(loadingIndicator)
        loadingOverlayView.addSubview(loadingLabel)
        addSubview(loadingOverlayView)
        updateIndicators()
    }

    private func layoutOverlayViews() {
        let topSize = NSSize(width: 160, height: 24)
        topIndicatorView.frame = NSRect(
            x: (bounds.width - topSize.width) / 2,
            y: bounds.height - topSize.height - 10,
            width: topSize.width,
            height: topSize.height
        )
        topIndicatorLabel.frame = NSRect(x: 10, y: 4, width: topSize.width - 20, height: 16)

        let overlaySize = NSSize(width: 220, height: 36)
        loadingOverlayView.frame = NSRect(
            x: (bounds.width - overlaySize.width) / 2,
            y: bounds.height - overlaySize.height - 10,
            width: overlaySize.width,
            height: overlaySize.height
        )
        loadingIndicator.frame = NSRect(x: 12, y: 9, width: 18, height: 18)
        loadingLabel.frame = NSRect(x: 40, y: 8, width: overlaySize.width - 52, height: 20)
    }

    private func configureCurrentSurface(_ surface: TerminalSurfaceView) {
        surface.setEventSink(eventSink)
        surface.setInteractive(true)
        surface.scrollbackInfoHandler = { [weak self] info in
            guard let self else { return }
            self.currentScrollbackInfo = info
            self.loadedStartOffsetBytes = info.loadedFrom
            self.totalScrollbackBytes = info.totalBytes
            self.testLogger.write(
                event: "scrollback_info",
                fields: [
                    "role": "primary",
                    "total_bytes": info.totalBytes,
                    "loaded_from": info.loadedFrom,
                ]
            )
            self.updateIndicators()
        }
        surface.scrollbarHandler = { [weak self] state in
            guard let self else { return }
            switch self.scrollbarCoordinator.receive(state) {
            case .apply:
                self.synchronizeScrollView()
            case .deferred:
                self.scheduleDeferredScrollbarFlushIfNeeded()
            }
            self.updateIndicators()
        }
    }

    private func configurePrefetchSurface(_ surface: TerminalSurfaceView) {
        surface.setEventSink(nil)
        surface.setInteractive(false)
        surface.scrollbackInfoHandler = { [weak self] info in
            guard let self else { return }
            self.prefetchScrollbackInfo = info
            self.totalScrollbackBytes = max(self.totalScrollbackBytes, info.totalBytes)
            self.testLogger.write(
                event: "prefetch_scrollback_info",
                fields: [
                    "role": "prefetch",
                    "total_bytes": info.totalBytes,
                    "loaded_from": info.loadedFrom,
                ]
            )
            self.maybeMarkPrefetchReady()
        }
        surface.scrollbarHandler = { [weak self] state in
            guard let self else { return }
            self.prefetchScrollbarState = state
            self.maybeMarkPrefetchReady()
        }
    }

    private func updatePrefetchStateFromVisibleRect() {
        guard !isSwappingSurface else { return }
        let visibleRect = scrollView.contentView.documentVisibleRect
        if !isAtTop(visibleRect: visibleRect) {
            prefetchTriggeredAtTop = false
        }
        if isNearTop(visibleRect: visibleRect) {
            maybeStartPrefetch()
        }
        if isAtTop(visibleRect: visibleRect) {
            prefetchTriggeredAtTop = true
            if prefetchReady {
                performSurfaceSwap()
                return
            }
        }
        updateIndicators()
    }

    private func maybeStartPrefetch() {
        guard loadedStartOffsetBytes > 0,
              !isPrefetching,
              prefetchSurfaceView == nil else { return }

        let fetchStart = loadedStartOffsetBytes > Self.defaultReplayTailBytes
            ? loadedStartOffsetBytes - Self.defaultReplayTailBytes
            : 0
        isPrefetching = true
        prefetchReady = false
        prefetchScrollbackInfo = nil
        prefetchScrollbarState = nil
        prefetchReadyWorkItem?.cancel()
        prefetchReadyWorkItem = nil

        let prefetchSurface = makeSurfaceView(
            role: "prefetch",
            offset: fetchStart,
            tailBytes: nil,
            interactive: false,
            eventSink: nil
        )
        configurePrefetchSurface(prefetchSurface)
        prefetchSurface.alphaValue = 0.01
        prefetchSurface.frame = bounds
        addSubview(prefetchSurface, positioned: .below, relativeTo: scrollView)
        prefetchSurface.setActive(scrollbarCoordinator.isActive)
        prefetchSurfaceView = prefetchSurface
        testLogger.write(
            event: "prefetch_started",
            fields: ["offset": fetchStart, "loaded_start_offset": loadedStartOffsetBytes]
        )
        updateIndicators()
    }

    private func makeSurfaceView(
        role: String,
        offset: UInt64?,
        tailBytes: UInt64?,
        interactive: Bool,
        eventSink: FlutterEventSink?
    ) -> TerminalSurfaceView {
        TerminalSurfaceView(
            sessionId: sessionId,
            serverBaseUrl: serverBaseUrl,
            authToken: authToken,
            eventSink: eventSink,
            attachOptions: TerminalAttachOptions(
                offset: offset,
                tailBytes: tailBytes,
                metadataPath: Self.makeMetadataPath(role: role, sessionId: sessionId),
                role: role
            ),
            interactionEnabled: interactive,
            testLogger: testLogger
        )
    }

    private func maybeMarkPrefetchReady() {
        guard isPrefetching,
              !prefetchReady,
              prefetchScrollbackInfo != nil,
              prefetchScrollbarState != nil else { return }
        if prefetchReadyDelay > 0, prefetchReadyWorkItem == nil {
            let workItem = DispatchWorkItem { [weak self] in
                self?.prefetchReadyWorkItem = nil
                self?.completePrefetchReadyIfPossible()
            }
            prefetchReadyWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + prefetchReadyDelay, execute: workItem)
            return
        }
        completePrefetchReadyIfPossible()
    }

    private func completePrefetchReadyIfPossible() {
        guard isPrefetching,
              !prefetchReady,
              prefetchScrollbackInfo != nil,
              prefetchScrollbarState != nil else { return }
        prefetchReady = true
        if let info = prefetchScrollbackInfo {
            testLogger.write(
                event: "prefetch_ready",
                fields: [
                    "loaded_from": info.loadedFrom,
                    "total_bytes": info.totalBytes,
                ]
            )
        }
        updateIndicators()
        if prefetchTriggeredAtTop {
            performSurfaceSwap()
        }
    }

    private func performSurfaceSwap() {
        guard !isSwappingSurface,
              let newSurface = prefetchSurfaceView,
              let currentState = scrollbarCoordinator.latestState,
              let newState = prefetchScrollbarState else { return }

        isSwappingSurface = true
        let oldSurface = surfaceView
        let prependedRows = Int(newState.total > currentState.total ? newState.total - currentState.total : 0)
        let targetRow = Int(currentState.offset) + prependedRows

        prefetchSurfaceView = nil
        prefetchScrollbackInfo = nil
        prefetchScrollbarState = nil
        prefetchReady = false
        isPrefetching = false
        prefetchTriggeredAtTop = false
        prefetchReadyWorkItem?.cancel()
        prefetchReadyWorkItem = nil

        oldSurface.setInteractive(false)
        oldSurface.setEventSink(nil)
        oldSurface.removeFromSuperview()

        surfaceView = newSurface
        surfaceView.alphaValue = 1.0
        surfaceView.frame = NSRect(origin: scrollView.contentView.documentVisibleRect.origin, size: scrollView.contentSize)
        documentView.addSubview(surfaceView)
        configureCurrentSurface(surfaceView)

        currentScrollbackInfo = surfaceView.latestScrollbackInfo
        if let info = currentScrollbackInfo {
            loadedStartOffsetBytes = info.loadedFrom
            totalScrollbackBytes = info.totalBytes
        }

        scrollbarCoordinator.replaceLatestState(newState)
        documentView.frame.size.height = Self.documentHeight(
            contentHeight: scrollView.contentSize.height,
            cellHeight: surfaceView.cellHeight,
            scrollbarState: newState
        )
        lastSentRow = targetRow
        surfaceView.performAction("scroll_to_row:\(targetRow)")
        testLogger.write(
            event: "swap_completed",
            fields: [
                "target_row": targetRow,
                "prepended_rows": prependedRows,
                "loaded_start_offset": loadedStartOffsetBytes,
            ]
        )
        isSwappingSurface = false
        updateIndicators()
    }

    private func updateIndicators() {
        let hasMoreHistory = loadedStartOffsetBytes > 0
        topIndicatorView.isHidden = !hasMoreHistory || isPrefetching
        topIndicatorLabel.stringValue = hasMoreHistory ? "Scroll up for more" : ""

        let showLoading = isPrefetching && prefetchTriggeredAtTop && !prefetchReady
        loadingOverlayView.isHidden = !showLoading

        if exposesDebugAccessibilityState,
           let data = try? JSONSerialization.data(
               withJSONObject: [
                   "loaded_start_offset": loadedStartOffsetBytes,
                    "total_scrollback_bytes": totalScrollbackBytes,
                    "is_prefetching": isPrefetching,
                    "prefetch_ready": prefetchReady,
                    "prefetch_triggered_at_top": prefetchTriggeredAtTop,
                    "test_prefetch_trigger_ratio": testPrefetchTriggerRatioOverride as Any,
                    "test_top_trigger_ratio": testTopTriggerRatioOverride as Any,
                ],
                options: [.sortedKeys]
           ),
           let json = String(data: data, encoding: .utf8) {
            scrollView.setAccessibilityValue(json)
        }
    }

    private func isNearTop(visibleRect: NSRect) -> Bool {
        let maxExtent = max(documentView.frame.height - visibleRect.height, 1)
        let ratio = distanceFromTop(visibleRect: visibleRect) / maxExtent
        let triggerRatio = testPrefetchTriggerRatioOverride ?? Self.prefetchTriggerRatio
        return ratio < triggerRatio
    }

    private func isAtTop(visibleRect: NSRect) -> Bool {
        let maxExtent = max(documentView.frame.height - visibleRect.height, 1)
        let ratio = distanceFromTop(visibleRect: visibleRect) / maxExtent
        if let triggerRatio = testTopTriggerRatioOverride {
            return ratio < triggerRatio
        }
        return distanceFromTop(visibleRect: visibleRect) <= Self.topTriggerDistance
    }

    private func distanceFromTop(visibleRect: NSRect) -> CGFloat {
        max(0, documentView.frame.height - visibleRect.origin.y - visibleRect.height)
    }

    private func scheduleDeferredScrollbarFlushIfNeeded() {
        guard scrollbarCoordinator.isCoalescingAfterActivation else { return }
        reactivationScrollFlushWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reactivationScrollFlushWorkItem = nil
            switch self.scrollbarCoordinator.flushDeferredActivationState() {
            case .apply:
                self.synchronizeScrollView(forceScrollOffset: true)
                self.synchronizeSurfaceView()
            case .deferred:
                break
            }
        }
        reactivationScrollFlushWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.reactivationScrollbarCoalesceDelay,
            execute: workItem
        )
    }

    func sendText(_ text: String) {
        surfaceView.sendText(text)
    }

    func performAction(_ action: String) {
        surfaceView.performAction(action)
    }

    func setActive(_ active: Bool) {
        reactivationScrollFlushWorkItem?.cancel()
        reactivationScrollFlushWorkItem = nil
        switch scrollbarCoordinator.setActive(active) {
        case .apply:
            synchronizeScrollView(forceScrollOffset: true)
            synchronizeSurfaceView()
            scheduleDeferredScrollbarFlushIfNeeded()
            surfaceView.setActive(true)
            prefetchSurfaceView?.setActive(true)
            return
        case .deferred:
            break
        }
        surfaceView.setActive(active)
        prefetchSurfaceView?.setActive(active)
    }

    func setImagePasteBridgeEnabled(_ enabled: Bool) {
        surfaceView.setImagePasteBridgeEnabled(enabled)
        prefetchSurfaceView?.setImagePasteBridgeEnabled(enabled)
    }

    private static func readCGFloatEnv(_ key: String) -> CGFloat? {
        guard let raw = ProcessInfo.processInfo.environment[key],
              let value = Double(raw) else {
            return nil
        }
        return CGFloat(value)
    }

    func setEventSink(_ sink: FlutterEventSink?) {
        eventSink = sink
        surfaceView.setEventSink(sink)
    }

    private static func makeMetadataPath(role: String, sessionId: String) -> String {
        let filename = "tether-\(sessionId)-\(role)-\(UUID().uuidString).jsonl"
        return (NSTemporaryDirectory() as NSString).appendingPathComponent(filename)
    }

    static func buildAttachCommand(
        sessionId: String,
        serverBaseUrl: String?,
        authToken: String?,
        clientPath: String?,
        offset: UInt64? = nil,
        tailBytes: UInt64? = defaultReplayTailBytes,
        metadataPath: String? = nil
    ) -> String {
        TerminalSurfaceView.buildAttachCommand(
            sessionId: sessionId,
            serverBaseUrl: serverBaseUrl,
            authToken: authToken,
            clientPath: clientPath,
            offset: offset,
            tailBytes: tailBytes,
            metadataPath: metadataPath
        )
    }

    static func documentHeight(
        contentHeight: CGFloat,
        cellHeight: CGFloat,
        scrollbarState: TerminalScrollbarState?
    ) -> CGFloat {
        guard let scrollbarState, cellHeight > 0 else { return contentHeight }
        let documentGridHeight = CGFloat(scrollbarState.total) * cellHeight
        let padding = contentHeight - (CGFloat(scrollbarState.len) * cellHeight)
        return max(contentHeight, documentGridHeight + padding)
    }

    static func scrollSynchronizationResult(
        contentHeight: CGFloat,
        cellHeight: CGFloat,
        scrollbarState: TerminalScrollbarState?,
        isLiveScrolling: Bool,
        shouldApplyScrollOffset: Bool
    ) -> ScrollSynchronizationResult {
        let documentHeight = documentHeight(
            contentHeight: contentHeight,
            cellHeight: cellHeight,
            scrollbarState: scrollbarState
        )

        guard shouldApplyScrollOffset,
              !isLiveScrolling,
              let scrollbarState,
              cellHeight > 0 else {
            return ScrollSynchronizationResult(
                documentHeight: documentHeight,
                targetOffsetY: nil,
                lastSentRow: nil
            )
        }

        let offsetY = CGFloat(scrollbarState.total - scrollbarState.offset - scrollbarState.len)
            * cellHeight
        return ScrollSynchronizationResult(
            documentHeight: documentHeight,
            targetOffsetY: offsetY,
            lastSentRow: Int(scrollbarState.offset)
        )
    }

    static func scrollActionForLiveScroll(
        documentHeight: CGFloat,
        visibleOriginY: CGFloat,
        visibleHeight: CGFloat,
        cellHeight: CGFloat,
        lastSentRow: Int?
    ) -> String? {
        guard cellHeight > 0 else { return nil }
        let scrollOffset = documentHeight - visibleOriginY - visibleHeight
        let row = Int(scrollOffset / cellHeight)
        guard row != lastSentRow else { return nil }
        return "scroll_to_row:\(row)"
    }

    static func pasteboardHasText(_ pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.string(forType: .string) != nil
    }

    static func pasteboardHasImage(_ pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    static func pasteboardHasPasteableContent(
        _ pasteboard: NSPasteboard = .general,
        allowImages: Bool
    ) -> Bool {
        pasteboardHasText(pasteboard) || (allowImages && pasteboardHasImage(pasteboard))
    }

    enum PasteRoutingAction: Equatable {
        case emitImageEvent
        case forwardClipboardText
        case ignore
    }

    static func shouldHandleImagePasteKeyboardShortcut(
        eventType: NSEvent.EventType,
        modifierFlags: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?,
        imagePasteBridgeEnabled: Bool,
        pasteboardHasImage: Bool
    ) -> Bool {
        guard imagePasteBridgeEnabled, pasteboardHasImage, eventType == .keyDown else {
            return false
        }

        return modifierFlags.intersection(.deviceIndependentFlagsMask) == .control &&
            charactersIgnoringModifiers?.lowercased() == "v"
    }

    static func keyboardPasteRoutingAction(
        eventType: NSEvent.EventType,
        modifierFlags: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?,
        imagePasteBridgeEnabled: Bool,
        pasteboardHasImage: Bool
    ) -> PasteRoutingAction {
        shouldHandleImagePasteKeyboardShortcut(
            eventType: eventType,
            modifierFlags: modifierFlags,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            imagePasteBridgeEnabled: imagePasteBridgeEnabled,
            pasteboardHasImage: pasteboardHasImage
        ) ? .emitImageEvent : .ignore
    }

    static func pasteCommandRoutingAction(
        imagePasteBridgeEnabled: Bool,
        pasteboardHasImage: Bool,
        pasteboardHasText: Bool
    ) -> PasteRoutingAction {
        if imagePasteBridgeEnabled && pasteboardHasImage {
            return .emitImageEvent
        }
        if pasteboardHasText {
            return .forwardClipboardText
        }
        return .ignore
    }

    static func isClipboardMenuActionEnabled(
        action: Selector?,
        hasSelection: Bool,
        canPaste: Bool
    ) -> Bool {
        switch action {
        case Self.copySelector:
            return hasSelection
        case Self.pasteSelector, Self.pasteAsPlainTextSelector:
            return canPaste
        default:
            return true
        }
    }
}

#if DEBUG
extension TerminalView {
    var debugScrollView: NSScrollView { scrollView }
    var debugLoadedStartOffsetBytes: UInt64 { loadedStartOffsetBytes }
    var debugTotalScrollbackBytes: UInt64 { totalScrollbackBytes }
}
#endif

protocol TerminalShortcutFocusable {}

/// NSView embedding a Ghostty surface whose child process is `tether-client attach`.
private final class TerminalSurfaceView: NSView, TerminalShortcutFocusable {
    private let sessionId: String
    private let serverBaseUrl: String?
    private let authToken: String?
    private let attachOptions: TerminalAttachOptions
    private let testLogger: TerminalTestLogger
    private var interactionEnabled: Bool

    private(set) var surface: ghostty_surface_t?
    private(set) var latestScrollbackInfo: ScrollbackInfoState?
    var eventSink: FlutterEventSink?
    var scrollbarHandler: ((TerminalScrollbarState?) -> Void)?
    var scrollbackInfoHandler: ((ScrollbackInfoState) -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var eventMonitor: Any?
    private var keyTextAccumulator: [String]? = nil
    private var isComposing = false
    private var focused = false
    private var suppressNextLeftMouseUp = false
    private var imagePasteBridgeEnabled = false
    private var metadataHandle: FileHandle?
    private var metadataMonitor: DispatchSourceFileSystemObject?
    private var metadataBuffer = Data()

    init(
        sessionId: String,
        serverBaseUrl: String?,
        authToken: String?,
        eventSink: FlutterEventSink?,
        attachOptions: TerminalAttachOptions,
        interactionEnabled: Bool,
        testLogger: TerminalTestLogger
    ) {
        self.sessionId = sessionId
        self.serverBaseUrl = serverBaseUrl
        self.authToken = authToken
        self.eventSink = eventSink
        self.attachOptions = attachOptions
        self.interactionEnabled = interactionEnabled
        self.testLogger = testLogger
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
        guard let app = TerminalApp.shared.app, let window = window else {
            print("[TerminalSurfaceView] TerminalApp not ready or no window")
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = window.backingScaleFactor
        CATransaction.commit()

        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform.macos.nsview = Unmanaged.passUnretained(self).toOpaque()
        let surfaceUserdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.userdata = surfaceUserdata
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? window.backingScaleFactor)

        let command = attachCommand()
        surface = withOptCString(command) { cmdPtr in
            cfg.command = cmdPtr
            return ghostty_surface_new(app, &cfg)
        }

        guard let s = surface else {
            print("[TerminalSurfaceView] ghostty_surface_new failed")
            return
        }

        startMetadataMonitor()
        let scaledBounds = convertToBacking(bounds)
        ghostty_surface_set_size(s, UInt32(scaledBounds.width), UInt32(scaledBounds.height))
        TerminalApp.shared.registerSurface(s, userdata: surfaceUserdata)
        ghostty_surface_draw(s)
        observeNotifications()
        updateEventMonitor()
        testLogger.write(
            event: "attach_started",
            fields: [
                "role": attachOptions.role,
                "offset": attachOptions.offset as Any,
                "tail_bytes": attachOptions.tailBytes as Any,
            ]
        )
    }

    private func attachCommand() -> String {
        Self.buildAttachCommand(
            sessionId: sessionId,
            serverBaseUrl: serverBaseUrl,
            authToken: authToken,
            clientPath: resolveTetherClientPath(),
            offset: attachOptions.offset,
            tailBytes: attachOptions.tailBytes,
            metadataPath: attachOptions.metadataPath
        )
    }

    static func buildAttachCommand(
        sessionId: String,
        serverBaseUrl: String?,
        authToken: String?,
        clientPath: String?,
        offset: UInt64?,
        tailBytes: UInt64?,
        metadataPath: String?
    ) -> String {
        guard let serverBaseUrl, !serverBaseUrl.isEmpty else {
            return "printf 'tether-server is not connected\\n'; exit 1"
        }

        guard let clientPath, !clientPath.isEmpty else {
            return "printf 'tether-client helper not found\\n'; exit 127"
        }

        var parts = [
            shellQuote(clientPath),
            "attach",
            "--server",
            shellQuote(serverBaseUrl),
            "--session",
            shellQuote(sessionId),
        ]
        if let authToken, !authToken.isEmpty {
            parts.append("--token")
            parts.append(shellQuote(authToken))
        }
        if let offset {
            parts.append("--offset")
            parts.append(String(offset))
        } else if let tailBytes, tailBytes > 0 {
            parts.append("--tail-bytes")
            parts.append(String(tailBytes))
        }
        if let metadataPath, !metadataPath.isEmpty {
            parts.append("--metadata-path")
            parts.append(shellQuote(metadataPath))
        }
        return parts.joined(separator: " ")
    }

    private func startMetadataMonitor() {
        guard let metadataPath = attachOptions.metadataPath, !metadataPath.isEmpty else { return }
        let fileURL = URL(fileURLWithPath: metadataPath)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return }
        metadataHandle = handle
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: handle.fileDescriptor,
            eventMask: [.extend, .write],
            queue: DispatchQueue.main
        )
        source.setEventHandler { [weak self] in
            self?.consumeMetadata()
        }
        source.setCancelHandler { [weak self] in
            try? self?.metadataHandle?.close()
        }
        metadataMonitor = source
        source.resume()
        consumeMetadata()
    }

    private func consumeMetadata() {
        guard let handle = metadataHandle,
              let data = try? handle.readToEnd(),
              !data.isEmpty else { return }
        metadataBuffer.append(data)
        while let newlineIndex = metadataBuffer.firstIndex(of: 0x0A) {
            let line = metadataBuffer.prefix(upTo: newlineIndex)
            metadataBuffer.removeSubrange(...newlineIndex)
            guard !line.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = json["type"] as? String else { continue }
            switch type {
            case "scrollback_info":
                guard let total = (json["total_bytes"] as? NSNumber)?.uint64Value,
                      let loaded = (json["loaded_from"] as? NSNumber)?.uint64Value else {
                    continue
                }
                let info = ScrollbackInfoState(totalBytes: total, loadedFrom: loaded)
                latestScrollbackInfo = info
                scrollbackInfoHandler?(info)
            default:
                continue
            }
        }
    }

    private func updateEventMonitor() {
        if interactionEnabled {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyUp, .leftMouseDown]
            ) { [weak self] in self?.localEventHandler($0) }
        } else if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    private func resolveTetherClientPath() -> String? {
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let envPath = env["TETHER_CLIENT_PATH"], !envPath.isEmpty {
            candidates.append(envPath)
        }
        candidates.append(
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Helpers/tether-client")
                .path
        )
        candidates.append("/usr/local/bin/tether-client")
        candidates.append("/opt/homebrew/bin/tether-client")

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = ["tether-client"]
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let rawPath = String(data: data, encoding: .utf8) {
                    let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                        return path
                    }
                }
            }
        } catch {
            return nil
        }

        return nil
    }

    static func shellQuote(_ value: String) -> String {
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func withOptCString<T>(_ value: String?, body: (UnsafePointer<CChar>?) -> T) -> T {
        guard let value, !value.isEmpty else { return body(nil) }
        return value.withCString(body)
    }

    var cellHeight: CGFloat {
        guard let surface else { return 0 }
        let size = ghostty_surface_size(surface)
        let scale = window?.backingScaleFactor ?? 1
        return CGFloat(size.cell_height_px) / scale
    }

    private func observeNotifications() {
        observers.append(NotificationCenter.default.addObserver(
            forName: .terminalTitleChanged, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, self.matchesSurface(note),
                  let title = note.userInfo?["title"] as? String else { return }
            self.eventSink?(["type": "title", "value": title])
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .terminalChildExited, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, self.matchesSurface(note) else { return }
            self.eventSink?(["type": "exited"])
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .terminalSearchStarted, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, self.matchesSurface(note) else { return }
            var payload: [String: Any] = ["type": "search_start"]
            if let needle = note.userInfo?["needle"] as? String {
                payload["value"] = needle
            }
            self.eventSink?(payload)
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .terminalSearchEnded, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, self.matchesSurface(note) else { return }
            self.eventSink?(["type": "search_end"])
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .terminalSearchTotalChanged, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, self.matchesSurface(note) else { return }
            var payload: [String: Any] = ["type": "search_total"]
            if let total = note.userInfo?["total"] as? Int {
                payload["value"] = total
            }
            self.eventSink?(payload)
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .terminalSearchSelectionChanged, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, self.matchesSurface(note) else { return }
            var payload: [String: Any] = ["type": "search_selected"]
            if let selected = note.userInfo?["selected"] as? Int {
                payload["value"] = selected
            }
            self.eventSink?(payload)
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .terminalScrollbarChanged, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, self.matchesSurface(note) else { return }
            if let total = note.userInfo?["total"] as? UInt64,
               let offset = note.userInfo?["offset"] as? UInt64,
               let len = note.userInfo?["len"] as? UInt64 {
                self.scrollbarHandler?(TerminalScrollbarState(total: total, offset: offset, len: len))
            }
        })
    }

    private func matchesSurface(_ note: Notification) -> Bool {
        guard let surface else { return false }
        guard let surfacePtr = note.userInfo?["surface"] as? OpaquePointer else { return false }
        return OpaquePointer(surface) == surfacePtr
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let s = surface, newSize.width > 0, newSize.height > 0 else { return }
        let scaled = convertToBacking(NSRect(origin: .zero, size: newSize))
        ghostty_surface_set_size(s, UInt32(scaled.width), UInt32(scaled.height))
        ghostty_surface_draw(s)
    }

    override func layout() {
        super.layout()
        guard let s = surface, bounds.width > 0, bounds.height > 0 else { return }

        if frame.width > 0 && frame.height > 0 {
            let fbFrame = convertToBacking(frame)
            ghostty_surface_set_content_scale(
                s,
                fbFrame.width / frame.width,
                fbFrame.height / frame.height
            )
        }

        let scaled = convertToBacking(bounds)
        ghostty_surface_set_size(s, UInt32(scaled.width), UInt32(scaled.height))
        ghostty_surface_draw(s)
        inputContext?.invalidateCharacterCoordinates()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window = window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }

        guard let s = surface else { return }
        let fbFrame = convertToBacking(frame)
        let xScale = frame.width > 0 ? fbFrame.width / frame.width : 1
        let yScale = frame.height > 0 ? fbFrame.height / frame.height : 1
        ghostty_surface_set_content_scale(s, xScale, yScale)
        let scaled = convertToBacking(bounds)
        ghostty_surface_set_size(s, UInt32(scaled.width), UInt32(scaled.height))
        ghostty_surface_draw(s)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        super.updateTrackingAreas()
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [
                .mouseEnteredAndExited,
                .mouseMoved,
                .inVisibleRect,
                .activeAlways,
            ],
            owner: self,
            userInfo: nil
        ))
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { focusDidChange(true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { focusDidChange(false) }
        return result
    }

    private func focusDidChange(_ newValue: Bool) {
        guard focused != newValue else { return }
        focused = newValue
        if let surface {
            ghostty_surface_set_focus(surface, newValue)
        }
    }

    private func localEventHandler(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyUp:
            return localEventKeyUp(event)
        case .leftMouseDown:
            return localEventLeftMouseDown(event)
        default:
            return event
        }
    }

    private func localEventLeftMouseDown(_ event: NSEvent) -> NSEvent? {
        guard let window,
              let eventWindow = event.window,
              window == eventWindow else { return event }

        let location = convert(event.locationInWindow, from: nil)
        guard hitTest(location) == self else { return event }

        suppressNextLeftMouseUp = false
        guard window.firstResponder !== self else { return event }

        if NSApp.isActive && window.isKeyWindow {
            window.makeFirstResponder(self)
            suppressNextLeftMouseUp = true
            return nil
        }

        window.makeFirstResponder(self)
        return event
    }

    private func localEventKeyUp(_ event: NSEvent) -> NSEvent? {
        guard event.modifierFlags.contains(.command) else { return event }
        guard focused else { return event }
        keyUp(with: event)
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let s = surface else { return }
        _ = ghostty_surface_mouse_button(
            s,
            GHOSTTY_MOUSE_PRESS,
            GHOSTTY_MOUSE_LEFT,
            modsFromEvent(event)
        )
    }

    override func mouseUp(with event: NSEvent) {
        if suppressNextLeftMouseUp {
            suppressNextLeftMouseUp = false
            return
        }
        guard let s = surface else { return }
        _ = ghostty_surface_mouse_button(
            s,
            GHOSTTY_MOUSE_RELEASE,
            GHOSTTY_MOUSE_LEFT,
            modsFromEvent(event)
        )
        ghostty_surface_mouse_pressure(s, 0, 0)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        return buildContextMenu()
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let menu = menu(for: event) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func rightMouseUp(with event: NSEvent) {}

    override func otherMouseDown(with event: NSEvent) {
        guard let s = surface else { return }
        _ = ghostty_surface_mouse_button(
            s,
            GHOSTTY_MOUSE_PRESS,
            mouseButton(from: event.buttonNumber),
            modsFromEvent(event)
        )
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let s = surface else { return }
        _ = ghostty_surface_mouse_button(
            s,
            GHOSTTY_MOUSE_RELEASE,
            mouseButton(from: event.buttonNumber),
            modsFromEvent(event)
        )
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        sendMousePosition(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard let s = surface else { return }
        ghostty_surface_mouse_pos(s, -1, -1, modsFromEvent(event))
    }

    override func mouseMoved(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func mouseDragged(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        sendMousePosition(event)
    }

    private func sendMousePosition(_ event: NSEvent) {
        guard let s = surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(s, pos.x, frame.height - pos.y, modsFromEvent(event))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let s = surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            x *= 2
            y *= 2
        }
        ghostty_surface_mouse_scroll(s, x, y, scrollModsFromEvent(event))
    }

    override func pressureChange(with event: NSEvent) {
        guard let s = surface else { return }
        ghostty_surface_mouse_pressure(s, UInt32(event.stage), Double(event.pressure))
    }

    override func flagsChanged(with event: NSEvent) {
        guard let s = surface, !hasMarkedText() else { return }
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }

        let mods = modsFromEvent(event)
        let action: ghostty_input_action_e =
            (mods.rawValue & mod) != 0 ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
        _ = sendKeyEvent(s, action: action, event: event, text: nil)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, focused else { return false }
        guard let s = surface else { return false }

        if TerminalView.keyboardPasteRoutingAction(
            eventType: event.type,
            modifierFlags: event.modifierFlags,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            imagePasteBridgeEnabled: imagePasteBridgeEnabled,
            pasteboardHasImage: TerminalView.pasteboardHasImage()
        ) == .emitImageEvent {
            return emitClipboardImageEventIfAvailable()
        }

        if !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.control) {
            return false
        }

        var ev = ghostty_input_key_s()
        ev.action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        ev.keycode = UInt32(event.keyCode)
        ev.mods = modsFromEvent(event)
        let text = event.characters ?? ""
        let handled = text.withCString { ptr in
            ev.text = ptr
            return ghostty_surface_key_is_binding(s, ev, nil)
        }
        guard handled || event.modifierFlags.contains(.control) else { return false }

        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard let s = surface else { return }

        if TerminalView.keyboardPasteRoutingAction(
            eventType: event.type,
            modifierFlags: event.modifierFlags,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            imagePasteBridgeEnabled: imagePasteBridgeEnabled,
            pasteboardHasImage: TerminalView.pasteboardHasImage()
        ) == .emitImageEvent {
            _ = emitClipboardImageEventIfAvailable()
            return
        }

        let action: ghostty_input_action_e =
            event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        interpretKeyEvents([event])

        if let list = keyTextAccumulator, !list.isEmpty {
            isComposing = false
            for text in list {
                _ = sendKeyEvent(s, action: action, event: event, text: text)
            }
        } else if !isComposing {
            _ = sendKeyEvent(s, action: action, event: event, text: keyCharacters(event))
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let s = surface else { return }
        _ = sendKeyEvent(s, action: GHOSTTY_ACTION_RELEASE, event: event, text: nil)
    }

    override func doCommand(by selector: Selector) {
        // Prevent NSBeep for unhandled commands.
    }

    @objc func copy(_ sender: Any?) {
        guard hasSelection() else { return }
        performAction("copy_to_clipboard")
    }

    @objc func paste(_ sender: Any?) {
        switch TerminalView.pasteCommandRoutingAction(
            imagePasteBridgeEnabled: imagePasteBridgeEnabled,
            pasteboardHasImage: TerminalView.pasteboardHasImage(),
            pasteboardHasText: TerminalView.pasteboardHasText()
        ) {
        case .emitImageEvent:
            _ = emitClipboardImageEventIfAvailable()
        case .forwardClipboardText:
            performAction("paste_from_clipboard")
        case .ignore:
            return
        }
    }

    @objc func pasteAsPlainText(_ sender: Any?) {
        paste(sender)
    }

    private func emitClipboardImageEventIfAvailable() -> Bool {
        guard imagePasteBridgeEnabled,
              let payload = Self.clipboardImageEventPayload() else { return false }
        eventSink?(payload)
        return true
    }

    private func sendKeyEvent(
        _ s: ghostty_surface_t,
        action: ghostty_input_action_e,
        event: NSEvent,
        text: String?
    ) -> Bool {
        var ev = ghostty_input_key_s()
        ev.action = action
        ev.keycode = UInt32(event.keyCode)
        ev.mods = modsFromEvent(event)
        var consumedRaw: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.shift) { consumedRaw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.option) { consumedRaw |= GHOSTTY_MODS_ALT.rawValue }
        ev.consumed_mods = ghostty_input_mods_e(rawValue: consumedRaw)
        if let chars = event.characters(byApplyingModifiers: []),
           let cp = chars.unicodeScalars.first {
            ev.unshifted_codepoint = cp.value
        }
        ev.composing = false

        if let text, !text.isEmpty, let first = text.utf8.first, first >= 0x20 {
            return text.withCString { ptr in
                ev.text = ptr
                return ghostty_surface_key(s, ev)
            }
        }

        ev.text = nil
        return ghostty_surface_key(s, ev)
    }

    private func keyCharacters(_ event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return event.characters(
                    byApplyingModifiers: event.modifierFlags.subtracting(.control)
                )
            }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }
        return characters
    }

    private func modsFromEvent(_ event: NSEvent) -> ghostty_input_mods_e {
        let flags = event.modifierFlags
        var raw: UInt32 = 0
        if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
    }

    private func scrollModsFromEvent(_ event: NSEvent) -> ghostty_input_scroll_mods_t {
        var raw: Int32 = 0
        if event.hasPreciseScrollingDeltas {
            raw |= 1
        }

        let momentum: Int32
        switch event.momentumPhase {
        case .began: momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_BEGAN.rawValue)
        case .stationary: momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_STATIONARY.rawValue)
        case .changed: momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue)
        case .ended: momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_ENDED.rawValue)
        case .cancelled: momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_CANCELLED.rawValue)
        case .mayBegin: momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN.rawValue)
        default: momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_NONE.rawValue)
        }

        raw |= momentum << 1
        return raw
    }

    private func mouseButton(from buttonNumber: Int) -> ghostty_input_mouse_button_e {
        switch buttonNumber {
        case 0: return GHOSTTY_MOUSE_LEFT
        case 1: return GHOSTTY_MOUSE_RIGHT
        case 2: return GHOSTTY_MOUSE_MIDDLE
        case 3: return GHOSTTY_MOUSE_EIGHT
        case 4: return GHOSTTY_MOUSE_NINE
        case 5: return GHOSTTY_MOUSE_SIX
        case 6: return GHOSTTY_MOUSE_SEVEN
        case 7: return GHOSTTY_MOUSE_FOUR
        case 8: return GHOSTTY_MOUSE_FIVE
        case 9: return GHOSTTY_MOUSE_TEN
        case 10: return GHOSTTY_MOUSE_ELEVEN
        default: return GHOSTTY_MOUSE_UNKNOWN
        }
    }

    private func hasSelection() -> Bool {
        guard let surface else { return false }
        return ghostty_surface_has_selection(surface)
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Terminal")
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        for item in menu.items {
            item.target = self
        }
        return menu
    }

    func sendText(_ text: String) {
        guard let s = surface else { return }
        ghostty_surface_text(s, text, UInt(text.utf8.count))
    }

    func performAction(_ action: String) {
        guard let s = surface else { return }
        _ = action.withCString { ptr in
            ghostty_surface_binding_action(s, ptr, UInt(action.utf8.count))
        }
    }

    func setActive(_ active: Bool) {
        guard let s = surface else { return }
        TerminalApp.shared.setSurfaceDrawable(s, drawable: active)
        ghostty_surface_set_occlusion(s, active)
        if !active {
            focusDidChange(false)
        }
    }

    func setImagePasteBridgeEnabled(_ enabled: Bool) {
        imagePasteBridgeEnabled = enabled
    }

    func setEventSink(_ sink: FlutterEventSink?) {
        eventSink = sink
    }

    func setInteractive(_ interactive: Bool) {
        interactionEnabled = interactive
        if !interactive {
            suppressNextLeftMouseUp = false
            focusDidChange(false)
        }
        updateEventMonitor()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        metadataMonitor?.cancel()
        metadataMonitor = nil
        if let metadataPath = attachOptions.metadataPath {
            try? FileManager.default.removeItem(atPath: metadataPath)
        }
        if let surface {
            TerminalApp.shared.unregisterSurface(
                surface,
                userdata: Unmanaged.passUnretained(self).toOpaque()
            )
            ghostty_surface_free(surface)
        }
    }

    private static func clipboardImageEventPayload(
        _ pasteboard: NSPasteboard = .general
    ) -> [String: Any]? {
        guard let image = pasteboardImage(pasteboard),
              let pngData = pngData(from: image) else { return nil }
        return [
            "type": "clipboard_image",
            "mimeType": "image/png",
            "data": FlutterStandardTypedData(bytes: pngData),
        ]
    }

    private static func pasteboardImage(_ pasteboard: NSPasteboard) -> NSImage? {
        let classes: [AnyClass] = [NSImage.self]
        let images = pasteboard.readObjects(forClasses: classes, options: nil) as? [NSImage]
        return images?.first
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

extension TerminalSurfaceView: NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let chars: String
        if let attr = string as? NSAttributedString {
            chars = attr.string
        } else if let str = string as? String {
            chars = str
        } else {
            return
        }

        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(chars)
            return
        }

        guard let s = surface else { return }
        ghostty_surface_text(s, chars, UInt(chars.utf8.count))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let str: String
        if let attr = string as? NSAttributedString {
            str = attr.string
        } else if let value = string as? String {
            str = value
        } else {
            return
        }
        isComposing = !str.isEmpty
    }

    func unmarkText() { isComposing = false }
    func selectedRange() -> NSRange { .init(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { .init(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { isComposing }
    func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window = window else { return .zero }
        let localRect = NSRect(x: 0, y: 0, width: 0, height: 0)
        let windowRect = convert(localRect, to: nil)
        return window.convertToScreen(windowRect)
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }
}

extension TerminalSurfaceView: NSUserInterfaceValidations {
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        TerminalView.isClipboardMenuActionEnabled(
            action: item.action,
            hasSelection: hasSelection(),
            canPaste: TerminalView.pasteboardHasPasteableContent(
                allowImages: imagePasteBridgeEnabled
            )
        )
    }
}
