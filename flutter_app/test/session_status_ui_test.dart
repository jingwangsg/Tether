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
import 'package:tether/utils/session_status.dart';
import 'package:tether/widgets/sidebar/group_section.dart';
import 'package:tether/widgets/sidebar/sidebar.dart';
import 'package:tether/widgets/terminal/session_status_dot.dart';
import 'package:tether/widgets/terminal/terminal_area.dart';
import 'package:tether/widgets/terminal/terminal_controller.dart';

Group _group(String id) {
  return Group(id: id, name: id);
}

Session _session(
  String id, {
  required String groupId,
  required String name,
  String? foregroundProcess,
  String? oscTitle,
}) {
  return Session(
    id: id,
    groupId: groupId,
    name: name,
    shell: 'bash',
    cols: 80,
    rows: 24,
    cwd: '/tmp/workspace',
    isAlive: true,
    createdAt: '',
    lastActive: '',
    foregroundProcess: foregroundProcess,
    oscTitle: oscTitle,
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

  testWidgets('session tab shows yellow waiting dot for Claude Code', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'show_tab_bar': true});
    final group = _group('local');
    final session = _session(
      'session-1',
      groupId: group.id,
      name: 'agent',
      foregroundProcess: 'claude',
      oscTitle: '· Claude Code',
    );
    final container = _container(
      ServerState(isConnected: true, groups: [group], sessions: [session]),
    );
    addTearDown(container.dispose);

    container.read(sessionProvider.notifier).openTab(session.id);

    await _pumpWithContainer(
      tester,
      container,
      TerminalArea(backend: const _FakeTerminalBackend()),
    );
    await tester.pump();

    final finder = find.byKey(const ValueKey('session-tab-status-session-1'));
    expect(finder, findsOneWidget);
    expect(find.text('Claude Code'), findsOneWidget);
    expect(
      tester.widget<SessionStatusDot>(finder).status,
      SessionToolStatus.waiting,
    );
  });

  testWidgets('session tab shows running dot for Codex activity', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'show_tab_bar': true});
    final group = _group('local');
    final session = _session(
      'session-2',
      groupId: group.id,
      name: 'agent',
      foregroundProcess: 'codex',
      oscTitle: '⠋ Codex',
    );
    final container = _container(
      ServerState(isConnected: true, groups: [group], sessions: [session]),
    );
    addTearDown(container.dispose);

    container.read(sessionProvider.notifier).openTab(session.id);

    await _pumpWithContainer(
      tester,
      container,
      TerminalArea(backend: const _FakeTerminalBackend()),
    );
    await tester.pump(const Duration(milliseconds: 150));

    final finder = find.byKey(const ValueKey('session-tab-status-session-2'));
    expect(finder, findsOneWidget);
    expect(
      tester.widget<SessionStatusDot>(finder).status,
      SessionToolStatus.running,
    );
  });

  testWidgets('session tab hides status dot when there is no tool state', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'show_tab_bar': true});
    final group = _group('local');
    final session = _session('session-3', groupId: group.id, name: 'shell');
    final container = _container(
      ServerState(isConnected: true, groups: [group], sessions: [session]),
    );
    addTearDown(container.dispose);

    container.read(sessionProvider.notifier).openTab(session.id);

    await _pumpWithContainer(
      tester,
      container,
      TerminalArea(backend: const _FakeTerminalBackend()),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('session-tab-status-session-3')),
      findsNothing,
    );
  });

  testWidgets('sidebar no longer renders raw osc title symbols', (
    tester,
  ) async {
    final group = _group('local');
    final session = _session(
      'session-4',
      groupId: group.id,
      name: 'agent',
      foregroundProcess: 'claude',
      oscTitle: '✱ Claude Code',
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

    expect(find.text('Claude Code'), findsOneWidget);
    expect(find.text('✱'), findsNothing);
    final finder = find.byKey(
      const ValueKey('session-sidebar-status-session-4'),
    );
    expect(finder, findsOneWidget);
    expect(
      tester.widget<SessionStatusDot>(finder).status,
      SessionToolStatus.running,
    );
  });

  testWidgets('root sidebar session shows waiting status dot', (tester) async {
    final session = _session(
      'session-5',
      groupId: 'missing-group',
      name: 'agent',
      foregroundProcess: 'claude',
      oscTitle: '· Claude Code',
    );
    final container = _container(
      ServerState(isConnected: true, groups: const [], sessions: [session]),
    );
    addTearDown(container.dispose);

    await _pumpWithContainer(tester, container, const Sidebar());

    final finder = find.byKey(
      const ValueKey('session-sidebar-status-session-5'),
    );
    expect(finder, findsOneWidget);
    expect(
      tester.widget<SessionStatusDot>(finder).status,
      SessionToolStatus.waiting,
    );
  });

  testWidgets('session tab status dot updates through live state changes', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'show_tab_bar': true});
    final group = _group('local');
    final session = _session(
      'session-6',
      groupId: group.id,
      name: 'agent',
      foregroundProcess: 'claude',
      oscTitle: '· Claude Code',
    );
    final container = _container(
      ServerState(isConnected: true, groups: [group], sessions: [session]),
    );
    addTearDown(container.dispose);

    container.read(sessionProvider.notifier).openTab(session.id);

    await _pumpWithContainer(
      tester,
      container,
      TerminalArea(backend: const _FakeTerminalBackend()),
    );
    await tester.pump();

    final finder = find.byKey(const ValueKey('session-tab-status-session-6'));
    expect(finder, findsOneWidget);
    expect(
      tester.widget<SessionStatusDot>(finder).status,
      SessionToolStatus.waiting,
    );

    final notifier = container.read(serverProvider.notifier);
    notifier.updateForegroundProcess(
      session.id,
      'claude',
      oscTitle: '✱ Claude Code',
    );
    await tester.pump(const Duration(milliseconds: 150));

    expect(
      tester.widget<SessionStatusDot>(finder).status,
      SessionToolStatus.running,
    );

    notifier.updateForegroundProcess(
      session.id,
      'claude',
      oscTitle: '· Claude Code',
    );
    await tester.pump(const Duration(milliseconds: 150));

    expect(
      tester.widget<SessionStatusDot>(finder).status,
      SessionToolStatus.waiting,
    );

    notifier.updateForegroundProcess(session.id, null);
    await tester.pump();

    expect(finder, findsNothing);
  });

  testWidgets('top bar stays hidden by default on fresh settings', (
    tester,
  ) async {
    final group = _group('local');
    final session = _session(
      'session-7',
      groupId: group.id,
      name: 'agent',
      foregroundProcess: 'claude',
      oscTitle: '· Claude Code',
    );
    final container = _container(
      ServerState(isConnected: true, groups: [group], sessions: [session]),
    );
    addTearDown(container.dispose);

    container.read(sessionProvider.notifier).openTab(session.id);

    await _pumpWithContainer(
      tester,
      container,
      TerminalArea(backend: const _FakeTerminalBackend()),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('session-tab-status-session-7')),
      findsNothing,
    );
    expect(find.text('Claude Code'), findsNothing);
  });
}

class _TestServerNotifier extends ServerNotifier {
  _TestServerNotifier(ServerState initialState) : super() {
    state = initialState;
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
