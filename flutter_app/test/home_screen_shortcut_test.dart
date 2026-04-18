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
import 'package:tether/widgets/sidebar/group_section.dart';
import 'package:tether/widgets/sidebar/sidebar.dart';
import 'package:tether/widgets/terminal/terminal_controller.dart';

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

Future<void> _dispatchWindowCommand(String method) async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  await messenger.handlePlatformMessage(
    'dev.tether/window',
    const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
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

    container.read(sessionProvider.notifier).openTab(session.id);

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
    final session = _session('session-2', groupId: group.id, name: 'beta');
    final container = _container(
      ServerState(isConnected: true, groups: [group], sessions: [session]),
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

  testWidgets('native backend ignores flutter-delivered cmd+r', (tester) async {
    final group = _group('local');
    final session = _session('session-6', groupId: group.id, name: 'zeta');
    final container = _container(
      ServerState(isConnected: true, groups: [group], sessions: [session]),
    );
    addTearDown(container.dispose);

    container.read(sessionProvider.notifier).openTab(session.id);

    await _pumpHomeScreen(
      tester,
      container,
      const _FakeTerminalBackend(platformId: 'native'),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    expect(find.text('Rename Session'), findsNothing);
  });

  testWidgets('cmd+f still triggers terminal search shortcut', (tester) async {
    final group = _group('local');
    final session = _session('session-3', groupId: group.id, name: 'gamma');
    final searchCalls = ValueNotifier<int>(0);
    addTearDown(searchCalls.dispose);
    final container = _container(
      ServerState(isConnected: true, groups: [group], sessions: [session]),
    );
    addTearDown(container.dispose);

    container.read(sessionProvider.notifier).openTab(session.id);

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

  testWidgets('sidebar session context menu no longer shows cmd+r label', (
    tester,
  ) async {
    final session = _session('session-4', groupId: 'missing', name: 'delta');
    final container = _container(
      ServerState(isConnected: true, sessions: [session]),
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: Sidebar())),
      ),
    );
    await tester.pump();

    await tester.longPress(find.text('delta'));
    await tester.pumpAndSettle();

    expect(find.text('Rename'), findsOneWidget);
    expect(find.text('⌘R'), findsNothing);
  });

  testWidgets('group session menu no longer shows cmd+r label', (tester) async {
    final group = _group('local');
    final session = _session('session-5', groupId: group.id, name: 'epsilon');
    final container = _container(
      ServerState(isConnected: true, groups: [group], sessions: [session]),
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: GroupSection(
              group: group,
              allGroups: [group],
              allSessions: [session],
              depth: 0,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('Session Options'));
    await tester.pumpAndSettle();

    expect(find.text('Rename Session'), findsOneWidget);
    expect(find.text('⌘R'), findsNothing);
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
}

class _TestServerNotifier extends ServerNotifier {
  _TestServerNotifier(super.state) : super.test();

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
}

class _FakeTerminalBackend implements TerminalBackend {
  const _FakeTerminalBackend({required this.platformId, this.onShowSearch});

  final VoidCallback? onShowSearch;

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
    bool imagePasteBridgeEnabled = false,
    VoidCallback? onSessionExited,
    void Function(String? title)? onTitleChanged,
    ForegroundChangedCallback? onForegroundChanged,
    Future<void> Function(Uint8List data, String mimeType)? onClipboardImage,
  }) {
    return _FakeTerminalWidget(
      key: key,
      controller: controller,
      onShowSearch: onShowSearch,
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
  });

  final TerminalController controller;
  final VoidCallback? onShowSearch;

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
    );
  }
}
