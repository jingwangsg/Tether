import 'dart:async';
import 'dart:math' show min;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/group.dart';
import '../../models/session.dart';
import '../../providers/server_provider.dart';
import '../../providers/session_provider.dart';
import '../../providers/ui_provider.dart';
import '../../utils/session_display.dart';
import '../../utils/session_interaction.dart';
import '../../utils/session_status.dart';
import '../../utils/test_event_logger.dart';
import '../terminal/session_status_dot.dart';
import 'group_dialog.dart';
import 'group_section.dart';
import 'settings_dialog.dart';
import 'ssh_host_list.dart';

bool get _isDesktop =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux);

String? _normalizedHost(String? host) {
  if (host == null || host.isEmpty) {
    return null;
  }
  return host;
}

bool _sameGroupScope(Group first, Group second) {
  return _normalizedHost(first.sshHost) == _normalizedHost(second.sshHost);
}

class Sidebar extends ConsumerWidget {
  const Sidebar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final serverState = ref.watch(serverProvider);
    final uiState = ref.watch(uiProvider);
    final screenWidth = MediaQuery.of(context).size.width;
    final sidebarWidth =
        uiState.isMobile ? min(280.0, screenWidth * 0.85) : 280.0;
    final safeTop = uiState.isMobile ? MediaQuery.of(context).padding.top : 0.0;

