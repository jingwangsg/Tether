# macOS Terminal Focus Reconciliation Design

Date: 2026-04-21

## Goal

Make newly created Tether macOS terminal sessions accept keyboard input immediately, without requiring an extra mouse click on the window or terminal surface.

This design narrows scope to the native focus path for embedded Ghostty terminal surfaces. It is intentionally not a broader "make Tether match cmux everywhere" redesign.

## Problem

Today Tether creates and selects a new session correctly from Flutter, but the native terminal surface does not reliably become the AppKit first responder after that session is shown.

The current behavior splits across two layers:

- Flutter successfully creates the session and marks it active.
- The native `TerminalSurfaceView` creates the Ghostty surface when attached to a window.
- The native surface only calls `window.makeFirstResponder(self)` in pointer-driven paths such as `mouseDown`, `menu(for:)`, and `rightMouseDown`.
- As a result, a newly created session can appear visually active while keyboard input is still routed to some other responder until the user clicks the terminal.

This is the exact class of bug that `cmux` solves with explicit focus reconciliation instead of relying on incidental pointer interaction.

## Non-Goals

This design does not:

- redesign Tether's project/session/window information architecture
- add `cmux` browser panes, notification center, or split-pane model changes
- change server-side session creation semantics
- change Ghostty keyboard binding behavior outside the first-responder handoff
- introduce a new cross-platform focus abstraction for non-macOS backends

## User-Facing Behavior

### New Session Interaction

When the user creates a new session from the macOS app, including `Cmd+T` routed through the native window shortcut path:

- the session is created as it is today
- the new session becomes the active session in Flutter state
- the native terminal surface for that active session becomes the window's first responder as soon as it is eligible
- the user can type immediately without clicking the terminal or the window first

### Focus Safety

Automatic focus repair must not steal focus from a more specific input target.

Tether must not force terminal focus when:

- a rename/create dialog text field owns input
- the terminal's search field is open and should keep focus
- the terminal surface is not currently the active visible session
- the native platform view has not attached to a window yet
- the platform view is hidden or not yet laid out enough for interaction

### Window Reactivation

If a window already shows the active terminal session and the app/window becomes key again, Tether should restore terminal first responder when eligible so keyboard input returns to the terminal without an extra click.

## Terms

- `Active session`: the session selected in Flutter state for the current project.
- `Visible terminal`: the native terminal platform view currently rendered for the active session.
- `Eligible focus target`: a terminal surface allowed to become first responder because it is active, visible, attached to a window, and not preempted by a higher-priority text input.
- `Focus reconciliation`: explicit native logic that converges AppKit first responder to the intended terminal surface.

## Options Considered

### Option 1: Minimal `viewDidMoveToWindow` patch

Call `window?.makeFirstResponder(self)` immediately after `TerminalSurfaceView` creates its Ghostty surface.

Pros:

- smallest diff
- likely fixes the simplest reproduction quickly

Cons:

- only addresses one lifecycle moment
- fragile when attach/layout timing delays eligibility
- does not systematically handle reactivation or active-session transitions

### Option 2: Flutter-triggered native focus request

After Flutter creates and activates a session, send an explicit method-channel call asking native code to focus the terminal.

Pros:

- directly tied to the `Cmd+T` session-creation flow
- easy to reason about at the feature level

Cons:

- makes Flutter own a native AppKit focus concern
- duplicates focus intent across Dart and native code
- does not age well when other native focus transitions need the same repair path

### Option 3: Native focus reconciliation modeled after `cmux`

Add a small native focus-repair path that runs when a terminal becomes active/visible/eligible and reasserts first responder on the intended terminal surface.

Pros:

- aligns with the `cmux` model that already solves this class of bug
- keeps AppKit focus ownership in native code
- covers session creation, visibility transitions, and window reactivation coherently

Cons:

- slightly more implementation work than a one-line patch
- requires careful guardrails to avoid stealing focus from text inputs

This design chooses Option 3.

## Architecture

### Ownership

Focus ownership stays in the macOS native layer.

- Flutter remains responsible for creating sessions and marking one session active.
- `TerminalView` remains responsible for native platform-view lifecycle and presentation state.
- `TerminalSurfaceView` owns AppKit first-responder behavior for the embedded Ghostty surface.

Flutter should express which session is active. Native code should decide when it is safe and correct to converge first responder to that session's terminal surface.

### New Native Responsibility

Introduce one explicit reconciliation entrypoint on the native terminal side, conceptually named like:

- `ensureInteractiveFocusIfEligible(reason:)`

The final method name can differ, but its job is fixed:

- inspect whether the current terminal surface is allowed to take focus
- call `window.makeFirstResponder(self)` when eligible
- retry once asynchronously when the surface is expected to become eligible after the current runloop/layout pass
- do nothing when some higher-priority responder should keep focus

This is intentionally a light-weight version of `cmux`'s richer `ensureFocus` pipeline, not a full port of its workspace/pane routing logic.

## Eligibility Rules

The native terminal surface is eligible to take focus only when all of the following are true:

- the terminal is active in UI state
- the terminal is visible in UI state
- the surface is attached to a window
- the window is key, or can safely be made key by the existing window lifecycle
- the surface has usable bounds for interaction
- the current first responder is not a search field or another editable text responder that should keep input

The terminal surface must be considered ineligible when any of the following are true:

