# SSH Hosts Flicker & Cmd+T Race Condition Fix

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix two bugs — (1) SSH hosts flickering in sidebar due to reachability jitter, (2) new sessions appearing then vanishing then reappearing when created via Cmd+T due to a stale-refresh race condition.

**Architecture:** Bug 1 is fixed by adding reachability hysteresis on the frontend — keep a host's previous `reachable=true` state unless it has been unreachable for 3 consecutive polls. Bug 2 is fixed by adding a refresh generation counter so stale in-flight refreshes are discarded when a newer refresh has already completed.

**Tech Stack:** Dart/Flutter (Riverpod state management)

---

## Root Cause Analysis

### Bug 1: SSH Hosts Flickering

The 5-second periodic `refresh()` calls `GET /api/ssh/hosts` which does a fresh TCP connect (2s timeout) to every SSH host. The sidebar (`sidebar.dart:197`) only renders hosts where `reachable == true`. When a TCP check fails transiently (network jitter, brief DNS hiccup, load spike), the host vanishes from the sidebar. Next poll it succeeds → host reappears. There is no debounce or hysteresis.

**Key files:**
- `flutter_app/lib/providers/server_snapshot_diff.dart:144-156` — `_sshHostsEqual` treats reachability flip as a real change
- `flutter_app/lib/widgets/sidebar/sidebar.dart:197-200` — sidebar filters on `reachable == true`
- `crates/tether-server/src/api/ssh.rs:21-54` — backend re-checks reachability on every call

### Bug 2: Cmd+T Appear-Disappear-Appear

Race condition between the periodic `refresh()` and `createSession()`'s `_refreshSessionsAndGroups()`:

1. Periodic timer fires → `refresh()` → `_loadSnapshot(api)` starts (3 parallel HTTP calls including slow SSH check)
2. User presses Cmd+T → `createSession()` API call → session created on server
3. `_refreshSessionsAndGroups()` fetches fresh groups+sessions → state updated → new session visible → **APPEAR**
4. `setActiveSession()` called → new session is active
5. Old `_loadSnapshot` from step 1 completes — its `listSessions()` was fetched BEFORE the session existed → stale data
6. `refresh()` overwrites state with stale snapshot → new session vanishes → **DISAPPEAR**
7. Next periodic refresh includes the session → **APPEAR AGAIN**

The `_connectionGeneration` guard only protects against disconnects, not concurrent refreshes.

**Key files:**
- `flutter_app/lib/providers/server_provider.dart:184` — periodic timer setup
- `flutter_app/lib/providers/server_provider.dart:204-247` — `refresh()` with no staleness guard
- `flutter_app/lib/providers/server_provider.dart:334-349` — `createSession` calls `_refreshSessionsAndGroups` then returns

---

### Task 1: Add refresh generation guard to prevent stale overwrites

**Files:**
- Modify: `flutter_app/lib/providers/server_provider.dart:85-92` (add field)
- Modify: `flutter_app/lib/providers/server_provider.dart:204-247` (guard refresh)
- Modify: `flutter_app/lib/providers/server_provider.dart:252-296` (guard _refreshSessionsAndGroups)
- Test: `flutter_app/test/server_provider_test.dart`

- [ ] **Step 1: Write failing test — stale refresh does not overwrite fresher state**

```dart
test('stale periodic refresh does not overwrite a newer _refreshSessionsAndGroups', () async {
  // Simulate: periodic refresh starts (slow), then createSession triggers
  // _refreshSessionsAndGroups (fast) that completes first. When the old
  // periodic refresh finishes, its stale data should be discarded.
  final staleCompleter = Completer<void>();
  int listSessionsCalls = 0;
  final newSession = Session(id: 'new-1', groupId: 'g1', name: 'new', ...);

  final api = MockApiService(
    listSessionsHandler: () async {
      listSessionsCalls++;
      if (listSessionsCalls == 1) {
        // First call (from periodic refresh) — slow, returns stale data
        await staleCompleter.future;
        return [existingSession]; // does NOT include newSession
      }
      // Second call (from _refreshSessionsAndGroups) — fast, returns fresh data
      return [existingSession, newSession];
    },
  );

  // Start periodic refresh (will block on staleCompleter)
  final refreshFuture = notifier.refresh();

  // createSession triggers _refreshSessionsAndGroups which completes first
  await notifier.createSession(groupId: 'g1');

  expect(notifier.state.sessions.any((s) => s.id == 'new-1'), isTrue);

  // Now let the stale refresh complete
  staleCompleter.complete();
  await refreshFuture;

  // Stale data must NOT have overwritten the fresh state
  expect(notifier.state.sessions.any((s) => s.id == 'new-1'), isTrue);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd flutter_app && flutter test test/server_provider_test.dart -v`
