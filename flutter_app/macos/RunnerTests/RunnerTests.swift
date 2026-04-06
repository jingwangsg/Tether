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
    )

    XCTAssertTrue(command.contains("'/tmp/tether-client'"))
    XCTAssertTrue(command.contains("--server 'http://localhost:7680'"))
    XCTAssertTrue(command.contains("--session 'session-123'"))
    XCTAssertTrue(command.contains("--token 'tok'\"'\"'en value'"))
  }

  func testBuildAttachCommandFallsBackWhenServerUnavailable() {
    let command = TerminalView.buildAttachCommand(
      sessionId: "session-123",
      serverBaseUrl: nil,
      authToken: nil,
      clientPath: "/tmp/tether-client",
    )

    XCTAssertEqual(command, "printf 'tether-server is not connected\\n'; exit 1")
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

  func testRenameShortcutRequiresExactCmdROnTerminal() {
    XCTAssertTrue(
      MainFlutterWindow.shouldDispatchRenameShortcut(
        eventType: .keyDown,
        modifierFlags: .command,
        charactersIgnoringModifiers: "r",
        superHandled: false,
        firstResponderIsTerminal: true,
      )
    )
  }

  func testRenameShortcutSkipsWhenSuperHandledOrNotTerminal() {
    XCTAssertFalse(
      MainFlutterWindow.shouldDispatchRenameShortcut(
        eventType: .keyDown,
        modifierFlags: .command,
        charactersIgnoringModifiers: "r",
        superHandled: true,
        firstResponderIsTerminal: true,
      )
    )
    XCTAssertFalse(
      MainFlutterWindow.shouldDispatchRenameShortcut(
        eventType: .keyDown,
        modifierFlags: .command,
        charactersIgnoringModifiers: "r",
        superHandled: false,
        firstResponderIsTerminal: false,
      )
    )
  }

  func testRenameShortcutRejectsModifiedOrWrongKeys() {
    XCTAssertFalse(
      MainFlutterWindow.shouldDispatchRenameShortcut(
        eventType: .keyDown,
        modifierFlags: [.command, .shift],
        charactersIgnoringModifiers: "r",
        superHandled: false,
        firstResponderIsTerminal: true,
      )
    )
    XCTAssertFalse(
      MainFlutterWindow.shouldDispatchRenameShortcut(
        eventType: .keyDown,
        modifierFlags: [.command, .option],
        charactersIgnoringModifiers: "r",
        superHandled: false,
        firstResponderIsTerminal: true,
      )
    )
    XCTAssertFalse(
      MainFlutterWindow.shouldDispatchRenameShortcut(
        eventType: .keyDown,
        modifierFlags: .control,
        charactersIgnoringModifiers: "r",
        superHandled: false,
        firstResponderIsTerminal: true,
      )
    )
    XCTAssertFalse(
      MainFlutterWindow.shouldDispatchRenameShortcut(
        eventType: .keyDown,
        modifierFlags: .command,
        charactersIgnoringModifiers: "f",
        superHandled: false,
        firstResponderIsTerminal: true,
      )
    )
  }

  func testRenameShortcutRejectsNonKeyDownEvents() {
    XCTAssertFalse(
      MainFlutterWindow.shouldDispatchRenameShortcut(
        eventType: .flagsChanged,
        modifierFlags: .command,
        charactersIgnoringModifiers: "r",
        superHandled: false,
        firstResponderIsTerminal: true,
      )
    )
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

}

private final class TerminalMarkerResponder: NSResponder, TerminalShortcutFocusable {}
