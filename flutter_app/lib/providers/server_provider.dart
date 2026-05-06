import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/group.dart';
import '../models/remote_host_status.dart';
import '../models/session.dart';
import '../models/ssh_host.dart';
import '../services/api_service.dart';
import '../utils/debug_log.dart';
import '../utils/test_event_logger.dart';
import 'server_snapshot_diff.dart';

typedef ApiServiceFactory = ApiService Function(ServerConfig config);

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
  final bool isStale;
  final String? error;
  final List<Group> groups;
  final List<Session> sessions;
  final List<SshHost> sshHosts;
  final List<RemoteHostStatus> remoteHosts;

  const ServerState({
    this.config,
    this.api,
    this.isConnected = false,
    this.isStale = false,
    this.error,
    this.groups = const [],
    this.sessions = const [],
    this.sshHosts = const [],
    this.remoteHosts = const [],
  });

  static const _noChange = Object();

  ServerState copyWith({
    ServerConfig? config,
    bool clearConfig = false,
    ApiService? api,
    bool clearApi = false,
    bool? isConnected,
    bool? isStale,
    Object? error = _noChange,
    List<Group>? groups,
    List<Session>? sessions,
    List<SshHost>? sshHosts,
    List<RemoteHostStatus>? remoteHosts,
  }) {
    return ServerState(
      config: clearConfig ? null : (config ?? this.config),
      api: clearApi ? null : (api ?? this.api),
      isConnected: isConnected ?? this.isConnected,
      isStale: isStale ?? this.isStale,
      error: identical(error, _noChange) ? this.error : error as String?,
      groups: groups ?? this.groups,
      sessions: sessions ?? this.sessions,
      sshHosts: sshHosts ?? this.sshHosts,
      remoteHosts: remoteHosts ?? this.remoteHosts,
    );
  }
}

class ServerNotifier extends StateNotifier<ServerState> {
  static const _refreshInterval = Duration(seconds: 5);
  static const _sshRefreshEveryN = 6;
  Timer? _refreshTimer;
  final ApiServiceFactory _apiFactory;
  int _groupStructureVersion = 0;
  int _sessionStructureVersion = 0;
  int _connectionGeneration = 0;
  int _refreshGeneration = 0;
  int _refreshCount = 0;

  ServerNotifier({bool autoConnect = true, ApiServiceFactory? apiFactory})
    : _apiFactory = apiFactory ?? _defaultApiFactory,
      super(const ServerState()) {
    if (autoConnect) {
      _tryAutoConnect();
    }
  }

  @visibleForTesting
  ServerNotifier.test([ServerState initialState = const ServerState()])
    : _apiFactory = _defaultApiFactory,
      super(initialState);

  @visibleForTesting
  ServerNotifier.testWithApiFactory(
    ServerState initialState, {
    required ApiServiceFactory apiFactory,
  }) : _apiFactory = apiFactory,
       super(initialState);

  static ApiService _defaultApiFactory(ServerConfig config) {
    return ApiService(baseUrl: config.baseUrl, authToken: config.token);
  }

