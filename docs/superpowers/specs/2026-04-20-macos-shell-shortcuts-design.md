# macOS Shell Shortcut Routing Design

## Goal

Make Tether's project/session shell shortcuts work reliably on macOS when the embedded Ghostty terminal has focus.

This design fixes the native shortcut routing path for:

- `Cmd+N`
- `Cmd+T`
- `Cmd+R`
- `Cmd+Shift+R`
- `Cmd+1` through `Cmd+9`
- `Ctrl+1` through `Ctrl+9`

The scope is intentionally narrow: preserve the existing Flutter shell behavior and repair the native event chain that should deliver those actions while a terminal surface is focused.

## Current Problem

The Flutter layer already knows how to execute shell actions correctly.

- `HomeScreen._performShellAction(...)` implements the desired project/session create, rename, and numeric selection flows.
- `home_screen_shortcut_test.dart` shows those actions work when the events reach Flutter.
- `MainFlutterWindow` already maps the intended macOS key equivalents to shell action payloads.

The failure is in the native focus and event path:

- `TerminalSurfaceView.performKeyEquivalent(...)` handles some `Cmd` and `Ctrl` combinations before the window-level shell action handler sees them.
- `Ctrl+digit` is especially problematic because the terminal view currently treats control-modified key equivalents as handled locally.
- As a result, widget tests pass but the real macOS app still fails when the terminal is the first responder.

## Terms

- `Shell shortcut`: a key equivalent that targets Tether's project/session chrome rather than terminal input.
- `Terminal shortcut`: a key equivalent that should remain owned by the embedded Ghostty surface.
- `Terminal focus`: `MainFlutterWindow.firstResponder` is a `TerminalShortcutFocusable` responder.
- `Shell action payload`: the `{action, index?}` message sent over `dev.tether/window` via `performShellAction`.

## User-Facing Behavior

### Shell Shortcuts

When the terminal is focused on macOS:

- `Cmd+N` creates a new project and then creates its first session.
- `Cmd+T` creates a new session in the current project, or falls back to the existing no-project flow.
- `Cmd+R` renames the active session.
- `Cmd+Shift+R` renames the current project.
- `Cmd+1` through `Cmd+9` select projects from the sidebar using top-level project sort order.
- `Ctrl+1` through `Ctrl+9` select session tabs for the current project using session sort order.

These shortcuts must behave the same as the existing Flutter shell actions. No new shell semantics are introduced in this design.

### Shortcut Hint Overlays

Shortcut-target digits should become visible while the relevant modifier is held.

- Holding `Cmd` shows transient `1` through `9` badges on the first nine visible sidebar projects.
- Holding `Ctrl` shows transient `1` through `9` badges on the first nine visible session tabs for the current project.
- Holding both modifiers at the same time shows both overlay sets simultaneously.
- The overlays are visual hints only. They do not add new tap targets or change selection order.
- The overlays disappear immediately when the relevant modifier is released.
- Projects or sessions beyond index 9 do not receive numeric overlays.

### Focus Boundaries

Shell shortcuts are only forwarded through the native window bridge when the first responder is the terminal surface.

- If focus is inside a Flutter dialog text field, settings input, or another non-terminal responder, the native terminal bridge does nothing.
- Numeric shortcuts that target a missing project/session index fail silently.
- The fix must not cause terminal text entry, Ghostty bindings, copy/paste behavior, or image-paste behavior to regress.

## Architecture

### Ownership

Shortcut ownership is split cleanly across three layers:

1. `MainFlutterWindow.swift`
2. `TerminalView.swift` / `TerminalSurfaceView`
3. `HomeScreen` in Flutter

Each layer keeps one job:

- `MainFlutterWindow` defines the authoritative shell shortcut mapping and forwards `performShellAction` messages.
- `TerminalSurfaceView` decides whether a terminal-focused key equivalent belongs to the shell or to Ghostty.
- Flutter executes the already-defined shell action semantics.

### Native Routing Rule

The terminal view must not consume shell shortcuts locally.

For any terminal-focused key equivalent that matches the shell shortcut set:

