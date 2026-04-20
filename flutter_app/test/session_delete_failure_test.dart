import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tether/models/group.dart';
import 'package:tether/models/session.dart';
import 'package:tether/models/ssh_host.dart';
import 'package:tether/providers/server_provider.dart';
import 'package:tether/providers/session_provider.dart';
import 'package:tether/services/api_service.dart';

/// ApiService that throws on deleteSession.
class _FailingDeleteApiService extends ApiService {
  _FailingDeleteApiService() : super(baseUrl: 'http://unused');

  @override
  Future<Map<String, dynamic>> getInfo() async => {'version': '0.0.0'};

  @override
  Future<void> deleteSession(String id) async {
    throw ApiException(500, 'Internal Server Error');
  }

  @override
  Future<List<Group>> listGroups() async => [];
  @override
  Future<List<Session>> listSessions() async => [];
  @override
  Future<List<SshHost>> listSshHosts() async => [];
  @override
  void dispose() {}
}

void main() {
  test(
    'cleanupSessions is NOT called when deleteSession throws',
    () async {
      final api = _FailingDeleteApiService();
      final serverNotifier = ServerNotifier.test(
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
            ),
          ],
          groups: [Group(id: 'g1', name: 'TestGroup')],
        ),
      );

      final sessionNotifier = SessionNotifier()
        ..selectProject('g1')
        ..setActiveSession(projectId: 'g1', sessionId: 's1');

      expect(sessionNotifier.state.selectedProjectId, 'g1');
      expect(sessionNotifier.state.activeSessionId, 's1');

      try {
        await serverNotifier.deleteSession('s1');
        sessionNotifier.cleanupSessions({});
      } catch (_) {
        // Delete failed — selection must stay intact.
      }

      expect(sessionNotifier.state.selectedProjectId, 'g1');
      expect(sessionNotifier.state.activeSessionId, 's1');
    },
  );

  test(
    'cleanupSessions IS called when deleteSession succeeds',
    () async {
      final api = _SuccessDeleteApiService();
      final serverNotifier = ServerNotifier.test(
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
            ),
          ],
          groups: [Group(id: 'g1', name: 'TestGroup')],
        ),
      );

      final sessionNotifier = SessionNotifier()
        ..selectProject('g1')
        ..setActiveSession(projectId: 'g1', sessionId: 's1');

      expect(sessionNotifier.state.activeSessionId, 's1');

      try {
        await serverNotifier.deleteSession('s1');
        sessionNotifier.cleanupSessions({});
      } catch (_) {
        // Should not happen
      }

      expect(sessionNotifier.state.activeSessionId, isNull,
          reason: 'Active session should be cleared on successful delete');
    },
  );
}

class _SuccessDeleteApiService extends ApiService {
  _SuccessDeleteApiService() : super(baseUrl: 'http://unused');

  @override
  Future<Map<String, dynamic>> getInfo() async => {'version': '0.0.0'};
  @override
  Future<void> deleteSession(String id) async {}
  @override
  Future<List<Group>> listGroups() async => [];
  @override
  Future<List<Session>> listSessions() async => [];
  @override
  Future<List<SshHost>> listSshHosts() async => [];
  @override
  void dispose() {}
}
