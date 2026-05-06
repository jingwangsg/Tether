import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tether/models/group.dart';
import 'package:tether/models/remote_host_status.dart';
import 'package:tether/models/session.dart';
import 'package:tether/models/ssh_host.dart';
import 'package:tether/platform/terminal_backend.dart';
import 'package:tether/providers/server_provider.dart';
import 'package:tether/providers/session_provider.dart';
import 'package:tether/providers/settings_provider.dart';
import 'package:tether/screens/home_screen.dart';
import 'package:tether/services/api_service.dart';
import 'package:tether/widgets/terminal/terminal_controller.dart';

class _MutableServerNotifier extends ServerNotifier {
  _MutableServerNotifier(super.initialState) : super.test();

  void replaceState(ServerState nextState) {
    state = nextState;
  }
}

class _RemoteEnsureCall {
  const _RemoteEnsureCall({required this.host, required this.restart});

  final String host;
  final bool restart;
}

class _RemoteEnsureRecordingServerNotifier extends ServerNotifier {
  _RemoteEnsureRecordingServerNotifier(super.initialState) : super.test();

  final calls = <_RemoteEnsureCall>[];

  void replaceState(ServerState nextState) {
    state = nextState;
  }

  @override
  Future<void> ensureConfiguredRemoteHost(
    String host, {
    required bool restart,
  }) async {
    calls.add(_RemoteEnsureCall(host: host, restart: restart));
  }
}

class _RemoteActionRecordingApiService extends ApiService {
  _RemoteActionRecordingApiService() : super(baseUrl: 'http://unused');

  final connectedHosts = <String>[];
  final restartedHosts = <String>[];
  final remoteHosts = <RemoteHostStatus>[];

  @override
  Future<List<Group>> listGroups() async => const [];

  @override
  Future<List<Session>> listSessions() async => const [];

  @override
  Future<List<SshHost>> listSshHosts() async => const [];

  @override
  Future<List<RemoteHostStatus>> listRemoteHosts() async => remoteHosts;

  @override
  Future<RemoteHostStatus> connectRemoteHost(String host) async {
    connectedHosts.add(host);
    final status = RemoteHostStatus(
      host: host,
      status: RemoteHostConnectionStatus.ready,
    );
    remoteHosts
      ..removeWhere((candidate) => candidate.host == host)
      ..add(status);
    return status;
  }

  @override
  Future<RemoteHostStatus> restartRemoteHost(String host) async {
    restartedHosts.add(host);
    final status = RemoteHostStatus(
      host: host,
      status: RemoteHostConnectionStatus.ready,
    );
    remoteHosts
      ..removeWhere((candidate) => candidate.host == host)
      ..add(status);
    return status;
  }

  @override
  void dispose() {}
}

class _FakeTerminalBackend implements TerminalBackend {
  const _FakeTerminalBackend();

  @override
  String get platformId => 'fake';

  @override
  bool get isLocalPty => false;

  @override
  int get retainedTerminalViewCap => 6;

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
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

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

  testWidgets('configured ssh host is ensured and retried after reconnect', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'selected_ssh_host': 'devbox',
      'restart_remote_on_connect': true,
    });
    final notifier = _RemoteEnsureRecordingServerNotifier(
      const ServerState(isConnected: true),
    );
    final container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith((ref) => SettingsNotifier()),
        serverProvider.overrideWith((ref) => notifier),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: HomeScreen(backend: _FakeTerminalBackend()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(notifier.calls, hasLength(1));
    expect(notifier.calls.single.host, 'devbox');
    expect(notifier.calls.single.restart, isTrue);

    notifier.replaceState(const ServerState(isConnected: false));
    await tester.pumpAndSettle();
    notifier.replaceState(const ServerState(isConnected: true));
    await tester.pumpAndSettle();

    expect(notifier.calls, hasLength(2));
    expect(notifier.calls.last.host, 'devbox');
    expect(notifier.calls.last.restart, isTrue);
  });

  testWidgets('configured ssh host uses non-restart connect by default', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'selected_ssh_host': 'devbox'});
    final api = _RemoteActionRecordingApiService();
    final notifier = ServerNotifier.test(
      ServerState(
        api: api,
        isConnected: true,
        config: ServerConfig(host: 'localhost', port: 7680),
      ),
    );
    final container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith((ref) => SettingsNotifier()),
        serverProvider.overrideWith((ref) => notifier),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: HomeScreen(backend: _FakeTerminalBackend()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(api.connectedHosts, ['devbox']);
    expect(api.restartedHosts, isEmpty);
  });

  test('ensureConfiguredRemoteHost skips ready and connecting hosts', () async {
    for (final status in [
      RemoteHostConnectionStatus.connecting,
      RemoteHostConnectionStatus.ready,
    ]) {
      for (final restart in [false, true]) {
        final api = _RemoteActionRecordingApiService();
        final notifier = ServerNotifier.test(
          ServerState(
            api: api,
            isConnected: true,
            remoteHosts: [RemoteHostStatus(host: 'devbox', status: status)],
          ),
        );

        await notifier.ensureConfiguredRemoteHost('devbox', restart: restart);

        expect(api.connectedHosts, isEmpty);
        expect(api.restartedHosts, isEmpty);
      }
    }
  });
}
