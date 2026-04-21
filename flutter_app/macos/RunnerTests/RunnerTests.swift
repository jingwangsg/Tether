import Cocoa
import FlutterMacOS
import XCTest
@testable import Tether

class RunnerTests: XCTestCase {

  func testBuildAttachCommandIncludesTokenAndQuotes() {
    let command = TerminalView.buildAttachCommand(
      sessionId: "session-123",
      serverBaseUrl: "http://localhost:7680",
      authToken: "tok'en value",
      clientPath: "/tmp/tether-client",
      tailBytes: 524288,
    )

    XCTAssertTrue(command.contains("'/tmp/tether-client'"))
    XCTAssertTrue(command.contains("--server 'http://localhost:7680'"))
    XCTAssertTrue(command.contains("--session 'session-123'"))
    XCTAssertTrue(command.contains("--token 'tok'\"'\"'en value'"))
    XCTAssertTrue(command.contains("--tail-bytes 524288"))
  }

  func testBuildAttachCommandFallsBackWhenServerUnavailable() {
    let command = TerminalView.buildAttachCommand(
      sessionId: "session-123",
      serverBaseUrl: nil,
      authToken: nil,
      clientPath: "/tmp/tether-client",
      tailBytes: 524288,
    )

    XCTAssertEqual(command, "printf 'tether-server is not connected\\n'; exit 1")
  }

  func testBuildAttachCommandPrefersOffsetAndMetadataPathOverTailBytes() {
    let command = TerminalView.buildAttachCommand(
      sessionId: "session-123",
      serverBaseUrl: "http://localhost:7680",
      authToken: nil,
      clientPath: "/tmp/tether-client",
      offset: 4096,
      tailBytes: nil,
      metadataPath: "/tmp/terminal metadata.jsonl",
    )

    XCTAssertTrue(command.contains("--offset 4096"))
    XCTAssertFalse(command.contains("--tail-bytes"))
    XCTAssertTrue(command.contains("--metadata-path '/tmp/terminal metadata.jsonl'"))
  }

  func testBuildAttachCommandUsesThirtyTwoMiBTailByDefault() {
    let command = TerminalView.buildAttachCommand(
      sessionId: "session-123",
      serverBaseUrl: "http://localhost:7680",
      authToken: nil,
      clientPath: "/tmp/tether-client"
    )

    XCTAssertTrue(command.contains("--tail-bytes 33554432"))
  }

  func testHandleActionPostsSearchNotifications() {
    TerminalApp.shared.setup()
    guard let app = TerminalApp.shared.app else {
      XCTFail("ghostty app failed to initialize")
      return
    }
    let surface = ghostty_surface_t(bitPattern: 0x1234)

    let started = expectation(forNotification: .terminalSearchStarted, object: nil) { note in
      (note.userInfo?["surface"] as? OpaquePointer) == OpaquePointer(surface)
        && (note.userInfo?["needle"] as? String) == "codex"
    }

    let totalChanged = expectation(forNotification: .terminalSearchTotalChanged, object: nil) { note in
      (note.userInfo?["surface"] as? OpaquePointer) == OpaquePointer(surface)
        && (note.userInfo?["total"] as? Int) == 5
    }

    let selectedChanged = expectation(forNotification: .terminalSearchSelectionChanged, object: nil) { note in
      (note.userInfo?["surface"] as? OpaquePointer) == OpaquePointer(surface)
        && (note.userInfo?["selected"] as? Int) == 2
    }

    var totalAction = ghostty_action_s()
    totalAction.tag = GHOSTTY_ACTION_SEARCH_TOTAL
    totalAction.action.search_total.total = 5

    var selectedAction = ghostty_action_s()
    selectedAction.tag = GHOSTTY_ACTION_SEARCH_SELECTED
    selectedAction.action.search_selected.selected = 2

    var target = ghostty_target_s()
    target.tag = GHOSTTY_TARGET_SURFACE
    target.target.surface = surface

    "codex".withCString { ptr in
      var startAction = ghostty_action_s()
      startAction.tag = GHOSTTY_ACTION_START_SEARCH
      startAction.action.start_search.needle = ptr
      TerminalApp.shared.handleAction(app: app, target: target, action: startAction)
    }
    TerminalApp.shared.handleAction(app: app, target: target, action: totalAction)
    TerminalApp.shared.handleAction(app: app, target: target, action: selectedAction)

    wait(for: [started, totalChanged, selectedChanged], timeout: 1.0)
  }

  func testHandleActionPostsScrollbarNotification() {
    TerminalApp.shared.setup()
    guard let app = TerminalApp.shared.app else {
      XCTFail("ghostty app failed to initialize")
      return
    }
    let surface = ghostty_surface_t(bitPattern: 0x5678)

    let scrollbarChanged = expectation(forNotification: .terminalScrollbarChanged, object: nil) { note in
      (note.userInfo?["surface"] as? OpaquePointer) == OpaquePointer(surface)
        && (note.userInfo?["total"] as? UInt64) == 100
        && (note.userInfo?["offset"] as? UInt64) == 25
        && (note.userInfo?["len"] as? UInt64) == 10
    }

    var action = ghostty_action_s()
    action.tag = GHOSTTY_ACTION_SCROLLBAR
    action.action.scrollbar.total = 100
    action.action.scrollbar.offset = 25
    action.action.scrollbar.len = 10

    var target = ghostty_target_s()
    target.tag = GHOSTTY_TARGET_SURFACE
    target.target.surface = surface

    TerminalApp.shared.handleAction(app: app, target: target, action: action)

    wait(for: [scrollbarChanged], timeout: 1.0)
  }

  func testHandleActionPostsDesktopNotificationEvent() {
    TerminalApp.shared.setup()
    guard let app = TerminalApp.shared.app else {
      XCTFail("ghostty app failed to initialize")
      return
    }
    let surface = ghostty_surface_t(bitPattern: 0x2222)

    let desktopNotification = expectation(
      forNotification: .terminalDesktopNotification,
      object: nil
    ) { note in
      (note.userInfo?["surface"] as? OpaquePointer) == OpaquePointer(surface)
        && (note.userInfo?["title"] as? String) == "Codex"
        && (note.userInfo?["body"] as? String) == "needs input"
    }

    var action = ghostty_action_s()
    action.tag = GHOSTTY_ACTION_DESKTOP_NOTIFICATION
    var target = ghostty_target_s()
    target.tag = GHOSTTY_TARGET_SURFACE
    target.target.surface = surface

    "Codex".withCString { titlePtr in
      "needs input".withCString { bodyPtr in
        action.action.desktop_notification.title = titlePtr
        action.action.desktop_notification.body = bodyPtr
        TerminalApp.shared.handleAction(app: app, target: target, action: action)
      }
    }

    wait(for: [desktopNotification], timeout: 1.0)
  }

