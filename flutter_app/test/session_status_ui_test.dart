import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tether/models/group.dart';
import 'package:tether/models/session.dart';
import 'package:tether/platform/terminal_backend.dart';
import 'package:tether/providers/server_provider.dart';
import 'package:tether/providers/session_provider.dart';
import 'package:tether/utils/session_status.dart';
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
  int attentionSeq = 0,
  int attentionAckSeq = 0,
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
    attentionSeq: attentionSeq,
    attentionAckSeq: attentionAckSeq,
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

  testWidgets('session tab prefers agent title while showing waiting status', (
    tester,
  ) async {
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

    container.read(sessionProvider.notifier)
      ..selectProject(group.id)
      ..setActiveSession(projectId: group.id, sessionId: session.id);

    await _pumpWithContainer(
      tester,
      container,
      TerminalArea(backend: const _FakeTerminalBackend()),
    );
    await tester.pump();

    final finder = find.byKey(const ValueKey('session-tab-status-session-1'));
    expect(finder, findsOneWidget);
    expect(find.text('Claude Code'), findsOneWidget);
    expect(find.text('agent'), findsNothing);
    expect(
      tester.widget<SessionStatusDot>(finder).status,
      SessionIndicatorStatus.waiting,
    );
  });

  testWidgets('session tab shows running dot for Codex activity', (
    tester,
  ) async {
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

    container.read(sessionProvider.notifier)
      ..selectProject(group.id)
      ..setActiveSession(projectId: group.id, sessionId: session.id);

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
      SessionIndicatorStatus.running,
    );
  });

  testWidgets('session tab hides status dot when there is no tool state', (
    tester,
  ) async {
    final group = _group('local');
    final session = _session('session-3', groupId: group.id, name: 'shell');
    final container = _container(
      ServerState(isConnected: true, groups: [group], sessions: [session]),
    );
    addTearDown(container.dispose);

    container.read(sessionProvider.notifier)
      ..selectProject(group.id)
      ..setActiveSession(projectId: group.id, sessionId: session.id);

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

  testWidgets('session tab status dot updates through live state changes', (
    tester,
  ) async {
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

    container.read(sessionProvider.notifier)
      ..selectProject(group.id)
      ..setActiveSession(projectId: group.id, sessionId: session.id);

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
      SessionIndicatorStatus.waiting,
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
      SessionIndicatorStatus.running,
    );

    notifier.updateForegroundProcess(
      session.id,
      'claude',
      oscTitle: '· Claude Code',
    );
    await tester.pump(const Duration(milliseconds: 150));

    expect(
      tester.widget<SessionStatusDot>(finder).status,
      SessionIndicatorStatus.waiting,
    );

    notifier.updateForegroundProcess(session.id, null);
    await tester.pump();

    expect(finder, findsNothing);
  });

  testWidgets('active tab suppresses bell indicator for completed session', (
    tester,
  ) async {
    final group = _group('local');
    final session = _session(
      'session-9',
      groupId: group.id,
      name: 'agent',
      foregroundProcess: 'claude',
      oscTitle: '· Claude Code',
      attentionSeq: 2,
      attentionAckSeq: 1,
    );
    final container = _container(
      ServerState(isConnected: true, groups: [group], sessions: [session]),
    );
    addTearDown(container.dispose);

    container.read(sessionProvider.notifier)
      ..selectProject(group.id)
      ..setActiveSession(projectId: group.id, sessionId: session.id);

    await _pumpWithContainer(
      tester,
      container,
      TerminalArea(backend: const _FakeTerminalBackend()),
    );
    await tester.pump();

    final finder = find.byKey(const ValueKey('session-tab-status-session-9'));
    expect(finder, findsOneWidget);
    expect(
      tester.widget<SessionStatusDot>(finder).status,
      SessionIndicatorStatus.waiting,
    );
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
    bool isVisibleInUI = true,
    bool imagePasteBridgeEnabled = false,
    VoidCallback? onSessionExited,
    ForegroundChangedCallback? onForegroundChanged,
    Future<void> Function(Uint8List data, String mimeType)? onClipboardImage,
  }) {
    return SizedBox(key: key);
  }
}