1. `TerminalSurfaceView.performKeyEquivalent(...)` identifies it as a shell shortcut.
2. The terminal view returns `false` so AppKit continues the responder chain.
3. `MainFlutterWindow.performKeyEquivalent(...)` receives the event.
4. `MainFlutterWindow.shellShortcutPayload(...)` converts the event into `{action, index?}`.
5. The window channel invokes `performShellAction`.
6. Flutter runs the existing shell action.

For non-shell shortcuts, existing terminal behavior remains in place.

### Shortcut Classification

The shell shortcut set is fixed to:

- `Cmd+N`
- `Cmd+T`
- `Cmd+R`
- `Cmd+Shift+R`
- `Cmd+1...9`
- `Ctrl+1...9`

No other command/control combinations are added in this iteration.

To prevent duplicated logic from drifting:

- native code should expose one small helper for shell-shortcut classification in `TerminalSurfaceView`
- that helper should use the same key/modifier rules as `MainFlutterWindow.shellShortcutPayload(...)`

The implementation may share logic directly or keep two tiny helpers, but the accepted shortcut set must remain identical in both places.

## Detailed Interaction Rules

### Terminal-Focused Shell Actions

When the terminal is first responder:

- shell shortcuts take precedence over terminal-local binding resolution
- `Ctrl+digit` must not be sent to Ghostty as terminal input
- `Cmd+digit` must not be interpreted as a terminal-local command binding

This is the core behavioral change.

### Dialog and Text-Input Safety

When the first responder is not terminal-backed:

- `MainFlutterWindow.shellShortcutPayload(...)` returns `nil`
- native shell forwarding does not occur
- AppKit/Flutter continue to handle the event normally

This avoids hijacking rename dialogs or other text-entry flows.

### Compatibility

The legacy `renameActiveSession` method-channel entrypoint may remain temporarily for compatibility with existing tests, but the intended shell path is:

- native shortcut
- `performShellAction`
- Flutter action dispatch

New coverage should target that unified path rather than the legacy rename-only entrypoint.

## Testing Strategy

### Native Unit Tests

Update `flutter_app/macos/RunnerTests/RunnerTests.swift` to cover:

- `shellShortcutPayload(...)` returns the expected action for all six shortcut groups
- `shellShortcutPayload(...)` returns `nil` when `superHandled == true`
- `shellShortcutPayload(...)` returns `nil` when the first responder is not terminal-backed
- the terminal-view shell-shortcut classification helper returns `true` for the shell shortcut set
- the terminal-view helper returns `false` for nearby non-shell combinations so terminal ownership is preserved

### Flutter Widget Tests

Keep `flutter_app/test/home_screen_shortcut_test.dart` as the behavioral contract for the Flutter shell layer.

It must continue to verify:

- project/session rename behavior
- project/session creation behavior
- project selection by `Cmd+digit`
- session selection by `Ctrl+digit`

These tests prove the action execution path remains unchanged.

### macOS UI Tests

Extend `flutter_app/macos/RunnerUITests/RunnerUITests.swift` with an end-to-end test that exercises the real native path while the terminal is focused.

The test should:

1. provision at least two top-level projects
2. provision multiple sessions in one project and at least one session in another
3. launch the app and focus a terminal surface
4. send `Cmd+digit` and verify project selection changes
5. send `Ctrl+digit` and verify session-tab selection changes
6. send `Cmd+R` / `Cmd+Shift+R` and verify the correct rename dialogs appear
7. send `Cmd+N` / `Cmd+T` and verify the created project/session appears in the UI

This is the primary regression shield because it covers the exact terminal-focused macOS path that widget tests cannot observe.

## Acceptance Criteria

The design is complete when all of the following are true:

- terminal-focused macOS shell shortcuts work for project create, session create, project rename, session rename, project selection, and session selection
- `Ctrl+digit` no longer gets swallowed by the terminal view
- dialog/text-entry focus does not trigger terminal-native shell forwarding
- existing Flutter shell shortcut behavior remains unchanged
- widget tests and native macOS tests both pass

## Out of Scope

This design does not:

- redefine project/session shell behavior in Flutter
- move all shortcuts into AppKit menu commands
- redesign Ghostty keybinding behavior beyond the shell-shortcut carveout
- change backend APIs, persistence, or database schema
- alter mobile, Linux, or non-macOS shortcut handling