    return Container(
      width: sidebarWidth,
      color: const Color(0xFF1A1A1A),
      child: Column(
        children: [
          if (safeTop > 0) SizedBox(height: safeTop),
          _buildHeader(context, ref, serverState),
          const Divider(height: 1, color: Colors.white12),
          Expanded(
            child:
                serverState.isConnected
                    ? _buildContent(context, ref, serverState)
                    : _buildDisconnected(context, ref, serverState),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context, WidgetRef ref, ServerState state) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          const Icon(Icons.terminal, color: Colors.white70, size: 20),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Tether',
              style: TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings, size: 18),
            color: Colors.white54,
            tooltip: 'Settings',
            onPressed: () => showSettingsDialog(context, ref),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
          if (state.isConnected) ...[
            IconButton(
              icon: const Icon(Icons.create_new_folder_outlined, size: 18),
              color: Colors.white54,
              tooltip: 'New Group',
              onPressed: () => _showCreateGroupDialog(context, ref),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
            IconButton(
              icon: const Icon(Icons.add, size: 18),
              color: Colors.white54,
              tooltip: 'New Session',
              onPressed: () => _showCreateSessionDialog(context, ref),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildContent(BuildContext context, WidgetRef ref, ServerState state) {
    final groups = state.groups;
    final sessions = visibleSessions(state.sessions, groups);
    final rootScopes = _buildRootScopes(groups);

    return ListView(
      children: [
        if (state.sshHosts.any((h) => h.reachable == true)) ...[
          SshHostList(
            hosts: state.sshHosts.where((h) => h.reachable == true).toList(),
          ),
          const Divider(height: 1, color: Colors.white12),
        ],
        for (final scope in rootScopes) ...[
          _buildScopeHeader(scope),
          for (final group in scope.groups)
            _buildRootGroupDropTarget(
              context,
              ref,
              group,
              scope.groups,
              groups,
              sessions,
            ),
          if (scope.groups.isNotEmpty)
            _buildRootScopeEndDropZone(context, ref, scope.groups),
        ],
        for (final session in sessions.where(
          (s) => !groups.any((g) => g.id == s.groupId),
        ))
          _buildSessionTile(context, ref, session),
      ],
    );
  }

  Widget _buildScopeHeader(_RootGroupScope scope) {
    return Container(
      key: ValueKey('root-scope-header-${scope.key}'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Row(
        children: [
          Icon(
            scope.isRemote ? Icons.cloud_outlined : Icons.laptop_mac_outlined,
            size: 12,
            color: Colors.white38,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              scope.label,
              style: const TextStyle(
                color: Colors.white38,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRootGroupDropTarget(
    BuildContext context,
    WidgetRef ref,
    Group group,
    List<Group> scopeGroups,
    List<Group> allGroups,
    List<Session> sessions,
  ) {
    return DragTarget<Group>(
      key: ValueKey('root-group-drop-${group.id}'),
      onWillAcceptWithDetails:
          (details) =>
              details.data.id != group.id &&
              details.data.parentId == null &&
              _sameGroupScope(details.data, group),
      onAcceptWithDetails: (details) {
        unawaited(
          _handleGroupDrop(context, ref, details.data, group, scopeGroups),
        );
      },
      builder: (context, candidateData, rejectedData) {
        final isDropTarget = candidateData.isNotEmpty;
        return Column(
          key: ValueKey('root-group-column-${group.id}'),
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isDropTarget) Container(height: 2, color: Colors.blue),
            Builder(
              builder: (context) {
                final feedback = Material(
                  elevation: 4,
                  color: const Color(0xFF2A2A2A),
                  borderRadius: BorderRadius.circular(4),
                  child: SizedBox(
                    width: 220,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.folder,
                            size: 16,
                            color: Colors.white54,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              group.name,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
                final childWhenDragging = Opacity(
                  opacity: 0.3,
                  child: GroupSection(
                    key: ValueKey('group-section-${group.id}'),
                    group: group,
                    allGroups: allGroups,
                    allSessions: sessions,
                    depth: 0,
                  ),
                );
                final child = GroupSection(
                  key: ValueKey('group-section-${group.id}'),
                  group: group,
                  allGroups: allGroups,
                  allSessions: sessions,
                  depth: 0,
                );
                return _isDesktop
                    ? Draggable<Group>(
                      data: group,
                      feedback: feedback,
                      childWhenDragging: childWhenDragging,
                      child: child,
                    )
                    : LongPressDraggable<Group>(
                      data: group,
                      feedback: feedback,
                      childWhenDragging: childWhenDragging,
                      child: child,
                    );
              },
            ),
          ],
        );
      },
    );
  }

  Widget _buildRootScopeEndDropZone(
    BuildContext context,
    WidgetRef ref,
    List<Group> scopeGroups,
  ) {
    return DragTarget<Group>(
      key: ValueKey('root-group-end-drop-${scopeGroups.first.localityKey}'),
      onWillAcceptWithDetails:
          (details) =>
              details.data.parentId == null &&
              details.data.id != scopeGroups.last.id &&
              _sameGroupScope(details.data, scopeGroups.last),
      onAcceptWithDetails: (details) {
        unawaited(
          _handleGroupDropToEnd(context, ref, details.data, scopeGroups),
        );
      },
      builder: (context, candidateData, rejectedData) {
        final isDropTarget = candidateData.isNotEmpty;
        return Container(
          height: isDropTarget ? 24 : 4,
          color:
              isDropTarget
                  ? Colors.blue.withValues(alpha: 0.15)
                  : Colors.transparent,
          child:
              isDropTarget
                  ? Center(child: Container(height: 2, color: Colors.blue))
                  : null,
        );
      },
    );
  }

  Future<void> _handleGroupDrop(
    BuildContext context,
    WidgetRef ref,
    Group dragged,
    Group target,
    List<Group> rootGroups,
  ) async {
    if (!_sameGroupScope(dragged, target)) {
      return;
    }

    final groups = List<Group>.from(rootGroups);
    groups.removeWhere((g) => g.id == dragged.id);
    final targetIdx = groups.indexWhere((g) => g.id == target.id);
    if (targetIdx >= 0) {
      groups.insert(targetIdx, dragged);
    } else {
      groups.add(dragged);
    }

    final items = <Map<String, dynamic>>[];
    for (int i = 0; i < groups.length; i++) {
      items.add({'id': groups[i].id, 'sort_order': i});
    }
    try {
      await ref.read(serverProvider.notifier).reorderGroups(items);
    } catch (_) {
      if (!context.mounted) {
        return;
      }
      _showReorderError(context, 'folders');
    }
  }

  Future<void> _handleGroupDropToEnd(
    BuildContext context,
    WidgetRef ref,
    Group dragged,
    List<Group> scopeGroups,
  ) async {
    if (scopeGroups.isEmpty || !_sameGroupScope(dragged, scopeGroups.first)) {
      return;
    }

    final groups = List<Group>.from(scopeGroups);
    groups.removeWhere((group) => group.id == dragged.id);
    groups.add(dragged);

    final items = <Map<String, dynamic>>[];
    for (int i = 0; i < groups.length; i++) {
      items.add({'id': groups[i].id, 'sort_order': i});
    }
    try {
      await ref.read(serverProvider.notifier).reorderGroups(items);
    } catch (_) {
      if (!context.mounted) {
        return;
      }
      _showReorderError(context, 'folders');
    }
  }

  Widget _buildSessionTile(
    BuildContext context,
    WidgetRef ref,
    Session session,
  ) {
    final activeId = ref.watch(sessionProvider).activeSessionId;
    final isActive = session.id == activeId;
    final serverState = ref.read(serverProvider);
    final display = getDisplayInfo(session, serverState.sessions);
    final canOpen = isSessionInteractive(session, serverState.groups);
    final status = deriveSessionIndicatorStatus(session, isActive: isActive);
    if (status != null) {
      TestEventLogger.instance.log('session_sidebar_status_visible', {
        'session_id': session.id,
        'session_name': display.displayName,
        'status': status.name,
        'source': 'sidebar',
      });
    }
    final semanticsLabel = display.displayName;
    final semanticsValue = [
      display.subtitle,
      switch (status) {
        SessionIndicatorStatus.waiting => 'status waiting',
        SessionIndicatorStatus.running => 'status running',
        SessionIndicatorStatus.attention => 'status attention',
        null => null,
      },
    ].whereType<String>().join(', ');
    final titleColor =
        canOpen ? (isActive ? Colors.white : Colors.white70) : Colors.white38;
    final subtitleColor = canOpen ? Colors.white38 : Colors.white24;

    return Semantics(
      container: true,
      button: canOpen,
      enabled: canOpen,
      selected: isActive,
      identifier: 'session-tile-${session.id}',
      label: semanticsLabel,
      value: semanticsValue.isEmpty ? null : semanticsValue,
      child: GestureDetector(
        onSecondaryTapDown:
            (details) => _showSessionContextMenu(
              context,
              ref,
              session,
              details.globalPosition,
            ),
        onLongPressStart:
            (details) => _showSessionContextMenu(
              context,
              ref,
              session,
              details.globalPosition,
            ),
        child: ListTile(
          dense: true,
          selected: isActive,
          selectedTileColor: Colors.white.withValues(alpha: 0.08),
          leading:
              display.iconAsset != null
                  ? Image.asset(display.iconAsset!, width: 16, height: 16)
                  : Icon(display.icon, size: 16, color: display.iconColor),
          title: Text(
            display.displayName,
            style: TextStyle(color: titleColor, fontSize: 13),
            overflow: TextOverflow.ellipsis,
          ),
          subtitle:
              display.subtitle != null
                  ? Text(
                    display.subtitle!,
                    style: TextStyle(color: subtitleColor, fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  )
                  : null,
          trailing: SizedBox(
            width: status != null ? 44 : 24,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (status != null) ...[
                  SessionStatusDot(
                    key: ValueKey('session-sidebar-status-${session.id}'),
                    status: status,
                    semanticIdentifier: 'session-sidebar-status-${session.id}',
                  ),
                  const SizedBox(width: 6),
                ],
                SizedBox(
                  width: 24,
                  height: 24,
                  child: IconButton(
                    icon: const Icon(Icons.close, size: 14),
                    color: Colors.white38,
                    padding: EdgeInsets.zero,
                    tooltip: 'Delete Session',
                    onPressed: () async {
                      try {
                        await ref
                            .read(serverProvider.notifier)
                            .deleteSession(session.id);
                        ref.read(sessionProvider.notifier).closeTab(session.id);
                      } catch (_) {
                        // Delete failed — leave tab open
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
          onTap:
              canOpen
                  ? () {
                    ref.read(sessionProvider.notifier).openTab(session.id);
                    final ui = ref.read(uiProvider);
                    if (ui.isMobile) {
                      ref.read(uiProvider.notifier).setSidebarOpen(false);
                    }
                  }
                  : null,
        ),
      ),
    );
  }

  Widget _buildDisconnected(
    BuildContext context,
    WidgetRef ref,
    ServerState state,
  ) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.link_off, size: 48, color: Colors.white24),
            const SizedBox(height: 16),
            Text(
              state.error ?? 'Not connected',
              style: const TextStyle(color: Colors.white54, fontSize: 13),
              textAlign: TextAlign.center,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => _showConnectDialog(context, ref),
              child: const Text('Connect to Server'),
            ),
          ],
        ),
      ),
    );
  }

  void _showConnectDialog(BuildContext context, WidgetRef ref) {
    final hostController = TextEditingController(text: 'localhost');
    final portController = TextEditingController(text: '7680');
    final tokenController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) {
        void doConnect() {
          final config = ServerConfig(
            host: hostController.text.trim(),
            port: int.tryParse(portController.text.trim()) ?? 7680,
            token:
                tokenController.text.trim().isEmpty
                    ? null
                    : tokenController.text.trim(),
          );
          ref.read(serverProvider.notifier).connect(config);
          Navigator.pop(ctx);
        }

        return AlertDialog(
          title: const Text('Connect to Server'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: hostController,
                decoration: const InputDecoration(labelText: 'Host'),
              ),
              TextField(
                controller: portController,
                decoration: const InputDecoration(labelText: 'Port'),
                keyboardType: TextInputType.number,
              ),
              TextField(
                controller: tokenController,
                decoration: const InputDecoration(
                  labelText: 'Auth Token (optional)',
                ),
                obscureText: true,
                onSubmitted: (_) => doConnect(),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(onPressed: doConnect, child: const Text('Connect')),
          ],
        );
      },
    );
  }

  void _showCreateGroupDialog(BuildContext context, WidgetRef ref) {
    showDialog(context: context, builder: (_) => const GroupDialog());
  }

  void _showCreateSessionDialog(BuildContext context, WidgetRef ref) async {
    final state = ref.read(serverProvider);
    final groups = state.groups;
    String groupId;
    if (groups.isEmpty) {
      final group = await ref
          .read(serverProvider.notifier)
          .createGroup(name: 'Default');
      groupId = group.id;
    } else {
      groupId = groups.first.id;
    }
    if (!context.mounted) return;
    _showCreateSessionInGroup(context, ref, groupId);
  }

  void _showCreateSessionInGroup(
    BuildContext context,
    WidgetRef ref,
    String groupId,
  ) {
    final nameController = TextEditingController();
    final commandController = TextEditingController();
    final cwdController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) {
        Future<void> doCreate() async {
          final session = await ref
              .read(serverProvider.notifier)
              .createSession(
                groupId: groupId,
                name:
                    nameController.text.trim().isEmpty
                        ? null
                        : nameController.text.trim(),
                command:
                    commandController.text.trim().isEmpty
                        ? null
                        : commandController.text.trim(),
                cwd:
                    cwdController.text.trim().isEmpty
                        ? null
                        : cwdController.text.trim(),
              );
          if (ctx.mounted) Navigator.pop(ctx);
          ref.read(sessionProvider.notifier).openTab(session.id);
        }

        return AlertDialog(
          title: const Text('New Session'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'Session Name (optional)',
                ),
                onSubmitted: (_) => doCreate(),
              ),
              TextField(
                controller: commandController,
                decoration: const InputDecoration(
                  labelText: 'Command (optional)',
                  hintText: 'e.g., ssh myserver',
                ),
                onSubmitted: (_) => doCreate(),
              ),
              TextField(
                controller: cwdController,
                decoration: const InputDecoration(
                  labelText: 'Working Directory (optional)',
                  hintText: 'e.g., ~/projects',
                ),
                onSubmitted: (_) => doCreate(),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(onPressed: doCreate, child: const Text('Create')),
          ],
        );
      },
    );
  }

  void _showSessionContextMenu(
    BuildContext context,
    WidgetRef ref,
    Session session,
    Offset position,
  ) {
    final rect = RelativeRect.fromLTRB(
      position.dx,
      position.dy,
      position.dx,
      position.dy,
    );
    showMenu<String>(
      context: context,
      position: rect,
      items: [
        const PopupMenuItem(value: 'rename', child: Text('Rename')),
        const PopupMenuItem(
          value: 'delete',
          child: Text('Delete', style: TextStyle(color: Colors.red)),
        ),
      ],
    ).then((value) async {
      if (value == null) return;
      if (!context.mounted) return;
      switch (value) {
        case 'rename':
          _showRenameSessionDialog(context, ref, session);
        case 'delete':
          try {
            await ref.read(serverProvider.notifier).deleteSession(session.id);
            ref.read(sessionProvider.notifier).closeTab(session.id);
          } catch (_) {
            // Delete failed — leave tab open
          }
      }
    });
  }

  void _showRenameSessionDialog(
    BuildContext context,
    WidgetRef ref,
    Session session,
  ) {
    final controller = TextEditingController(text: session.name);

    showDialog(
      context: context,
      builder: (ctx) {
        void doRename() {
          final name = controller.text.trim();
          if (name.isNotEmpty) {
            ref
                .read(serverProvider.notifier)
                .updateSession(session.id, name: name);
            Navigator.pop(ctx);
          }
        }

        return AlertDialog(
          title: const Text('Rename Session'),
          content: TextField(
            controller: controller,
            autofocus: true,
            onSubmitted: (_) => doRename(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(onPressed: doRename, child: const Text('Rename')),
          ],
        );
      },
    );
  }
}

List<_RootGroupScope> _buildRootScopes(List<Group> groups) {
  final grouped = <String, List<Group>>{};
  for (final group in groups.where((group) => group.parentId == null)) {
    grouped.putIfAbsent(group.localityKey, () => []).add(group);
  }

  final scopes = <_RootGroupScope>[];
  final localGroups = grouped.remove('local');
  if (localGroups != null && localGroups.isNotEmpty) {
    localGroups.sort(_compareGroups);
    scopes.add(
      _RootGroupScope(key: 'local', label: 'Local', groups: localGroups),
    );
  }

  final remoteKeys = grouped.keys.toList()..sort();
  for (final key in remoteKeys) {
    final scopeGroups = grouped[key]!;
    scopeGroups.sort(_compareGroups);
    final host = key.startsWith('ssh:') ? key.substring(4) : key;
    scopes.add(
      _RootGroupScope(
        key: key,
        label: 'Remote: $host',
        groups: scopeGroups,
        isRemote: true,
      ),
    );
  }

  return scopes;
}

int _compareGroups(Group a, Group b) {
  final bySortOrder = a.sortOrder.compareTo(b.sortOrder);
  if (bySortOrder != 0) {
    return bySortOrder;
  }
  return a.name.compareTo(b.name);
}

class _RootGroupScope {
  final String key;
  final String label;
  final List<Group> groups;
  final bool isRemote;

  const _RootGroupScope({
    required this.key,
    required this.label,
    required this.groups,
    this.isRemote = false,
  });
}

void _showReorderError(BuildContext context, String itemType) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) {
    return;
  }
  messenger
    ..removeCurrentSnackBar()
    ..showSnackBar(
      SnackBar(content: Text("Couldn't reorder $itemType. Reverted.")),
    );
}
