import 'package:flutter_test/flutter_test.dart';
import 'package:tether/models/group.dart';
import 'package:tether/models/session.dart';
import 'package:tether/models/ssh_host.dart';
import 'package:tether/providers/server_provider.dart';
import 'package:tether/services/api_service.dart';

class _StableApiService extends ApiService {
  _StableApiService() : super(baseUrl: 'http://unused');

  @override
  Future<Map<String, dynamic>> getInfo() async => {'version': '0.0.0'};

  @override
  Future<List<Group>> listGroups() async => [Group(id: 'alpha', name: 'Alpha')];

  @override
  Future<List<Session>> listSessions() async => [
    Session(
      id: 's1',
      groupId: 'alpha',
      name: 'shell',
      shell: 'bash',
      cols: 80,
      rows: 24,
      cwd: '/tmp',
      isAlive: true,
      createdAt: '',
      lastActive: '',
    ),
  ];

  @override
  Future<List<SshHost>> listSshHosts() async => [];

  @override
  void dispose() {}
}

class _InfoFailingApiService extends ApiService {
  _InfoFailingApiService() : super(baseUrl: 'http://unused');

  @override
  Future<Map<String, dynamic>> getInfo() async {
    throw StateError('connect failed');
  }

  @override
  void dispose() {}
}

class _RefreshFailingApiService extends ApiService {
  _RefreshFailingApiService() : super(baseUrl: 'http://unused');

  @override
  Future<Map<String, dynamic>> getInfo() async => {'version': '0.0.0'};

  @override
  Future<List<Group>> listGroups() async {
    throw StateError('refresh failed');
  }

  @override
  Future<List<Session>> listSessions() async => const [];

  @override
  Future<List<SshHost>> listSshHosts() async => const [];

  @override
  void dispose() {}
}

void main() {
  test('connect failure preserves the existing working connection', () async {
    final oldConfig = ServerConfig(host: 'old-host', port: 7680);
    final oldApi = _StableApiService();
    final notifier = ServerNotifier.testWithApiFactory(
      ServerState(
        config: oldConfig,
        api: oldApi,
        isConnected: true,
        groups: [Group(id: 'alpha', name: 'Alpha')],
      ),
      apiFactory: (_) => _InfoFailingApiService(),
    );

    await notifier.connect(ServerConfig(host: 'bad-host', port: 9999));

    expect(notifier.state.isConnected, isTrue);
    expect(notifier.state.config?.host, 'old-host');
    expect(identical(notifier.state.api, oldApi), isTrue);
    expect(notifier.state.groups.map((group) => group.id), ['alpha']);
    expect(notifier.state.error, contains('connect failed'));
  });

  test('refresh failure marks the cached snapshot as stale', () async {
    final notifier = ServerNotifier.test(
      ServerState(
        config: ServerConfig(host: 'localhost', port: 7680),
        api: _RefreshFailingApiService(),
        isConnected: true,
        groups: [Group(id: 'alpha', name: 'Alpha')],
        sessions: [
          Session(
            id: 's1',
            groupId: 'alpha',
            name: 'shell',
            shell: 'bash',
            cols: 80,
            rows: 24,
            cwd: '/tmp',
            isAlive: true,
            createdAt: '',
            lastActive: '',
          ),
        ],
      ),
    );

    await notifier.refresh();

    expect(notifier.state.isConnected, isTrue);
    expect(notifier.state.isStale, isTrue);
    expect(notifier.state.groups.map((group) => group.id), ['alpha']);
    expect(notifier.state.sessions.map((session) => session.id), ['s1']);
    expect(notifier.state.error, contains('refresh failed'));
  });
}
