import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tether/models/group.dart';
import 'package:tether/models/session.dart';
import 'package:tether/platform/terminal_backend.dart';
import 'package:tether/providers/server_provider.dart';
import 'package:tether/providers/session_provider.dart';
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

  testWidgets('terminal area excludes dead local sessions from project view', (
    tester,
  ) async {
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

    container.read(sessionProvider.notifier)
      ..selectProject(group.id)
      ..setActiveSession(projectId: group.id, sessionId: alive.id);

    await _pumpWithContainer(
      tester,
      container,
      TerminalArea(backend: const _FakeTerminalBackend()),
    );
    await tester.pump();

    // Session should be visible in the top bar
    expect(find.text('local-live'), findsOneWidget);

    // Session dies
    final notifier =
        container.read(serverProvider.notifier) as _TestServerNotifier;
    notifier.setServerState(
      ServerState(isConnected: true, groups: [group], sessions: [dead]),
    );

    await tester.pump();
    await tester.pump();

    // Dead local session should be excluded
    expect(find.text('No sessions in this project'), findsOneWidget);
  });

  testWidgets('sidebar shows project tile but no individual session names', (
    tester,
  ) async {
    final group = _group('local');
    final alive = _session(
      'session-1',
      groupId: group.id,
      name: 'alive-local',
      isAlive: true,
    );
    final container = _container(
      ServerState(isConnected: true, groups: [group], sessions: [alive]),
    );
    addTearDown(container.dispose);

    await _pumpWithContainer(
      tester,
      container,
      const SizedBox(width: 280, child: Sidebar()),
    );
    await tester.pumpAndSettle();

    // Project tile should exist
    expect(find.text('local'), findsOneWidget);
    // Individual session names should NOT appear in the sidebar
    expect(find.text('alive-local'), findsNothing);
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
    ForegroundChangedCallback? onForegroundChanged,
    Future<void> Function(Uint8List data, String mimeType)? onClipboardImage,
  }) {
    return SizedBox(key: key);
  }
}