  func testFocusedSurfaceSuppressesDesktopNotificationDelivery() {
    let center = TerminalDesktopNotificationCenter()

    XCTAssertFalse(
      center.shouldDeliverDesktopNotification(
        appIsActive: true,
        windowIsKey: true,
        surfaceIsFocused: true
      )
    )
    XCTAssertTrue(
      center.shouldDeliverDesktopNotification(
        appIsActive: false,
        windowIsKey: false,
        surfaceIsFocused: false
      )
    )
  }

  func testScrollActionForLiveScrollConvertsViewportToRow() {
    let action = TerminalView.scrollActionForLiveScroll(
      documentHeight: 1000,
      visibleOriginY: 700,
      visibleHeight: 200,
      cellHeight: 10,
      lastSentRow: nil,
    )

    XCTAssertEqual(action, "scroll_to_row:10")
  }

  func testScrollActionForLiveScrollSuppressesDuplicateRow() {
    let action = TerminalView.scrollActionForLiveScroll(
      documentHeight: 1000,
      visibleOriginY: 700,
      visibleHeight: 200,
      cellHeight: 10,
      lastSentRow: 10,
    )

    XCTAssertNil(action)
  }

  func testScrollSynchronizationResultDefersOffsetWhileInactive() {
    let result = TerminalView.scrollSynchronizationResult(
      contentHeight: 200,
      cellHeight: 10,
      scrollbarState: TerminalScrollbarState(total: 100, offset: 20, len: 10),
      isLiveScrolling: false,
      shouldApplyScrollOffset: false
    )

    XCTAssertEqual(result.documentHeight, 1100)
    XCTAssertNil(result.targetOffsetY)
    XCTAssertNil(result.lastSentRow)
  }

  func testScrollSynchronizationResultAppliesLatestOffsetWhenActive() {
    let result = TerminalView.scrollSynchronizationResult(
      contentHeight: 200,
      cellHeight: 10,
      scrollbarState: TerminalScrollbarState(total: 100, offset: 5, len: 10),
      isLiveScrolling: false,
      shouldApplyScrollOffset: true
    )

    XCTAssertEqual(result.documentHeight, 1100)
    XCTAssertEqual(result.targetOffsetY, 850)
    XCTAssertEqual(result.lastSentRow, 5)
  }

  func testScrollSynchronizationResultSuppressesOffsetDuringLiveScroll() {
    let result = TerminalView.scrollSynchronizationResult(
      contentHeight: 200,
      cellHeight: 10,
      scrollbarState: TerminalScrollbarState(total: 100, offset: 5, len: 10),
      isLiveScrolling: true,
      shouldApplyScrollOffset: true
    )

    XCTAssertEqual(result.documentHeight, 1100)
    XCTAssertNil(result.targetOffsetY)
    XCTAssertNil(result.lastSentRow)
  }

  func testMouseExitReportingMatchesGhosttyDragBehavior() {
    XCTAssertFalse(TerminalView.shouldReportMouseExit(pressedMouseButtons: 1))
    XCTAssertTrue(TerminalView.shouldReportMouseExit(pressedMouseButtons: 0))
  }

  func testScrollbarActivationCoordinatorCoalescesUpdatesAroundReactivation() {
    var coordinator = ScrollbarActivationCoordinator()
    let inactiveLatest = TerminalScrollbarState(total: 100, offset: 12, len: 10)
    let intermediate = TerminalScrollbarState(total: 100, offset: 6, len: 10)
    let final = TerminalScrollbarState(total: 100, offset: 2, len: 10)

    XCTAssertEqual(coordinator.receive(inactiveLatest), .apply(inactiveLatest))
    XCTAssertEqual(coordinator.setActive(false), .deferred)
    XCTAssertEqual(coordinator.receive(inactiveLatest), .deferred)

    XCTAssertEqual(coordinator.setActive(true), .apply(inactiveLatest))
    XCTAssertEqual(coordinator.receive(intermediate), .deferred)
    XCTAssertEqual(coordinator.receive(final), .deferred)
    XCTAssertEqual(
      coordinator.flushDeferredActivationState(),
      .apply(final)
    )

    let steadyState = TerminalScrollbarState(total: 100, offset: 0, len: 10)
    XCTAssertEqual(coordinator.receive(steadyState), .apply(steadyState))
  }

  func testPasteFallbackSkipsWhenSuperHandled() {
    XCTAssertFalse(
      MainFlutterWindow.shouldUsePasteChannelFallback(
        eventType: .keyDown,
        modifierFlags: .command,
        charactersIgnoringModifiers: "v",
        superHandled: true,
      )
    )
  }

  func testPasteFallbackOnlyHandlesCmdV() {
    XCTAssertTrue(
      MainFlutterWindow.shouldUsePasteChannelFallback(
        eventType: .keyDown,
        modifierFlags: .command,
        charactersIgnoringModifiers: "v",
        superHandled: false,
      )
    )
    XCTAssertFalse(
      MainFlutterWindow.shouldUsePasteChannelFallback(
        eventType: .keyDown,
        modifierFlags: [.command, .shift],
        charactersIgnoringModifiers: "v",
        superHandled: false,
      )
    )
    XCTAssertFalse(
      MainFlutterWindow.shouldUsePasteChannelFallback(
        eventType: .keyDown,
        modifierFlags: .command,
        charactersIgnoringModifiers: "c",
        superHandled: false,
      )
    )
  }

  func testDesktopShortcutCmdRReturnsRenameCurrentSession() {
    let payload = MainFlutterWindow.desktopActionPayload(
      eventType: .keyDown,
      modifierFlags: .command,
      characters: "r",
      charactersIgnoringModifiers: "r",
    )
    XCTAssertEqual(payload?.action, "renameCurrentSession")
    XCTAssertNil(payload?.index)
  }

  func testDesktopShortcutCmdShiftRReturnsRenameCurrentProject() {
    let payload = MainFlutterWindow.desktopActionPayload(
      eventType: .keyDown,
      modifierFlags: [.command, .shift],
      characters: "R",
      charactersIgnoringModifiers: "R",
    )
    XCTAssertEqual(payload?.action, "renameCurrentProject")
    XCTAssertNil(payload?.index)
  }

