import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tether/models/group.dart';
import 'package:tether/models/session.dart';
import 'package:tether/platform/terminal_backend.dart';
import 'package:tether/providers/server_provider.dart';
import 'package:tether/providers/session_provider.dart';
import 'package:tether/widgets/terminal/terminal_area.dart';
import 'package:tether/widgets/terminal/terminal_controller.dart';

Group _group(String id, String name) => Group(id: id, name: name);

Session _session(String id, String groupId, String name) => Session(
  id: id,
  groupId: groupId,
  name: name,
  shell: 'bash',
  cols: 80,
  rows: 24,
  cwd: '/tmp/$id',
  isAlive: true,
  createdAt: '',
  lastActive: '',
);

void main() {
  testWidgets('terminal area shows only sessions from the selected project', (tester) async {
    final alpha = _group('alpha', 'Alpha');
    final beta = _group('beta', 'Beta');
    final sessions = [
      _session('a-1', alpha.id, 'alpha-one'),
      _session('a-2', alpha.id, 'alpha-two'),
      _session('b-1', beta.id, 'beta-one'),
    ];

    final container = ProviderContainer(
      overrides: [
        serverProvider.overrideWith(
          (ref) => ServerNotifier.test(
            ServerState(isConnected: true, groups: [alpha, beta], sessions: sessions),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    container.read(sessionProvider.notifier)
      ..selectProject(alpha.id)
      ..setActiveSession(projectId: alpha.id, sessionId: 'a-2');

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: TerminalArea(backend: _FakeTerminalBackend()))),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('session-top-bar')), findsOneWidget);
    expect(find.text('alpha-one'), findsOneWidget);
    expect(find.text('alpha-two'), findsOneWidget);
    expect(find.text('beta-one'), findsNothing);
  });
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
    bool imagePasteBridgeEnabled = false,
    VoidCallback? onSessionExited,
    void Function(String? title)? onTitleChanged,
    ForegroundChangedCallback? onForegroundChanged,
    Future<void> Function(Uint8List data, String mimeType)? onClipboardImage,
  }) {
    return ColoredBox(
      key: ValueKey('terminal-$sessionId'),
      color: isActive ? Colors.green : Colors.grey,
    );
  }
}
