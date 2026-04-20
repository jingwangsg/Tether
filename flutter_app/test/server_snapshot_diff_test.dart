import 'package:flutter_test/flutter_test.dart';
import 'package:tether/models/group.dart';
import 'package:tether/models/session.dart';
import 'package:tether/models/ssh_host.dart';
import 'package:tether/providers/server_snapshot_diff.dart';

Group _group(String id) => Group(id: id, name: id);

Session _session(
  String id, {
  String groupId = 'alpha',
  int sortOrder = 0,
  bool isAlive = true,
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
    cwd: '/tmp/$id',
    isAlive: isAlive,
    createdAt: '',
    lastActive: '',
    sortOrder: sortOrder,
    foregroundProcess: foregroundProcess,
    oscTitle: oscTitle,
    attentionSeq: attentionSeq,
    attentionAckSeq: attentionAckSeq,
  );
}

SshHost _ssh(String host, {bool? reachable}) =>
    SshHost(host: host, reachable: reachable);

void main() {
  group('diffServerSnapshot', () {
    test('runtime-only session fields do not mark sessions as structural changes', () {
      final diff = diffServerSnapshot(
        currentGroups: [_group('alpha')],
        currentSessions: [
          _session(
            's1',
            foregroundProcess: 'claude',
            oscTitle: '* thinking',
            attentionSeq: 2,
            attentionAckSeq: 1,
          ),
        ],
        currentSshHosts: [_ssh('devbox', reachable: true)],
        refreshedGroups: [_group('alpha')],
        refreshedSessions: [_session('s1')],
        refreshedSshHosts: [_ssh('devbox', reachable: false)],
      );

      expect(diff.sessionsChanged, isTrue);
      expect(diff.sessionsStructureChanged, isFalse);
      expect(diff.sshHostsChanged, isTrue);
      expect(diff.mergedSessions.single.foregroundProcess, 'claude');
      expect(diff.mergedSessions.single.oscTitle, '* thinking');
      expect(diff.mergedSessions.single.attentionSeq, 2);
      expect(diff.mergedSessions.single.attentionAckSeq, 1);
    });

    test('session reorder and liveness changes remain structural', () {
      final diff = diffServerSnapshot(
        currentGroups: [_group('alpha')],
        currentSessions: [_session('s1', sortOrder: 0, isAlive: true)],
        currentSshHosts: const [],
        refreshedGroups: [_group('alpha')],
        refreshedSessions: [_session('s1', sortOrder: 1, isAlive: false)],
        refreshedSshHosts: const [],
      );

      expect(diff.sessionsChanged, isTrue);
      expect(diff.sessionsStructureChanged, isTrue);
    });

    test('unchanged snapshots produce no work', () {
      final groups = [_group('alpha')];
      final sessions = [_session('s1')];
      final sshHosts = [_ssh('devbox', reachable: true)];

      final diff = diffServerSnapshot(
        currentGroups: groups,
        currentSessions: sessions,
        currentSshHosts: sshHosts,
        refreshedGroups: groups,
        refreshedSessions: sessions,
        refreshedSshHosts: sshHosts,
      );

      expect(diff.hasChanges, isFalse);
      expect(diff.groupsStructureChanged, isFalse);
      expect(diff.sessionsStructureChanged, isFalse);
      expect(diff.sshHostsChanged, isFalse);
    });
  });
}
