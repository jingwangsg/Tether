import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tether/models/group.dart';
import 'package:tether/models/session.dart';
import 'package:tether/models/ssh_host.dart';
import 'package:tether/providers/server_provider.dart';
import 'package:tether/services/api_service.dart';

/// ApiService where listSessions returns different data depending on call order,
/// and the first call is gated by a completer to simulate a slow in-flight refresh.
class _RaceApiService extends ApiService {
  _RaceApiService() : super(baseUrl: 'http://unused');

  final Completer<void> firstCallGate = Completer<void>();
  int _listSessionsCalls = 0;

  final _existingSession = Session(
    id: 's1',
    groupId: 'g1',
    name: 'existing',
    shell: 'bash',
    cols: 80,
    rows: 24,
    cwd: '/tmp',
    isAlive: true,
    createdAt: '',
    lastActive: '',
  );

  final _newSession = Session(
    id: 'new-1',
    groupId: 'g1',
    name: 'new-session',
    shell: 'bash',
    cols: 80,
    rows: 24,
    cwd: '/tmp',
    isAlive: true,
    createdAt: '',
    lastActive: '',
  );

  @override
  Future<Map<String, dynamic>> getInfo() async => {'version': '0.0.0'};

  @override
  Future<List<Group>> listGroups() async =>
      [Group(id: 'g1', name: 'TestGroup')];

  @override
  Future<List<Session>> listSessions() async {
    _listSessionsCalls++;
    if (_listSessionsCalls == 1) {
      // First call (from periodic refresh) — slow, returns stale data
      await firstCallGate.future;
      return [_existingSession];
    }
    // Subsequent calls (from _refreshSessionsAndGroups) — includes new session
    return [_existingSession, _newSession];
  }

  @override
  Future<List<SshHost>> listSshHosts() async {
    // Also gated on first call (part of _loadSnapshot)
    if (_listSessionsCalls <= 1) {
      await firstCallGate.future;
    }
    return [];
  }

  @override
  Future<Session> createSession({
    required String groupId,
    String? name,
    String? command,
    String? cwd,
    bool local = false,
  }) async {
    return _newSession;
  }

  @override
  void dispose() {}
}

void main() {
  test(
    'stale periodic refresh does not overwrite a newer _refreshSessionsAndGroups',
    () async {
      final api = _RaceApiService();
      final notifier = ServerNotifier.test(
        ServerState(
          config: ServerConfig(host: 'localhost', port: 7680),
          api: api,
          isConnected: true,
          sessions: [api._existingSession],
          groups: [Group(id: 'g1', name: 'TestGroup')],
        ),
      );

      // Start periodic refresh — it will block on firstCallGate
      final refreshFuture = notifier.refresh();

      // While old refresh is in flight, create a session (triggers _refreshSessionsAndGroups)
      await notifier.createSession(groupId: 'g1');

      // New session should be in state now
      expect(
        notifier.state.sessions.any((s) => s.id == 'new-1'),
        isTrue,
        reason: 'New session should exist after createSession',
      );

      // Let the stale refresh complete
      api.firstCallGate.complete();
      await refreshFuture;

      // Stale data must NOT have overwritten the fresh state
      expect(
        notifier.state.sessions.any((s) => s.id == 'new-1'),
        isTrue,
        reason: 'Stale refresh must not remove the new session',
      );
    },
  );
}
