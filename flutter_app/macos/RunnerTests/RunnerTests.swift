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

}
