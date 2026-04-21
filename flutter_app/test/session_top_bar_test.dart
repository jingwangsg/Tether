import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tether/models/group.dart';
import 'package:tether/models/session.dart';
import 'package:tether/platform/terminal_backend.dart';
import 'package:tether/providers/server_provider.dart';
import 'package:tether/providers/session_provider.dart';
import 'package:tether/providers/ui_provider.dart';
import 'package:tether/widgets/terminal/session_top_bar.dart';
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
  testWidgets('terminal area shows only sessions from the selected project', (
    tester,
  ) async {
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
      ..setActiveSession(projectId: alpha.id, sessionId: 'a-2');

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: TerminalArea(backend: _FakeTerminalBackend())),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('session-top-bar')), findsOneWidget);
    expect(find.text('alpha-one'), findsOneWidget);
    expect(find.text('alpha-two'), findsOneWidget);
    expect(find.text('beta-one'), findsNothing);
  });

  testWidgets(
    'session top bar shows ctrl digit hints for only the first nine sessions',
    (tester) async {
      tester.view.physicalSize = const Size(3000, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final sessions = List.generate(
        10,
        (index) => Session(
          id: 'session-$index',
          groupId: 'alpha',
          name: 'session-$index',
          shell: 'bash',
          cols: 80,
          rows: 24,
          cwd: '/tmp/session-$index',
          isAlive: true,
          createdAt: '',
          lastActive: '',
          sortOrder: index,
        ),
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container
          .read(uiProvider.notifier)
          .setDesktopShortcutHints(
            showProjectHints: false,
            showSessionHints: true,
          );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 2000,
                child: SessionTopBar(
                  projectId: 'alpha',
                  sessions: sessions,
                  activeSessionId: 'session-0',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      for (var index = 0; index < 9; index++) {
        expect(
          find.byKey(ValueKey('session-shortcut-hint-session-$index')),
          findsOneWidget,
        );
      }
      expect(
        find.byKey(const ValueKey('session-shortcut-hint-session-9')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'session top bar shows close button for every tab and no overflow menu',
    (tester) async {
      final group = _group('alpha', 'Alpha');
      final sessions = [
        _session('session-0', group.id, 'session-0'),
        _session('session-1', group.id, 'session-1'),
      ];
      final container = ProviderContainer(
        overrides: [
          serverProvider.overrideWith(
            (ref) => _SessionTopBarTestServerNotifier(
              ServerState(
                isConnected: true,
                groups: [group],
                sessions: sessions,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      container.read(sessionProvider.notifier)
        ..selectProject(group.id)
        ..setActiveSession(projectId: group.id, sessionId: sessions.first.id);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: SessionTopBar(
                projectId: group.id,
                sessions: sessions,
                activeSessionId: sessions.first.id,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(PopupMenuButton<String>), findsNothing);
      expect(find.byIcon(Icons.more_vert), findsNothing);
      expect(
        find.byKey(const ValueKey('session-close-button-session-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('session-close-button-session-1')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'closing the active session tab switches to the first remaining session',
    (tester) async {
      final group = _group('alpha', 'Alpha');
      final sessions = [
        _session('session-0', group.id, 'session-0'),
        _session('session-1', group.id, 'session-1'),
        _session('session-2', group.id, 'session-2'),
      ];
      final container = ProviderContainer(
        overrides: [
          serverProvider.overrideWith(
            (ref) => _SessionTopBarTestServerNotifier(
              ServerState(
                isConnected: true,
                groups: [group],
                sessions: sessions,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      container.read(sessionProvider.notifier)
        ..selectProject(group.id)
        ..setActiveSession(projectId: group.id, sessionId: 'session-1');

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: SessionTopBar(
                projectId: group.id,
                sessions: sessions,
                activeSessionId: 'session-1',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('session-close-button-session-1')),
      );
      await tester.pumpAndSettle();

      final notifier =
          container.read(serverProvider.notifier)
              as _SessionTopBarTestServerNotifier;
      expect(notifier.deletedSessionIds, ['session-1']);
      expect(container.read(sessionProvider).activeSessionId, 'session-0');
      expect(
        container.read(serverProvider).sessions.map((session) => session.id),
        ['session-0', 'session-2'],
      );
    },
  );

  testWidgets(
    'closing an inactive session tab keeps the active session selected',
    (tester) async {
      final group = _group('alpha', 'Alpha');
      final sessions = [
        _session('session-0', group.id, 'session-0'),
        _session('session-1', group.id, 'session-1'),
        _session('session-2', group.id, 'session-2'),
      ];
      final container = ProviderContainer(
        overrides: [
          serverProvider.overrideWith(
            (ref) => _SessionTopBarTestServerNotifier(
              ServerState(
                isConnected: true,
                groups: [group],
                sessions: sessions,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      container.read(sessionProvider.notifier)
        ..selectProject(group.id)
        ..setActiveSession(projectId: group.id, sessionId: 'session-0');

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: SessionTopBar(
                projectId: group.id,
                sessions: sessions,
                activeSessionId: 'session-0',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('session-close-button-session-2')),
      );
      await tester.pumpAndSettle();

      final notifier =
          container.read(serverProvider.notifier)
              as _SessionTopBarTestServerNotifier;
      expect(notifier.deletedSessionIds, ['session-2']);
      expect(container.read(sessionProvider).activeSessionId, 'session-0');
      expect(
        container.read(serverProvider).sessions.map((session) => session.id),
        ['session-0', 'session-1'],
      );
    },
  );

  testWidgets(
    'session top bar keeps the session name and shows the agent osc title',
    (tester) async {
      final sessions = [
        Session(
          id: 'session-0',
          groupId: 'alpha',
          name: 'feature/refactor-shell',
          shell: 'bash',
          cols: 80,
          rows: 24,
          cwd: '/tmp/session-0',
          isAlive: true,
          createdAt: '',
          lastActive: '',
          foregroundProcess: 'claude',
          oscTitle: '· Claude Code',
        ),
      ];

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: SessionTopBar(
                projectId: 'alpha',
                sessions: sessions,
                activeSessionId: 'session-0',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('feature/refactor-shell'), findsOneWidget);
      expect(find.text('· Claude Code'), findsOneWidget);
    },
  );

  testWidgets('session top bar supports direct horizontal drag reordering', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final group = _group('alpha', 'Alpha');
    final sessions = [
      _session('session-0', group.id, 'session-0').copyWith(sortOrder: 0),
      _session('session-1', group.id, 'session-1').copyWith(sortOrder: 1),
    ];
    final notifier = _SessionTopBarTestServerNotifier(
      ServerState(isConnected: true, groups: [group], sessions: sessions),
    );
    final container = ProviderContainer(
      overrides: [serverProvider.overrideWith((ref) => notifier)],
    );
    addTearDown(container.dispose);

    container.read(sessionProvider.notifier)
      ..selectProject(group.id)
      ..setActiveSession(projectId: group.id, sessionId: 'session-0');

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.macOS),
          home: Scaffold(
            body: SizedBox(
              width: 1200,
              child: SessionTopBar(
                projectId: group.id,
                sessions: container.read(serverProvider).sessions,
                activeSessionId: 'session-0',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final firstCenter = tester.getCenter(
      find.byKey(const ValueKey('session-top-tab-session-0')),
    );
    final gesture = await tester.startGesture(
      firstCenter,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.moveBy(const Offset(400, 0));
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(notifier.reorderSessionPayloads, isNotEmpty);
    expect(
      (List<Session>.from(container.read(serverProvider).sessions)..sort(
        (a, b) => a.sortOrder.compareTo(b.sortOrder),
      )).map((session) => session.id),
      ['session-1', 'session-0'],
    );
  });
}

class _SessionTopBarTestServerNotifier extends ServerNotifier {
  _SessionTopBarTestServerNotifier(super.state) : super.test();

  final List<String> deletedSessionIds = [];
  final List<List<Map<String, dynamic>>> reorderSessionPayloads = [];

  @override
  Future<void> deleteSession(String id) async {
    deletedSessionIds.add(id);
    state = state.copyWith(
      sessions: state.sessions.where((session) => session.id != id).toList(),
    );
  }

  @override
  Future<void> reorderSessions(List<Map<String, dynamic>> items) async {
    reorderSessionPayloads.add(items);
    final updates = {
      for (final item in items)
        item['id'] as String: (
          sortOrder: item['sort_order'] as int,
          groupId: item['group_id'] as String?,
        ),
    };
    state = state.copyWith(
      sessions:
          state.sessions.map((session) {
            final update = updates[session.id];
            if (update == null) {
              return session;
            }
            return session.copyWith(
              sortOrder: update.sortOrder,
              groupId: update.groupId ?? session.groupId,
            );
          }).toList(),
    );
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
    Future<void> Function(Uint8List data, String mimeType)? onClipboardImage,
  }) {
    return ColoredBox(
      key: ValueKey('terminal-$sessionId'),
      color: isActive ? Colors.green : Colors.grey,
    );
  }
}
