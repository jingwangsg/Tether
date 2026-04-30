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

Group _group(String id) => Group(id: id, name: id);

Session _session(String id, String groupId) => Session(
  id: id,
  groupId: groupId,
  name: id,
  shell: 'zsh',
  cols: 80,
  rows: 24,
  cwd: '/tmp/$id',
  isAlive: true,
  createdAt: '',
  lastActive: '',
);

/// Finds a terminal widget by session id, including offstage widgets.
/// We use skipOffstage: false because we're testing widget-tree presence,
/// not visibility (Offstage hides inactive terminals but they may still
/// be mounted as the "warm" previous session).
Finder _terminalFinder(String sessionId) =>
    find.byKey(ValueKey('terminal-$sessionId'), skipOffstage: false);

void main() {
  testWidgets('terminal area keeps terminals mounted across project switches', (
    tester,
  ) async {
    final alpha = _group('alpha');
    final beta = _group('beta');
    final sessions = [_session('a-1', alpha.id), _session('b-1', beta.id)];

    final container = ProviderContainer(
      overrides: [
        serverProvider.overrideWith(
          (ref) => ServerNotifier.test(
            ServerState(
              isConnected: true,
              groups: [alpha, beta],
              sessions: sessions,
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    container.read(sessionProvider.notifier)
      ..selectProject(alpha.id)
      ..setActiveSession(projectId: alpha.id, sessionId: 'a-1');

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: TerminalArea(backend: _RetentionBackend())),
        ),
      ),
    );
    await tester.pump();

    expect(_terminalFinder('a-1'), findsOneWidget);
    expect(_terminalFinder('b-1'), findsNothing);

    container.read(sessionProvider.notifier)
      ..selectProject(beta.id)
      ..setActiveSession(projectId: beta.id, sessionId: 'b-1');
    await tester.pump();

    // Previous project's terminal stays mounted and hidden instead of being destroyed.
    expect(_terminalFinder('a-1'), findsOneWidget);
    expect(_terminalFinder('b-1'), findsOneWidget);
  });

  testWidgets('terminal area evicts least-recently-used terminals after cap', (
    tester,
  ) async {
    final alpha = _group('alpha');
    final sessions = [
      _session('a-1', alpha.id),
      _session('a-2', alpha.id),
      _session('a-3', alpha.id),
      _session('a-4', alpha.id),
      _session('a-5', alpha.id),
      _session('a-6', alpha.id),
      _session('a-7', alpha.id),
    ];

    final container = ProviderContainer(
      overrides: [
        serverProvider.overrideWith(
          (ref) => ServerNotifier.test(
            ServerState(isConnected: true, groups: [alpha], sessions: sessions),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    container.read(sessionProvider.notifier)
      ..selectProject(alpha.id)
      ..setActiveSession(projectId: alpha.id, sessionId: 'a-1');

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: TerminalArea(backend: _RetentionBackend())),
        ),
      ),
    );
    await tester.pump();

    for (final session in sessions.skip(1)) {
      container
          .read(sessionProvider.notifier)
          .setActiveSession(projectId: alpha.id, sessionId: session.id);
      await tester.pump();
    }

    // Retention cap is 6. a-1 is the oldest and should be evicted.
    expect(_terminalFinder('a-1'), findsNothing);
    expect(_terminalFinder('a-2'), findsOneWidget);
    expect(_terminalFinder('a-3'), findsOneWidget);
    expect(_terminalFinder('a-4'), findsOneWidget);
    expect(_terminalFinder('a-5'), findsOneWidget);
    expect(_terminalFinder('a-6'), findsOneWidget);
    expect(_terminalFinder('a-7'), findsOneWidget);
  });

  testWidgets('terminal area honors backend retention cap', (tester) async {
    final alpha = _group('alpha');
    final sessions = [
      _session('a-1', alpha.id),
      _session('a-2', alpha.id),
      _session('a-3', alpha.id),
      _session('a-4', alpha.id),
    ];

    final container = ProviderContainer(
      overrides: [
        serverProvider.overrideWith(
          (ref) => ServerNotifier.test(
            ServerState(isConnected: true, groups: [alpha], sessions: sessions),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    container.read(sessionProvider.notifier)
      ..selectProject(alpha.id)
      ..setActiveSession(projectId: alpha.id, sessionId: 'a-1');

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: TerminalArea(
              backend: _RetentionBackend(retainedTerminalViewCap: 2),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    container
        .read(sessionProvider.notifier)
        .setActiveSession(projectId: alpha.id, sessionId: 'a-2');
    await tester.pump();
    container
        .read(sessionProvider.notifier)
        .setActiveSession(projectId: alpha.id, sessionId: 'a-3');
    await tester.pump();
    container
        .read(sessionProvider.notifier)
        .setActiveSession(projectId: alpha.id, sessionId: 'a-4');
    await tester.pump();

    expect(_terminalFinder('a-1'), findsNothing);
    expect(_terminalFinder('a-2'), findsNothing);
    expect(_terminalFinder('a-3'), findsOneWidget);
    expect(_terminalFinder('a-4'), findsOneWidget);
  });
}

class _RetentionBackend implements TerminalBackend {
  const _RetentionBackend({this.retainedTerminalViewCap = 6});

  final int retainedTerminalViewCap;

  @override
  String get platformId => 'retention';

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
    return Container(
      key: ValueKey('terminal-$sessionId'),
      color: isActive ? Colors.green : Colors.grey,
    );
  }
}