  Future<void> _tryAutoConnect() async {
    try {
      final config =
          _testOverrideConfig() ?? ServerConfig(host: '127.0.0.1', port: 7680);
      final probe = _apiFactory(config);
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
    final previousState = state;
    final previousApi = previousState.api;
    final generation = ++_connectionGeneration;
    final api = _apiFactory(config);

    try {
      await api.getInfo();
      final snapshot = await _loadSnapshot(api);
      if (_connectionGeneration != generation) {
        api.dispose();
        return;
      }

      _refreshTimer?.cancel();
      if (!identical(previousApi, api)) {
        previousApi?.dispose();
      }

      state = previousState.copyWith(
        config: config,
        api: api,
        isConnected: true,
        isStale: false,
        error: null,
        groups: snapshot.groups,
        sessions: snapshot.sessions,
        sshHosts: snapshot.sshHosts,
        remoteHosts: snapshot.remoteHosts,
      );
      TestEventLogger.instance.log('server_connected', {
        'host': config.host,
        'port': config.port,
        'use_tls': config.useTls,
      });
      _refreshTimer = Timer.periodic(_refreshInterval, (_) => refresh());
    } catch (e) {
      api.dispose();
      if (_connectionGeneration != generation) {
        return;
      }

      if (previousState.isConnected && previousApi != null) {
        state = previousState.copyWith(error: e.toString());
        return;
      }

      state = ServerState(
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
    final refreshGen = ++_refreshGeneration;
    final refreshCount = ++_refreshCount;
    final includeSsh =
        _testRefreshAlwaysIncludesSsh() ||
        (refreshCount % _sshRefreshEveryN) == 0;
    final refreshKind = includeSsh ? 'full' : 'sessions_groups';
    _logRefreshEvent(
      'server_refresh_started',
      kind: refreshKind,
      connectionGen: generation,
      refreshGen: refreshGen,
      sessions: state.sessions,
    );

    try {
      final List<Group> groups;
      final List<Session> sessions;
      final List<SshHost> sshHosts;
      final List<RemoteHostStatus> remoteHosts;

      if (includeSsh) {
        final snapshot = await _loadSnapshot(api);
        groups = snapshot.groups;
        sessions = snapshot.sessions;
        sshHosts = snapshot.sshHosts;
        remoteHosts = snapshot.remoteHosts;
      } else {
        final results = await Future.wait([
          api.listGroups(),
          api.listSessions(),
        ]);
        groups = results[0] as List<Group>;
        sessions = results[1] as List<Session>;
        sshHosts = state.sshHosts;
        remoteHosts = state.remoteHosts;
      }

      _logRefreshEvent(
        'server_refresh_loaded',
        kind: refreshKind,
        connectionGen: generation,
        refreshGen: refreshGen,
        sessions: sessions,
      );

      if (_connectionGeneration != generation) {
        _logRefreshDiscarded(
          kind: refreshKind,
          connectionGen: generation,
          refreshGen: refreshGen,
          reason: 'connection_generation',
          sessions: sessions,
        );
        return;
      }
      if (_refreshGeneration != refreshGen) {
        _logRefreshDiscarded(
          kind: refreshKind,
          connectionGen: generation,
          refreshGen: refreshGen,
          reason: 'refresh_generation',
          sessions: sessions,
        );
        return;
      }

      final diff = diffServerSnapshot(
        currentGroups: state.groups,
        currentSessions: state.sessions,
        currentSshHosts: state.sshHosts,
        refreshedGroups: groups,
        refreshedSessions: sessions,
        refreshedSshHosts: sshHosts,
      );
      final remoteHostsChanged =
          !_remoteHostsEqual(state.remoteHosts, remoteHosts);

      if (!diff.hasChanges &&
          !remoteHostsChanged &&
          !state.isStale &&
          state.error == null) {
        return;
      }

      _replaceState(
        groups: diff.groups,
        groupsStructureChanged: diff.groupsStructureChanged,
        sessions: diff.mergedSessions,
        sessionsStructureChanged: diff.sessionsStructureChanged,
        sshHosts: diff.sshHosts,
        remoteHosts: remoteHosts,
        isStale: false,
        error: null,
      );

      _logRefreshEvent(
        'server_refresh_applied',
        kind: refreshKind,
        connectionGen: generation,
        refreshGen: refreshGen,
        sessions: diff.mergedSessions,
        extra: {
          'group_count': diff.groups.length,
          'ssh_host_count': diff.sshHosts.length,
        },
      );
      TestEventLogger.instance.log('sessions_refreshed', {
        'group_count': diff.groups.length,
        'session_count': diff.mergedSessions.length,
        'session_names': diff.mergedSessions.map((s) => s.name).toList(),
      });
    } catch (error) {
      if (_connectionGeneration != generation) {
        _logRefreshDiscarded(
          kind: refreshKind,
          connectionGen: generation,
          refreshGen: refreshGen,
          reason: 'connection_generation',
          sessions: state.sessions,
        );
        return;
      }
      if (_refreshGeneration != refreshGen) {
        _logRefreshDiscarded(
          kind: refreshKind,
          connectionGen: generation,
          refreshGen: refreshGen,
          reason: 'refresh_generation',
          sessions: state.sessions,
        );
        return;
      }
      _logRefreshEvent(
        'server_refresh_failed',
        kind: refreshKind,
        connectionGen: generation,
        refreshGen: refreshGen,
        sessions: state.sessions,
        extra: {'error': error.toString()},
      );
      state = state.copyWith(isStale: true, error: error.toString());
    }
  }

  /// Fast refresh that only fetches groups and sessions, skipping the slow
  /// SSH host reachability check. Used after session/group mutations where
  /// the caller needs the updated list immediately.
  Future<void> _refreshSessionsAndGroups() async {
    final api = state.api;
    if (api == null) return;
    final generation = _connectionGeneration;
    final refreshGen = ++_refreshGeneration;
    const refreshKind = 'sessions_groups';
    _logRefreshEvent(
      'server_refresh_started',
      kind: refreshKind,
      connectionGen: generation,
      refreshGen: refreshGen,
      sessions: state.sessions,
    );

    try {
      final results = await Future.wait([api.listGroups(), api.listSessions()]);
      final sessions = results[1] as List<Session>;
      _logRefreshEvent(
        'server_refresh_loaded',
        kind: refreshKind,
        connectionGen: generation,
        refreshGen: refreshGen,
        sessions: sessions,
      );
      if (_connectionGeneration != generation) {
        _logRefreshDiscarded(
          kind: refreshKind,
          connectionGen: generation,
          refreshGen: refreshGen,
          reason: 'connection_generation',
          sessions: sessions,
        );
        return;
      }
      if (_refreshGeneration != refreshGen) {
        _logRefreshDiscarded(
          kind: refreshKind,
          connectionGen: generation,
          refreshGen: refreshGen,
          reason: 'refresh_generation',
          sessions: sessions,
        );
        return;
      }

      final diff = diffServerSnapshot(
        currentGroups: state.groups,
        currentSessions: state.sessions,
        currentSshHosts: state.sshHosts,
        refreshedGroups: results[0] as List<Group>,
        refreshedSessions: sessions,
        refreshedSshHosts: state.sshHosts,
      );

      if (!diff.hasChanges && !state.isStale && state.error == null) {
        return;
      }

      _replaceState(
        groups: diff.groups,
        groupsStructureChanged: diff.groupsStructureChanged,
        sessions: diff.mergedSessions,
        sessionsStructureChanged: diff.sessionsStructureChanged,
        sshHosts: diff.sshHosts,
        isStale: false,
        error: null,
      );

      _logRefreshEvent(
        'server_refresh_applied',
        kind: refreshKind,
        connectionGen: generation,
        refreshGen: refreshGen,
        sessions: diff.mergedSessions,
        extra: {
          'group_count': diff.groups.length,
          'ssh_host_count': diff.sshHosts.length,
        },
      );
      TestEventLogger.instance.log('sessions_refreshed', {
        'group_count': diff.groups.length,
        'session_count': diff.mergedSessions.length,
        'session_names': diff.mergedSessions.map((s) => s.name).toList(),
      });
    } catch (error) {
      if (_connectionGeneration != generation) {
        _logRefreshDiscarded(
          kind: refreshKind,
          connectionGen: generation,
          refreshGen: refreshGen,
          reason: 'connection_generation',
          sessions: state.sessions,
        );
        return;
      }
      if (_refreshGeneration != refreshGen) {
        _logRefreshDiscarded(
          kind: refreshKind,
          connectionGen: generation,
          refreshGen: refreshGen,
          reason: 'refresh_generation',
          sessions: state.sessions,
        );
        return;
      }
      _logRefreshEvent(
        'server_refresh_failed',
        kind: refreshKind,
        connectionGen: generation,
        refreshGen: refreshGen,
        sessions: state.sessions,
        extra: {'error': error.toString()},
      );
      state = state.copyWith(isStale: true, error: error.toString());
    }
  }

  Future<RemoteHostStatus> connectRemoteHost(String host) async {
    final api = state.api;
    if (api == null) {
      throw StateError('Not connected');
    }
    final status = await api.connectRemoteHost(host);
    _replaceRemoteHostStatus(status);
    await refresh();
    return status;
  }

  Future<RemoteHostStatus> deployRemoteHost(String host) async {
    final api = state.api;
    if (api == null) {
      throw StateError('Not connected');
    }
    final status = await api.deployRemoteHost(host);
    _replaceRemoteHostStatus(status);
    await refresh();
    return status;
  }

  Future<RemoteHostStatus> restartRemoteHost(String host) async {
    final api = state.api;
    if (api == null) {
      throw StateError('Not connected');
    }
    final status = await api.restartRemoteHost(host);
    _replaceRemoteHostStatus(status);
    await refresh();
    return status;
  }

  Future<void> ensureConfiguredRemoteHost(
    String host, {
    required bool restart,
  }) async {
    final normalized = host.trim();
    if (normalized.isEmpty) {
      return;
    }
    final existing = _remoteHostStatus(normalized);
    if (existing?.isConnectingOrReady == true) {
      return;
    }
    if (restart) {
      await restartRemoteHost(normalized);
    } else {
      await connectRemoteHost(normalized);
    }
  }

  RemoteHostStatus? _remoteHostStatus(String host) {
    for (final status in state.remoteHosts) {
      if (status.host == host) {
        return status;
      }
    }
    return null;
  }

  void _replaceRemoteHostStatus(RemoteHostStatus status) {
    final next = [...state.remoteHosts];
    final index = next.indexWhere((candidate) => candidate.host == status.host);
    if (index == -1) {
      next.add(status);
    } else {
      next[index] = status;
    }
    state = state.copyWith(remoteHosts: next);
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
    TestEventLogger.instance.log('server_create_session_requested', {
      'group_id': groupId,
      'session_count': state.sessions.length,
      'session_ids': state.sessions.map((s) => s.id).toList(),
      'session_names': state.sessions.map((s) => s.name).toList(),
    });
    final session = await state.api!.createSession(
      groupId: groupId,
      name: name,
      command: command,
      cwd: cwd,
      local: false,
    );
    await _refreshSessionsAndGroups();
    TestEventLogger.instance.log('server_create_session_returned', {
      'group_id': groupId,
      'session_id': session.id,
      'session_count': state.sessions.length,
      'session_ids': state.sessions.map((s) => s.id).toList(),
      'session_names': state.sessions.map((s) => s.name).toList(),
    });
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
      debugLog(
        '[BELL:4:provider] updateForegroundProcess session=${shortId(sessionId)} old(fg=${current.foregroundProcess} osc=${current.oscTitle} att=${current.attentionSeq}/${current.attentionAckSeq}) -> new(fg=$newFg osc=$newOsc att=$newAttnSeq/$newAttnAckSeq)',
      );
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

  /// Mark a session as needing attention due to a bell event from Ghostty.
  /// This is a client-side only operation — no server call needed since the
  /// bell originated from the local PTY surface.
  void markSessionBell(String sessionId) {
    final sessions =
        state.sessions.map((s) {
          if (s.id != sessionId) return s;
          return s.copyWith(attentionSeq: s.attentionSeq + 1);
        }).toList();
    _replaceState(sessions: sessions);
    debugLog(
      '[BELL:4:provider] markSessionBell session=${shortId(sessionId)} new attSeq=${sessions.firstWhere((s) => s.id == sessionId).attentionSeq}',
    );
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
    List<RemoteHostStatus>? remoteHosts,
    bool? isStale,
    Object? error = ServerState._noChange,
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
      remoteHosts: remoteHosts,
      isStale: isStale,
      error: error,
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

  bool _testRefreshAlwaysIncludesSsh() {
    final value =
        Platform.environment['TETHER_TEST_REFRESH_ALWAYS_INCLUDES_SSH'];
    return value != null && value.isNotEmpty && value != '0';
  }

  void _logRefreshDiscarded({
    required String kind,
    required int connectionGen,
    required int refreshGen,
    required String reason,
    required List<Session> sessions,
  }) {
    _logRefreshEvent(
      'server_refresh_discarded',
      kind: kind,
      connectionGen: connectionGen,
      refreshGen: refreshGen,
      sessions: sessions,
      extra: {
        'reason': reason,
        'current_connection_gen': _connectionGeneration,
        'current_refresh_gen': _refreshGeneration,
      },
    );
  }

  void _logRefreshEvent(
    String event, {
    required String kind,
    required int connectionGen,
    required int refreshGen,
    required List<Session> sessions,
    Map<String, Object?> extra = const {},
  }) {
    TestEventLogger.instance.log(event, {
      'kind': kind,
      'connection_gen': connectionGen,
      'refresh_gen': refreshGen,
      'session_count': sessions.length,
      'session_ids': sessions.map((s) => s.id).toList(),
      'session_names': sessions.map((s) => s.name).toList(),
      ...extra,
    });
  }
}

extension on ServerNotifier {
  Future<
    ({
      List<Group> groups,
      List<Session> sessions,
      List<SshHost> sshHosts,
      List<RemoteHostStatus> remoteHosts,
    })
  >
  _loadSnapshot(ApiService api) async {
    final results = await Future.wait([
      api.listGroups(),
      api.listSessions(),
      api.listSshHosts(),
      api.listRemoteHosts(),
    ]);

    return (
      groups: results[0] as List<Group>,
      sessions: results[1] as List<Session>,
      sshHosts: results[2] as List<SshHost>,
      remoteHosts: results[3] as List<RemoteHostStatus>,
    );
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

bool _remoteHostsEqual(List<RemoteHostStatus> a, List<RemoteHostStatus> b) {
  if (a.length != b.length) {
    return false;
  }
  final leftSorted = [...a]
    ..sort((left, right) => left.host.compareTo(right.host));
  final rightSorted = [...b]
    ..sort((left, right) => left.host.compareTo(right.host));
  for (var i = 0; i < a.length; i++) {
    final left = leftSorted[i];
    final right = rightSorted[i];
    if (left.host != right.host ||
        left.status != right.status ||
        left.tunnelPort != right.tunnelPort ||
        left.failureMessage != right.failureMessage) {
      return false;
    }
  }
  return true;
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
