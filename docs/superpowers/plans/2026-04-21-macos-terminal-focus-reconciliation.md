# macOS Terminal Focus Reconciliation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `Cmd+T`-created macOS terminal sessions in Tether accept keyboard input immediately without requiring an extra click.

**Architecture:** Keep AppKit focus ownership in native Swift. Add a small, explicit focus-reconciliation policy to `TerminalSurfaceView`, trigger it from native lifecycle events that already represent terminal activation, and lock the behavior down with focused XCTest and XCUITest coverage.

**Tech Stack:** Swift, AppKit, Flutter macOS host views, XCTest, XCUITest, `xcodebuild`, Flutter widget tests

---

## File Structure

- `flutter_app/macos/Runner/TerminalView.swift`
  Responsibility: define the focus-reconciliation policy, bounded retry behavior, window-key observer, and native lifecycle hooks for `TerminalSurfaceView`.
- `flutter_app/macos/RunnerTests/RunnerTests.swift`
  Responsibility: unit-test the new focus policy decisions so dialog/search/text-input blockers and retry conditions are deterministic.
- `flutter_app/macos/RunnerUITests/RunnerUITests.swift`
  Responsibility: reproduce the real `Cmd+T` path and prove the user can type into the new session without clicking.
- `flutter_app/test/home_screen_shortcut_test.dart`
  Responsibility: existing Flutter shell-shortcut contract. No code change planned, but run it as a guard so native focus work does not regress `Cmd+T` session creation semantics.

### Task 1: Add Native Focus Policy and Lock It With Unit Tests

**Files:**
- Modify: `flutter_app/macos/Runner/TerminalView.swift:660-727`
- Modify: `flutter_app/macos/Runner/TerminalView.swift:1088-1116`
- Test: `flutter_app/macos/RunnerTests/RunnerTests.swift:896-1058`

- [ ] **Step 1: Write the failing unit tests for focus-policy decisions**

Add these tests near the existing `MainFlutterWindow`/shortcut tests in `flutter_app/macos/RunnerTests/RunnerTests.swift`:

```swift
  func testTerminalInteractiveFocusDispositionAllowsEligibleKeyWindow() {
    let disposition = TerminalSurfaceView.interactiveFocusDisposition(
      isActiveInUI: true,
      isVisibleInUI: true,
      bounds: NSRect(x: 0, y: 0, width: 640, height: 400),
      firstResponder: NSResponder(),
      hasAttachedSheet: false,
      windowIsKey: true,
      windowExists: true
    )

    XCTAssertEqual(disposition, .focusNow)
  }

  func testTerminalInteractiveFocusDispositionBlocksEditableTextResponder() {
    let disposition = TerminalSurfaceView.interactiveFocusDisposition(
      isActiveInUI: true,
      isVisibleInUI: true,
      bounds: NSRect(x: 0, y: 0, width: 640, height: 400),
      firstResponder: NSTextView(),
      hasAttachedSheet: false,
      windowIsKey: true,
      windowExists: true
    )

    XCTAssertEqual(disposition, .blocked)
  }

  func testTerminalInteractiveFocusDispositionRequestsRetryBeforeWindowExists() {
    let disposition = TerminalSurfaceView.interactiveFocusDisposition(
      isActiveInUI: true,
      isVisibleInUI: true,
      bounds: NSRect(x: 0, y: 0, width: 640, height: 400),
      firstResponder: nil,
      hasAttachedSheet: false,
      windowIsKey: false,
      windowExists: false
    )

    XCTAssertEqual(disposition, .retryOnNextRunLoop)
  }

  func testTerminalInteractiveFocusDispositionRequestsRetryForTinyBounds() {
    let disposition = TerminalSurfaceView.interactiveFocusDisposition(
      isActiveInUI: true,
      isVisibleInUI: true,
      bounds: NSRect(x: 0, y: 0, width: 1, height: 1),
      firstResponder: NSResponder(),
      hasAttachedSheet: false,
      windowIsKey: true,
      windowExists: true
    )

    XCTAssertEqual(disposition, .retryOnNextRunLoop)
  }

  func testTerminalInteractiveFocusDispositionBlocksAttachedSheet() {
    let disposition = TerminalSurfaceView.interactiveFocusDisposition(
      isActiveInUI: true,
      isVisibleInUI: true,
      bounds: NSRect(x: 0, y: 0, width: 640, height: 400),
      firstResponder: NSResponder(),
      hasAttachedSheet: true,
      windowIsKey: true,
      windowExists: true
    )

    XCTAssertEqual(disposition, .blocked)
  }

  func testTerminalInteractiveFocusDispositionBlocksInactiveOrHiddenSurface() {
    XCTAssertEqual(
      TerminalSurfaceView.interactiveFocusDisposition(
        isActiveInUI: false,
        isVisibleInUI: true,
        bounds: NSRect(x: 0, y: 0, width: 640, height: 400),
        firstResponder: NSResponder(),
        hasAttachedSheet: false,
        windowIsKey: true,
        windowExists: true
      ),
      .blocked
    )

    XCTAssertEqual(
      TerminalSurfaceView.interactiveFocusDisposition(
        isActiveInUI: true,
        isVisibleInUI: false,
        bounds: NSRect(x: 0, y: 0, width: 640, height: 400),
        firstResponder: NSResponder(),
        hasAttachedSheet: false,
        windowIsKey: true,
        windowExists: true
      ),
      .blocked
    )
  }
```

