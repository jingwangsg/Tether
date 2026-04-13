import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tether/models/group.dart';
import 'package:tether/models/session.dart';
import 'package:tether/models/ssh_host.dart';
import 'package:tether/providers/server_provider.dart';
import 'package:tether/services/api_service.dart';

/// ApiService whose listGroups/listSessions/listSshHosts are driven by
/// a completer so we can control when the refresh() future resolves.
class _DelayedApiService extends ApiService {
  _DelayedApiService() : super(baseUrl: 'http://unused');

  Completer<void>? refreshGate;

  @override
  Future<Map<String, dynamic>> getInfo() async => {'version': '0.0.0'};

  @override
  Future<List<Group>> listGroups() async {
    await refreshGate?.future;
    return [Group(id: 'g1', name: 'TestGroup')];
  }

  @override
  Future<List<Session>> listSessions() async {
    await refreshGate?.future;
    return [
      Session(
        id: 's1',
        groupId: 'g1',
        name: 'test-session',
        shell: 'bash',
        cols: 80,
        rows: 24,
        cwd: '/tmp',
        isAlive: true,
        createdAt: '',
        lastActive: '',
      ),
    ];
  }

  @override
  Future<List<SshHost>> listSshHosts() async {
    await refreshGate?.future;
    return [];
  }

  @override
  void dispose() {}
}

void main() {
  test(
    'in-flight refresh does NOT overwrite state after disconnect()',
    () async {
      final api = _DelayedApiService();
      final notifier = ServerNotifier.test(
        ServerState(
          config: ServerConfig(host: 'localhost', port: 7680),
          api: api,
          isConnected: true,
          sessions: [],
          groups: [],
        ),
      );

      // Gate the refresh so it doesn't complete immediately
      api.refreshGate = Completer<void>();

      // Start refresh — it will await the gate
      final refreshFuture = notifier.refresh();

      // While refresh is in flight, disconnect
      notifier.disconnect();

      // State should be empty after disconnect
      expect(notifier.state.isConnected, isFalse);
      expect(notifier.state.sessions, isEmpty);
      expect(notifier.state.groups, isEmpty);

      // Now let the stale refresh complete
      api.refreshGate!.complete();
      await refreshFuture;

      // State MUST still be empty — the stale refresh data should be discarded
      expect(notifier.state.isConnected, isFalse,
          reason: 'Stale refresh must not re-connect');
      expect(notifier.state.sessions, isEmpty,
          reason: 'Stale refresh must not inject sessions');
      expect(notifier.state.groups, isEmpty,
          reason: 'Stale refresh must not inject groups');
    },
  );
}