  func testDesktopShortcutCmdNReturnsNewProject() {
    let payload = MainFlutterWindow.desktopActionPayload(
      eventType: .keyDown,
      modifierFlags: .command,
      characters: "n",
      charactersIgnoringModifiers: "n",
    )
    XCTAssertEqual(payload?.action, "newProject")
    XCTAssertNil(payload?.index)
  }

  func testDesktopShortcutCmdTReturnsNewSession() {
    let payload = MainFlutterWindow.desktopActionPayload(
      eventType: .keyDown,
      modifierFlags: .command,
      characters: "t",
      charactersIgnoringModifiers: "t",
    )
    XCTAssertEqual(payload?.action, "newSession")
    XCTAssertNil(payload?.index)
  }

  func testDesktopShortcutCmdWReturnsCloseCurrentSession() {
    let payload = MainFlutterWindow.desktopActionPayload(
      eventType: .keyDown,
      modifierFlags: .command,
      characters: "w",
      charactersIgnoringModifiers: "w",
    )
    XCTAssertEqual(payload?.action, "closeCurrentSession")
    XCTAssertNil(payload?.index)
  }

  func testDesktopShortcutCmd1ReturnsSelectProjectByNumber() {
    let payload = MainFlutterWindow.desktopActionPayload(
      eventType: .keyDown,
      modifierFlags: .command,
      characters: "1",
      charactersIgnoringModifiers: "1",
    )
    XCTAssertEqual(payload?.action, "selectProjectByNumber")
    XCTAssertEqual(payload?.index, 0)
  }

  func testDesktopShortcutCtrl1ReturnsSelectSessionByNumber() {
    let payload = MainFlutterWindow.desktopActionPayload(
      eventType: .keyDown,
      modifierFlags: .control,
      characters: "1",
      charactersIgnoringModifiers: "1",
    )
    XCTAssertEqual(payload?.action, "selectSessionByNumber")
    XCTAssertEqual(payload?.index, 0)
  }

  func testDesktopShortcutCmdFReturnsShowSearch() {
    let payload = MainFlutterWindow.desktopActionPayload(
      eventType: .keyDown,
      modifierFlags: .command,
      characters: "f",
      charactersIgnoringModifiers: "f"
    )
    XCTAssertEqual(payload?.action, "showSearch")
    XCTAssertNil(payload?.index)
  }

  func testDesktopShortcutCmdBReturnsToggleSidebar() {
    let payload = MainFlutterWindow.desktopActionPayload(
      eventType: .keyDown,
      modifierFlags: .command,
      characters: "b",
      charactersIgnoringModifiers: "b"
    )
    XCTAssertEqual(payload?.action, "toggleSidebar")
    XCTAssertNil(payload?.index)
  }

  func testDesktopShortcutCmdEqualReturnsIncreaseFontSize() {
    let payload = MainFlutterWindow.desktopActionPayload(
      eventType: .keyDown,
      modifierFlags: .command,
      characters: "=",
      charactersIgnoringModifiers: "="
    )
    XCTAssertEqual(payload?.action, "increaseFontSize")
    XCTAssertNil(payload?.index)
  }

  func testDesktopShortcutCmdShiftEqualReturnsIncreaseFontSize() {
    let payload = MainFlutterWindow.desktopActionPayload(
      eventType: .keyDown,
      modifierFlags: [.command, .shift],
      characters: "+",
      charactersIgnoringModifiers: "="
    )
    XCTAssertEqual(payload?.action, "increaseFontSize")
    XCTAssertNil(payload?.index)
  }

  func testDesktopShortcutCmdMinusReturnsDecreaseFontSize() {
    let payload = MainFlutterWindow.desktopActionPayload(
      eventType: .keyDown,
      modifierFlags: .command,
      characters: "-",
      charactersIgnoringModifiers: "-"
    )
    XCTAssertEqual(payload?.action, "decreaseFontSize")
    XCTAssertNil(payload?.index)
  }

  func testDesktopShortcutCmd0ReturnsResetFontSize() {
    let payload = MainFlutterWindow.desktopActionPayload(
      eventType: .keyDown,
      modifierFlags: .command,
      characters: "0",
      charactersIgnoringModifiers: "0"
    )
    XCTAssertEqual(payload?.action, "resetFontSize")
    XCTAssertNil(payload?.index)
  }

  func testDesktopShortcutReturnsNilForNonKeyDownEvent() {
    let payload = MainFlutterWindow.desktopActionPayload(
      eventType: .flagsChanged,
      modifierFlags: .command,
      characters: "r",
      charactersIgnoringModifiers: "r"
    )
    XCTAssertNil(payload)
  }

  func testTerminalFocusedResponderMarker() {
    XCTAssertTrue(
      MainFlutterWindow.isTerminalFocusedResponder(TerminalMarkerResponder())
    )
    XCTAssertFalse(
      MainFlutterWindow.isTerminalFocusedResponder(NSResponder())
    )
  }

  func testClipboardMenuValidation() {
    XCTAssertTrue(
      TerminalView.isClipboardMenuActionEnabled(
        action: TerminalView.copySelector,
        hasSelection: true,
        canPaste: false,
      )
    )
    XCTAssertFalse(
      TerminalView.isClipboardMenuActionEnabled(
        action: TerminalView.copySelector,
        hasSelection: false,
        canPaste: true,
      )
    )
    XCTAssertTrue(
      TerminalView.isClipboardMenuActionEnabled(
        action: TerminalView.pasteSelector,
        hasSelection: false,
        canPaste: true,
      )
    )
    XCTAssertTrue(
      TerminalView.isClipboardMenuActionEnabled(
        action: TerminalView.pasteAsPlainTextSelector,
        hasSelection: false,
        canPaste: true,
      )
    )
    XCTAssertFalse(
      TerminalView.isClipboardMenuActionEnabled(
        action: TerminalView.pasteSelector,
        hasSelection: true,
        canPaste: false,
      )
    )
  }

