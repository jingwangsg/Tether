import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tether/models/group.dart';
import 'package:tether/models/session.dart';
import 'package:tether/platform/terminal_backend.dart';
import 'package:tether/providers/server_provider.dart';
import 'package:tether/providers/session_provider.dart';
import 'package:tether/widgets/sidebar/group_section.dart';
import 'package:tether/widgets/sidebar/sidebar.dart';
import 'package:tether/widgets/terminal/terminal_area.dart';
import 'package:tether/widgets/terminal/terminal_controller.dart';

Group _group(String id, {String? sshHost}) {
  return Group(id: id, name: id, sshHost: sshHost);
}

Session _session(
  String id, {
  required String groupId,
  required String name,
  required bool isAlive,
}) {
  return Session(
    id: id,
    groupId: groupId,
    name: name,
    shell: 'bash',
    cols: 80,
    rows: 24,
    cwd: '/tmp/workspace',
    isAlive: isAlive,
    createdAt: '',
    lastActive: '',
  );
}

ProviderContainer _container(ServerState serverState) {
  return ProviderContainer(
    overrides: [
      serverProvider.overrideWith((ref) => _TestServerNotifier(serverState)),
    ],
  );
}

Future<void> _pumpWithContainer(
  WidgetTester tester,
  ProviderContainer container,
  Widget child,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Scaffold(body: child)),
    ),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'terminal area closes tabs for sessions that become dead locals',
    (tester) async {
      final group = _group('local');
      final alive = _session(
        'session-1',
        groupId: group.id,
        name: 'local-live',
        isAlive: true,
      );
      final dead = alive.copyWith(isAlive: false);
      final container = _container(
        ServerState(isConnected: true, groups: [group], sessions: [alive]),
      );
      addTearDown(container.dispose);

      container.read(sessionProvider.notifier).openTab(alive.id);

      await _pumpWithContainer(
        tester,
        container,
        TerminalArea(backend: const _FakeTerminalBackend()),
      );
      await tester.pump();

      expect(
        container
            .read(sessionProvider)
            .openTabs
            .map((tab) => tab.sessionId)
            .toList(),
        [alive.id],
      );

      final notifier =
          container.read(serverProvider.notifier) as _TestServerNotifier;
      notifier.setServerState(
        ServerState(isConnected: true, groups: [group], sessions: [dead]),
      );

      await tester.pump();
      await tester.pump();

      expect(container.read(sessionProvider).openTabs, isEmpty);
      expect(find.text('No sessions open'), findsOneWidget);
    },
  );

  testWidgets(
    'terminal area closes pre-opened tabs when only dead local sessions remain',
    (tester) async {
      final group = _group('local');
      final dead = _session(
        'session-1',
        groupId: group.id,
        name: 'dead-local',
        isAlive: false,
      );
      final container = _container(
        ServerState(isConnected: true, groups: [group], sessions: [dead]),
      );
      addTearDown(container.dispose);

      container.read(sessionProvider.notifier).openTab(dead.id);

      await _pumpWithContainer(
        tester,
        container,
        TerminalArea(backend: const _FakeTerminalBackend()),
      );
      await tester.pump();

      expect(container.read(sessionProvider).openTabs, isEmpty);
      expect(find.text('No sessions open'), findsOneWidget);
    },
  );

  testWidgets('dead local group session does not open from the sidebar group', (
    tester,
  ) async {
    final group = _group('local');
    final session = _session(
      'session-1',
      groupId: group.id,
      name: 'dead-local',
      isAlive: false,
    );
    final container = _container(
      ServerState(isConnected: true, groups: [group], sessions: [session]),
    );
    addTearDown(container.dispose);

    await _pumpWithContainer(
      tester,
      container,
      GroupSection(
        group: group,
        allGroups: [group],
        allSessions: [session],
        depth: 0,
      ),
    );

    expect(find.text('dead-local'), findsNothing);
    expect(find.text('0'), findsOneWidget);
    expect(container.read(sessionProvider).openTabs, isEmpty);
  });

  testWidgets('alive local group session still opens from the sidebar group', (
    tester,
  ) async {
    final group = _group('local');
    final session = _session(
      'session-1',
      groupId: group.id,
      name: 'alive-local',
      isAlive: true,
    );
    final container = _container(
      ServerState(isConnected: true, groups: [group], sessions: [session]),
    );
    addTearDown(container.dispose);

    await _pumpWithContainer(
      tester,
      container,
      GroupSection(
        group: group,
        allGroups: [group],
        allSessions: [session],
        depth: 0,
      ),
    );

    await tester.tap(find.text('alive-local'));
    await tester.pump();

    expect(
      container
          .read(sessionProvider)
          .openTabs
          .map((tab) => tab.sessionId)
          .toList(),
      [session.id],
    );
  });

  testWidgets('dead root session tile in sidebar does not open', (
    tester,
  ) async {
    final session = _session(
      'session-1',
      groupId: 'missing-group',
      name: 'dead-root',
      isAlive: false,
    );
    final container = _container(
      ServerState(isConnected: true, groups: const [], sessions: [session]),
    );
    addTearDown(container.dispose);

    await _pumpWithContainer(tester, container, const Sidebar());

    expect(find.text('dead-root'), findsNothing);
    expect(container.read(sessionProvider).openTabs, isEmpty);
  });

  testWidgets('alive root session tile in sidebar still opens', (tester) async {
    final session = _session(
      'session-1',
      groupId: 'missing-group',
      name: 'alive-root',
      isAlive: true,
    );
    final container = _container(
      ServerState(isConnected: true, groups: const [], sessions: [session]),
    );
    addTearDown(container.dispose);

    await _pumpWithContainer(tester, container, const Sidebar());

    await tester.tap(find.text('alive-root'));
    await tester.pump();

    expect(
      container
          .read(sessionProvider)
          .openTabs
          .map((tab) => tab.sessionId)
          .toList(),
      [session.id],
    );
  });
}

class _TestServerNotifier extends ServerNotifier {
  _TestServerNotifier(ServerState initialState) : super() {
    state = initialState;
  }

  void setServerState(ServerState nextState) {
    state = nextState;
  }

  @override
  Future<void> connect(ServerConfig config) async {}

  @override
  Future<void> refresh() async {}
}

class _FakeTerminalBackend implements TerminalBackend {
  const _FakeTerminalBackend();

  @override
  bool get isLocalPty => false;

  @override
  String get platformId => 'fake';

  @override
  Widget createTerminalWidget({
    Key? key,
    required String sessionId,
    required TerminalController controller,
    required ServerConfig? serverConfig,
    String? command,
    String? cwd,
    required bool isActive,
    bool imagePasteBridgeEnabled = false,
    VoidCallback? onSessionExited,
    void Function(String? title)? onTitleChanged,
    ForegroundChangedCallback? onForegroundChanged,
    Future<void> Function(Uint8List data, String mimeType)? onClipboardImage,
  }) {
    return SizedBox(key: key);
  }
}
