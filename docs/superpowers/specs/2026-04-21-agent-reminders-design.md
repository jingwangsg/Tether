# Agent Reminders Design

Date: 2026-04-21

## Summary

Rebuild Tether's Claude Code and Codex reminder mechanism around the same core idea used by `cmux`:

- agent wrappers and hooks emit terminal-native reminder signals
- Ghostty surfaces convert those signals into desktop-notification actions
- Tether decides whether to surface or suppress the macOS notification based on app/session focus
- session tabs immediately switch their primary title to `Claude Code` or `Codex` whenever detection says that agent currently owns the session

This design keeps Tether's existing `foreground_process`, `osc_title`, and `attention_seq/attention_ack_seq` model. The new work does not add a full notification center or unread history UI. It makes reminder delivery reliable across:

- local Tether sessions
- SSH-group remote sessions
- best-effort manual nested `ssh` launched from inside a Tether session

## Problem

Today Tether has only part of the loop:

- the server can infer `claude` / `codex` foreground state from `ps`, OSC titles, output heuristics, and SSH-forwarded `foreground_changed`
- the UI can show session status dots from `foreground_process`, `osc_title`, and `attention_seq`
- the macOS app does not currently consume Ghostty desktop-notification actions, so OSC desktop notifications do not reach the user as real system notifications
- session top tabs still prioritize cached terminal titles over agent detection, so the tab can fail to switch to `Claude Code` or `Codex` even when detection is correct

The net result is a split system: some status is visible, but reminders are not delivered end to end and the most important UI affordance, the session tab title, can drift away from the actual active agent.

## Goals

- Follow the `cmux` reminder model as closely as practical.
- Make Claude Code and Codex reminders work end to end in local, SSH-group, and nested-SSH flows.
- Use terminal-native reminder signals instead of a custom network notification channel.
- Preserve the existing Tether attention model instead of replacing it.
- Make session tab title ownership explicit: detected agent name wins over cached terminal titles.
- Suppress macOS notifications when Tether is frontmost and the target session is already focused.

## Non-Goals

- Build a full notification inbox, unread list, or recent-notifications page.
- Generalize the system to arbitrary tools in this iteration. Scope is Claude Code and Codex.
- Perfectly support every SSH command-line variant. Nested SSH support is best effort for interactive shell-oriented use.
- Replace the existing fallback process detection pipeline. Fallbacks stay in place for resilience.

## Approach Options

### Option 1: Structured Tether-only reminder channel

Have wrappers send agent events directly to `tether-server`, then let the app decide when to notify.

Pros:

- clean state ownership
- easy to reason about session state transitions

Cons:

- least like `cmux`
- remote and nested SSH require a new backchannel
- reminder delivery depends on more than the PTY stream

### Option 2: Pure `cmux`-style OSC reminders

Use wrappers, hooks, and shims to emit `OSC 777` desktop notifications and rely on Ghostty plus the app to consume them.

Pros:

- closest to `cmux`
- naturally works across local and remote PTY flows
- simple reminder transport

Cons:

- by itself, it does not guarantee Tether's session state stays coherent
- the UI can still drift unless title and attention rules are tightened

### Option 3: Chosen approach: `cmux`-style reminder delivery plus Tether's existing attention state

Use Option 2 as the reminder transport, but intentionally preserve and feed Tether's existing `foreground_process`, `osc_title`, and `attention_seq` pipeline.

Pros:

- closest to `cmux` where it matters to the user
- no new reminder transport protocol
- preserves Tether's current session-dot and attention behavior
- keeps local, SSH-group, and nested SSH on one conceptual model

Cons:

- two outputs must stay aligned: desktop reminder OSC and title/status OSC
- shell/bootstrap work spans multiple layers

This is the selected design.

## Architecture

The system is built from four cooperating layers.

### 1. Agent reminder bundle

Tether materializes a runtime bundle that contains:

- `tether-agent-notify`: helper that emits reminder/title sequences
- `claude` wrapper: injects Claude hooks
- shadow `CODEX_HOME` containing `hooks.json` for Codex
- `terminal-notifier` shim: converts agent desktop-notifier calls into terminal OSC
- `ssh` wrapper used only inside Tether-managed interactive shells for nested SSH bootstrapping

The bundle is installed into Tether's existing runtime shell-integration area so it can be injected without changing the Flutter layer.

### 2. Shell/session bootstrap

Tether's existing `tether-zsh` and `tether-bash` wrappers become the injection point for local sessions. They prepend the agent bundle to `PATH`, export the shadow `CODEX_HOME`, and expose session-local environment needed for idempotence and nested SSH behavior.