  func testKeyboardPasteRoutingRequiresExactCtrlVWithBridgeAndImage() {
    XCTAssertEqual(
      TerminalView.keyboardPasteRoutingAction(
        eventType: .keyDown,
        modifierFlags: .control,
        charactersIgnoringModifiers: "v",
        imagePasteBridgeEnabled: true,
        pasteboardHasImage: true,
      ),
      .emitImageEvent,
    )
    XCTAssertEqual(
      TerminalView.keyboardPasteRoutingAction(
        eventType: .keyDown,
        modifierFlags: [.control, .shift],
        charactersIgnoringModifiers: "v",
        imagePasteBridgeEnabled: true,
        pasteboardHasImage: true,
      ),
      .ignore,
    )
    XCTAssertEqual(
      TerminalView.keyboardPasteRoutingAction(
        eventType: .keyDown,
        modifierFlags: .command,
        charactersIgnoringModifiers: "v",
        imagePasteBridgeEnabled: true,
        pasteboardHasImage: true,
      ),
      .ignore,
    )
    XCTAssertEqual(
      TerminalView.keyboardPasteRoutingAction(
        eventType: .keyDown,
        modifierFlags: .control,
        charactersIgnoringModifiers: "c",
        imagePasteBridgeEnabled: true,
        pasteboardHasImage: true,
      ),
      .ignore,
    )
    XCTAssertEqual(
      TerminalView.keyboardPasteRoutingAction(
        eventType: .flagsChanged,
        modifierFlags: .control,
        charactersIgnoringModifiers: "v",
        imagePasteBridgeEnabled: true,
        pasteboardHasImage: true,
      ),
      .ignore,
    )
    XCTAssertEqual(
      TerminalView.keyboardPasteRoutingAction(
        eventType: .keyDown,
        modifierFlags: .control,
        charactersIgnoringModifiers: "v",
        imagePasteBridgeEnabled: false,
        pasteboardHasImage: true,
      ),
      .ignore,
    )
    XCTAssertEqual(
      TerminalView.keyboardPasteRoutingAction(
        eventType: .keyDown,
        modifierFlags: .control,
        charactersIgnoringModifiers: "v",
        imagePasteBridgeEnabled: true,
        pasteboardHasImage: false,
      ),
      .ignore,
    )
  }

  func testPasteCommandRoutingPrefersImageBridgeBeforeTextFallback() {
    XCTAssertEqual(
      TerminalView.pasteCommandRoutingAction(
        imagePasteBridgeEnabled: true,
        pasteboardHasImage: true,
        pasteboardHasText: true,
      ),
      .emitImageEvent,
    )
    XCTAssertEqual(
      TerminalView.pasteCommandRoutingAction(
        imagePasteBridgeEnabled: false,
        pasteboardHasImage: true,
        pasteboardHasText: true,
      ),
      .forwardClipboardText,
    )
    XCTAssertEqual(
      TerminalView.pasteCommandRoutingAction(
        imagePasteBridgeEnabled: true,
        pasteboardHasImage: false,
        pasteboardHasText: true,
      ),
      .forwardClipboardText,
    )
    XCTAssertEqual(
      TerminalView.pasteCommandRoutingAction(
        imagePasteBridgeEnabled: true,
        pasteboardHasImage: false,
        pasteboardHasText: false,
      ),
      .ignore,
    )
  }

  func testSurfaceLookupTracksRegistrationLifecycle() {
    guard let surface = ghostty_surface_t(bitPattern: 0x9876),
          let userdata = UnsafeMutableRawPointer(bitPattern: 0x1234) else {
      XCTFail("failed to construct fake pointers")
      return
    }

    XCTAssertNil(TerminalApp.shared.surface(forUserdata: userdata))

    TerminalApp.shared.registerSurface(surface, userdata: userdata)
    XCTAssertEqual(TerminalApp.shared.surface(forUserdata: userdata), surface)

    TerminalApp.shared.unregisterSurface(surface, userdata: userdata)
    XCTAssertNil(TerminalApp.shared.surface(forUserdata: userdata))
  }

  func testCompleteClipboardRequestSkipsMissingSurface() {
    let userdata = UnsafeMutableRawPointer(bitPattern: 0xDEAD)
    let state = UnsafeMutableRawPointer(bitPattern: 0xBEEF)

    let completed = "paste".withCString { ptr in
      TerminalApp.shared.completeClipboardRequest(
        surfaceUserdata: userdata,
        text: ptr,
        state: state,
        confirmed: false,
      )
    }

    XCTAssertFalse(completed)
  }

  func testTerminalAppReactivationRestoresGhosttyFocusWithoutForcedRedraw() {
    TerminalApp.shared.setup()
    guard let surface = ghostty_surface_t(bitPattern: 0x4321) else {
      XCTFail("failed to construct fake surface pointer")
      return
    }

    var focusValues: [Bool] = []
    var redrawCount = 0

    TerminalApp.shared.focusSetterForTesting = { _, focused in
      focusValues.append(focused)
    }
    TerminalApp.shared.drawHandlerForTesting = { drawnSurface in
      if drawnSurface == surface {
        redrawCount += 1
      }
    }
    TerminalApp.shared.registerSurface(surface)
    defer {
      TerminalApp.shared.unregisterSurface(surface)
      TerminalApp.shared.focusSetterForTesting = nil
      TerminalApp.shared.drawHandlerForTesting = nil
    }

    NotificationCenter.default.post(
      name: NSApplication.didResignActiveNotification,
      object: NSApp
    )
    NotificationCenter.default.post(
      name: NSApplication.didBecomeActiveNotification,
      object: NSApp
    )

    XCTAssertEqual(focusValues, [false, true])
    XCTAssertEqual(redrawCount, 0)
  }

  func testTerminalAppReactivationLogsAppFocusTransitions() throws {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("tether-runner-focus-\(UUID().uuidString)", isDirectory: true)
    let eventLogURL = tempRoot.appendingPathComponent("terminal-events.jsonl")
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    setenv("TETHER_TERMINAL_TEST_LOG_PATH", eventLogURL.path, 1)
    defer {
      unsetenv("TETHER_TERMINAL_TEST_LOG_PATH")
      try? FileManager.default.removeItem(at: tempRoot)
    }

    TerminalApp.shared.setup()

    NotificationCenter.default.post(
      name: NSApplication.didResignActiveNotification,
      object: NSApp
    )
    NotificationCenter.default.post(
      name: NSApplication.didBecomeActiveNotification,
      object: NSApp
    )

    let events = try waitForLoggedEvents(
      at: eventLogURL,
      named: "app_focus_changed",
      minimumCount: 2
    )
    XCTAssertEqual(events.count, 2)
    XCTAssertEqual(events[0]["focused"] as? Bool, false)
    XCTAssertEqual(events[1]["focused"] as? Bool, true)
  }

