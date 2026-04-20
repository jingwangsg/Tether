import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/group.dart';
import '../models/session.dart';
import '../models/ssh_host.dart';
import '../services/api_service.dart';
import '../utils/test_event_logger.dart';
import 'server_snapshot_diff.dart';

class ServerConfig {
  final String host;
  final int port;
  final String? token;
  final bool useTls;

  ServerConfig({
    required this.host,
    required this.port,
    this.token,
    this.useTls = false,
  });

  String get baseUrl {
    final scheme = useTls ? 'https' : 'http';
    return '$scheme://$host:$port';
  }
}

class ServerState {
  final ServerConfig? config;
  final ApiService? api;
  final bool isConnected;
  final String? error;
  final List<Group> groups;
  final List<Session> sessions;
  final List<SshHost> sshHosts;

  const ServerState({
    this.config,
    this.api,
    this.isConnected = false,
    this.error,
    this.groups = const [],
    this.sessions = const [],
    this.sshHosts = const [],
  });

  ServerState copyWith({
    ServerConfig? config,
    ApiService? api,
    bool? isConnected,
    String? error,
    List<Group>? groups,
    List<Session>? sessions,
    List<SshHost>? sshHosts,
  }) {
    return ServerState(
      config: config ?? this.config,
      api: api ?? this.api,
      isConnected: isConnected ?? this.isConnected,
      error: error,
      groups: groups ?? this.groups,
      sessions: sessions ?? this.sessions,
      sshHosts: sshHosts ?? this.sshHosts,
    );
  }
}

class ServerNotifier extends StateNotifier<ServerState> {
  static const _refreshInterval = Duration(seconds: 5);
  Timer? _refreshTimer;
  int _groupStructureVersion = 0;
  int _sessionStructureVersion = 0;
  int _connectionGeneration = 0;

  ServerNotifier({bool autoConnect = true}) : super(const ServerState()) {
    if (autoConnect) {
      _tryAutoConnect();
    }
  }

  @visibleForTesting
  ServerNotifier.test([super.state = const ServerState()]);

  Future<void> _tryAutoConnect() async {
    try {
      final config =
          _testOverrideConfig() ?? ServerConfig(host: 'localhost', port: 7680);
      final probe = ApiService(baseUrl: config.baseUrl);
      try {
        await probe.getInfo().timeout(const Duration(seconds: 2));
      } finally {
        probe.dispose();
      }
      await connect(config);
    } catch (_) {
      // No server on default port — stay disconnected
    }
  }

  ServerConfig? _testOverrideConfig() {
    final env = Platform.environment;
    final host = env['TETHER_TEST_SERVER_HOST'];
    final port = int.tryParse(env['TETHER_TEST_SERVER_PORT'] ?? '');
    if (host == null || host.isEmpty || port == null) {
      return null;
    }
    return ServerConfig(
      host: host,
      port: port,
      token: env['TETHER_TEST_SERVER_TOKEN'],
      useTls: env['TETHER_TEST_SERVER_TLS'] == 'true',
    );
  }

  Future<void> connect(ServerConfig config) async {
    _connectionGeneration++;
    final api = ApiService(baseUrl: config.baseUrl, authToken: config.token);

    try {
      await api.getInfo();
      state = state.copyWith(
        config: config,
        api: api,
        isConnected: true,
        error: null,
      );
      TestEventLogger.instance.log('server_connected', {
        'host': config.host,
        'port': config.port,
        'use_tls': config.useTls,
      });
      await refresh();

      _refreshTimer?.cancel();
      _refreshTimer = Timer.periodic(_refreshInterval, (_) => refresh());
    } catch (e) {
      state = state.copyWith(
        config: config,
        isConnected: false,
        error: e.toString(),
      );
    }
  }

  Future<void> refresh() async {
    final api = state.api;
    if (api == null) return;

    final generation = _connectionGeneration;

    try {
      final results = await Future.wait([
        api.listGroups(),
        api.listSessions(),
        api.listSshHosts(),
      ]);

      if (_connectionGeneration != generation) return;

      final diff = diffServerSnapshot(
        currentGroups: state.groups,
        currentSessions: state.sessions,
        currentSshHosts: state.sshHosts,
        refreshedGroups: results[0] as List<Group>,
        refreshedSessions: results[1] as List<Session>,
        refreshedSshHosts: results[2] as List<SshHost>,
      );

      if (!diff.hasChanges) {
        return;
      }

      _replaceState(
        groups: diff.groups,
        groupsStructureChanged: diff.groupsStructureChanged,
        sessions: diff.mergedSessions,
        sessionsStructureChanged: diff.sessionsStructureChanged,
        sshHosts: diff.sshHosts,
      );

      TestEventLogger.instance.log('sessions_refreshed', {
        'group_count': diff.groups.length,
        'session_count': diff.mergedSessions.length,
        'session_names': diff.mergedSessions.map((s) => s.name).toList(),
      });
    } catch (_) {
      // Silently fail on refresh — data may be stale
    }
  }

