import 'package:flutter_test/flutter_test.dart';
import 'package:tether/models/session.dart';

// Reproduces the SSH-session icon flicker caused by the 10-second HTTP refresh
// overwriting foreground state that only the remote WebSocket knows about.
//
// Scenario: the remote tether-server pushes `foreground_changed {process:"claude"}`
// via WebSocket.  Ten seconds later the local server's HTTP /api/sessions returns
// foreground_process=null (local server has no PtySession for SSH sessions).
// Without the fix, refresh() overwrites "claude" with null and the icon reverts
// to terminal.  With the fix, the WebSocket-pushed value is preserved.

// Mirror of the merge logic in ServerNotifier.refresh().
List<Session> _merge(List<Session> fromHttp, List<Session> current) {
  return fromHttp.map((s) {
    if (s.foregroundProcess != null) return s;
    final c = current.where((c) => c.id == s.id).firstOrNull;
    if (c?.foregroundProcess == null) return s;
    return s.copyWith(
      foregroundProcess: c!.foregroundProcess,
      oscTitle: c.oscTitle,
    );
  }).toList();
}

Session _session(String id, {String? fg, String? oscTitle}) => Session(
      id: id,
      groupId: 'g',
      name: 'test',
      shell: 'bash',
      cols: 80,
      rows: 24,
      cwd: '/tmp',
      isAlive: true,
      createdAt: '',
      lastActive: '',
      foregroundProcess: fg,
      oscTitle: oscTitle,
    );

void main() {
  group('refresh() foreground preservation for SSH sessions', () {
    test('preserves WebSocket-pushed "claude" when HTTP returns null', () {
      // BEFORE fix: icon reverts to terminal every 10 s while claude is idle.
      // AFTER fix: foreground is kept from the last WebSocket push.
      final current = [_session('s1', fg: 'claude', oscTitle: 'idle')];
      final fromHttp = [_session('s1')]; // local server returns null

      final merged = _merge(fromHttp, current);

      expect(merged[0].foregroundProcess, 'claude');
      expect(merged[0].oscTitle, 'idle');
    });

    test('does not preserve when WebSocket already cleared the foreground', () {
      // Tool exited → WS pushed null → current is null → HTTP null doesn't resurrect it.
      final current = [_session('s1')];
      final fromHttp = [_session('s1')];

      final merged = _merge(fromHttp, current);

      expect(merged[0].foregroundProcess, isNull);
    });

    test('uses HTTP value when it is non-null (local sessions)', () {
      // Local sessions: local server knows the real foreground, trust it.
      final current = [_session('s1')];
      final fromHttp = [_session('s1', fg: 'codex')];

      final merged = _merge(fromHttp, current);

      expect(merged[0].foregroundProcess, 'codex');
    });

    test('HTTP non-null overrides stale WebSocket value (local sessions)', () {
      // If the local server detects a DIFFERENT process, use the fresh HTTP value.
      final current = [_session('s1', fg: 'claude')];
      final fromHttp = [_session('s1', fg: 'codex')];

      final merged = _merge(fromHttp, current);

      expect(merged[0].foregroundProcess, 'codex');
    });

    test('handles multiple sessions — only SSH sessions (null HTTP fg) are preserved', () {
      final current = [
        _session('local', fg: null),       // local session, no tool running
        _session('ssh-claude', fg: 'claude', oscTitle: 'idle'), // SSH, tool running
        _session('ssh-none', fg: null),    // SSH, no tool
      ];
      final fromHttp = [
        _session('local', fg: 'codex'),   // local server knows this one
        _session('ssh-claude'),            // SSH: local server returns null
        _session('ssh-none'),              // SSH: null, and current is also null
      ];

      final merged = _merge(fromHttp, current);

      expect(merged.firstWhere((s) => s.id == 'local').foregroundProcess, 'codex');
      expect(merged.firstWhere((s) => s.id == 'ssh-claude').foregroundProcess, 'claude');
      expect(merged.firstWhere((s) => s.id == 'ssh-none').foregroundProcess, isNull);
    });
  });
}