  func testTerminalSurfaceFocusLoggingTracksFirstResponderTransitions() throws {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("tether-surface-focus-\(UUID().uuidString)", isDirectory: true)
    let eventLogURL = tempRoot.appendingPathComponent("terminal-events.jsonl")
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    setenv("TETHER_TERMINAL_TEST_LOG_PATH", eventLogURL.path, 1)
    defer {
      unsetenv("TETHER_TERMINAL_TEST_LOG_PATH")
      try? FileManager.default.removeItem(at: tempRoot)
    }

    TerminalApp.shared.setup()
    let logger = TerminalTestLogger(sessionId: "surface-focus-test")
    let attachOptions = TerminalAttachOptions(
      offset: nil,
      tailBytes: nil,
      metadataPath: nil,
      role: "primary"
    )
    let surfaceView = TerminalSurfaceView(
      sessionId: "surface-focus-session",
      serverBaseUrl: nil,
      authToken: nil,
      eventSink: nil,
      attachOptions: attachOptions,
      interactionEnabled: true,
      testLogger: logger
    )

    surfaceView.debugSetFocusForTesting(true)
    surfaceView.debugSetFocusForTesting(false)

    let events = try waitForLoggedEvents(
      at: eventLogURL,
      named: "surface_focus_changed",
      minimumCount: 2
    )
    XCTAssertEqual(events.count, 2)
    XCTAssertEqual(events[0]["focused"] as? Bool, true)
    XCTAssertEqual(events[1]["focused"] as? Bool, false)
    XCTAssertEqual(events[0]["role"] as? String, "primary")
    XCTAssertEqual(events[1]["role"] as? String, "primary")
  }

  func testNativeTerminalUsesSingleLargeInitialReplayWithoutLazyLoading() throws {
    let harness = try TerminalLazyLoadingHarness()
    defer { harness.cleanup() }

    TerminalApp.shared.setup()
    let sessionId = try harness.provisionSession(named: "lazy-session")
    let terminalView: TerminalView = DispatchQueue.main.sync {
      let terminalView = TerminalView(
        sessionId: sessionId,
        serverBaseUrl: "http://127.0.0.1:\(harness.port)",
        authToken: nil,
      )

      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false,
      )
      window.contentView = terminalView
      window.makeKeyAndOrderFront(nil)
      terminalView.window?.displayIfNeeded()
      return terminalView
    }
    defer {
      DispatchQueue.main.sync {
        terminalView.window?.orderOut(nil)
        terminalView.window?.close()
      }
    }

    let primaryAttach = try harness.waitForEvent(named: "attach_started", timeout: 20) {
      ($0["role"] as? String) == "primary"
    }
    XCTAssertEqual(TerminalLazyLoadingHarness.uint64(primaryAttach, key: "tail_bytes"), 33_554_432)
    XCTAssertNil(primaryAttach["offset"])

    let primaryScrollback = try harness.waitForEvent(named: "scrollback_info", timeout: 20) {
      ($0["role"] as? String) == "primary"
    }
    let initialLoadedFrom = try XCTUnwrap(
      TerminalLazyLoadingHarness.uint64(primaryScrollback, key: "loaded_from")
    )
    XCTAssertGreaterThan(initialLoadedFrom, 0)

