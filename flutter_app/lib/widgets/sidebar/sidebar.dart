import 'dart:math' show min;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/group.dart';
import '../../models/session.dart';
import '../../models/ssh_host.dart';
import '../../providers/server_provider.dart';
import '../../providers/session_provider.dart';
import '../../providers/ui_provider.dart';
import '../../utils/session_creation.dart';
import '../../utils/project_status_summary.dart';
import '../../utils/session_interaction.dart';
import '../../utils/session_status.dart';
import '../../utils/shell_dialogs.dart';
import '../reorderable/platform_reorder_drag_start_listener.dart';
import '../shell_shortcut_hint_badge.dart';
import '../terminal/session_status_dot.dart';
import 'settings_dialog.dart';
import 'ssh_host_list.dart';

List<Group> _projects(List<Group> groups) =>
    groups.where((group) => group.parentId == null).toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

class Sidebar extends ConsumerWidget {
  final double? width;

  const Sidebar({super.key, this.width});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(serverProvider.select((s) => s.groups));
    final sessions = ref.watch(serverProvider.select((s) => s.sessions));
    final sshHosts = ref.watch(serverProvider.select((s) => s.sshHosts));
    final isConnected = ref.watch(serverProvider.select((s) => s.isConnected));
    final error = ref.watch(serverProvider.select((s) => s.error));
    final navState = ref.watch(sessionProvider);
    final uiState = ref.watch(uiProvider);
    final screenWidth = MediaQuery.of(context).size.width;
    final sidebarWidth =
        width ?? (uiState.isMobile ? min(280.0, screenWidth * 0.85) : 280.0);
    final safeTop = uiState.isMobile ? MediaQuery.of(context).padding.top : 0.0;

    final visible = visibleSessions(sessions, groups);
    final projectStatuses = summarizeProjectStatuses(
      sessions: visible,
      selectedProjectId: navState.selectedProjectId,
      activeSessionId: navState.activeSessionId,
    );

    return Container(
      width: sidebarWidth,
      color: const Color(0xFF1A1A1A),
      child: Column(
        children: [
          if (safeTop > 0) SizedBox(height: safeTop),
          _buildHeader(context, ref, isConnected),
          const Divider(height: 1, color: Colors.white12),
          Expanded(
            child:
                isConnected
                    ? _buildContent(
                      context,
                      ref,
                      groups: groups,
                      sessions: visible,
                      sshHosts: sshHosts,
                      navState: navState,
                      projectStatuses: projectStatuses,
                    )
                    : _buildDisconnected(context, ref, error),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context, WidgetRef ref, bool isConnected) {
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
          if (isConnected) ...[
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
              onPressed: () => _createSession(context, ref),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    WidgetRef ref, {
    required List<Group> groups,
    required List<Session> sessions,
    required List<SshHost> sshHosts,
    required SessionState navState,
    required Map<String, SessionIndicatorStatus> projectStatuses,
  }) {
    final projects = _projects(groups);

    return CustomScrollView(
      slivers: [
        if (sshHosts.any((h) => h.reachable == true)) ...[
          SliverToBoxAdapter(
            child: SshHostList(
              hosts: sshHosts.where((h) => h.reachable == true).toList(),
            ),
          ),
          const SliverToBoxAdapter(
            child: Divider(height: 1, color: Colors.white12),
          ),
        ],
        SliverReorderableList(
          itemCount: projects.length,
          onReorder: (oldIndex, newIndex) async {
            if (newIndex > oldIndex) {
              newIndex--;
            }
            final reordered = List<Group>.from(projects);
            final moved = reordered.removeAt(oldIndex);
            reordered.insert(newIndex, moved);
            final payload = [
              for (int i = 0; i < reordered.length; i++)
                {'id': reordered[i].id, 'sort_order': i},
            ];
            await ref.read(serverProvider.notifier).reorderGroups(payload);
          },
          itemBuilder: (context, index) {
            final project = projects[index];
            return PlatformReorderDragStartListener(
              key: ValueKey('project-tile-${project.id}'),
              index: index,
              axis: Axis.vertical,
              child: _buildProjectTile(
                context,
                ref,
                project,
                isSelected: navState.selectedProjectId == project.id,
                status: projectStatuses[project.id],
                shortcutIndex: index,
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildProjectTile(
    BuildContext context,
    WidgetRef ref,
    Group project, {
    required bool isSelected,
    required SessionIndicatorStatus? status,
    required int shortcutIndex,
  }) {
    final uiState = ref.watch(uiProvider);
    return Material(
      color: Colors.transparent,
      child: Semantics(
        identifier: 'project-tile-${project.id}',
        label: project.name,
        selected: isSelected,
        child: InkWell(
          onTap: () {
            ref.read(sessionProvider.notifier).selectProject(project.id);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            color: isSelected ? Colors.white.withValues(alpha: 0.08) : null,
            child: Row(
              children: [
                const Icon(
                  Icons.folder_outlined,
                  size: 16,
                  color: Colors.white54,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    project.name,
                    style: TextStyle(
                      color: isSelected ? Colors.white : Colors.white70,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (project.normalizedSshHost != null) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    child: Container(
                      key: ValueKey('project-ssh-badge-${project.id}'),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.blue.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        project.normalizedSshHost!,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.lightBlueAccent,
                          fontSize: 10,
                        ),
                      ),
                    ),
                  ),
                ],
                if (uiState.showProjectShortcutHints && shortcutIndex < 9) ...[
                  const SizedBox(width: 8),
                  ShellShortcutHintBadge(
                    key: ValueKey('project-shortcut-hint-${project.id}'),
                    label: '${shortcutIndex + 1}',
                  ),
                ],
                if (status != null)
                  SessionStatusDot(
                    key: ValueKey('project-status-${project.id}'),
                    status: status,
                    semanticIdentifier: 'project-status-${project.id}',
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDisconnected(
    BuildContext context,
    WidgetRef ref,
    String? error,
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
              error ?? 'Not connected',
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
    showCreateProjectDialog(context);
  }

  void _createSession(BuildContext context, WidgetRef ref) async {
    await createSessionInCurrentProject(context, ref);
  }
}
