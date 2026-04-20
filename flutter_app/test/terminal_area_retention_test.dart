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
  testWidgets('terminal area keeps only active and previous session mounted', (
    tester,
  ) async {
    final alpha = _group('alpha');
    final sessions = [
      _session('a-1', alpha.id),
      _session('a-2', alpha.id),
      _session('a-3', alpha.id),
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

    // Only active session a-1 mounted; no warm session yet.
    expect(_terminalFinder('a-1'), findsOneWidget);
    expect(_terminalFinder('a-2'), findsNothing);
    expect(_terminalFinder('a-3'), findsNothing);

    // Switch to a-2: a-1 becomes warm, a-2 becomes active.
    container
        .read(sessionProvider.notifier)
        .setActiveSession(projectId: alpha.id, sessionId: 'a-2');
    await tester.pump();

    expect(_terminalFinder('a-1'), findsOneWidget);
    expect(_terminalFinder('a-2'), findsOneWidget);
    expect(_terminalFinder('a-3'), findsNothing);

    // Switch to a-3: a-2 becomes warm, a-1 is evicted.
    container
        .read(sessionProvider.notifier)
        .setActiveSession(projectId: alpha.id, sessionId: 'a-3');
    await tester.pump();

    expect(_terminalFinder('a-1'), findsNothing);
    expect(_terminalFinder('a-2'), findsOneWidget);
    expect(_terminalFinder('a-3'), findsOneWidget);
  });
}

class _RetentionBackend implements TerminalBackend {
  const _RetentionBackend();

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
    bool imagePasteBridgeEnabled = false,
    VoidCallback? onSessionExited,
    ForegroundChangedCallback? onForegroundChanged,
    Future<void> Function(Uint8List data, String mimeType)? onClipboardImage,
  }) {
    return Container(
      key: ValueKey('terminal-$sessionId'),
      color: isActive ? Colors.green : Colors.grey,
    );
  }
}
