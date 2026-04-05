import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tether/models/group.dart';
import 'package:tether/models/session.dart';
import 'package:tether/providers/server_provider.dart';
import 'package:tether/widgets/sidebar/sidebar.dart';

class TestServerNotifier extends ServerNotifier {
  TestServerNotifier(super.state) : super.test();

  void replaceState(ServerState nextState) {
    state = nextState;
  }
}

Group _group(String id, String name, int sortOrder, {String? sshHost}) =>
    Group(id: id, name: name, sortOrder: sortOrder, sshHost: sshHost);

Session _session(String id, String groupId) => Session(
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
);

Future<void> _pumpSidebar(
  WidgetTester tester,
  TestServerNotifier notifier,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [serverProvider.overrideWith((ref) => notifier)],
      child: const MaterialApp(
        home: Scaffold(body: SizedBox(width: 280, child: Sidebar())),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'root groups render in separate local and remote scope sections',
    (tester) async {
      final local = _group('local', 'Local One', 5);
      final remoteA = _group('remote-a', 'Remote A', 0, sshHost: 'devbox');
      final remoteB = _group('remote-b', 'Remote B', 1, sshHost: 'devbox');
      final notifier = TestServerNotifier(
        ServerState(
          isConnected: true,
          groups: [remoteA, local, remoteB],
          sessions: [
            _session('local-session', local.id),
            _session('remote-a-session', remoteA.id),
            _session('remote-b-session', remoteB.id),
          ],
        ),
      );

      await _pumpSidebar(tester, notifier);

      expect(find.text('Local'), findsOneWidget);
      expect(find.text('Remote: devbox'), findsOneWidget);

      final localHeaderY = tester.getTopLeft(find.text('Local')).dy;
      final localGroupY = tester.getTopLeft(find.text('Local One')).dy;
      final remoteHeaderY = tester.getTopLeft(find.text('Remote: devbox')).dy;
      final remoteAY = tester.getTopLeft(find.text('Remote A')).dy;
      final remoteBY = tester.getTopLeft(find.text('Remote B')).dy;

      expect(localHeaderY, lessThan(localGroupY));
      expect(localGroupY, lessThan(remoteHeaderY));
      expect(remoteHeaderY, lessThan(remoteAY));
      expect(remoteAY, lessThan(remoteBY));
    },
  );

  testWidgets('new remote groups append to the end of their host section', (
    tester,
  ) async {
    final local = _group('local', 'Local One', 0);
    final remoteA = _group('remote-a', 'Remote A', 0, sshHost: 'devbox');
    final notifier = TestServerNotifier(
      ServerState(
        isConnected: true,
        groups: [local, remoteA],
        sessions: [
          _session('local-session', local.id),
          _session('remote-a-session', remoteA.id),
        ],
      ),
    );

    await _pumpSidebar(tester, notifier);

    final remoteAY = tester.getTopLeft(find.text('Remote A')).dy;

    notifier.replaceState(
      notifier.state.copyWith(
        groups: [
          local,
          remoteA,
          _group('remote-b', 'Remote B', 1, sshHost: 'devbox'),
        ],
        sessions: [
          _session('local-session', local.id),
          _session('remote-a-session', remoteA.id),
          _session('remote-b-session', 'remote-b'),
        ],
      ),
    );
    await tester.pumpAndSettle();

    final remoteBY = tester.getTopLeft(find.text('Remote B')).dy;
    expect(remoteAY, lessThan(remoteBY));
  });

  testWidgets('group expansion state follows the group after sidebar reorder', (
    tester,
  ) async {
    final alpha = _group('alpha', 'Alpha', 0);
    final beta = _group('beta', 'Beta', 1);
    final notifier = TestServerNotifier(
      ServerState(
        isConnected: true,
        groups: [alpha, beta],
        sessions: [
          _session('alpha-session', alpha.id),
          _session('beta-session', beta.id),
        ],
      ),
    );

    await _pumpSidebar(tester, notifier);

    expect(find.text('alpha-session'), findsOneWidget);
    expect(find.text('beta-session'), findsOneWidget);

    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();

    expect(find.text('alpha-session'), findsNothing);
    expect(find.text('beta-session'), findsOneWidget);

    notifier.replaceState(
      notifier.state.copyWith(
        groups: [beta.copyWith(sortOrder: 0), alpha.copyWith(sortOrder: 1)],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('alpha-session'), findsNothing);
    expect(find.text('beta-session'), findsOneWidget);
  });
}
