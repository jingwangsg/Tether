import 'dart:async';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/group.dart';
import '../models/session.dart';
import '../models/ssh_host.dart';
import '../services/api_service.dart';

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

  ServerNotifier({bool autoConnect = true}) : super(const ServerState()) {
    if (autoConnect) {
      _tryAutoConnect();
    }
  }

  @visibleForTesting
  ServerNotifier.test([super.state = const ServerState()]);

  Future<void> _tryAutoConnect() async {
    try {
      final config = ServerConfig(host: 'localhost', port: 7680);
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

  Future<void> connect(ServerConfig config) async {
    final api = ApiService(baseUrl: config.baseUrl, authToken: config.token);

    try {
      await api.getInfo();
      state = state.copyWith(
        config: config,
        api: api,
        isConnected: true,
        error: null,
      );
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

    try {
      final results = await Future.wait([
        api.listGroups(),
        api.listSessions(),
        api.listSshHosts(),
      ]);

      // Preserve the freshest transient foreground state we have from
      // WebSocket events, since the HTTP session list may lag behind.
      final currentSessions = state.sessions;
      final refreshed =
          (results[1] as List<Session>).map((s) {
            final current =
                currentSessions.where((c) => c.id == s.id).firstOrNull;
            if (s.foregroundProcess == null && current?.foregroundProcess != null) {
              return s.copyWith(
                foregroundProcess: current!.foregroundProcess,
                oscTitle: current.oscTitle,
              );
            }
            return s;
          }).toList();

      _replaceState(
        groups: results[0] as List<Group>,
        groupsStructureChanged: true,
        sessions: refreshed,
        sessionsStructureChanged: true,
        sshHosts: results[2] as List<SshHost>,
      );
    } catch (e) {
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
  }) {
    final sessions =
        state.sessions.map((s) {
          if (s.id == sessionId) {
            return s.copyWith(
              foregroundProcess: process,
              oscTitle: oscTitle,
              clearForeground: process == null,
            );
          }
          return s;
        }).toList();
    _replaceState(sessions: sessions);
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