    try harness.scrollToRatio(terminalView: terminalView, targetRatio: 1.0)
    try harness.assertNoEvent(named: "prefetch_started", during: 3.0)
    try harness.assertNoEvent(named: "prefetch_ready", during: 3.0)
    try harness.assertNoEvent(named: "swap_completed", during: 3.0)
    XCTAssertEqual(
      try harness.eventCount(named: "attach_started"),
      1
    )
    XCTAssertEqual(
      try harness.eventCount(named: "attach_started") { ($0["role"] as? String) == "primary" },
      1
    )
    XCTAssertEqual(terminalView.debugLoadedStartOffsetBytes, initialLoadedFrom)
  }

  func testNativeTerminalResizePreservesSemanticLoadedOffsets() throws {
    let harness = try TerminalLazyLoadingHarness()
    defer { harness.cleanup() }

    TerminalApp.shared.setup()
    let sessionId = try harness.provisionSemanticPromptSession(named: "semantic-resize-session")
    let terminalView: TerminalView = DispatchQueue.main.sync {
      let terminalView = TerminalView(
        sessionId: sessionId,
        serverBaseUrl: "http://127.0.0.1:\(harness.port)",
        authToken: nil,
      )

      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false,
      )
      window.contentView = terminalView
      window.makeKeyAndOrderFront(nil)
      terminalView.window?.displayIfNeeded()
      return terminalView
    }
    defer {
      DispatchQueue.main.sync {
        terminalView.window?.orderOut(nil)
        terminalView.window?.close()
      }
    }

    let primaryScrollback = try harness.waitForEvent(named: "scrollback_info", timeout: 20) {
      ($0["role"] as? String) == "primary"
    }
    let initialLoadedFrom = try XCTUnwrap(
      TerminalLazyLoadingHarness.uint64(primaryScrollback, key: "loaded_from")
    )
    let initialLoadedStartOffset = terminalView.debugLoadedStartOffsetBytes
    let initialTotalScrollbackBytes = terminalView.debugTotalScrollbackBytes
    XCTAssertEqual(initialLoadedStartOffset, initialLoadedFrom)
    XCTAssertGreaterThan(initialTotalScrollbackBytes, 0)

    DispatchQueue.main.sync {
      guard let window = terminalView.window else { return }
      let frame = window.frame
      window.setFrame(
        NSRect(x: frame.origin.x, y: frame.origin.y, width: 340, height: frame.height),
        display: true
      )
      window.displayIfNeeded()
      terminalView.layoutSubtreeIfNeeded()
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))

    XCTAssertEqual(terminalView.debugLoadedStartOffsetBytes, initialLoadedStartOffset)
    XCTAssertEqual(terminalView.debugTotalScrollbackBytes, initialTotalScrollbackBytes)
  }

  func testDesktopShortcutRoutingDispatchesRecognizedShortcutsForWorkspaceResponder() {
    let routing = MainFlutterWindow.desktopShortcutRouting(
      eventType: .keyDown,
      modifierFlags: .command,
      characters: "f",
      charactersIgnoringModifiers: "f",
      firstResponder: NSResponder(),
      hasAttachedSheet: false
    )

    XCTAssertEqual(
      routing,
      .dispatch(MainFlutterWindow.DesktopActionPayload(action: "showSearch", index: nil))
    )
  }

  func testDesktopShortcutRoutingSuppressesRecognizedShortcutsForEditableTextResponder() {
    let routing = MainFlutterWindow.desktopShortcutRouting(
      eventType: .keyDown,
      modifierFlags: .command,
      characters: "n",
      charactersIgnoringModifiers: "n",
      firstResponder: NSTextView(),
      hasAttachedSheet: false
    )

    XCTAssertEqual(routing, .suppress)
  }

  func testDesktopShortcutRoutingSuppressesRecognizedShortcutsForAttachedSheet() {
    let routing = MainFlutterWindow.desktopShortcutRouting(
      eventType: .keyDown,
      modifierFlags: .command,
      characters: "n",
      charactersIgnoringModifiers: "n",
      firstResponder: NSResponder(),
      hasAttachedSheet: true
    )

    XCTAssertEqual(routing, .suppress)
  }

  func testDesktopShortcutHintStateShowsCommandAndControlHintsForWorkspaceResponder() {
    let commandState = MainFlutterWindow.desktopShortcutHintState(
      modifierFlags: .command,
      firstResponder: NSResponder(),
      hasAttachedSheet: false
    )
    XCTAssertEqual(commandState.showProjectHints, true)
    XCTAssertEqual(commandState.showSessionHints, false)

    let controlState = MainFlutterWindow.desktopShortcutHintState(
      modifierFlags: .control,
      firstResponder: NSResponder(),
      hasAttachedSheet: false
    )
    XCTAssertEqual(controlState.showProjectHints, false)
    XCTAssertEqual(controlState.showSessionHints, true)
  }

  func testDesktopShortcutHintStateHidesHintsForEditableTextOrAttachedSheet() {
    let editableText = MainFlutterWindow.desktopShortcutHintState(
      modifierFlags: [.command, .control],
      firstResponder: NSTextView(),
      hasAttachedSheet: false
    )
    XCTAssertEqual(editableText.showProjectHints, false)
    XCTAssertEqual(editableText.showSessionHints, false)

    let attachedSheet = MainFlutterWindow.desktopShortcutHintState(
      modifierFlags: [.command, .control],
      firstResponder: NSResponder(),
      hasAttachedSheet: true
    )
    XCTAssertEqual(attachedSheet.showProjectHints, false)
    XCTAssertEqual(attachedSheet.showSessionHints, false)
  }

  func testTerminalViewForwardsWindowOwnedShortcutsToWindow() {
    XCTAssertTrue(
      TerminalView.shouldForwardShortcutToWindow(
        eventType: .keyDown,
        characters: "n",
        modifierFlags: .command,
        charactersIgnoringModifiers: "n"
      )
    )
    XCTAssertTrue(
      TerminalView.shouldForwardShortcutToWindow(
        eventType: .keyDown,
        characters: "1",
        modifierFlags: .control,
        charactersIgnoringModifiers: "1"
      )
    )
    XCTAssertTrue(
      TerminalView.shouldForwardShortcutToWindow(
        eventType: .keyDown,
        characters: "R",
        modifierFlags: [.command, .shift],
        charactersIgnoringModifiers: "r"
      )
    )
    XCTAssertTrue(
      TerminalView.shouldForwardShortcutToWindow(
        eventType: .keyDown,
        characters: "f",
        modifierFlags: .command,
        charactersIgnoringModifiers: "f"
      )
    )
    XCTAssertTrue(
      TerminalView.shouldForwardShortcutToWindow(
        eventType: .keyDown,
        characters: "w",
        modifierFlags: .command,
        charactersIgnoringModifiers: "w"
      )
    )
    XCTAssertTrue(
      TerminalView.shouldForwardShortcutToWindow(
        eventType: .keyDown,
        characters: "=",
        modifierFlags: .command,
        charactersIgnoringModifiers: "="
      )
    )
  }

  func testTerminalViewKeepsNonWindowOwnedShortcutsInTerminal() {
    XCTAssertFalse(
      TerminalView.shouldForwardShortcutToWindow(
        eventType: .keyDown,
        characters: "p",
        modifierFlags: .command,
        charactersIgnoringModifiers: "p"
      )
    )
    XCTAssertFalse(
      TerminalView.shouldForwardShortcutToWindow(
        eventType: .keyDown,
        characters: "v",
        modifierFlags: .command,
        charactersIgnoringModifiers: "v"
      )
    )
    XCTAssertFalse(
      TerminalView.shouldForwardShortcutToWindow(
        eventType: .keyDown,
        characters: "1",
        modifierFlags: [.command, .option],
        charactersIgnoringModifiers: "1"
      )
    )
    XCTAssertFalse(
      TerminalView.shouldForwardShortcutToWindow(
        eventType: .flagsChanged,
        characters: nil,
        modifierFlags: .command,
        charactersIgnoringModifiers: nil
      )
    )
  }

}

private func waitForLoggedEvents(
  at url: URL,
  named name: String,
  minimumCount: Int,
  timeout: TimeInterval = 2
) throws -> [[String: Any]] {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    let matches = try readLoggedEvents(at: url).filter { ($0["event"] as? String) == name }
    if matches.count >= minimumCount {
      return matches
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
  }

  XCTFail("timed out waiting for \(minimumCount) \(name) events")
  throw HarnessFailure("timed out waiting for \(minimumCount) \(name) events")
}

private func readLoggedEvents(at url: URL) throws -> [[String: Any]] {
  guard FileManager.default.fileExists(atPath: url.path) else { return [] }
  let contents = try String(contentsOf: url, encoding: .utf8)
  return contents
    .split(separator: "\n")
    .compactMap { line in
      guard let data = String(line).data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
      }
      return json
    }
}

private final class TerminalLazyLoadingHarness {
  let port = 17680
  private let repoRoot: URL
  private let tempRoot: URL
  private let eventLogURL: URL
  private var serverProcess: Process?