- [ ] **Step 2: Run the native unit tests to verify they fail for the missing focus policy**

Run:

```bash
cd flutter_app/macos && xcodebuild test \
  -workspace Runner.xcworkspace \
  -scheme Runner \
  -destination 'platform=macOS' \
  -only-testing:RunnerTests/RunnerTests
```

Expected: FAIL at compile time because `TerminalSurfaceView.interactiveFocusDisposition` and `.retryOnNextRunLoop` / `.focusNow` do not exist yet.

- [ ] **Step 3: Implement the focus-policy enum and helper in `TerminalSurfaceView`**

Add this code in `flutter_app/macos/Runner/TerminalView.swift` near `TerminalSurfaceView`'s focus state:

```swift
extension TerminalSurfaceView {
    enum InteractiveFocusDisposition: Equatable {
        case focusNow
        case retryOnNextRunLoop
        case blocked
    }

    static func interactiveFocusDisposition(
        isActiveInUI: Bool,
        isVisibleInUI: Bool,
        bounds: NSRect,
        firstResponder: NSResponder?,
        hasAttachedSheet: Bool,
        windowIsKey: Bool,
        windowExists: Bool
    ) -> InteractiveFocusDisposition {
        guard isActiveInUI, isVisibleInUI else { return .blocked }
        guard windowExists else { return .retryOnNextRunLoop }
        guard bounds.width > 1, bounds.height > 1 else { return .retryOnNextRunLoop }
        guard !hasAttachedSheet else { return .blocked }
        guard !MainFlutterWindow.isEditableTextResponder(firstResponder) else {
            return .blocked
        }
        guard windowIsKey else { return .retryOnNextRunLoop }
        return .focusNow
    }
}
```

Do not wire lifecycle triggers yet in this task. Keep this task scoped to policy definition and pure testability.

- [ ] **Step 4: Run the native unit tests again and verify the policy tests pass**

Run:

```bash
cd flutter_app/macos && xcodebuild test \
  -workspace Runner.xcworkspace \
  -scheme Runner \
  -destination 'platform=macOS' \
  -only-testing:RunnerTests/RunnerTests
```

Expected: PASS for the new focus-policy tests and the pre-existing RunnerTests suite.

- [ ] **Step 5: Commit the policy-only change**

```bash
git add flutter_app/macos/Runner/TerminalView.swift flutter_app/macos/RunnerTests/RunnerTests.swift
git commit -m "test: lock macOS terminal focus policy"
```

### Task 2: Reconcile AppKit First Responder on Attach, Activation, and Window Reactivation

**Files:**
- Modify: `flutter_app/macos/Runner/TerminalView.swift:394-420`
- Modify: `flutter_app/macos/Runner/TerminalView.swift:676-727`
- Modify: `flutter_app/macos/Runner/TerminalView.swift:1088-1195`
- Modify: `flutter_app/macos/Runner/TerminalView.swift:1524-1563`
- Test: `flutter_app/macos/RunnerUITests/RunnerUITests.swift:230-316`
- Test: `flutter_app/macos/RunnerUITests/RunnerUITests.swift:734-783`

- [ ] **Step 1: Write the failing macOS UI regression for `Cmd+T` typing without an extra click**

Add this test and helpers to `flutter_app/macos/RunnerUITests/RunnerUITests.swift`:

