import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tether/models/group.dart';
import 'package:tether/models/session.dart';
import 'package:tether/platform/terminal_backend.dart';
import 'package:tether/providers/server_provider.dart';
import 'package:tether/providers/session_provider.dart';
import 'package:tether/screens/home_screen.dart';
import 'package:tether/widgets/terminal/terminal_controller.dart';

class _MutableServerNotifier extends ServerNotifier {
  _MutableServerNotifier(super.initialState) : super.test();

  void replaceState(ServerState nextState) {
    state = nextState;
  }
}

class _FakeTerminalBackend implements TerminalBackend {
  const _FakeTerminalBackend();

  @override
  String get platformId => 'fake';

  @override
  bool get isLocalPty => false;

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
    void Function(String title, String body)? onBell,
    Future<void> Function(Uint8List data, String mimeType)? onClipboardImage,
  }) {
    return ColoredBox(
      key: ValueKey('terminal-$sessionId'),
      color: isActive ? Colors.green : Colors.grey,
    );
  }
}

Group _group(String id, String name, int sortOrder) =>
    Group(id: id, name: name, sortOrder: sortOrder);

Session _session(String id, String groupId) => Session(
  id: id,
  groupId: groupId,
  name: id,
  shell: 'bash',
  cols: 80,
  rows: 24,
  cwd: '/tmp',
  isAlive: true,
  createdAt: '',
  lastActive: '',
);

void main() {
  testWidgets('selected project falls back to the first surviving project', (
    tester,
  ) async {
    final alpha = _group('alpha', 'Alpha', 0);
    final beta = _group('beta', 'Beta', 1);
    final notifier = _MutableServerNotifier(
      ServerState(
        isConnected: true,
        groups: [alpha, beta],
        sessions: [_session('beta-shell', beta.id)],
      ),
    );
    final container = ProviderContainer(
      overrides: [serverProvider.overrideWith((ref) => notifier)],
    );
    addTearDown(container.dispose);

    container.read(sessionProvider.notifier)
      ..setActiveSession(projectId: alpha.id, sessionId: 'alpha-shell')
      ..setActiveSession(projectId: beta.id, sessionId: 'beta-shell')
      ..selectProject(beta.id);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: HomeScreen(backend: _FakeTerminalBackend()),
        ),
      ),
    );
    await tester.pump();

    notifier.replaceState(
      ServerState(isConnected: true, groups: [alpha], sessions: const []),
    );
    await tester.pump();
    await tester.pump();

    final sessionState = container.read(sessionProvider);
    expect(sessionState.selectedProjectId, alpha.id);
    expect(sessionState.activeSessionIdFor(beta.id), isNull);
  });
}