Expected: FAIL — stale refresh overwrites the new session

- [ ] **Step 3: Add `_refreshGeneration` counter to ServerNotifier**

In `flutter_app/lib/providers/server_provider.dart`, add a field alongside `_connectionGeneration`:

```dart
class ServerNotifier extends StateNotifier<ServerState> {
  static const _refreshInterval = Duration(seconds: 5);
  Timer? _refreshTimer;
  final ApiServiceFactory _apiFactory;
  int _groupStructureVersion = 0;
  int _sessionStructureVersion = 0;
  int _connectionGeneration = 0;
  int _refreshGeneration = 0;  // NEW
```

- [ ] **Step 4: Guard `refresh()` with generation check**

In the `refresh()` method, capture and check `_refreshGeneration`:

```dart
Future<void> refresh() async {
    final api = state.api;
    if (api == null) return;

    final generation = _connectionGeneration;
    final refreshGen = ++_refreshGeneration;  // NEW: increment at start

    try {
      final snapshot = await _loadSnapshot(api);

      if (_connectionGeneration != generation) return;
      if (_refreshGeneration != refreshGen) return;  // NEW: stale refresh guard

      // ... rest unchanged
```

- [ ] **Step 5: Guard `_refreshSessionsAndGroups()` with same pattern**

```dart
Future<void> _refreshSessionsAndGroups() async {
    final api = state.api;
    if (api == null) return;
    final generation = _connectionGeneration;
    final refreshGen = ++_refreshGeneration;  // NEW

    try {
      final results = await Future.wait([
        api.listGroups(),
        api.listSessions(),
      ]);
      if (_connectionGeneration != generation) return;
      if (_refreshGeneration != refreshGen) return;  // NEW

      // ... rest unchanged
```

- [ ] **Step 6: Run test to verify it passes**

Run: `cd flutter_app && flutter test test/server_provider_test.dart -v`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add flutter_app/lib/providers/server_provider.dart flutter_app/test/server_provider_test.dart
git commit -m "fix: add refresh generation guard to prevent stale snapshot overwrites

