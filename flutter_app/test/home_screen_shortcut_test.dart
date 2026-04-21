import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tether/models/group.dart';
import 'package:tether/models/session.dart';
import 'package:tether/platform/terminal_backend.dart';
import 'package:tether/providers/server_provider.dart';
import 'package:tether/providers/session_provider.dart';
import 'package:tether/providers/ui_provider.dart';
import 'package:tether/screens/home_screen.dart';
import 'package:tether/widgets/terminal/terminal_controller.dart';

class _CreateSessionCall {
  const _CreateSessionCall({
    required this.groupId,
    this.name,
    this.command,
    this.cwd,
  });

  final String groupId;
  final String? name;
  final String? command;
  final String? cwd;
}

Group _group(String id) {
  return Group(id: id, name: id);
}

Session _session(String id, {required String groupId, required String name}) {
  return Session(
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
}

ProviderContainer _container(ServerState serverState) {
  return ProviderContainer(
    overrides: [
      serverProvider.overrideWith((ref) => _TestServerNotifier(serverState)),
    ],
  );
}

Future<void> _pumpHomeScreen(
  WidgetTester tester,
  ProviderContainer container,
  TerminalBackend backend,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: HomeScreen(backend: backend)),
    ),
  );
  await tester.pump();
}

Future<void> _dispatchWindowCommand(
  String method, [
  Map<String, dynamic>? arguments,
]) async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  await messenger.handlePlatformMessage(
    'dev.tether/window',
    const StandardMethodCodec().encodeMethodCall(MethodCall(method, arguments)),
    (_) {},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('native rename command opens rename dialog for active session', (
    tester,
  ) async {
    final group = _group('local');
    final session = _session('session-1', groupId: group.id, name: 'alpha');
    final container = _container(
      ServerState(isConnected: true, groups: [group], sessions: [session]),
    );
    addTearDown(container.dispose);

    container.read(sessionProvider.notifier)
      ..selectProject(group.id)
      ..setActiveSession(projectId: group.id, sessionId: session.id);

    await _pumpHomeScreen(
      tester,
      container,
      const _FakeTerminalBackend(platformId: 'native'),
    );

    await _dispatchWindowCommand('renameActiveSession');
    await tester.pumpAndSettle();

    expect(find.text('Rename Session'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'alpha'), findsOneWidget);
  });

  testWidgets('native rename command is ignored without an active session', (
    tester,
  ) async {
    final group = _group('local');
    final container = _container(
      ServerState(isConnected: true, groups: [group], sessions: const []),
    );
    addTearDown(container.dispose);

    await _pumpHomeScreen(
      tester,
      container,
      const _FakeTerminalBackend(platformId: 'native'),
    );

    await _dispatchWindowCommand('renameActiveSession');
    await tester.pumpAndSettle();

    expect(find.text('Rename Session'), findsNothing);
  });

  testWidgets(
    'native backend ignores flutter-delivered desktop shortcuts reserved for the window channel',
    (tester) async {
      final group = _group('native-project');
      final sessionA = _session('native-a', groupId: group.id, name: 'alpha');
      final sessionB = _session('native-b', groupId: group.id, name: 'beta');
      var showSearchCount = 0;
      final performedActions = <String>[];
      final container = _container(
        ServerState(
          isConnected: true,
          groups: [group],
          sessions: [sessionA, sessionB],
        ),
      );
      addTearDown(container.dispose);

      container.read(sessionProvider.notifier)
        ..selectProject(group.id)
        ..setActiveSession(projectId: group.id, sessionId: sessionB.id);

      await _pumpHomeScreen(
        tester,
        container,
        _FakeTerminalBackend(
          platformId: 'native',
          onShowSearch: () => showSearchCount++,
          onPerformAction: performedActions.add,
        ),
      );

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.digit1);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.digit1);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyB);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyB);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.equal);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.equal);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyW);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyW);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();

      final notifier =
          container.read(serverProvider.notifier) as _TestServerNotifier;
      expect(find.text('New Group'), findsNothing);
      expect(notifier.createSessionCalls, isEmpty);
      expect(notifier.deletedSessionIds, isEmpty);
      expect(container.read(sessionProvider).activeSessionId, sessionB.id);
      expect(showSearchCount, 0);
      expect(performedActions, isEmpty);
      expect(container.read(uiProvider).sidebarOpen, isTrue);
    },
  );

  testWidgets('cmd+f still triggers terminal search shortcut', (tester) async {
    final group = _group('local');
    final session = _session('session-3', groupId: group.id, name: 'gamma');
    final searchCalls = ValueNotifier<int>(0);
    addTearDown(searchCalls.dispose);
    final container = _container(
      ServerState(isConnected: true, groups: [group], sessions: [session]),
    );
    addTearDown(container.dispose);

    container.read(sessionProvider.notifier)
      ..selectProject(group.id)
      ..setActiveSession(projectId: group.id, sessionId: session.id);

    await _pumpHomeScreen(
      tester,
      container,
      _FakeTerminalBackend(
        platformId: 'xterm',
        onShowSearch: () => searchCalls.value++,
      ),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();

    expect(searchCalls.value, 1);
  });

  testWidgets('cmd+w closes the active session on xterm backend', (
    tester,
  ) async {
    final group = _group('close-project');
    final sessionA = _session('close-a', groupId: group.id, name: 'alpha');
    final sessionB = _session('close-b', groupId: group.id, name: 'beta');
    final container = _container(
      ServerState(
        isConnected: true,
        groups: [group],
        sessions: [sessionA, sessionB],
      ),
    );
    addTearDown(container.dispose);

    container.read(sessionProvider.notifier)
      ..selectProject(group.id)
      ..setActiveSession(projectId: group.id, sessionId: sessionB.id);

    await _pumpHomeScreen(
      tester,
      container,
      const _FakeTerminalBackend(platformId: 'xterm'),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyW);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyW);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    final notifier =
        container.read(serverProvider.notifier) as _TestServerNotifier;
    expect(notifier.deletedSessionIds, ['close-b']);
    expect(container.read(sessionProvider).activeSessionId, sessionA.id);
    expect(
      container.read(serverProvider).sessions.map((session) => session.id),
      [sessionA.id],
    );
  });

  testWidgets('mobile home screen suppresses route pop gestures', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final container = _container(const ServerState());
    addTearDown(container.dispose);

    await _pumpHomeScreen(
      tester,
      container,
      const _FakeTerminalBackend(platformId: 'xterm'),
    );
    await tester.pump();

    final popScope = tester.widget<PopScope<void>>(find.byType(PopScope<void>));
    expect(popScope.canPop, isFalse);
  });

  testWidgets('mobile back closes sidebar instead of popping the app', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final container = _container(const ServerState());
    addTearDown(container.dispose);

    await _pumpHomeScreen(
      tester,
      container,
      const _FakeTerminalBackend(platformId: 'xterm'),
    );
    await tester.pump();

    container.read(uiProvider.notifier).setSidebarOpen(true);
    await tester.pumpAndSettle();
    expect(container.read(uiProvider).sidebarOpen, isTrue);

    WidgetsBinding.instance.handlePopRoute();
    await tester.pumpAndSettle();

    expect(container.read(uiProvider).sidebarOpen, isFalse);
  });

  testWidgets('mobile drag from left half but not edge does not open sidebar', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final container = _container(const ServerState());
    addTearDown(container.dispose);

    await _pumpHomeScreen(
      tester,
      container,
      const _FakeTerminalBackend(platformId: 'xterm'),
    );
    await tester.pump();

    expect(container.read(uiProvider).sidebarOpen, isFalse);

    await tester.dragFrom(const Offset(96, 300), const Offset(140, 0));
    await tester.pumpAndSettle();

    expect(container.read(uiProvider).sidebarOpen, isFalse);
  });

  testWidgets('mobile drag from left edge still opens sidebar', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final container = _container(const ServerState());
    addTearDown(container.dispose);

    await _pumpHomeScreen(
      tester,
      container,
      const _FakeTerminalBackend(platformId: 'xterm'),
    );
    await tester.pump();

    expect(container.read(uiProvider).sidebarOpen, isFalse);

    await tester.dragFrom(const Offset(8, 300), const Offset(140, 0));
    await tester.pumpAndSettle();

    expect(container.read(uiProvider).sidebarOpen, isTrue);
  });

  testWidgets(
    'mobile left-edge drag does not open sidebar during selection gesture',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = _container(const ServerState());
      addTearDown(container.dispose);

      await _pumpHomeScreen(
        tester,
        container,
        const _FakeTerminalBackend(platformId: 'xterm'),
      );
      await tester.pump();

      container.read(uiProvider.notifier).setSelectionGestureActive(true);
      await tester.pump();

      await tester.dragFrom(const Offset(8, 300), const Offset(140, 0));
      await tester.pumpAndSettle();

      expect(container.read(uiProvider).sidebarOpen, isFalse);
    },
  );

  testWidgets('cmd+r opens Rename Session dialog on xterm backend', (
    tester,
  ) async {
    final group = _group('proj-1');
    final session = _session('s1', groupId: group.id, name: 'shell');
    final container = _container(
      ServerState(isConnected: true, groups: [group], sessions: [session]),
    );
    addTearDown(container.dispose);

    container.read(sessionProvider.notifier)
      ..selectProject(group.id)
      ..setActiveSession(projectId: group.id, sessionId: session.id);

    await _pumpHomeScreen(
      tester,
      container,
      const _FakeTerminalBackend(platformId: 'xterm'),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    expect(find.text('Rename Session'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'shell'), findsOneWidget);
  });

  testWidgets('cmd+shift+r opens Rename Project dialog', (tester) async {
    final group = _group('proj-2');
    final session = _session('s2', groupId: group.id, name: 'my-session');
    final container = _container(
      ServerState(isConnected: true, groups: [group], sessions: [session]),
    );
    addTearDown(container.dispose);

    container.read(sessionProvider.notifier)
      ..selectProject(group.id)
      ..setActiveSession(projectId: group.id, sessionId: session.id);

    await _pumpHomeScreen(
      tester,
      container,
      const _FakeTerminalBackend(platformId: 'xterm'),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    expect(find.text('Rename Project'), findsOneWidget);
    expect(find.widgetWithText(TextField, group.name), findsOneWidget);
  });

  testWidgets('cmd+t creates a session directly in the selected project', (
    tester,
  ) async {
    final group = _group('proj-direct');
    final existing = _session('existing', groupId: group.id, name: 'shell');
    final container = _container(
      ServerState(isConnected: true, groups: [group], sessions: [existing]),
    );
    addTearDown(container.dispose);

    container.read(sessionProvider.notifier)
      ..selectProject(group.id)
      ..setActiveSession(projectId: group.id, sessionId: existing.id);

    await _pumpHomeScreen(
      tester,
      container,
      const _FakeTerminalBackend(platformId: 'xterm'),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyT);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyT);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    final notifier =
        container.read(serverProvider.notifier) as _TestServerNotifier;
    expect(notifier.createSessionCalls, hasLength(1));
    expect(notifier.createSessionCalls.single.groupId, group.id);
    expect(notifier.createSessionCalls.single.command, isNull);
    expect(notifier.createSessionCalls.single.cwd, isNull);
    expect(find.text('New Session in ${group.name}'), findsNothing);
    expect(container.read(sessionProvider).activeSessionId, 'created-1');
    expect(
      container.read(serverProvider).sessions.map((session) => session.id),
      contains('created-1'),
    );
  });

  testWidgets('cmd+t falls back to the first top-level project', (
    tester,
  ) async {
    final child = Group(
      id: 'child',
      name: 'Child',
      parentId: 'alpha',
      sortOrder: 0,
    );
    final beta = Group(id: 'beta', name: 'Beta', sortOrder: 1);
    final alpha = Group(id: 'alpha', name: 'Alpha', sortOrder: 0);
    final container = _container(
      ServerState(
        isConnected: true,
        groups: [child, beta, alpha],
        sessions: const [],
      ),
    );
    addTearDown(container.dispose);

    await _pumpHomeScreen(
      tester,
      container,
      const _FakeTerminalBackend(platformId: 'xterm'),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyT);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyT);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    final notifier =
        container.read(serverProvider.notifier) as _TestServerNotifier;
    expect(notifier.createSessionCalls, hasLength(1));
    expect(notifier.createSessionCalls.single.groupId, alpha.id);
    expect(container.read(sessionProvider).selectedProjectId, alpha.id);
    expect(container.read(sessionProvider).activeSessionId, 'created-1');
  });

  testWidgets('cmd+t without any project still opens New Group dialog', (
    tester,
  ) async {
    final container = _container(const ServerState(isConnected: true));
    addTearDown(container.dispose);

    await _pumpHomeScreen(
      tester,
      container,
      const _FakeTerminalBackend(platformId: 'xterm'),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyT);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyT);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    expect(find.text('New Group'), findsOneWidget);
    final notifier =
        container.read(serverProvider.notifier) as _TestServerNotifier;
    expect(notifier.createSessionCalls, isEmpty);
  });

  testWidgets('cmd+1 selects the first project', (tester) async {
    final groupA = Group(id: 'a', name: 'Alpha', sortOrder: 0);
    final groupB = Group(id: 'b', name: 'Beta', sortOrder: 1);
    final sA = _session('sA', groupId: groupA.id, name: 'sA');
    final sB = _session('sB', groupId: groupB.id, name: 'sB');
    final container = _container(
      ServerState(
        isConnected: true,
        groups: [groupA, groupB],
        sessions: [sA, sB],
      ),
    );
    addTearDown(container.dispose);

    container.read(sessionProvider.notifier).selectProject(groupB.id);
    expect(container.read(sessionProvider).selectedProjectId, 'b');

    await _pumpHomeScreen(
      tester,
      container,
      const _FakeTerminalBackend(platformId: 'xterm'),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.digit1);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.digit1);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();

    expect(container.read(sessionProvider).selectedProjectId, 'a');
  });

  testWidgets(
    'ctrl+1 selects the first session in current project without changing tab labels',
    (tester) async {
      final group = _group('proj-3');
      final s1 = Session(
        id: 's1',
        groupId: group.id,
        name: 'first',
        shell: 'bash',
        cols: 80,
        rows: 24,
        cwd: '/tmp',
        isAlive: true,
        createdAt: '',
        lastActive: '',
        sortOrder: 0,
        foregroundProcess: 'claude',
        oscTitle: '· Claude Code',
      );
      final s2 = Session(
        id: 's2',
        groupId: group.id,
        name: 'second',
        shell: 'bash',
        cols: 80,
        rows: 24,
        cwd: '/tmp',
        isAlive: true,
        createdAt: '',
        lastActive: '',
        sortOrder: 1,
      );
      final container = _container(
        ServerState(isConnected: true, groups: [group], sessions: [s1, s2]),
      );
      addTearDown(container.dispose);

      container.read(sessionProvider.notifier)
        ..selectProject(group.id)
        ..setActiveSession(projectId: group.id, sessionId: s2.id);
      expect(container.read(sessionProvider).activeSessionId, 's2');

      await _pumpHomeScreen(
        tester,
        container,
        const _FakeTerminalBackend(platformId: 'xterm'),
      );

      expect(find.text('first'), findsOneWidget);
      expect(find.text('second'), findsOneWidget);
      expect(find.text('Claude Code'), findsNothing);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.digit1);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.digit1);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(container.read(sessionProvider).activeSessionId, 's1');
      expect(find.text('first'), findsOneWidget);
      expect(find.text('second'), findsOneWidget);
      expect(find.text('Claude Code'), findsNothing);
    },
  );

  testWidgets('cmd+n opens New Group dialog', (tester) async {
    final container = _container(const ServerState(isConnected: true));
    addTearDown(container.dispose);

    await _pumpHomeScreen(
      tester,
      container,
      const _FakeTerminalBackend(platformId: 'xterm'),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    // The GroupDialog title for create mode is 'New Group'.
    expect(find.text('New Group'), findsOneWidget);
  });

  testWidgets('sidebar New Session creates directly in the selected project', (
    tester,
  ) async {
    final alpha = Group(id: 'alpha', name: 'Alpha', sortOrder: 0);
    final beta = Group(id: 'beta', name: 'Beta', sortOrder: 1);
    final existing = _session('existing', groupId: beta.id, name: 'shell');
    final container = _container(
      ServerState(
        isConnected: true,
        groups: [alpha, beta],
        sessions: [existing],
      ),
    );
    addTearDown(container.dispose);

    container.read(sessionProvider.notifier)
      ..selectProject(beta.id)
      ..setActiveSession(projectId: beta.id, sessionId: existing.id);

    await _pumpHomeScreen(
      tester,
      container,
      const _FakeTerminalBackend(platformId: 'xterm'),
    );

    await tester.tap(find.byTooltip('New Session'));
    await tester.pumpAndSettle();

    final notifier =
        container.read(serverProvider.notifier) as _TestServerNotifier;
    expect(notifier.createSessionCalls, hasLength(1));
    expect(notifier.createSessionCalls.single.groupId, beta.id);
    expect(notifier.createSessionCalls.single.command, isNull);
    expect(notifier.createSessionCalls.single.cwd, isNull);
    expect(find.text('New Session in ${beta.name}'), findsNothing);
    expect(container.read(sessionProvider).selectedProjectId, beta.id);
    expect(container.read(sessionProvider).activeSessionId, 'created-1');
  });

  testWidgets(
    'native performShellAction payload creates and selects a new session',
    (tester) async {
      final group = _group('native-group');
      final session = _session('seed', groupId: group.id, name: 'seed');
      final container = _container(
        ServerState(isConnected: true, groups: [group], sessions: [session]),
      );
      addTearDown(container.dispose);

      container.read(sessionProvider.notifier)
        ..selectProject(group.id)
        ..setActiveSession(projectId: group.id, sessionId: session.id);

      await _pumpHomeScreen(
        tester,
        container,
        const _FakeTerminalBackend(platformId: 'native'),
      );

      await _dispatchWindowCommand('performShellAction', {
        'action': 'newSession',
      });
      await tester.pumpAndSettle();

      final notifier =
          container.read(serverProvider.notifier) as _TestServerNotifier;
      expect(notifier.createSessionCalls, hasLength(1));
      expect(notifier.createSessionCalls.single.groupId, group.id);
      expect(container.read(sessionProvider).activeSessionId, 'created-1');
    },
  );

  testWidgets(
    'native performShellAction payload selects projects and sessions by index',
    (tester) async {
      final alpha = Group(id: 'alpha', name: 'Alpha', sortOrder: 0);
      final beta = Group(id: 'beta', name: 'Beta', sortOrder: 1);
      final alphaSession = _session(
        'alpha-1',
        groupId: alpha.id,
        name: 'alpha-1',
      );
      final betaSessionA = _session('beta-1', groupId: beta.id, name: 'beta-1');
      final betaSessionB = Session(
        id: 'beta-2',
        groupId: beta.id,
        name: 'beta-2',
        shell: 'bash',
        cols: 80,
        rows: 24,
        cwd: '/tmp/beta-2',
        isAlive: true,
        createdAt: '',
        lastActive: '',
        sortOrder: 1,
      );
      final container = _container(
        ServerState(
          isConnected: true,
          groups: [alpha, beta],
          sessions: [alphaSession, betaSessionA, betaSessionB],
        ),
      );
      addTearDown(container.dispose);

      container.read(sessionProvider.notifier)
        ..selectProject(beta.id)
        ..setActiveSession(projectId: beta.id, sessionId: betaSessionB.id);

      await _pumpHomeScreen(
        tester,
        container,
        const _FakeTerminalBackend(platformId: 'native'),
      );

      await _dispatchWindowCommand('performShellAction', {
        'action': 'selectProjectByNumber',
        'index': 0,
      });
      await tester.pump();
      expect(container.read(sessionProvider).selectedProjectId, alpha.id);

      container.read(sessionProvider.notifier)
        ..selectProject(beta.id)
        ..setActiveSession(projectId: beta.id, sessionId: betaSessionB.id);

      await _dispatchWindowCommand('performShellAction', {
        'action': 'selectSessionByNumber',
        'index': 0,
      });
      await tester.pump();
      expect(container.read(sessionProvider).activeSessionId, betaSessionA.id);
    },
  );

  testWidgets('native shell hint messages toggle desktop hint visibility', (
    tester,
  ) async {
    final group = _group('hint-project');
    final session = _session(
      'hint-session',
      groupId: group.id,
      name: 'hint-session',
    );
    final container = _container(
      ServerState(isConnected: true, groups: [group], sessions: [session]),
    );
    addTearDown(container.dispose);

    container.read(sessionProvider.notifier)
      ..selectProject(group.id)
      ..setActiveSession(projectId: group.id, sessionId: session.id);

    await _pumpHomeScreen(
      tester,
      container,
      const _FakeTerminalBackend(platformId: 'native'),
    );

    await _dispatchWindowCommand('setShellShortcutHints', {
      'showProjectHints': true,
      'showSessionHints': true,
    });
    await tester.pump();

    expect(container.read(uiProvider).showProjectShortcutHints, isTrue);
    expect(container.read(uiProvider).showSessionShortcutHints, isTrue);

    await _dispatchWindowCommand('setShellShortcutHints', {
      'showProjectHints': false,
      'showSessionHints': false,
    });
    await tester.pump();

    expect(container.read(uiProvider).showProjectShortcutHints, isFalse);
    expect(container.read(uiProvider).showSessionShortcutHints, isFalse);
  });

  testWidgets(
    'native performDesktopAction payload triggers workspace actions',
    (tester) async {
      final group = _group('desktop-group');
      final session = _session(
        'desktop-session',
        groupId: group.id,
        name: 'gamma',
      );
      var showSearchCount = 0;
      final performedActions = <String>[];
      final container = _container(
        ServerState(isConnected: true, groups: [group], sessions: [session]),
      );
      addTearDown(container.dispose);

      container.read(sessionProvider.notifier)
        ..selectProject(group.id)
        ..setActiveSession(projectId: group.id, sessionId: session.id);

      await _pumpHomeScreen(
        tester,
        container,
        _FakeTerminalBackend(
          platformId: 'native',
          onShowSearch: () => showSearchCount++,
          onPerformAction: performedActions.add,
        ),
      );

      expect(container.read(uiProvider).sidebarOpen, isTrue);

      await _dispatchWindowCommand('performDesktopAction', {
        'action': 'showSearch',
      });
      await tester.pump();

      await _dispatchWindowCommand('performDesktopAction', {
        'action': 'toggleSidebar',
      });
      await tester.pump();

      await _dispatchWindowCommand('performDesktopAction', {
        'action': 'increaseFontSize',
      });
      await tester.pump();

      await _dispatchWindowCommand('performDesktopAction', {
        'action': 'decreaseFontSize',
      });
      await tester.pump();

      await _dispatchWindowCommand('performDesktopAction', {
        'action': 'resetFontSize',
      });
      await tester.pump();

      expect(showSearchCount, 1);
      expect(container.read(uiProvider).sidebarOpen, isFalse);
      expect(performedActions, [
        'increase_font_size:1',
        'decrease_font_size:1',
        'reset_font_size',
      ]);
    },
  );

  testWidgets('native performDesktopAction payload closes the active session', (
    tester,
  ) async {
    final group = _group('desktop-close-group');
    final sessionA = _session(
      'desktop-close-a',
      groupId: group.id,
      name: 'alpha',
    );
    final sessionB = _session(
      'desktop-close-b',
      groupId: group.id,
      name: 'beta',
    );
    final container = _container(
      ServerState(
        isConnected: true,
        groups: [group],
        sessions: [sessionA, sessionB],
      ),
    );
    addTearDown(container.dispose);

    container.read(sessionProvider.notifier)
      ..selectProject(group.id)
      ..setActiveSession(projectId: group.id, sessionId: sessionB.id);

    await _pumpHomeScreen(
      tester,
      container,
      const _FakeTerminalBackend(platformId: 'native'),
    );

    await _dispatchWindowCommand('performDesktopAction', {
      'action': 'closeCurrentSession',
    });
    await tester.pumpAndSettle();

    final notifier =
        container.read(serverProvider.notifier) as _TestServerNotifier;
    expect(notifier.deletedSessionIds, [sessionB.id]);
    expect(container.read(sessionProvider).activeSessionId, sessionA.id);
    expect(
      container.read(serverProvider).sessions.map((session) => session.id),
      [sessionA.id],
    );
  });
}