### 3. PTY-native reminder transport

The helper emits:

- `OSC 777;notify;...` for desktop reminder delivery
- `OSC 2` titles that continue to feed Tether's existing foreground and tool-status logic

This deliberately keeps the reminder transport inside the terminal stream, matching the `cmux` design.

### 4. macOS native reminder coordinator

The app consumes `GHOSTTY_ACTION_DESKTOP_NOTIFICATION`, maps it back to the owning Tether session, applies suppression rules, and schedules a real macOS user notification only when allowed.

## Event Semantics

Tether already interprets session tool state from `foreground_process` plus the leading glyph in `osc_title`.

Current semantics that must remain true:

- leading `·` means the agent is waiting for user input
- leading `*`, `✱`, or a braille spinner means the agent is running
- `attention_seq > attention_ack_seq` means the session has unacknowledged attention

Reminder generation must align with those semantics.

### Running state

When an agent resumes work:

- emit `OSC 2` with a running-style title, using either `✱ <Agent>` or a braille-spinner-prefixed title
- do not emit `OSC 777`
- allow the existing process monitor to keep `attention_ack_seq` cleared when the session resumes from attention

### Waiting state

When an agent needs the user:

- emit `OSC 2` with a waiting-style title prefixed by `·`
- emit one `OSC 777` notification for the transition into waiting
- do not repeatedly emit the same reminder while the session remains in the same waiting state

### Cleared state

A reminder is considered cleared when either:

- the user focuses the target session and Tether acks attention
- the agent resumes execution and re-enters running state

At that point the helper must stop repeating reminders and restore a running or normal title as appropriate.

## Hook Mapping

### Claude Code

Claude hooks are injected by a wrapper placed earlier in `PATH`.

Required behavior:

- `Notification` hook: produce waiting title plus reminder
- `PreToolUse` hook: produce running title
- `Stop` hook: produce waiting reminder only when Claude is actually waiting for the user, not on every internal step completion
- `SessionEnd` hook: clear reminder-related state

### Codex

Codex uses a shadow `CODEX_HOME/hooks.json`.

Required behavior:

- `SessionStart`: produce running title
- `UserPromptSubmit`: produce running title
- `Stop`: produce waiting title plus reminder
- end-of-session cleanup: clear reminder-related state

### terminal-notifier shim

Any Claude or Codex path that shells out to `terminal-notifier` is intercepted and converted to `OSC 777` through `tether-agent-notify`.

## Session Bootstrapping Paths

### Local Tether sessions

Local sessions already spawn through Tether-controlled shell wrappers. Extend that path to:

- prepend `tether-agent/bin` to `PATH`
- export shadow `CODEX_HOME`
- expose session-scoped env used by helpers to de-duplicate reminders

This path is the authoritative local bootstrap and requires no Flutter-side involvement.

### SSH-group sessions

For SSH groups, extend the command currently built by `resolve_ssh_command(...)`.

Before `exec $SHELL -l` on the remote host, Tether stages a remote copy of the agent reminder bundle and exports:

- remote bundle `PATH`
- remote `CODEX_HOME`
- remote helper path env

Remote reminders then travel back to the local app through the same PTY stream that already carries titles and output.

### Nested SSH inside a local session

Nested SSH support is best effort and shell-oriented. Tether injects an `ssh` wrapper only inside Tether-managed interactive shells.

The wrapper must:

- intercept common interactive forms such as `ssh host`, `ssh -t host`, and `ssh host cmd`
- inject the remote bundle before handing control to the remote shell or remote command
- bypass non-interactive and transport-oriented forms such as `scp`, `sftp`, `rsync`, `ssh -N`, `ssh -L`, `ssh -R`, `ssh -D`, `ssh -O`, and `ssh -S`

This keeps the common developer path working without risking side effects on control-only SSH usage.

## Native macOS Reminder Handling

### Ghostty action handling

Add `GHOSTTY_ACTION_DESKTOP_NOTIFICATION` handling in the macOS app's Ghostty action bridge. The handler must extract:

- notification title
- notification body
- owning Tether session id

### Suppression rules

Notification suppression is fixed to the approved rule set:

- if Tether is not frontmost, deliver the macOS notification
- if Tether is frontmost but the target session is not focused, deliver the macOS notification
- if Tether is frontmost and the target session is focused, suppress the macOS notification

Suppression never clears attention by itself. It only prevents noisy desktop delivery.