  Future<Group> createGroup({
    required String name,
    String? parentId,
    String? defaultCwd,
    String? sshHost,
  }) async {
    final group = await state.api!.createGroup(
      name: name,
      parentId: parentId,
      defaultCwd: defaultCwd,
      sshHost: sshHost,
    );
    await refresh();
    return group;
  }

  Future<void> updateGroup(
    String id, {
    String? name,
    int? sortOrder,
    String? defaultCwd,
  }) async {
    await state.api!.updateGroup(
      id,
      name: name,
      sortOrder: sortOrder,
      defaultCwd: defaultCwd,
    );
    await refresh();
  }

  Future<void> deleteGroup(String id) async {
    await state.api!.deleteGroup(id);
    await refresh();
  }

  Future<Session> createSession({
    required String groupId,
    String? name,
    String? command,
    String? cwd,
  }) async {
    final session = await state.api!.createSession(
      groupId: groupId,
      name: name,
      command: command,
      cwd: cwd,
      local: false,
    );
    await refresh();
    return session;
  }

  Future<void> updateSession(
    String id, {
    String? name,
    int? sortOrder,
    String? groupId,
  }) async {
    await state.api!.updateSession(
      id,
      name: name,
      sortOrder: sortOrder,
      groupId: groupId,
    );
    await refresh();
  }

  Future<void> deleteSession(String id) async {
    await state.api!.deleteSession(id);
    await refresh();
  }

  Future<void> reorderGroups(List<Map<String, dynamic>> items) async {
    final previousGroups = state.groups;
    final optimisticGroups = _applyGroupReorder(previousGroups, items);
    final operationVersion = _replaceState(
      groups: optimisticGroups,
      groupsStructureChanged: true,
    );

    try {
      await state.api!.reorderGroups(items);
    } catch (_) {
      _rollbackGroupReorder(
        previousGroups: previousGroups,
        optimisticGroups: optimisticGroups,
        operationVersion: operationVersion.groupVersion,
      );
      rethrow;
    }

    try {
      await refresh();
    } catch (error) {
      debugPrint('Group reorder refresh failed: $error');
    }
  }

  Future<void> reorderSessions(List<Map<String, dynamic>> items) async {
    final previousSessions = state.sessions;
    final optimisticSessions = _applySessionReorder(previousSessions, items);
    final operationVersion = _replaceState(
      sessions: optimisticSessions,
      sessionsStructureChanged: true,
    );

    try {
      await state.api!.reorderSessions(items);
    } catch (_) {
      _rollbackSessionReorder(
        previousSessions: previousSessions,
        optimisticSessions: optimisticSessions,
        operationVersion: operationVersion.sessionVersion,
      );
      rethrow;
    }

    try {
      await refresh();
    } catch (error) {
      debugPrint('Session reorder refresh failed: $error');
    }
  }

  void updateForegroundProcess(
    String sessionId,
    String? process, {
    String? oscTitle,
    int? attentionSeq,
    int? attentionAckSeq,
  }) {
    // Early return if nothing has actually changed — avoids unnecessary
    // provider notifications that cascade into widget rebuilds.
    final current = state.sessions.where((s) => s.id == sessionId).firstOrNull;
    if (current != null) {
      final newFg = process;
      final newOsc = process == null ? null : (oscTitle ?? current.oscTitle);
      final newAttnSeq = attentionSeq ?? current.attentionSeq;
      final newAttnAckSeq = attentionAckSeq ?? current.attentionAckSeq;
      if (current.foregroundProcess == newFg &&
          current.oscTitle == newOsc &&
          current.attentionSeq == newAttnSeq &&
          current.attentionAckSeq == newAttnAckSeq) {
        return;
      }
    }

    final sessions =
        state.sessions.map((s) {
          if (s.id == sessionId) {
            return s.copyWith(
              foregroundProcess: process,
              oscTitle: oscTitle,
              attentionSeq: attentionSeq,
              attentionAckSeq: attentionAckSeq,
              clearForeground: process == null,
            );
          }
          return s;
        }).toList();
    _replaceState(sessions: sessions);
  }

  Future<void> ackSessionAttention(String sessionId) async {
    final api = state.api;
    if (api == null) return;

    final session = state.sessions.where((s) => s.id == sessionId).firstOrNull;
    if (session == null || !session.hasAttention) {
      return;
    }

    final previousSessions = state.sessions;
    final optimisticSessions =
        previousSessions.map((s) {
          if (s.id != sessionId) {
            return s;
          }
          return s.copyWith(attentionAckSeq: s.attentionSeq);
        }).toList();
    _replaceState(sessions: optimisticSessions);

    try {
      final updated = await api.ackSessionAttention(sessionId);
      final sessions =
          state.sessions.map((s) {
            if (s.id != sessionId) {
              return s;
            }
            return s.copyWith(
              attentionSeq: updated.attentionSeq,
              attentionAckSeq: updated.attentionAckSeq,
            );
          }).toList();
      _replaceState(sessions: sessions);
    } catch (_) {
      _replaceState(sessions: previousSessions);
      // Resync client/server state so the UI doesn't stay desynced.
      await refresh();
    }
  }

