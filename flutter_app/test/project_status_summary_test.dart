import 'package:flutter_test/flutter_test.dart';
import 'package:tether/models/group.dart';
import 'package:tether/models/session.dart';
import 'package:tether/utils/project_status_summary.dart';
import 'package:tether/utils/session_status.dart';

Group _group(String id) => Group(id: id, name: id);

Session _session(
  String id, {
  required String groupId,
  String? foregroundProcess,
  String? oscTitle,
  int attentionSeq = 0,
  int attentionAckSeq = 0,
}) {
  return Session(
    id: id,
    groupId: groupId,
    name: id,
    shell: 'zsh',
    cols: 80,
    rows: 24,
    cwd: '/tmp',
    isAlive: true,
    createdAt: '',
    lastActive: '',
    foregroundProcess: foregroundProcess,
    oscTitle: oscTitle,
    attentionSeq: attentionSeq,
    attentionAckSeq: attentionAckSeq,
  );
}

void main() {
  test('attention beats waiting and running within a project', () {
    final summary = summarizeProjectStatuses(
      sessions: [
        _session('run', groupId: 'alpha', foregroundProcess: 'claude', oscTitle: '* thinking'),
        _session('wait', groupId: 'alpha', foregroundProcess: 'claude', oscTitle: '· ready'),
        _session('ping', groupId: 'alpha', attentionSeq: 3, attentionAckSeq: 1),
      ],
      selectedProjectId: null,
      activeSessionId: null,
    );

    expect(summary['alpha'], SessionIndicatorStatus.attention);
  });

  test('active session attention does not light the project badge', () {
    final summary = summarizeProjectStatuses(
      sessions: [
        _session(
          'active',
          groupId: 'alpha',
          attentionSeq: 3,
          attentionAckSeq: 1,
        ),
      ],
      selectedProjectId: 'alpha',
      activeSessionId: 'active',
    );

    expect(summary.containsKey('alpha'), isFalse);
  });
}