```swift
    func testCmdTSessionAcceptsTypingWithoutExtraClick() throws {
        let runId = String(UUID().uuidString.prefix(8))
        let seedSessionName = "seed-\(runId)"

        if canReachConfiguredExternalServer() {
            try waitForServerReady()
        } else {
            try ensureCargoBinary(named: "tether-server")
            try startServer()
        }
        try ensureCargoBinary(named: "tether-client")

        let groupId = try createGroup(named: "Focus Group \(runId)")
        _ = try provisionCommandSession(
            named: seedSessionName,
            groupId: groupId,
            command: "while :; do sleep 1; done"
        )

        let app = XCUIApplication()
        app.launchEnvironment["TETHER_CLIENT_PATH"] =
            repoRoot.appendingPathComponent("target/debug/tether-client").path
        app.launchEnvironment["TETHER_TEST_SERVER_HOST"] = "127.0.0.1"
        app.launchEnvironment["TETHER_TEST_SERVER_PORT"] = "\(port)"
        app.launchEnvironment["TETHER_TEST_AUTO_OPEN_SESSION_NAME"] = seedSessionName
        app.launch()

        _ = try waitForEvent(named: "sessions_refreshed", timeout: 20) {
            guard let names = $0["session_names"] as? [Any] else { return false }
            return names.contains { ($0 as? String) == seedSessionName }
        }

        let terminal = terminalScrollView(in: app)
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))

        typeShortcut(in: app, terminal: terminal, key: "t", modifierFlags: .command)
        try waitForSessionCount(groupId: groupId, equals: 2, timeout: 10)

        let captureURL = tempRoot.appendingPathComponent("cmd-t-focus.txt")
        let token = "focus-\(runId)"
        try? FileManager.default.removeItem(at: captureURL)

        app.typeText("printf %s \(shellQuote(token)) > \(shellQuote(captureURL.path))\n")
        try waitForFileContents(at: captureURL, equals: token, timeout: 10)
    }

    private func shellQuote(_ raw: String) -> String {
        "'" + raw.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func waitForFileContents(
        at url: URL,
        equals expected: String,
        timeout: TimeInterval
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? String(contentsOf: url, encoding: .utf8), data == expected {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        throw UITestFailure(description: "timed out waiting for \(url.lastPathComponent) to equal \(expected)")
    }
```

This test must not click the terminal after `Cmd+T`. `app.typeText(...)` is the assertion mechanism for “typing works immediately.”

- [ ] **Step 2: Run the new UI test to verify the current app still requires a click**

Run:

```bash
cd flutter_app/macos && xcodebuild test \
  -workspace Runner.xcworkspace \
  -scheme Runner \
  -destination 'platform=macOS' \
  -only-testing:RunnerUITests/RunnerUITests/testCmdTSessionAcceptsTypingWithoutExtraClick
```

Expected: FAIL with a timeout from `waitForFileContents(...)`, because the newly created session is visible but not yet the AppKit first responder.

- [ ] **Step 3: Implement bounded native focus reconciliation in `TerminalSurfaceView`**

In `flutter_app/macos/Runner/TerminalView.swift`, add the focus-repair bookkeeping and trigger hooks below.

Add new state near the existing `focused` / `suppressNextLeftMouseUp` fields:

```swift
    private var interactiveFocusRetryWorkItem: DispatchWorkItem?
    private var windowDidBecomeKeyObserver: NSObjectProtocol?
```

Update `viewDidMoveToWindow()` and add observer management:

```swift
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        clearWindowDidBecomeKeyObserver()

        guard let window else {
            interactiveFocusRetryWorkItem?.cancel()
            interactiveFocusRetryWorkItem = nil
            return
        }

        installWindowDidBecomeKeyObserver(for: window)

        if surface == nil {
            createSurface()
        } else {
            ensureInteractiveFocusIfEligible(reason: "viewDidMoveToWindow")
        }
    }

    private func installWindowDidBecomeKeyObserver(for window: NSWindow) {
        windowDidBecomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.ensureInteractiveFocusIfEligible(reason: "windowDidBecomeKey")
        }
    }

    private func clearWindowDidBecomeKeyObserver() {
        if let windowDidBecomeKeyObserver {
            NotificationCenter.default.removeObserver(windowDidBecomeKeyObserver)
            self.windowDidBecomeKeyObserver = nil
        }
    }
```

Add the reconciliation methods near `focusDidChange(_:)`:

