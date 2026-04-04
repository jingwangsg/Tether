import 'dart:async';
import 'package:flutter/foundation.dart' show debugPrint;
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

  ServerNotifier() : super(const ServerState()) {
    _tryAutoConnect();
  }

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

      // Preserve the freshest transient foreground state we have. Older or
      // remote daemons may omit tool_state or the full foreground payload from
      // the HTTP session list, while WebSocket events can be more current.
      final currentSessions = state.sessions;
      final refreshed =
          (results[1] as List<Session>).map((s) {
            final current =
                currentSessions.where((c) => c.id == s.id).firstOrNull;
            Session merged;
            if (s.foregroundProcess != null || s.toolState != null) {
              if (s.toolState == null && current?.toolState != null) {
                merged = s.copyWith(toolState: current!.toolState);
              } else {
                merged = s;
              }
            } else if (current?.foregroundProcess != null) {
              merged = s.copyWith(
                foregroundProcess: current!.foregroundProcess,
                toolState: current.toolState,
              );
            } else {
              merged = s;
            }
            if (_shouldLogToolState(
              s.foregroundProcess,
              s.toolState,
              current?.foregroundProcess,
              current?.toolState,
            )) {
              debugPrint(
                '[tool-state][refresh] sid=${s.id} '
                'http=${s.foregroundProcess}/${s.toolState} '
                'current=${current?.foregroundProcess}/${current?.toolState} '
                'merged=${merged.foregroundProcess}/${merged.toolState}',
              );
            }
            return merged;
          }).toList();

      state = state.copyWith(
        groups: results[0] as List<Group>,
        sessions: refreshed,
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
    await state.api!.reorderGroups(items);
    await refresh();
  }

  Future<void> reorderSessions(List<Map<String, dynamic>> items) async {
    await state.api!.reorderSessions(items);
    await refresh();
  }

  void updateForegroundProcess(
    String sessionId,
    String? process, {
    String? toolState,
  }) {
    final before = state.sessions.where((s) => s.id == sessionId).firstOrNull;
    final sessions =
        state.sessions.map((s) {
          if (s.id == sessionId) {
            return s.copyWith(
              foregroundProcess: process,
              toolState: toolState,
              clearForeground: process == null,
            );
          }
          return s;
        }).toList();
    if (_shouldLogToolState(
      process,
      toolState,
      before?.foregroundProcess,
      before?.toolState,
    )) {
      debugPrint(
        '[tool-state][provider-update] sid=$sessionId '
        'before=${before?.foregroundProcess}/${before?.toolState} '
        'after=$process/$toolState',
      );
    }
    state = state.copyWith(sessions: sessions);
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

bool _isKnownTool(String? process) => process == 'claude' || process == 'codex';

bool _shouldLogToolState(
  String? process,
  String? toolState,
  String? otherProcess,
  String? otherToolState,
) {
  return _isKnownTool(process) ||
      _isKnownTool(otherProcess) ||
      toolState != null ||
      otherToolState != null;
}

final serverProvider = StateNotifierProvider<ServerNotifier, ServerState>((
  ref,
) {
  return ServerNotifier();
});
