import 'dart:math' show min;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/group.dart';
import '../../models/session.dart';
import '../../providers/server_provider.dart';
import '../../providers/session_provider.dart';
import '../../providers/ui_provider.dart';
import '../../utils/session_display.dart';
import 'group_dialog.dart';
import 'group_section.dart';
import 'settings_dialog.dart';
import 'ssh_host_list.dart';

class Sidebar extends ConsumerWidget {
  const Sidebar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final serverState = ref.watch(serverProvider);
    final uiState = ref.watch(uiProvider);
    final screenWidth = MediaQuery.of(context).size.width;
    final sidebarWidth = uiState.isMobile ? min(280.0, screenWidth * 0.85) : 280.0;
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
            child: serverState.isConnected
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
    final sessions = state.sessions;

    final rootGroups = groups.where((g) => g.parentId == null).toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

    return ListView(
      children: [
        if (state.sshHosts.any((h) => h.reachable == true)) ...[
          SshHostList(hosts: state.sshHosts.where((h) => h.reachable == true).toList()),
          const Divider(height: 1, color: Colors.white12),
        ],
        for (final group in rootGroups)
          DragTarget<Group>(
            onWillAcceptWithDetails: (details) => details.data.id != group.id,
            onAcceptWithDetails: (details) {
              _handleGroupDrop(ref, details.data, group, rootGroups);
            },
            builder: (context, candidateData, rejectedData) {
              final isDropTarget = candidateData.isNotEmpty;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isDropTarget)
                    Container(height: 2, color: Colors.blue),
                  LongPressDraggable<Group>(
                    data: group,
                    feedback: Material(
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
                              const Icon(Icons.folder, size: 16, color: Colors.white54),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  group.name,
                                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    childWhenDragging: Opacity(
                      opacity: 0.3,
                      child: GroupSection(
                        group: group,
                        allGroups: groups,
                        allSessions: sessions,
                        depth: 0,
                      ),
                    ),
                    child: GroupSection(
                      group: group,
                      allGroups: groups,
                      allSessions: sessions,
                      depth: 0,
                    ),
                  ),
                ],
              );
            },
          ),
        for (final session in sessions.where(
          (s) => !groups.any((g) => g.id == s.groupId),
        ))
          _buildSessionTile(context, ref, session),
      ],
    );
  }

  void _handleGroupDrop(WidgetRef ref, Group dragged, Group target, List<Group> rootGroups) {
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
      items.add({
        'id': groups[i].id,
        'sort_order': i,
      });
    }
    ref.read(serverProvider.notifier).reorderGroups(items);
  }

  Widget _buildSessionTile(BuildContext context, WidgetRef ref, Session session) {
    final activeId = ref.watch(sessionProvider).activeSessionId;
    final isActive = session.id == activeId;
    final serverState = ref.read(serverProvider);
    final display = getDisplayInfo(session, serverState.sessions);

    return GestureDetector(
      onSecondaryTapDown: (details) => _showSessionContextMenu(context, ref, session, details.globalPosition),
      onLongPressStart: (details) => _showSessionContextMenu(context, ref, session, details.globalPosition),
      child: ListTile(
        dense: true,
        selected: isActive,
        selectedTileColor: Colors.white.withValues(alpha: 0.08),
        leading: display.iconAsset != null
            ? Image.asset(display.iconAsset!, width: 16, height: 16)
            : Icon(display.icon, size: 16, color: display.iconColor),
        title: Text(
          display.displayName,
          style: TextStyle(
            color: isActive ? Colors.white : Colors.white70,
            fontSize: 13,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: display.subtitle != null
            ? Text(
                display.subtitle!,
                style: const TextStyle(color: Colors.white38, fontSize: 11),
                overflow: TextOverflow.ellipsis,
              )
            : null,
        trailing: SizedBox(
          width: 24,
          height: 24,
          child: IconButton(
            icon: const Icon(Icons.close, size: 14),
            color: Colors.white38,
            padding: EdgeInsets.zero,
            tooltip: 'Delete Session',
            onPressed: () {
              ref.read(serverProvider.notifier).deleteSession(session.id);
              ref.read(sessionProvider.notifier).closeTab(session.id);
            },
          ),
        ),
        onTap: () {
          ref.read(sessionProvider.notifier).openTab(session.id);
          final ui = ref.read(uiProvider);
          if (ui.isMobile) {
            ref.read(uiProvider.notifier).setSidebarOpen(false);
          }
        },
      ),
    );
  }

  Widget _buildDisconnected(BuildContext context, WidgetRef ref, ServerState state) {
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
            token: tokenController.text.trim().isEmpty
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
                decoration: const InputDecoration(labelText: 'Auth Token (optional)'),
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
            ElevatedButton(
              onPressed: doConnect,
              child: const Text('Connect'),
            ),
          ],
        );
      },
    );
  }

  void _showCreateGroupDialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (_) => const GroupDialog(),
    );
  }

  void _showCreateSessionDialog(BuildContext context, WidgetRef ref) async {
    final state = ref.read(serverProvider);
    final groups = state.groups;
    String groupId;
    if (groups.isEmpty) {
      final group = await ref.read(serverProvider.notifier).createGroup(name: 'Default');
      groupId = group.id;
    } else {
      groupId = groups.first.id;
    }
    if (!context.mounted) return;
    _showCreateSessionInGroup(context, ref, groupId);
  }

  void _showCreateSessionInGroup(BuildContext context, WidgetRef ref, String groupId) {
    final nameController = TextEditingController();
    final commandController = TextEditingController();
    final cwdController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) {
        Future<void> doCreate() async {
          final session = await ref.read(serverProvider.notifier).createSession(
            groupId: groupId,
            name: nameController.text.trim().isEmpty ? null : nameController.text.trim(),
            command: commandController.text.trim().isEmpty ? null : commandController.text.trim(),
            cwd: cwdController.text.trim().isEmpty ? null : cwdController.text.trim(),
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
                decoration: const InputDecoration(labelText: 'Session Name (optional)'),
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
            ElevatedButton(
              onPressed: doCreate,
              child: const Text('Create'),
            ),
          ],
        );
      },
    );
  }

  void _showSessionContextMenu(BuildContext context, WidgetRef ref, Session session, Offset position) {
    final rect = RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy);
    showMenu<String>(
      context: context,
      position: rect,
      items: [
        const PopupMenuItem(value: 'rename', child: Row(
          children: [
            Text('Rename'),
            Spacer(),
            Text('⌘R', style: TextStyle(fontSize: 12, color: Colors.white38)),
          ],
        )),
        const PopupMenuItem(
          value: 'delete',
          child: Text('Delete', style: TextStyle(color: Colors.red)),
        ),
      ],
    ).then((value) {
      if (value == null) return;
      switch (value) {
        case 'rename':
          _showRenameSessionDialog(context, ref, session);
        case 'delete':
          ref.read(serverProvider.notifier).deleteSession(session.id);
          ref.read(sessionProvider.notifier).closeTab(session.id);
      }
    });
  }

  void _showRenameSessionDialog(BuildContext context, WidgetRef ref, Session session) {
    final controller = TextEditingController(text: session.name);

    showDialog(
      context: context,
      builder: (ctx) {
        void doRename() {
          final name = controller.text.trim();
          if (name.isNotEmpty) {
            ref.read(serverProvider.notifier).updateSession(session.id, name: name);
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
            ElevatedButton(
              onPressed: doRename,
              child: const Text('Rename'),
            ),
          ],
        );
      },
    );
  }
}
