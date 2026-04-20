# Shell Performance Hardening Design

## Goal

Reduce the "whole window feels sluggish" behavior that appears once Tether accumulates many sessions across multiple projects, especially when remote SSH-backed sessions are involved.

This work is intentionally a client-shell performance pass, not a transport rewrite. The design focuses on eliminating unnecessary rebuild fan-out, repeated global scans, and hidden live terminal work that continues even when a session is inactive.

## Problem Statement

The current shell has three high-probability sources of avoidable UI cost:

- `serverProvider.refresh()` treats ordinary runtime field changes as structural updates, which fans out rebuild pressure into navigation and terminal shell layers.
- `HomeScreen`, `Sidebar`, and `TerminalArea` subscribe too broadly, so a change in one session can cause much larger portions of the UI tree to rebuild than necessary.
- Inactive terminal tabs remain too "live". Hidden views keep widget, websocket, and metadata behavior around longer than needed, even though only one session is visible at a time.

The reported symptom is not just "terminal tab X is slow". The entire window becomes less responsive, which points to shell-wide work, not a single SSH tunnel bottleneck.

## Scope

This design covers:

- provider-level separation between structural updates and runtime status updates
- narrower widget subscriptions in the shell and sidebar
- project status aggregation without repeated full-session rescans per tile
- bounded retention of live terminal views
- real connection shedding for inactive terminal sessions

This design does not cover:

- changing the remote tunnel topology
- introducing a new backend schema
- changing PTY semantics
- redesigning the tab/project information architecture

## Terms

- `Structural change`: a change that alters ordering, membership, or identity in projects/sessions
- `Runtime change`: a change to live status fields such as foreground process, OSC title, attention state, or SSH reachability
- `Live terminal view`: a mounted terminal widget with active websocket and terminal rendering state
- `Inactive session`: a session that is not currently selected in the terminal area

## User-Facing Behavior

### Shell Responsiveness

- Opening many sessions across multiple projects should no longer make the whole window feel uniformly heavy.
- Project switching, clicking, dragging the window, and opening menus should remain responsive even when many inactive sessions exist elsewhere.
- Active-session behavior remains real-time.

### Inactive Session Tradeoff

- Inactive sessions are allowed to show status updates with refresh-interval latency instead of websocket-immediate latency.
- Returning to an inactive session may require reconstructing its live view from server scrollback and live reconnect state.
- This is an acceptable trade: hidden tabs should not consume shell-wide responsiveness.

### Status Indicators

- Session status indicators in the top bar remain live for the active project.
- Project-level status indicators in the sidebar continue to surface useful information, but they should be derived from aggregated data rather than each tile recomputing against the full session list.
- Project-level indicators should avoid expensive continuous animation; animation emphasis stays closer to the currently active session context.

## Architecture

### 1. State Update Separation

`ServerNotifier.refresh()` must separate structural updates from runtime updates.

Structural updates include:

- project creation or deletion
- session creation or deletion
- reorder changes
- project/session membership changes

Runtime updates include:

- `foregroundProcess`
- `oscTitle`
- `attentionSeq`
- `attentionAckSeq`
- SSH reachability or similar host status fields

Only structural updates should advance group/session structure versions. Runtime-only changes must update state without being misclassified as shell structure churn.

### 2. Shell Subscription Narrowing

`HomeScreen`, `Sidebar`, and `TerminalArea` should stop watching the entire `serverProvider` object when they only need a subset.

The design expects these widgets to subscribe by slice:

- `HomeScreen`: only the fields required for shortcut routing, auto-open logic, and shell layout
- `Sidebar`: only project list, SSH host list, selection state, and precomputed status summary
- `TerminalArea`: only selected project state, current project's sessions, and the active session identity

This preserves current behavior while reducing unnecessary rebuild breadth.

### 3. Sidebar Aggregation

Sidebar project status must be computed in one aggregation pass across visible sessions instead of every project tile rescanning the session list.

The aggregation output should map `projectId -> summarized project status`, where status priority remains:

1. attention
2. waiting
3. running
4. none

This keeps semantics stable while reducing repeated work as session counts grow.

### 4. Bounded Live Terminal Retention

`TerminalArea` should not keep an unbounded number of mounted live terminal views.

The design keeps:

- the active session view
- at most one recently visited inactive session view for fast bounce-back

Other inactive sessions should retain lightweight controller identity only, not a mounted live terminal widget. When reactivated, the session rebuilds from the server using the existing replay and reconnect path.

This bounds hidden UI and transport cost to a constant-sized set.

### 5. Real Inactive Connection Shedding

For xterm-backed sessions, inactive state should not merely send a logical pause if the server ignores that signal. The client should dispose the live websocket when the session becomes inactive and reconnect when it becomes active again.

For native terminal views, metadata websocket subscriptions should also be active-session scoped rather than permanently attached for every hidden view.

This aligns client behavior with actual backend behavior instead of relying on a no-op pause protocol.

## Detailed Data Flow

### Refresh Path

1. Poll HTTP data.
2. Merge transient websocket-derived status where needed.
3. Detect whether projects/sessions changed structurally.
4. Publish only the minimal state updates required.
5. Avoid no-op writes in project/session cleanup helpers.

The essential rule is that runtime status churn must not masquerade as structure churn.

### Session Activation Path

When the user activates a session:

1. mark it as active in project-scoped navigation state
2. ensure a live terminal view exists
3. connect or reconnect the main websocket
4. send terminal size
5. replay scrollback and resume live updates

When the user deactivates a session:

1. allow controller identity to remain cached
2. dispose live transport if the view is not inside the bounded retention window
3. rely on refresh-driven status for background visibility

## Error Handling

- If a reactivated session fails to reconnect, existing reconnect UI and server-side recovery semantics remain the source of truth.
- If an inactive session misses a transient status pulse while disconnected, the next refresh is allowed to catch it up.
- No new error surface is introduced for this work. Existing snackbars, reconnect banners, and status fallbacks remain in place.

## Testing Strategy

### Provider Tests

Add or update tests that prove:

- runtime-only session updates do not count as structural changes
- structure versions only change on real membership/order changes
- `syncProjects()` is a no-op when project identity is unchanged
- `cleanupSessions()` is a no-op when session identity is unchanged

### Widget Tests

Add or update tests that prove:

- sidebar project-status aggregation is correct
- active/inactive terminal switching narrows live websocket behavior
- native terminal metadata websocket lifecycle follows active state
- xterm terminal reconnects cleanly after inactive disposal
- bounded terminal retention does not remove the active session and does evict older inactive views

### Manual Verification

Verify these workflows manually:

- 10 to 20 sessions distributed across multiple projects
- multiple remote SSH-backed sessions present
- sidebar open and closed
- repeated project switching
- repeated session switching within a project

Success means the whole window remains responsive during ordinary navigation, not merely that terminal output still renders.

## Non-Goals

This work does not:

- change SSH tunnel sharing rules
- adopt a new transport protocol
- promise zero-cost hidden-session status updates
- refactor backend remote-manager behavior
- redesign session/project UX

## Recommended Implementation Order

1. fix provider classification of structural vs runtime updates
2. add no-op guards to navigation/session cleanup state
3. narrow shell and sidebar subscriptions
4. introduce sidebar status aggregation
5. implement bounded live terminal retention
6. make inactive websocket lifecycle real instead of logical-only pause
7. run targeted widget/provider tests, then full Flutter verification