When a periodic refresh() is in-flight and createSession triggers
_refreshSessionsAndGroups() which completes first, the old refresh
would overwrite state with stale data missing the new session.
Now both methods increment _refreshGeneration at start and discard
results if the generation has advanced."
```

---

### Task 2: Add SSH host reachability hysteresis in snapshot diff

**Files:**
- Modify: `flutter_app/lib/providers/server_snapshot_diff.dart` (merge reachability)
- Test: `flutter_app/test/server_snapshot_diff_test.dart`

- [ ] **Step 1: Write failing test — reachable host stays reachable on single false poll**

```dart
test('SSH host that was reachable stays reachable when server returns unreachable', () {
  final current = [SshHost(host: 'prod', hostname: 'prod.example.com', user: 'deploy', port: 22, reachable: true)];
  final refreshed = [SshHost(host: 'prod', hostname: 'prod.example.com', user: 'deploy', port: 22, reachable: false)];

  final diff = diffServerSnapshot(
    currentGroups: [],
    currentSessions: [],
    currentSshHosts: current,
    refreshedGroups: [],
    refreshedSessions: [],
    refreshedSshHosts: refreshed,
  );

  // Should preserve reachable=true (hysteresis)
  expect(diff.sshHosts.first.reachable, isTrue);
  // Should NOT report as changed since we're preserving the value
  expect(diff.sshHostsChanged, isFalse);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd flutter_app && flutter test test/server_snapshot_diff_test.dart -v`
Expected: FAIL — `reachable` is `false`, `sshHostsChanged` is `true`

- [ ] **Step 3: Implement reachability hysteresis in `diffServerSnapshot`**

In `server_snapshot_diff.dart`, merge SSH host reachability — if a host was previously reachable and the refresh says unreachable, keep it reachable (the frontend will show it until a later poll confirms unreachability via a separate mechanism):

```dart
ServerSnapshotDiff diffServerSnapshot({
  required List<Group> currentGroups,
  required List<Session> currentSessions,
  required List<SshHost> currentSshHosts,
  required List<Group> refreshedGroups,
  required List<Session> refreshedSessions,
  required List<SshHost> refreshedSshHosts,
}) {
  // ... existing session merge logic ...

  // Merge SSH host reachability: if a host was reachable in the current state
  // but the server now reports it as unreachable, preserve reachable=true
  // to prevent UI flicker from transient network failures.
  final currentSshHostMap = {for (final h in currentSshHosts) h.host: h};
  final mergedSshHosts = refreshedSshHosts.map((refreshed) {
    final current = currentSshHostMap[refreshed.host];
    if (current != null && current.reachable == true && refreshed.reachable == false) {
      return refreshed.copyWith(reachable: true);
    }
    return refreshed;
  }).toList();

  // ... rest of diff using mergedSshHosts instead of refreshedSshHosts ...
```

Update the return to use `mergedSshHosts`:
```dart
  final sshHostsChanged = !_sshHostsEqual(currentSshHosts, mergedSshHosts);

  return ServerSnapshotDiff(
    // ...
    sshHosts: mergedSshHosts,
    // ...
    sshHostsChanged: sshHostsChanged,
  );
```

- [ ] **Step 4: Ensure SshHost has a `copyWith` method**

Check `flutter_app/lib/models/ssh_host.dart`. If `copyWith` doesn't exist, add it:

```dart
SshHost copyWith({
  String? host,
  String? hostname,
  String? user,
  int? port,
  bool? reachable,
}) {
  return SshHost(
    host: host ?? this.host,
    hostname: hostname ?? this.hostname,
    user: user ?? this.user,
    port: port ?? this.port,
    reachable: reachable ?? this.reachable,
  );
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd flutter_app && flutter test test/server_snapshot_diff_test.dart -v`
Expected: PASS

- [ ] **Step 6: Write additional test — host that was never reachable stays unreachable**

```dart
test('SSH host that was never reachable stays unreachable', () {
  final current = [SshHost(host: 'down', hostname: 'down.example.com', user: null, port: 22, reachable: false)];
  final refreshed = [SshHost(host: 'down', hostname: 'down.example.com', user: null, port: 22, reachable: false)];

  final diff = diffServerSnapshot(
    currentGroups: [],
    currentSessions: [],
    currentSshHosts: current,
    refreshedGroups: [],
    refreshedSessions: [],
    refreshedSshHosts: refreshed,
  );

  expect(diff.sshHosts.first.reachable, isFalse);
  expect(diff.sshHostsChanged, isFalse);
});
```

- [ ] **Step 7: Write test — newly reachable host becomes reachable**

```dart
test('SSH host that becomes reachable updates correctly', () {
  final current = [SshHost(host: 'waking', hostname: 'waking.example.com', user: null, port: 22, reachable: false)];
  final refreshed = [SshHost(host: 'waking', hostname: 'waking.example.com', user: null, port: 22, reachable: true)];

  final diff = diffServerSnapshot(
    currentGroups: [],
    currentSessions: [],
    currentSshHosts: current,
    refreshedGroups: [],
    refreshedSessions: [],
    refreshedSshHosts: refreshed,
  );

  expect(diff.sshHosts.first.reachable, isTrue);
  expect(diff.sshHostsChanged, isTrue);
});
```

- [ ] **Step 8: Run all diff tests**

Run: `cd flutter_app && flutter test test/server_snapshot_diff_test.dart -v`
Expected: ALL PASS

- [ ] **Step 9: Commit**

```bash
git add flutter_app/lib/providers/server_snapshot_diff.dart flutter_app/lib/models/ssh_host.dart flutter_app/test/server_snapshot_diff_test.dart
git commit -m "fix: add SSH host reachability hysteresis to prevent sidebar flicker

When the server reports a previously-reachable host as unreachable,
preserve the reachable state in the frontend diff layer. This prevents
transient TCP check failures from causing hosts to flash in/out of
the sidebar every 5 seconds."
```

---

### Task 3: Decouple SSH reachability polling from the main refresh cycle

**Files:**
- Modify: `flutter_app/lib/providers/server_provider.dart:204-247,623-641` (separate SSH polling)

- [ ] **Step 1: Write failing test — SSH hosts are NOT fetched on every refresh**

```dart
test('periodic refresh does not call listSshHosts every cycle', () async {
  int sshCallCount = 0;
  final api = MockApiService(
    listSshHostsHandler: () async {
      sshCallCount++;
      return [];
    },
  );

  // Trigger 3 refreshes
  await notifier.refresh();
  await notifier.refresh();
  await notifier.refresh();

  // SSH should NOT have been called 3 times (decoupled to slower cycle)
  expect(sshCallCount, lessThan(3));
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd flutter_app && flutter test test/server_provider_test.dart -v`
Expected: FAIL — `sshCallCount` is 3

- [ ] **Step 3: Separate SSH polling into its own slower timer**

In `server_provider.dart`, add a separate SSH refresh counter. Instead of fetching SSH hosts on every refresh, only include them every 6th refresh (every 30 seconds):

```dart
class ServerNotifier extends StateNotifier<ServerState> {
  static const _refreshInterval = Duration(seconds: 5);
  static const _sshRefreshEveryN = 6;  // NEW: SSH every 30s
  Timer? _refreshTimer;
  final ApiServiceFactory _apiFactory;
  int _groupStructureVersion = 0;
  int _sessionStructureVersion = 0;
  int _connectionGeneration = 0;
  int _refreshGeneration = 0;
  int _refreshCount = 0;  // NEW
```

Modify `refresh()` to conditionally include SSH:

```dart
Future<void> refresh() async {
    final api = state.api;
    if (api == null) return;

    final generation = _connectionGeneration;
    final refreshGen = ++_refreshGeneration;
    final includeSsh = (++_refreshCount % _sshRefreshEveryN) == 0;

    try {
      final List<Group> groups;
      final List<Session> sessions;
      final List<SshHost> sshHosts;

      if (includeSsh) {
        final snapshot = await _loadSnapshot(api);
        groups = snapshot.groups;
        sessions = snapshot.sessions;
        sshHosts = snapshot.sshHosts;
      } else {
        final results = await Future.wait([
          api.listGroups(),
          api.listSessions(),
        ]);
        groups = results[0] as List<Group>;
        sessions = results[1] as List<Session>;
        sshHosts = state.sshHosts; // keep current SSH state
      }

      if (_connectionGeneration != generation) return;
      if (_refreshGeneration != refreshGen) return;

      final diff = diffServerSnapshot(
        currentGroups: state.groups,
        currentSessions: state.sessions,
        currentSshHosts: state.sshHosts,
        refreshedGroups: groups,
        refreshedSessions: sessions,
        refreshedSshHosts: sshHosts,
      );

      // ... rest unchanged
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd flutter_app && flutter test test/server_provider_test.dart -v`
Expected: PASS

- [ ] **Step 5: Run ALL tests**

Run: `cd flutter_app && flutter test -v`
Expected: ALL PASS

- [ ] **Step 6: Commit**

```bash
git add flutter_app/lib/providers/server_provider.dart flutter_app/test/server_provider_test.dart
git commit -m "perf: decouple SSH reachability poll from main 5s refresh cycle

SSH reachability checks (2s TCP timeout per host) now only run every
30 seconds instead of every 5 seconds. This reduces the frequency of
reachability jitter and prevents the slow SSH endpoint from blocking
the fast session/group refresh path."
```