  _StructureVersion _replaceState({
    List<Group>? groups,
    bool groupsStructureChanged = false,
    List<Session>? sessions,
    bool sessionsStructureChanged = false,
    List<SshHost>? sshHosts,
  }) {
    if (groupsStructureChanged) {
      _groupStructureVersion++;
    }
    if (sessionsStructureChanged) {
      _sessionStructureVersion++;
    }
    state = state.copyWith(
      groups: groups,
      sessions: sessions,
      sshHosts: sshHosts,
    );
    return _StructureVersion(
      groupVersion: _groupStructureVersion,
      sessionVersion: _sessionStructureVersion,
    );
  }

  void _rollbackGroupReorder({
    required List<Group> previousGroups,
    required List<Group> optimisticGroups,
    required int operationVersion,
  }) {
    if (_groupStructureVersion != operationVersion) {
      return;
    }

    final previousById = {for (final group in previousGroups) group.id: group};
    final optimisticById = {
      for (final group in optimisticGroups) group.id: group,
    };

    final rolledBackGroups =
        state.groups.map((group) {
          final previous = previousById[group.id];
          final optimistic = optimisticById[group.id];
          if (previous == null || optimistic == null) {
            return group;
          }
          if (group.sortOrder != optimistic.sortOrder) {
            return group;
          }
          return group.copyWith(sortOrder: previous.sortOrder);
        }).toList();

    _replaceState(groups: rolledBackGroups, groupsStructureChanged: true);
  }

  void _rollbackSessionReorder({
    required List<Session> previousSessions,
    required List<Session> optimisticSessions,
    required int operationVersion,
  }) {
    if (_sessionStructureVersion != operationVersion) {
      return;
    }

    final previousById = {
      for (final session in previousSessions) session.id: session,
    };
    final optimisticById = {
      for (final session in optimisticSessions) session.id: session,
    };

    final rolledBackSessions =
        state.sessions.map((session) {
          final previous = previousById[session.id];
          final optimistic = optimisticById[session.id];
          if (previous == null || optimistic == null) {
            return session;
          }
          if (session.sortOrder != optimistic.sortOrder ||
              session.groupId != optimistic.groupId) {
            return session;
          }
          return session.copyWith(
            sortOrder: previous.sortOrder,
            groupId: previous.groupId,
          );
        }).toList();

    _replaceState(sessions: rolledBackSessions, sessionsStructureChanged: true);
  }

  void disconnect() {
    _connectionGeneration++;
    _refreshTimer?.cancel();
    state.api?.dispose();
    state = const ServerState();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    state.api?.dispose();
    super.dispose();
  }
}

final serverProvider = StateNotifierProvider<ServerNotifier, ServerState>((
  ref,
) {
  return ServerNotifier();
});

List<Group> _applyGroupReorder(
  List<Group> groups,
  List<Map<String, dynamic>> items,
) {
  final sortOrders = <String, int>{};
  for (final item in items) {
    final id = item['id'] as String?;
    final sortOrder = item['sort_order'] as int?;
    if (id == null || sortOrder == null) {
      continue;
    }
    sortOrders[id] = sortOrder;
  }

  return groups
      .map(
        (group) =>
            group.copyWith(sortOrder: sortOrders[group.id] ?? group.sortOrder),
      )
      .toList();
}

List<Session> _applySessionReorder(
  List<Session> sessions,
  List<Map<String, dynamic>> items,
) {
  final updates = <String, _SessionReorderUpdate>{};
  for (final item in items) {
    final id = item['id'] as String?;
    final sortOrder = item['sort_order'] as int?;
    if (id == null || sortOrder == null) {
      continue;
    }
    updates[id] = _SessionReorderUpdate(
      sortOrder: sortOrder,
      groupId: item['group_id'] as String?,
    );
  }

  return sessions.map((session) {
    final update = updates[session.id];
    if (update == null) {
      return session;
    }
    return session.copyWith(
      sortOrder: update.sortOrder,
      groupId: update.groupId ?? session.groupId,
    );
  }).toList();
}

class _SessionReorderUpdate {
  final int sortOrder;
  final String? groupId;

  const _SessionReorderUpdate({required this.sortOrder, this.groupId});
}

class _StructureVersion {
  final int groupVersion;
  final int sessionVersion;

  const _StructureVersion({
    required this.groupVersion,
    required this.sessionVersion,
  });
}
