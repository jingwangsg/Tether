import 'package:flutter_test/flutter_test.dart';
import 'package:tether/models/group.dart';
import 'package:tether/models/session.dart';
import 'package:tether/providers/session_provider.dart';
import 'package:tether/utils/session_interaction.dart';

Group _group(String id, {String? sshHost}) {
  return Group(id: id, name: id, sshHost: sshHost);
}

Session _session(String id, {required String groupId, required bool isAlive}) {
  return Session(
    id: id,
    groupId: groupId,
    name: id,
    shell: 'bash',
    cols: 80,
    rows: 24,
    cwd: '/tmp/$id',
    isAlive: isAlive,
    createdAt: '',
    lastActive: '',
  );
}

void main() {
  group('session interaction', () {
    test('alive local session stays interactive', () {
      final session = _session('local-alive', groupId: 'local', isAlive: true);

      expect(isSessionInteractive(session, [_group('local')]), isTrue);
    });

    test('dead local session is not interactive', () {
      final session = _session('local-dead', groupId: 'local', isAlive: false);

      expect(isSessionInteractive(session, [_group('local')]), isFalse);
    });

    test('remote session remains interactive', () {
      final session = _session('remote', groupId: 'remote', isAlive: false);

      expect(
        isSessionInteractive(session, [_group('remote', sshHost: 'prod')]),
        isTrue,
      );
    });

    test('interactive session ids exclude only dead local sessions', () {
      final sessions = [
        _session('alive-local', groupId: 'local', isAlive: true),
        _session('dead-local', groupId: 'local', isAlive: false),
        _session('remote', groupId: 'remote', isAlive: false),
      ];
      final groups = [_group('local'), _group('remote', sshHost: 'prod')];

      expect(interactiveSessionIds(sessions, groups), {
        'alive-local',
        'remote',
      });
    });

    test('visible sessions hide only dead local sessions', () {
      final sessions = [
        _session('alive-local', groupId: 'local', isAlive: true),
        _session('dead-local', groupId: 'local', isAlive: false),
        _session('remote', groupId: 'remote', isAlive: false),
      ];
      final groups = [_group('local'), _group('remote', sshHost: 'prod')];

      expect(
        visibleSessions(sessions, groups).map((session) => session.id).toList(),
        ['alive-local', 'remote'],
      );
    });
  });

  group('session tab cleanup', () {
    test(
      'cleanupStaleTabs removes invalid tabs and falls forward for active',
      () {
        final notifier =
            SessionNotifier()
              ..openTab('first')
              ..openTab('second')
              ..openTab('third')
              ..setActiveSession('second');

        notifier.cleanupStaleTabs({'first', 'third'});

        expect(notifier.state.openTabs.map((tab) => tab.sessionId).toList(), [
          'first',
          'third',
        ]);
        expect(notifier.state.activeSessionId, 'third');
      },
    );

    test('cleanupStaleTabs clears the active session when no tabs remain', () {
      final notifier = SessionNotifier()..openTab('only');

      notifier.cleanupStaleTabs({});

      expect(notifier.state.openTabs, isEmpty);
      expect(notifier.state.activeSessionId, isNull);
    });
  });
}
