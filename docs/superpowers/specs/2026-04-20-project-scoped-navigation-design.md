# Project-Scoped Navigation Design

## Goal

Make Tether's navigation model match the `cmux` mental model more closely:

- the sidebar is a single-level project switcher
- the top bar is the always-visible session switcher for the current project
- keyboard shortcuts target those two layers directly

The result should feel like a navigation-shell redesign, not a terminal/backend rewrite.

## Terms

- `Project`: the UI term for what is currently stored as a `Group`
- `Session`: the existing terminal session model, unchanged in backend semantics
- `Current project`: the selected project shown in the sidebar
- `Session tabs`: all sessions that belong to the currently selected project, rendered in the top bar

## User-Facing Behavior

### Sidebar

- The sidebar shows a flat list of projects only.
- Nested groups are no longer rendered, edited, created, or reordered as a tree.
- Each sidebar item behaves like a project tab.
- Selecting a project switches the entire content shell to that project's session context.

### Top Bar

- The top bar is always visible.
- The top bar shows all sessions that belong to the current project.
- Reordering session tabs remains available inside the current project.
- Session rename/delete actions move to the top bar context menu and no longer depend on a separate open-tab concept.
- The old "Show Tab Bar" setting is removed from the UI and ignored at runtime.

### Creation and Rename Flows

- `Cmd+N` creates a new project, immediately creates the first session inside it, selects that project, and opens that first session.
- `Cmd+T` creates a new session inside the current project and activates it.
- If there is no current project, `Cmd+T` falls back to the `Cmd+N` flow.
- `Cmd+R` renames the current session.
- `Cmd+Shift+R` renames the current project.

### Numeric Navigation

- `Cmd+1` through `Cmd+9` select projects from the sidebar.
- `Ctrl+1` through `Ctrl+9` select session tabs in the top bar for the current project.
- Projects or sessions beyond index 9 remain reachable by pointer/touch interaction only.

### Mobile

- Mobile uses the same information architecture as desktop.
- The sidebar can still be presented as a drawer/overlay, but its content is the same flat project list.
- The top bar remains visible on mobile and becomes horizontally scrollable when needed.
- Mobile does not keep the previous "group tree in sidebar" model.

## Architecture

### Navigation Shell

The app shell is reorganized around two navigation layers:

1. `ProjectSidebar`
2. `ProjectContentShell`

`ProjectContentShell` is composed of:

1. `SessionTopBar`
2. `TerminalArea`

`HomeScreen` remains the overall container, but it no longer treats the sidebar as a session tree and the terminal area as a mostly independent tab host. Both are driven by the same selected-project state.

### Data Model Strategy

The backend continues to use `groups` and `sessions`. No new `projects` table is introduced.

- `Group` is reinterpreted as `Project` in the Flutter UI.
- `Session.groupId` continues to define project membership.
- Existing API endpoints for create/update/delete/reorder continue to be used.

This keeps the scope focused on shell layout and client state management.

### Client State

The current shell state is reduced to project selection plus per-project active session memory.

The client keeps:

- `selectedProjectId`
- `projectId -> activeSessionId`

The top bar is derived directly from `ServerState.sessions` filtered by `groupId == selectedProjectId`, ordered by `sort_order`.

This state is local UI/navigation state. It does not redefine backend persistence semantics. Existing persistence behavior should remain logically unchanged; only the presentation changes so that the top bar becomes the visible list of project sessions.

### Terminal Ownership

`TerminalArea` only renders the active session for the current project.

- terminal controllers remain keyed by session id
- switching projects swaps which active session is shown in the shell
- already-created controllers may still be cached by session id for fast revisits, but they are not the source of truth for tab visibility

No PTY, websocket, scrollback, or replay behavior changes are part of this work.

## Detailed Interaction Rules

### Selecting a Project

When the user selects a project:

- `selectedProjectId` updates
- the top bar updates to that project's sessions
- the terminal area activates that project's remembered active session if it still exists
- if no remembered active session exists, the first session in project sort order becomes active
- if the project has no sessions, the terminal area shows a project-specific empty state

### Creating a Project

When the user creates a project:

1. create project
2. create first session inside that project
3. mark that project as selected
4. mark the new session as active for that project

This applies to explicit project creation and the `Cmd+N` shortcut.

### Creating a Session

When the user creates a session:

- the session is created inside the current project
- it becomes the active session for that project
- it appears in the top bar automatically because the top bar is derived from project sessions

If no project exists, the app creates one first and then creates the session.

### Session Actions in the Top Bar

The top bar represents real sessions, not temporary open tabs.

- primary click selects the session
- secondary click / overflow menu exposes rename and delete
- no non-destructive "close tab" action is preserved in this redesign

### Removing Cross-Project Session Moves

The new shell does not preserve session moves between projects.

- no drag-and-drop session move between projects
- no context-menu move action
- no replacement workflow in this iteration

The backend API may still support changing a session's `group_id`, but the new UI does not expose that capability.

## Compatibility and Migration

### Historical Nested Groups

The backend may still contain nested `groups` via `parent_id`. The new UI does not support nested project navigation.

For this redesign:

- the UI treats top-level groups as selectable projects
- nested children are not rendered as navigable items
- no automatic flattening or data migration is performed in this iteration

This keeps migration risk low and avoids silently rewriting user data.

### Persisted Settings

- `showTabBar` is removed from the settings UI
- any old stored value may remain in preferences, but runtime behavior ignores it
- no dedicated migration step is required for that preference

### Backend Schema

No schema changes are required for this redesign.

- `groups.parent_id` stays in the database
- recursive deletion and remote sync code remain intact
- the redesign is intentionally a client-shell change

## Error Handling and Empty States

### Empty States

Two explicit empty states are required:

- No projects exist: prompt to create the first project
- Current project has no sessions: prompt to create the first session in that project

Both states must expose the same next action as the keyboard shortcuts.

### Rename Actions

Rename actions must resolve against current shell selection:

- project rename fails safely when no project is selected
- session rename fails safely when no session is active

### API Failures

Create, rename, reorder, and delete failures continue to use the existing snackbar/dialog error style. No new failure transport is required.

## Testing Strategy

### Flutter State and Unit Tests

Add or update tests that cover:

- selected project changes
- per-project open session tab storage
- per-project active session restoration
- cleanup when projects or sessions disappear from server state
- shortcut routing for project/session navigation and rename actions

### Flutter Widget Tests

Update widget tests to reflect:

- flat project sidebar
- always-visible top bar
- project switch updates top bar contents
- mobile still exposes project drawer plus top bar
- removed tab-bar setting

Tests that encode nested sidebar behavior should be removed or rewritten around flat project behavior.

### macOS UI Tests

Add at least one end-to-end navigation test that verifies:

- project creation creates and opens a first session
- top bar remains visible
- switching project changes the visible session set
- existing attention/status indicators still surface correctly in the new layout

## Non-Goals

This redesign does not:

- change PTY lifecycle behavior
- change websocket attach/reconnect behavior
- add new backend entities
- rewrite remote sync semantics
- migrate historical nested group data
- preserve session move-between-project interactions

## Recommended Implementation Shape

The implementation should be treated as a shell refactor with focused state changes:

1. flatten sidebar project rendering
2. introduce selected-project and per-project active-session state
3. make the top bar derive from current-project sessions
4. make top bar mandatory
5. reroute shortcuts and rename actions
6. remove obsolete nested-group and tab-bar-toggle paths

That sequence keeps the work incremental and testable while preserving terminal behavior.