class _TestServerNotifier extends ServerNotifier {
  _TestServerNotifier(super.state) : super.test();

  final List<_CreateSessionCall> createSessionCalls = [];
  final List<String> deletedSessionIds = [];

  @override
  Future<Session> createSession({
    required String groupId,
    String? name,
    String? command,
    String? cwd,
  }) async {
    createSessionCalls.add(
      _CreateSessionCall(
        groupId: groupId,
        name: name,
        command: command,
        cwd: cwd,
      ),
    );
    final session = Session(
      id: 'created-${createSessionCalls.length}',
      groupId: groupId,
      name: name ?? 'session-${createSessionCalls.length}',
      shell: command ?? 'bash',
      cols: 80,
      rows: 24,
      cwd: cwd ?? '/default/$groupId',
      isAlive: true,
      createdAt: '',
      lastActive: '',
    );
    state = state.copyWith(sessions: [...state.sessions, session]);
    return session;
  }

  @override
  Future<void> updateSession(
    String id, {
    String? name,
    int? sortOrder,
    String? groupId,
  }) async {
    state = state.copyWith(
      sessions:
          state.sessions.map((session) {
            if (session.id != id) {
              return session;
            }
            return session.copyWith(
              name: name ?? session.name,
              sortOrder: sortOrder ?? session.sortOrder,
              groupId: groupId ?? session.groupId,
            );
          }).toList(),
    );
  }