  init() throws {
    repoRoot = try Self.repoRoot()
    tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("tether-runner-tests-\(UUID().uuidString)", isDirectory: true)
    eventLogURL = tempRoot.appendingPathComponent("terminal-events.jsonl")
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    try ensureCargoBinary(named: "tether-server")
    try ensureCargoBinary(named: "tether-client")
    setenv("TETHER_CLIENT_PATH", repoRoot.appendingPathComponent("target/debug/tether-client").path, 1)
    setenv("TETHER_TERMINAL_TEST_LOG_PATH", eventLogURL.path, 1)
    setenv("TETHER_TERMINAL_TEST_MODE", "1", 1)
    try startServer()
  }

  func cleanup() {
    serverProcess?.terminate()
    serverProcess?.waitUntilExit()
    serverProcess = nil
    unsetenv("TETHER_CLIENT_PATH")
    unsetenv("TETHER_TERMINAL_TEST_LOG_PATH")
    unsetenv("TETHER_TERMINAL_TEST_MODE")
    try? FileManager.default.removeItem(at: tempRoot)
  }

  func provisionSession(named sessionName: String) throws -> String {
    let scriptURL = tempRoot.appendingPathComponent("emit-history.sh")
    let readyURL = tempRoot.appendingPathComponent("emit-history.ready")
    let script = """
    #!/bin/sh
    prefix=''
    j=0
    while [ "$j" -lt 128 ]; do
      prefix="${prefix}\\033[31m\\033[32m\\033[33m\\033[34m\\033[35m\\033[36m\\033[0m"
      j=$((j + 1))
    done
    i=0
    while [ "$i" -lt 8192 ]; do
      printf '%b' "$prefix"
      printf 'lazy-%06d line for mac lazy loading verification................................\\n' "$i"
      i=$((i + 1))
    done
    touch "\(readyURL.path)"
    while :; do
      sleep 1
    done
    """
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

    let groupResponse = try jsonResponse(
      url: URL(string: "http://127.0.0.1:\(port)/api/groups")!,
      method: "POST",
      body: [
        "name": "Runner Lazy Group",
        "default_cwd": tempRoot.path,
      ]
    )
    XCTAssertEqual(groupResponse.statusCode, 201)
    let groupId = try XCTUnwrap(groupResponse.json["id"] as? String)

    let sessionResponse = try jsonResponse(
      url: URL(string: "http://127.0.0.1:\(port)/api/sessions")!,
      method: "POST",
      body: [
        "group_id": groupId,
        "name": sessionName,
        "command": scriptURL.path,
        "cwd": tempRoot.path,
      ]
    )
    XCTAssertEqual(sessionResponse.statusCode, 201)
    let sessionId = try XCTUnwrap(sessionResponse.json["id"] as? String)

    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      let list = try jsonArrayResponse(url: URL(string: "http://127.0.0.1:\(port)/api/sessions")!)
      if let row = list.first(where: { ($0["id"] as? String) == sessionId }),
         let isAlive = row["is_alive"] as? Bool,
         isAlive {
        try waitForFile(at: readyURL, timeout: 20, description: "history fixture ready file")
        return sessionId
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    XCTFail("session did not become alive before timeout")
    throw HarnessFailure("session did not become alive before timeout")
  }

  func provisionSemanticPromptSession(named sessionName: String) throws -> String {
    let scriptURL = tempRoot.appendingPathComponent("emit-semantic-history.sh")
    let readyURL = tempRoot.appendingPathComponent("emit-semantic-history.ready")
    let script = """
    #!/bin/sh
    printf '\\033]133;A;redraw=1\\007'
    printf 'tether-codex> '
    printf '\\033]133;B\\007'
    printf 'plan a fix for wrapped codex overflow rendering that exceeds one terminal row and forces prompt redraw decisions in narrow windows'
    printf '\\r\\n'
    printf '\\033]133;C\\007'
    i=0
    while [ "$i" -lt 70000 ]; do
      printf 'semantic-%06d output line for resize verification with enough repeated width to wrap in narrow windows and preserve history integrity across rebuilds................................\\n' "$i"
      i=$((i + 1))
    done
    printf '\\033]133;D;0\\007'
    touch "\(readyURL.path)"
    while :; do
      sleep 1
    done
    """
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

    let groupResponse = try jsonResponse(
      url: URL(string: "http://127.0.0.1:\(port)/api/groups")!,
      method: "POST",
      body: [
        "name": "Runner Semantic Group",
        "default_cwd": tempRoot.path,
      ]
    )
    XCTAssertEqual(groupResponse.statusCode, 201)
    let groupId = try XCTUnwrap(groupResponse.json["id"] as? String)

    let sessionResponse = try jsonResponse(
      url: URL(string: "http://127.0.0.1:\(port)/api/sessions")!,
      method: "POST",
      body: [
        "group_id": groupId,
        "name": sessionName,
        "command": scriptURL.path,
        "cwd": tempRoot.path,
      ]
    )
    XCTAssertEqual(sessionResponse.statusCode, 201)
    let sessionId = try XCTUnwrap(sessionResponse.json["id"] as? String)

    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      let list = try jsonArrayResponse(url: URL(string: "http://127.0.0.1:\(port)/api/sessions")!)
      if let row = list.first(where: { ($0["id"] as? String) == sessionId }),
         let isAlive = row["is_alive"] as? Bool,
         isAlive {
        try waitForFile(at: readyURL, timeout: 20, description: "semantic fixture ready file")
        return sessionId
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    XCTFail("semantic session did not become alive before timeout")
    throw HarnessFailure("semantic session did not become alive before timeout")
  }

  func waitForEvent(
    named name: String,
    timeout: TimeInterval,
    where predicate: ([String: Any]) -> Bool = { _ in true }
  ) throws -> [String: Any] {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let event = try latestEvent(named: name, where: predicate) {
        return event
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }

    XCTFail("timed out waiting for event \(name)")
    throw HarnessFailure("timed out waiting for event \(name)")
  }

  func scroll(
    terminalView: TerminalView,
    untilEvent eventName: String,
    targetRatio: CGFloat,
    timeout: TimeInterval
  ) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if try latestEvent(named: eventName) != nil {
        return
      }
      let scrollView = terminalView.debugScrollView
      let maxOrigin = max(
        0,
        scrollView.documentView?.frame.height ?? 0 - scrollView.contentView.bounds.height
      )
      if maxOrigin > 0 {
        DispatchQueue.main.sync {
          NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView
          )
          scrollView.contentView.scroll(to: NSPoint(x: 0, y: maxOrigin * targetRatio))
          NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
          )
          NotificationCenter.default.post(
            name: NSScrollView.didLiveScrollNotification,
            object: scrollView
          )
          NotificationCenter.default.post(
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
          )
        }
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    XCTFail("timed out waiting for \(eventName)")
    throw HarnessFailure("timed out waiting for \(eventName)")
  }