### Notification click behavior

Clicking the macOS notification must:

- activate Tether
- focus the owning project/session if it still exists
- let the normal session-focus path perform attention ack

## Session Tab Title Ownership

This is a required behavior, not an optional polish item.

### Rule

When Tether detects that a session's `foreground_process` is `claude` or `codex`, the session top tab's primary title must switch immediately to:

- `Claude Code`
- `Codex`

### Title source precedence

The top tab title source order becomes:

1. detected agent label from `foreground_process` when `foreground_process` is `claude` or `codex`
2. cached terminal title from native title-change events when no supported agent is active
3. persisted session display name

This explicitly fixes the current inversion where cached terminal titles can override an already-detected agent.

### Supporting UI rules

- running/waiting/attention state remains encoded by the existing status indicator, not by the title text
- the original session name is retained for tooltip or secondary context, but it no longer owns the top-tab primary label while an agent is active
- the rule is identical for local, SSH-group, and nested-SSH sessions

## UI Impact

The iteration intentionally keeps UI scope small.

Required visual changes:

- top session tab primary title switches to `Claude Code` or `Codex` when detected
- existing status indicator continues to show running, waiting, or attention
- if notification delivery is suppressed because the target session is already focused, the user still sees the tab title and status change immediately

Explicitly out of scope:

- unread badge counts in Tether session tabs
- notification history text rows in the tab strip
- a dedicated notifications popover

## Failure Handling

### Bundle injection failures

If the local or remote reminder bundle cannot be staged:

- the session must still start
- Tether falls back to existing passive detection
- the failure is logged with enough detail to distinguish local bootstrap, SSH-group bootstrap, and nested-SSH bootstrap failures

### Notification permission denial

If macOS notification authorization is denied:

- reminders still drive tab-title ownership and attention state
- only desktop delivery is lost
- Tether does not silently drop the session-state change

### Session mapping failures

If a Ghostty desktop-notification action cannot be mapped back to a live session:

- ignore the desktop notification delivery attempt
- do not mutate unrelated session state
- log a warning with the owning native surface identifier

## Testing Strategy

The design requires both regression tests and end-to-end verification.

### Automated tests

- wrapper tests for Claude hook injection
- shadow `CODEX_HOME` tests for Codex hook injection
- nested-SSH wrapper tests that verify interactive and bypassed command forms
- native macOS tests for `GHOSTTY_ACTION_DESKTOP_NOTIFICATION` routing and suppression
- UI tests for session top-tab title precedence

### End-to-end test coverage

End-to-end means running the real Tether stack, not only isolated unit tests.

Required scenarios:

1. Local session, fake Claude:
   - spawn a real Tether local session
   - run a fake Claude executable through the real wrapper path
   - verify top-tab title changes to `Claude Code`
   - verify waiting emits a real desktop-notification action
   - verify focused-session suppression keeps the notification from surfacing while attention still changes

2. Local session, fake Codex:
   - same expectations as Claude, using the shadow `CODEX_HOME` path

3. SSH-group session:
   - use an automated remote harness that exercises the real remote bootstrap path and emits reminders through the real PTY flow
   - verify top-tab title changes and desktop-notification delivery on the local app

4. Nested SSH session:
   - use a test harness that launches a Tether local session, runs `ssh` through the Tether-provided wrapper, stages the remote bundle, and executes fake Claude/Codex remotely
   - verify title ownership and reminder delivery still work

The end-to-end harness may use fake executables and a fake SSH target, but it must exercise the real Tether bootstrap, PTY, Ghostty action, and app-focus suppression paths.

### Manual acceptance checks

Before declaring the work complete, manually verify on macOS:

- local Claude reminder while Tether is backgrounded
- local Codex reminder while Tether is backgrounded
- SSH-group reminder while Tether is backgrounded
- focused-session suppression for both agents
- tab title switches immediately when the agent starts and restores correctly when the agent exits

## Acceptance Criteria

- A detected Claude Code session always shows `Claude Code` as the top-tab primary title.
- A detected Codex session always shows `Codex` as the top-tab primary title.
- Cached terminal titles never override a currently detected Claude/Codex session title.
- Waiting-state transitions emit `OSC 777` and can surface as macOS notifications when allowed.
- Running-state transitions never emit reminder notifications.
- Local, SSH-group, and common nested-SSH flows all use the same reminder semantics.
- Focused-session suppression prevents noisy desktop notifications without losing attention state.
- The feature is verified with real end-to-end tests, not only unit tests.
