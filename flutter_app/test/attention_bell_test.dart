import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tether/models/group.dart';
import 'package:tether/models/session.dart';
import 'package:tether/platform/terminal_backend.dart';
import 'package:tether/providers/server_provider.dart';
import 'package:tether/providers/session_provider.dart';
import 'package:tether/screens/home_screen.dart';
import 'package:tether/widgets/sidebar/sidebar.dart';
import 'package:tether/widgets/terminal/terminal_controller.dart';

Group _group(String id) => Group(id: id, name: id);

Session _session(String id, String groupId, {bool needsAttention = false}) {
  return Session(
    id: id,
    groupId: groupId,
    name: 'session',
    shell: 'bash',
    cols: 80,
    rows: 24,
    cwd: '/tmp/workspace',
    isAlive: true,
    createdAt: '',
    lastActive: '',
    needsAttention: needsAttention,
    attentionSeq: needsAttention ? 1 : 0,
    attentionUpdatedAt: needsAttention ? '2026-04-05T00:00:00Z' : null,
  );
}

ProviderContainer _container(_AttentionServerNotifier notifier) {
  return ProviderContainer(
    overrides: [serverProvider.overrideWith((ref) => notifier)],
  );
}

Future<void> _pump(
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

  testWidgets('header bell opens the oldest unseen completed session', (
    tester,
  ) async {
    final group = _group('local');
    final session = _session('session-1', group.id, needsAttention: true);
    final notifier = _AttentionServerNotifier(
      ServerState(isConnected: true, groups: [group], sessions: [session]),
    );
    final container = _container(notifier);
    addTearDown(container.dispose);

    await _pump(tester, container, const Sidebar());

    expect(
      find.byTooltip('Open oldest unseen completed session'),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('Open oldest unseen completed session'));
    await tester.pump();

    expect(container.read(sessionProvider).activeSessionId, session.id);
  });

  testWidgets(
    'active unseen session is acknowledged after a stable foreground dwell',
    (tester) async {
      final group = _group('local');
      final session = _session('session-1', group.id, needsAttention: true);
      final notifier = _AttentionServerNotifier(
        ServerState(isConnected: true, groups: [group], sessions: [session]),
      );
      final container = _container(notifier);
      addTearDown(container.dispose);

      container.read(sessionProvider.notifier).openTab(session.id);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: HomeScreen(backend: _FakeTerminalBackend()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));

      expect(notifier.ackedSessions, [(session.id, session.attentionSeq)]);
      final updated = container.read(serverProvider).sessions.single;
      expect(updated.needsAttention, isFalse);
    },
  );
}

class _AttentionServerNotifier extends ServerNotifier {
  _AttentionServerNotifier(ServerState state) : super.test(state);

  final List<(String, int)> ackedSessions = [];

  @override
  Future<void> ackSessionAttention(String sessionId, int attentionSeq) async {
    ackedSessions.add((sessionId, attentionSeq));
    state = state.copyWith(
      sessions:
          state.sessions.map((session) {
            if (session.id != sessionId) return session;
            return session.copyWith(needsAttention: false);
          }).toList(),
    );
  }
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
    VoidCallback? onSessionExited,
    void Function(String? title)? onTitleChanged,
    ForegroundChangedCallback? onForegroundChanged,
  }) {
    return SizedBox(key: key);
  }
}