  func scrollToRatio(
    terminalView: TerminalView,
    targetRatio: CGFloat
  ) throws {
    let scrollView = terminalView.debugScrollView
    let maxOrigin = max(
      0,
      scrollView.documentView?.frame.height ?? 0 - scrollView.contentView.bounds.height
    )
    guard maxOrigin > 0 else {
      XCTFail("expected scroll view to have scrollback content")
      throw HarnessFailure("expected scroll view to have scrollback content")
    }

    DispatchQueue.main.sync {
      NotificationCenter.default.post(
        name: NSScrollView.willStartLiveScrollNotification,
        object: scrollView
      )
      scrollView.contentView.scroll(to: NSPoint(x: 0, y: maxOrigin * targetRatio))
      NotificationCenter.default.post(
        name: NSView.boundsDidChangeNotification,
        object: scrollView.contentView
      )
      NotificationCenter.default.post(
        name: NSScrollView.didLiveScrollNotification,
        object: scrollView
      )
      NotificationCenter.default.post(
        name: NSScrollView.didEndLiveScrollNotification,
        object: scrollView
      )
    }
  }

  func assertNoEvent(
    named name: String,
    during duration: TimeInterval,
    where predicate: ([String: Any]) -> Bool = { _ in true }
  ) throws {
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline {
      if let event = try latestEvent(named: name, where: predicate) {
        XCTFail("unexpected event \(name): \(event)")
        throw HarnessFailure("unexpected event \(name)")
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
  }

  func waitForFile(
    at url: URL,
    timeout: TimeInterval,
    description: String
  ) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if FileManager.default.fileExists(atPath: url.path) {
        return
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }

    XCTFail("timed out waiting for \(description)")
    throw HarnessFailure("timed out waiting for \(description)")
  }

  func eventCount(
    named name: String,
    where predicate: ([String: Any]) -> Bool = { _ in true }
  ) throws -> Int {
    try readEvents().filter { ($0["event"] as? String) == name && predicate($0) }.count
  }

  private func startServer() throws {
    let process = Process()
    process.currentDirectoryURL = repoRoot
    process.executableURL = repoRoot.appendingPathComponent("target/debug/tether-server")
    process.arguments = ["--port", "\(port)"]
    var environment = ProcessInfo.processInfo.environment
    environment["TETHER_DATA_DIR"] = tempRoot.appendingPathComponent("data").path
    environment["RUST_LOG"] = "error"
    process.environment = environment
    let sink = Pipe()
    process.standardOutput = sink
    process.standardError = sink
    try process.run()
    serverProcess = process

    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
      if let response = try? jsonResponse(url: URL(string: "http://127.0.0.1:\(port)/api/info")!),
         response.statusCode == 200 {
        return
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    XCTFail("tether-server did not become ready before timeout")
    throw HarnessFailure("tether-server did not become ready before timeout")
  }

  private func ensureCargoBinary(named binaryName: String) throws {
    let binaryURL = repoRoot.appendingPathComponent("target/debug/\(binaryName)")
    guard !FileManager.default.isExecutableFile(atPath: binaryURL.path) else { return }

    let build = Process()
    build.currentDirectoryURL = repoRoot
    build.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    build.arguments = ["cargo", "build", "-p", binaryName]
    var environment = ProcessInfo.processInfo.environment
    let existingPath = environment["PATH"] ?? ""
    let home = environment["HOME"] ?? NSHomeDirectory()
    environment["PATH"] = "\(home)/.cargo/bin:/opt/homebrew/bin:\(existingPath)"
    build.environment = environment
    try build.run()
    build.waitUntilExit()
    XCTAssertEqual(build.terminationStatus, 0)
  }

  func latestEvent(
    named name: String,
    where predicate: ([String: Any]) -> Bool = { _ in true }
  ) throws -> [String: Any]? {
    try readEvents()
      .reversed()
      .first { ($0["event"] as? String) == name && predicate($0) }
  }

  private func readEvents() throws -> [[String: Any]] {
    guard FileManager.default.fileExists(atPath: eventLogURL.path) else { return [] }
    let contents = try String(contentsOf: eventLogURL, encoding: .utf8)
    return contents
      .split(separator: "\n")
      .compactMap { line in
        guard let data = String(line).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
          return nil
        }
        return json
      }
  }

  private func jsonResponse(
    url: URL,
    method: String = "GET",
    body: [String: Any]? = nil
  ) throws -> (statusCode: Int, json: [String: Any]) {
    var request = URLRequest(url: url)
    request.httpMethod = method
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let result = try synchronousData(for: request)
    let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: result.data) as? [String: Any])
    return (result.statusCode, json)
  }

  private func jsonArrayResponse(url: URL) throws -> [[String: Any]] {
    let result = try synchronousData(for: URLRequest(url: url))
    XCTAssertEqual(result.statusCode, 200)
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: result.data) as? [[String: Any]])
  }

  private func synchronousData(for request: URLRequest) throws -> (data: Data, statusCode: Int) {
    let semaphore = DispatchSemaphore(value: 0)
    var payload: Data?
    var responseCode = 0
    var capturedError: Error?

    URLSession.shared.dataTask(with: request) { data, response, error in
      defer { semaphore.signal() }
      if let error {
        capturedError = error
        return
      }
      payload = data
      responseCode = (response as? HTTPURLResponse)?.statusCode ?? 0
    }.resume()

    semaphore.wait()
    if let capturedError {
      throw capturedError
    }
    return (try XCTUnwrap(payload), responseCode)
  }

  private static func repoRoot() throws -> URL {
    var url = URL(fileURLWithPath: #filePath)
    while url.path != "/" {
      if FileManager.default.fileExists(atPath: url.appendingPathComponent("Cargo.toml").path) {
        return url
      }
      url.deleteLastPathComponent()
    }
    throw HarnessFailure("failed to resolve repo root")
  }

  static func uint64(_ payload: [String: Any], key: String) -> UInt64? {
    if let value = payload[key] as? NSNumber {
      return value.uint64Value
    }
    if let value = payload[key] as? String {
      return UInt64(value)
    }
    return nil
  }
}

private struct HarnessFailure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

private final class TerminalMarkerResponder: NSResponder, TerminalShortcutFocusable {}