  @override
  Future<void> deleteSession(String id) async {
    deletedSessionIds.add(id);
    state = state.copyWith(
      sessions: state.sessions.where((session) => session.id != id).toList(),
    );
  }
}

class _FakeTerminalBackend implements TerminalBackend {
  const _FakeTerminalBackend({
    required this.platformId,
    this.onShowSearch,
    this.onPerformAction,
  });

  final VoidCallback? onShowSearch;
  final void Function(String action)? onPerformAction;

  @override
  final String platformId;

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
    return _FakeTerminalWidget(
      key: key,
      controller: controller,
      onShowSearch: onShowSearch,
      onPerformAction: onPerformAction,
    );
  }

  @override
  bool get isLocalPty => false;
}

class _FakeTerminalWidget extends StatefulWidget {
  const _FakeTerminalWidget({
    super.key,
    required this.controller,
    this.onShowSearch,
    this.onPerformAction,
  });

  final TerminalController controller;
  final VoidCallback? onShowSearch;
  final void Function(String action)? onPerformAction;

  @override
  State<_FakeTerminalWidget> createState() => _FakeTerminalWidgetState();
}

class _FakeTerminalWidgetState extends State<_FakeTerminalWidget> {
  @override
  void initState() {
    super.initState();
    _attach(widget.controller);
  }

  @override
  void didUpdateWidget(covariant _FakeTerminalWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller)) {
      return;
    }
    oldWidget.controller.detach();
    _attach(widget.controller);
  }

  @override
  void dispose() {
    widget.controller.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const SizedBox.expand();
  }

  void _attach(TerminalController controller) {
    controller.attach(
      sendText: (_) {},
      paste: (_) {},
      showSearch: widget.onShowSearch ?? () {},
      performAction: widget.onPerformAction,
    );
  }
}
