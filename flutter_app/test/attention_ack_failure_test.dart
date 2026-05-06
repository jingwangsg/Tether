import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tether/models/group.dart';
import 'package:tether/models/remote_host_status.dart';
import 'package:tether/models/session.dart';
import 'package:tether/models/ssh_host.dart';
import 'package:tether/providers/server_provider.dart';
import 'package:tether/services/api_service.dart';

/// ApiService that fails ack but tracks refresh calls.
class _FailingAckApiService extends ApiService {
  _FailingAckApiService() : super(baseUrl: 'http://unused');

  int refreshCallCount = 0;

  @override
  Future<Map<String, dynamic>> getInfo() async => {'version': '0.0.0'};

  @override
  Future<SessionAttentionState> ackSessionAttention(String id) async {
    throw ApiException(500, 'Internal Server Error');
  }

  @override
  Future<List<Group>> listGroups() async {
    refreshCallCount++;
    return [Group(id: 'g1', name: 'TestGroup')];
  }

  @override
  Future<List<Session>> listSessions() async {
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
        attentionSeq: 2,
        attentionAckSeq: 1,
      ),
    ];
  }

  @override
  Future<List<SshHost>> listSshHosts() async => [];

  @override
  Future<List<RemoteHostStatus>> listRemoteHosts() async => [];

  @override
  void dispose() {}
}

void main() {
  test('ackSessionAttention schedules refresh on failure', () async {
    final api = _FailingAckApiService();
    final notifier = ServerNotifier.test(
      ServerState(
        config: ServerConfig(host: 'localhost', port: 7680),
        api: api,
        isConnected: true,
        sessions: [
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
            attentionSeq: 2,
            attentionAckSeq: 1,
          ),
        ],
        groups: [Group(id: 'g1', name: 'TestGroup')],
      ),
    );

    final refreshCountBefore = api.refreshCallCount;

    // ackSessionAttention should catch the error internally and schedule
    // a refresh to resync state. It should NOT throw to the caller.
    await notifier.ackSessionAttention('s1');

    // refresh() should have been called as a result of the ack failure
    expect(
      api.refreshCallCount,
      greaterThan(refreshCountBefore),
      reason: 'refresh() should be called after ack failure to resync',
    );
  });
}
