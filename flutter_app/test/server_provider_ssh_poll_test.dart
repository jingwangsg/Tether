import 'package:flutter_test/flutter_test.dart';
import 'package:tether/models/group.dart';
import 'package:tether/models/session.dart';
import 'package:tether/models/ssh_host.dart';
import 'package:tether/providers/server_provider.dart';
import 'package:tether/services/api_service.dart';

/// ApiService that counts how many times listSshHosts is called.
class _CountingApiService extends ApiService {
  _CountingApiService() : super(baseUrl: 'http://unused');

  int sshCallCount = 0;

  @override
  Future<Map<String, dynamic>> getInfo() async => {'version': '0.0.0'};

  @override
  Future<List<Group>> listGroups() async =>
      [Group(id: 'g1', name: 'TestGroup')];

  @override
  Future<List<Session>> listSessions() async => [
        Session(
          id: 's1',
          groupId: 'g1',
          name: 'test',
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
  Future<List<SshHost>> listSshHosts() async {
    sshCallCount++;
    return [SshHost(host: 'devbox', reachable: true)];
  }

  @override
  void dispose() {}
}

void main() {
  test('SSH hosts are not fetched on every refresh cycle', () async {
    final api = _CountingApiService();
    final notifier = ServerNotifier.test(
      ServerState(
        config: ServerConfig(host: 'localhost', port: 7680),
        api: api,
        isConnected: true,
        sessions: [],
        groups: [],
      ),
    );

    // Run 6 refreshes — SSH should only be fetched once (every 6th)
    for (var i = 0; i < 6; i++) {
      await notifier.refresh();
    }

    expect(api.sshCallCount, 1,
        reason: 'SSH hosts should be fetched once per 6 refresh cycles');
  });

  test('SSH state is preserved during non-SSH refresh cycles', () async {
    final api = _CountingApiService();
    final initialSshHosts = [SshHost(host: 'devbox', reachable: true)];
    final notifier = ServerNotifier.test(
      ServerState(
        config: ServerConfig(host: 'localhost', port: 7680),
        api: api,
        isConnected: true,
        sessions: [],
        groups: [],
        sshHosts: initialSshHosts,
      ),
    );

    // First refresh is not an SSH cycle (count 1, 1 % 6 != 0)
    await notifier.refresh();

    expect(notifier.state.sshHosts.length, 1);
    expect(notifier.state.sshHosts.first.host, 'devbox');
    expect(api.sshCallCount, 0,
        reason: 'Non-SSH refresh should not call listSshHosts');
  });
}