- `isActiveInUI == false`
- `isVisibleInUI == false`
- `window == nil`
- `bounds.width <= 1` or `bounds.height <= 1`
- the window first responder is the terminal search field or another editable descendant that intentionally owns input
- a dialog, sheet, or text field elsewhere in the window is expected to keep keyboard focus

## Triggers

The focus reconciliation entrypoint should run from three trigger classes only.

### 1. Surface Attach / Initial Creation

After `TerminalSurfaceView` is attached to a window and creates its Ghostty surface, Tether should attempt focus reconciliation for the newly interactive terminal.

This handles the main reproduction where the session exists and renders, but never claims first responder until clicked.

### 2. Active-State Promotion

When Flutter changes a terminal from inactive to active through `setActive(true)`, native code should attempt focus reconciliation.

This ensures the selected session in Flutter is also the selected AppKit input target.

### 3. Window Reactivation

When the terminal's window becomes key again, native code should attempt focus reconciliation for the active visible terminal if no higher-priority text input should win.

This keeps keyboard routing stable after app/window activation changes.

## Retry Strategy

The reconciliation path should use a bounded retry strategy:

- attempt `window.makeFirstResponder(self)` immediately when the surface appears eligible
- if eligibility is likely delayed by attach/layout timing, schedule exactly one asynchronous retry on the next main-queue turn or a short deferred pass
- do not install open-ended timers or loops

The retry exists only to survive native platform-view timing. It must not become a background focus churn mechanism.

## Interaction with Existing Behavior

### Pointer Focus

Existing pointer-driven focus acquisition remains valid.

- clicking the terminal should still focus it
- right-click/context-menu entry should still focus it before acting
- these paths remain useful for explicit pointer intent

The new work only fills the gap where the terminal is already the intended active session but has not yet acquired first responder.

### Search UI

Search focus must continue to override terminal focus while the search field is open.

If the terminal search overlay is active:

- automatic terminal focus repair must not steal focus from the search field
- once search closes, the terminal may again become eligible for focus reconciliation if it is still the active visible terminal

### Dialogs and Rename Flows

The native repair path must not undo text-entry focus inside dialogs.

If a modal or attached sheet is open and its text field owns input, terminal focus reconciliation must no-op until that text input is no longer the intended responder.

## Testing Strategy

### Native Unit Tests

Extend `flutter_app/macos/RunnerTests/RunnerTests.swift` to cover the new eligibility and reconciliation helpers.

Required cases:

- active + visible + attached terminal with no competing text responder attempts first-responder assignment
- inactive terminal does not attempt focus
- hidden terminal does not attempt focus
- terminal with tiny or zero-sized bounds does not attempt focus
- editable text responder blocks terminal focus repair
- search-field ownership blocks terminal focus repair
- asynchronous retry is scheduled only for retryable ineligibility, not for permanently blocked states

These tests should target extracted helper methods where possible so the behavior is deterministic and not dependent on full Ghostty startup.

### macOS UI Regression Test

Add or extend a macOS UI test that exercises the actual user path:

1. launch Tether against the local test server
2. create or auto-open a project with one session
3. issue the native `Cmd+T` shortcut
4. wait for the new session to become the active visible session
5. type a unique token immediately without clicking the window
6. assert the token appears in terminal output or is observed through the same test logging path used for terminal focus diagnostics

The regression must fail on the old behavior where a click is required and pass once reconciliation is implemented.

### Scope Discipline for Tests

The test suite for this change should prove only the focus contract.

It should not expand into unrelated coverage for:

- sidebar state
- session ordering
- remote sessions
- split panes
- browser panels

Those belong to separate work.

## Implementation Notes

The design assumes the final implementation will likely touch:

- `flutter_app/macos/Runner/TerminalView.swift`
- `flutter_app/macos/RunnerTests/RunnerTests.swift`
- `flutter_app/macos/RunnerUITests/RunnerUITests.swift`

It may also need a very small supporting change in:

- `flutter_app/lib/widgets/terminal/terminal_view.dart`

That Dart file should only change if the native trigger needs a cleaner `isActive` or visibility transition signal. It should not become the primary owner of AppKit focus decisions.

## Risks

### Risk: Focus Stealing

If eligibility checks are too loose, Tether could steal focus from dialogs or the search field.

Mitigation:

- centralize eligibility checks in one helper
- explicitly test editable-text and search ownership blockers
- keep trigger count small and bounded

### Risk: Timing Flakes

If the first focus attempt runs before the platform view is fully attachable, the bug may remain intermittent.

Mitigation:

- use a single bounded deferred retry
- test the helper behavior separately from the UI test
- log focus-attempt reasons in the existing terminal test log if extra diagnostics are needed

### Risk: Overfitting to `Cmd+T`

If the implementation is hard-coded to session creation only, later focus regressions will reappear on other transitions.

Mitigation:

- implement a generic reconciliation entrypoint
- trigger it from attach, active-state promotion, and reactivation rather than one feature-specific call site

## Success Criteria

This work is successful when all of the following are true:

- `Cmd+T` creates a new session and the user can type into it immediately without clicking
- the active visible terminal and AppKit first responder converge reliably on macOS
- terminal search and dialog text inputs keep focus when they are supposed to
- new native unit tests cover focus eligibility and blocker cases
- a macOS UI regression test reproduces and locks the bug down
