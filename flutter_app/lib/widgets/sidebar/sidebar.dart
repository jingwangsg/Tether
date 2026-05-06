import 'dart:math' show min;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/group.dart';
import '../../models/session.dart';
import '../../providers/server_provider.dart';
import '../../providers/session_provider.dart';
import '../../providers/ui_provider.dart';
import '../../utils/session_creation.dart';
import '../../utils/project_status_summary.dart';
import '../../utils/debug_log.dart';
import '../../utils/session_interaction.dart';
import 'notification_bell.dart';
import '../../utils/session_status.dart';
import '../../utils/shell_dialogs.dart';
import '../../utils/test_event_logger.dart';
import '../reorderable/platform_reorder_drag_start_listener.dart';
import '../shell_shortcut_hint_badge.dart';
import '../terminal/session_status_dot.dart';
import 'settings_dialog.dart';

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
    final isConnected = ref.watch(serverProvider.select((s) => s.isConnected));
    final isStale = ref.watch(serverProvider.select((s) => s.isStale));
    final error = ref.watch(serverProvider.select((s) => s.error));
    final navState = ref.watch(sessionProvider);
    final uiState = ref.watch(uiProvider);
    final allowMutations = isConnected && !isStale;
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
    if (projectStatuses.isNotEmpty) {
      debugLog(
        '[BELL:6:sidebar] projectStatuses=$projectStatuses selected=${navState.selectedProjectId} active=${navState.activeSessionId}',
      );
    }

    return Container(
      width: sidebarWidth,
      color: const Color(0xFF1A1A1A),
      child: Column(
        children: [
          if (safeTop > 0) SizedBox(height: safeTop),
          _buildHeader(context, ref, isConnected, isStale),
          const Divider(height: 1, color: Colors.white12),
          Expanded(
            child:
                isConnected
                    ? Column(
                      children: [
                        if (isStale) _buildStaleBanner(error),
                        Expanded(
                          child: _buildContent(
                            context,
                            ref,
                            groups: groups,
                            sessions: visible,
                            navState: navState,
                            projectStatuses: projectStatuses,
                            allowMutations: allowMutations,
                          ),
                        ),
                      ],
                    )
                    : _buildDisconnected(context, ref, error),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    WidgetRef ref,
    bool isConnected,
    bool isStale,
  ) {
    final allowMutations = isConnected && !isStale;
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
          if (isConnected) const NotificationBell(),
          IconButton(
            icon: const Icon(Icons.settings, size: 18),
            color: Colors.white54,
            tooltip: 'Settings',
            onPressed: () => showSettingsDialog(context, ref),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 32, height: 32),
            visualDensity: VisualDensity.compact,
            style: IconButton.styleFrom(
              minimumSize: const Size.square(32),
              fixedSize: const Size.square(32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          if (isConnected) ...[
            IconButton(
              icon: const Icon(Icons.create_new_folder_outlined, size: 18),
              color: Colors.white54,
              tooltip: 'New Group',
              onPressed:
                  allowMutations
                      ? () => _showCreateGroupDialog(context, ref)
                      : null,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 32, height: 32),
              visualDensity: VisualDensity.compact,
              style: IconButton.styleFrom(
                minimumSize: const Size.square(32),
                fixedSize: const Size.square(32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.add, size: 18),
              color: Colors.white54,
              tooltip: 'New Session',
              onPressed:
                  allowMutations ? () => _createSession(context, ref) : null,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 32, height: 32),
              visualDensity: VisualDensity.compact,
              style: IconButton.styleFrom(
                minimumSize: const Size.square(32),
                fixedSize: const Size.square(32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStaleBanner(String? error) {
    return Container(
      key: const ValueKey('sidebar-stale-banner'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: const Color(0x33C48A00),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Showing stale data',
            style: TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (error case final String message when message.isNotEmpty)
            Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontSize: 11),
            ),
        ],
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    WidgetRef ref, {
    required List<Group> groups,
    required List<Session> sessions,
    required SessionState navState,
    required Map<String, SessionIndicatorStatus> projectStatuses,
    required bool allowMutations,
  }) {
    final projects = _projects(groups);

    return CustomScrollView(
      slivers: [
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
              child: _buildProjectTile(
                context,
                ref,
                project,
                isSelected: navState.selectedProjectId == project.id,
                status: projectStatuses[project.id],
                shortcutIndex: index,
                allowMutations: allowMutations,
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
    required bool allowMutations,
  }) {
    final uiState = ref.watch(uiProvider);
    if (status != null) {
      TestEventLogger.instance.log('project_sidebar_status_visible', {
        'project_id': project.id,
        'status': switch (status) {
          SessionIndicatorStatus.waiting => 'waiting',
          SessionIndicatorStatus.running => 'running',
          SessionIndicatorStatus.attention => 'attention',
        },
      });
    }
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
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 120),
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
                const SizedBox(width: 2),
                IconButton(
                  key: ValueKey('project-delete-button-${project.id}'),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 18,
                    height: 18,
                  ),
                  splashRadius: 10,
                  tooltip: 'Delete project',
                  onPressed:
                      allowMutations
                          ? () async {
                            await ref
                                .read(serverProvider.notifier)
                                .deleteGroup(project.id);
                          }
                          : null,
                  icon: Icon(
                    Icons.close,
                    size: 12,
                    color: isSelected ? Colors.white54 : Colors.white24,
                  ),
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
    final hostController = TextEditingController(text: '127.0.0.1');
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