```swift
    private func ensureInteractiveFocusIfEligible(reason: String) {
        guard let window else {
            scheduleInteractiveFocusRetry(reason: "\(reason).missingWindow")
            return
        }
        if window.firstResponder === self { return }

        switch Self.interactiveFocusDisposition(
            isActiveInUI: isActiveInUI,
            isVisibleInUI: isVisibleInUI,
            bounds: bounds,
            firstResponder: window.firstResponder,
            hasAttachedSheet: window.attachedSheet != nil,
            windowIsKey: window.isKeyWindow,
            windowExists: true
        ) {
        case .focusNow:
            interactiveFocusRetryWorkItem?.cancel()
            interactiveFocusRetryWorkItem = nil
            _ = window.makeFirstResponder(self)
        case .retryOnNextRunLoop:
            scheduleInteractiveFocusRetry(reason: reason)
        case .blocked:
            interactiveFocusRetryWorkItem?.cancel()
            interactiveFocusRetryWorkItem = nil
        }
    }

    private func scheduleInteractiveFocusRetry(reason: String) {
        guard interactiveFocusRetryWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.interactiveFocusRetryWorkItem = nil
            self.ensureInteractiveFocusIfEligible(reason: "\(reason).retry")
        }
        interactiveFocusRetryWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }
```

Wire the triggers into existing lifecycle code:

```swift
    private func createSurface() {
        // existing setup...
        observeNotifications()
        updateEventMonitor()
        ensureInteractiveFocusIfEligible(reason: "createSurface")
        testLogger.write(
            event: "attach_started",
            fields: [
                "role": attachOptions.role,
                "offset": attachOptions.offset as Any,
                "tail_bytes": attachOptions.tailBytes as Any,
            ]
        )
    }

    func setActive(_ active: Bool) {
        isActiveInUI = active
        if !active {
            interactiveFocusRetryWorkItem?.cancel()
            interactiveFocusRetryWorkItem = nil
            focusDidChange(false)
        }
        applyPresentationState()
        updateEventMonitor()
        if active && isVisibleInUI {
            ensureInteractiveFocusIfEligible(reason: "setActive")
        }
    }

    func setVisibleInUI(_ visible: Bool) {
        isVisibleInUI = visible
        if !visible {
            interactiveFocusRetryWorkItem?.cancel()
            interactiveFocusRetryWorkItem = nil
            focusDidChange(false)
        }
        applyPresentationState()
        updateEventMonitor()
        if visible && isActiveInUI {
            ensureInteractiveFocusIfEligible(reason: "setVisibleInUI")
        }
    }
```

Update teardown so observers and work items do not leak:

```swift
    deinit {
        interactiveFocusRetryWorkItem?.cancel()
        clearWindowDidBecomeKeyObserver()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        // existing metadata/surface cleanup...
    }
```

Keep the implementation narrow:

- do not add a Dart method channel for focus
- do not call `makeKeyAndOrderFront(nil)` here
- do not loop retries beyond the single async recheck

- [ ] **Step 4: Run the focused UI regression and verify the new session accepts typing immediately**

Run:

```bash
cd flutter_app/macos && xcodebuild test \
  -workspace Runner.xcworkspace \
  -scheme Runner \
  -destination 'platform=macOS' \
  -only-testing:RunnerUITests/RunnerUITests/testCmdTSessionAcceptsTypingWithoutExtraClick
```

Expected: PASS. The test should create the temp file without any terminal click after `Cmd+T`.

- [ ] **Step 5: Run guard regressions for existing shortcut and session-creation behavior**

Run:

```bash
cd flutter_app/macos && xcodebuild test \
  -workspace Runner.xcworkspace \
  -scheme Runner \
  -destination 'platform=macOS' \
  -only-testing:RunnerUITests/RunnerUITests/testTerminalFocusedShellShortcutsRouteToProjectAndSessionChrome

cd ../.. && cd flutter_app && flutter test test/home_screen_shortcut_test.dart \
  --plain-name 'cmd+t creates a session directly in the selected project'
```

Expected: PASS for both commands. This proves the native focus fix did not regress the existing `Cmd+T` creation contract.

- [ ] **Step 6: Commit the lifecycle wiring and UI regression**

```bash
git add \
  flutter_app/macos/Runner/TerminalView.swift \
  flutter_app/macos/RunnerUITests/RunnerUITests.swift

git commit -m "fix: reconcile macOS terminal first responder"
```
