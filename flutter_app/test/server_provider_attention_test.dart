import 'package:flutter_test/flutter_test.dart';
import 'package:tether/models/session.dart';
import 'package:tether/providers/server_provider.dart';

Session _session(
  String id, {
  bool needsAttention = false,
  int attentionSeq = 0,
}) {
  return Session(
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
    needsAttention: needsAttention,
    attentionSeq: attentionSeq,
    attentionUpdatedAt: needsAttention ? '2026-04-05T00:00:00Z' : null,
  );
}

void main() {
  test(
    'foreground updates without attention payload preserve existing bell state',
    () {
      final session = _session('s1', needsAttention: true, attentionSeq: 3);
      final notifier = ServerNotifier.test(
        ServerState(isConnected: true, sessions: [session]),
      );

      notifier.updateForegroundProcess(
        session.id,
        'claude',
        toolState: 'waiting',
        attentionStatePresent: false,
      );

      final updated = notifier.state.sessions.single;
      expect(updated.foregroundProcess, 'claude');
      expect(updated.toolState, 'waiting');
      expect(updated.needsAttention, isTrue);
      expect(updated.attentionSeq, 3);
      expect(updated.attentionUpdatedAt, session.attentionUpdatedAt);
    },
  );
}
