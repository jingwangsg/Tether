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
import '../tool_state_dot.dart';
import 'group_dialog.dart';

bool get _isDesktop =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux);

class GroupSection extends ConsumerStatefulWidget {
  final Group group;
  final List<Group> allGroups;
  final List<Session> allSessions;
  final int depth;

  const GroupSection({
    super.key,
    required this.group,
    required this.allGroups,
    required this.allSessions,
    required this.depth,
  });

  @override
  ConsumerState<GroupSection> createState() => _GroupSectionState();
}

class _GroupSectionState extends ConsumerState<GroupSection> {
  bool _expanded = true;

  String? _normalizedHost(String? host) {
    if (host == null || host.isEmpty) {
      return null;
    }
    return host;
  }

  Group? _findGroup(String groupId) {
    for (final group in widget.allGroups) {
      if (group.id == groupId) {
        return group;
      }
    }
    return null;
  }

  bool _sameGroupScope(Group first, Group second) {
    return _normalizedHost(first.sshHost) == _normalizedHost(second.sshHost);
  }

  bool _canMoveSessionToGroup(Session session, Group targetGroup) {
    final sourceGroup = _findGroup(session.groupId);
    if (sourceGroup == null) {
      return false;
    }
    return _sameGroupScope(sourceGroup, targetGroup);
  }

  bool _canMoveSessionBefore(Session dragged, Session target) {
    if (dragged.id == target.id) {
      return false;
    }

    final targetGroup = _findGroup(target.groupId);
    if (targetGroup == null) {
      return false;
    }

    return _canMoveSessionToGroup(dragged, targetGroup);
  }

  @override
  Widget build(BuildContext context) {
    final childGroups =
        widget.allGroups.where((g) => g.parentId == widget.group.id).toList()
          ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

    final sessions =
        widget.allSessions.where((s) => s.groupId == widget.group.id).toList()
          ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildGroupHeader(sessions),
        if (_expanded) ...[
          for (final childGroup in childGroups)
            DragTarget<Group>(
              onWillAcceptWithDetails:
                  (details) =>
                      details.data.id != childGroup.id &&
                      details.data.parentId == childGroup.parentId &&
                      _sameGroupScope(details.data, childGroup),
              onAcceptWithDetails:
                  (details) => _handleChildGroupDrop(
                    details.data,
                    childGroup,
                    childGroups,
                  ),
              builder: (context, candidateData, rejectedData) {
                final isDropTarget = candidateData.isNotEmpty;
                return Column(
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
                                      childGroup.name,
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
                            group: childGroup,
                            allGroups: widget.allGroups,
                            allSessions: widget.allSessions,
                            depth: widget.depth + 1,
                          ),
                        );
                        final child = GroupSection(
                          group: childGroup,
                          allGroups: widget.allGroups,
                          allSessions: widget.allSessions,
                          depth: widget.depth + 1,
                        );
                        return _isDesktop
                            ? Draggable<Group>(
                              data: childGroup,
                              feedback: feedback,
                              childWhenDragging: childWhenDragging,
                              child: child,
                            )
                            : LongPressDraggable<Group>(
                              data: childGroup,
                              feedback: feedback,
                              childWhenDragging: childWhenDragging,
                              child: child,
                            );
                      },
                    ),
                  ],
                );
              },
            ),
          if (childGroups.isNotEmpty) _buildChildGroupEndDropZone(childGroups),
          for (final session in sessions) _buildSessionTile(session),
          _buildEndDropZone(),
        ],
      ],
    );
  }

  Widget _buildGroupHeader(List<Session> sessions) {
    return DragTarget<Session>(
      onWillAcceptWithDetails:
          (details) => _canMoveSessionToGroup(details.data, widget.group),
      onAcceptWithDetails: (details) {
        _handleSessionDropOnGroup(details.data);
      },
      builder: (context, candidateData, rejectedData) {
        final isDropTarget = candidateData.isNotEmpty;
        return GestureDetector(
          onSecondaryTapDown:
              (details) => _showGroupContextMenu(details.globalPosition),
          child: InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Container(
              decoration:
                  isDropTarget
                      ? BoxDecoration(
                        color: Colors.blue.withValues(alpha: 0.1),
                        border: Border.all(
                          color: Colors.blue.withValues(alpha: 0.4),
                        ),
                      )
                      : null,
              padding: EdgeInsets.only(
                left: 8.0 + widget.depth * 16.0,
                right: 8,
                top: 6,
                bottom: 6,
              ),
              child: Row(
                children: [
                  Icon(
                    _expanded ? Icons.expand_more : Icons.chevron_right,
                    size: 16,
                    color: Colors.white38,
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.folder_open : Icons.folder,
                    size: 16,
                    color: Colors.white54,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      widget.group.name,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (widget.group.sshHost != null &&
                      widget.group.sshHost!.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.blue.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        widget.group.sshHost!,
                        style: const TextStyle(
                          color: Colors.lightBlueAccent,
                          fontSize: 10,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                  Text(
                    '${sessions.length}',
                    style: const TextStyle(color: Colors.white24, fontSize: 11),
                  ),
                  const SizedBox(width: 4),
                  _buildAddButton(),
                  _buildGroupMenuButton(),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildAddButton() {
    return SizedBox(
      width: 24,
      height: 24,
      child: IconButton(
        icon: const Icon(Icons.add, size: 14),
        color: Colors.white38,
        padding: EdgeInsets.zero,
        tooltip: 'New Session',
        onPressed: () => _createSession(),
      ),
    );
  }

  Widget _buildGroupMenuButton() {
    return SizedBox(
      width: 24,
      height: 24,
      child: PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert, size: 14),
        iconColor: Colors.white38,
        padding: EdgeInsets.zero,
        tooltip: 'Group Options',
        iconSize: 14,
        itemBuilder:
            (_) => [
              const PopupMenuItem(value: 'edit', child: Text('Edit Group')),
              const PopupMenuItem(value: 'rename', child: Text('Rename Group')),
              const PopupMenuItem(
                value: 'new_session',
                child: Text('New Session'),
              ),
              const PopupMenuItem(
                value: 'delete',
                child: Text(
                  'Delete Group',
                  style: TextStyle(color: Colors.red),
                ),
              ),
            ],
        onSelected: (value) {
          switch (value) {
            case 'edit':
              showDialog(
                context: context,
                builder: (_) => GroupDialog(group: widget.group),
              );
            case 'rename':
              _showRenameGroupDialog(context);
            case 'new_session':
              _createSession();
            case 'delete':
              ref.read(serverProvider.notifier).deleteGroup(widget.group.id);
          }
        },
      ),
    );
  }

  Widget _buildSessionTile(Session session) {
    final activeId = ref.watch(sessionProvider).activeSessionId;
    final isActive = session.id == activeId;
    final display = getDisplayInfo(session, widget.allSessions);
    final canOpen = isSessionInteractive(session, widget.allGroups);
    final titleColor =
        canOpen ? (isActive ? Colors.white : Colors.white60) : Colors.white38;
    final subtitleColor = canOpen ? Colors.white38 : Colors.white24;

    final tile = GestureDetector(
      onSecondaryTapDown:
          (details) => _showSessionContextMenu(session, details.globalPosition),
      child: InkWell(
        onTap:
            canOpen
                ? () {
                  ref.read(sessionProvider.notifier).openTab(session.id);
                  if (ref.read(uiProvider).isMobile) {
                    ref.read(uiProvider.notifier).setSidebarOpen(false);
                  }
                }
                : null,
        child: Container(
          padding: EdgeInsets.only(
            left: 28.0 + widget.depth * 16.0,
            right: 8,
            top: 6,
            bottom: 6,
          ),
          color: isActive ? Colors.white.withValues(alpha: 0.08) : null,
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  display.iconAsset != null
                      ? Image.asset(display.iconAsset!, width: 14, height: 14)
                      : Icon(display.icon, size: 14, color: display.iconColor),
                  if (session.toolState != null)
                    Positioned(
                      right: -3,
                      bottom: -3,
                      child: ToolStateDot(session.toolState),
                    ),
                ],
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      display.displayName,
                      style: TextStyle(color: titleColor, fontSize: 13),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (display.subtitle != null)
                      Text(
                        display.subtitle!,
                        style: TextStyle(color: subtitleColor, fontSize: 11),
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              _buildSessionMenuButton(session),
              SizedBox(
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
            ],
          ),
        ),
      ),
    );

    return DragTarget<Session>(
      onWillAcceptWithDetails:
          (details) => _canMoveSessionBefore(details.data, session),
      onAcceptWithDetails: (details) {
        _handleSessionDrop(details.data, session);
      },
      builder: (context, candidateData, rejectedData) {
        final isDropTarget = candidateData.isNotEmpty;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isDropTarget) Container(height: 2, color: Colors.blue),
            Builder(
              builder: (context) {
                final feedback = Material(
                  elevation: 4,
                  color: const Color(0xFF2D2D2D),
                  borderRadius: BorderRadius.circular(4),
                  child: SizedBox(
                    width: 220,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          display.iconAsset != null
                              ? Image.asset(
                                display.iconAsset!,
                                width: 14,
                                height: 14,
                              )
                              : Icon(
                                display.icon,
                                size: 14,
                                color: display.iconColor,
                              ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              display.displayName,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 13,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
                return _isDesktop
                    ? Draggable<Session>(
                      data: session,
                      feedback: feedback,
                      childWhenDragging: Opacity(opacity: 0.3, child: tile),
                      child: tile,
                    )
                    : LongPressDraggable<Session>(
                      data: session,
                      feedback: feedback,
                      childWhenDragging: Opacity(opacity: 0.3, child: tile),
                      child: tile,
                    );
              },
            ),
          ],
        );
      },
    );
  }

  Widget _buildSessionMenuButton(Session session) {
    return SizedBox(
      width: 24,
      height: 24,
      child: PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert, size: 14),
        iconColor: Colors.white38,
        padding: EdgeInsets.zero,
        tooltip: 'Session Options',
        iconSize: 14,
        itemBuilder:
            (_) => [
              const PopupMenuItem(
                value: 'rename',
                child: Row(
                  children: [
                    Text('Rename Session'),
                    Spacer(),
                    Text(
                      '⌘R',
                      style: TextStyle(fontSize: 12, color: Colors.white38),
                    ),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'delete',
                child: Text(
                  'Delete Session',
                  style: TextStyle(color: Colors.red),
                ),
              ),
            ],
        onSelected: (value) {
          switch (value) {
            case 'rename':
              _showRenameSessionDialog(session);
            case 'delete':
              ref.read(serverProvider.notifier).deleteSession(session.id);
              ref.read(sessionProvider.notifier).closeTab(session.id);
          }
        },
      ),
    );
  }

  Widget _buildChildGroupEndDropZone(List<Group> childGroups) {
    return DragTarget<Group>(
      onWillAcceptWithDetails:
          (details) =>
              details.data.parentId == widget.group.id &&
              details.data.id != childGroups.last.id &&
              _sameGroupScope(details.data, widget.group),
      onAcceptWithDetails: (details) {
        final groups = List<Group>.from(childGroups);
        groups.removeWhere((g) => g.id == details.data.id);
        groups.add(details.data);
        final items = <Map<String, dynamic>>[];
        for (int i = 0; i < groups.length; i++) {
          items.add({'id': groups[i].id, 'sort_order': i});
        }
        ref.read(serverProvider.notifier).reorderGroups(items);
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

  Widget _buildEndDropZone() {
    return DragTarget<Session>(
      onWillAcceptWithDetails:
          (details) => _canMoveSessionToGroup(details.data, widget.group),
      onAcceptWithDetails: (details) {
        _handleSessionDropOnGroup(details.data);
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

  void _handleChildGroupDrop(
    Group dragged,
    Group target,
    List<Group> siblingGroups,
  ) {
    if (!_sameGroupScope(dragged, target)) {
      return;
    }

    final groups = List<Group>.from(siblingGroups);
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
    ref.read(serverProvider.notifier).reorderGroups(items);
  }

  void _handleSessionDrop(Session dragged, Session target) {
    if (!_canMoveSessionBefore(dragged, target)) {
      return;
    }

    final targetGroupId = target.groupId;
    final sessions =
        widget.allSessions.where((s) => s.groupId == targetGroupId).toList()
          ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

    sessions.removeWhere((s) => s.id == dragged.id);
    final targetIdx = sessions.indexWhere((s) => s.id == target.id);
    if (targetIdx >= 0) {
      sessions.insert(targetIdx, dragged);
    } else {
      sessions.add(dragged);
    }

    final items = <Map<String, dynamic>>[];
    for (int i = 0; i < sessions.length; i++) {
      items.add({
        'id': sessions[i].id,
        'sort_order': i,
        'group_id': targetGroupId,
      });
    }
    ref.read(serverProvider.notifier).reorderSessions(items);
  }

  void _handleSessionDropOnGroup(Session dragged) {
    if (!_canMoveSessionToGroup(dragged, widget.group)) {
      return;
    }

    final groupId = widget.group.id;
    final sessions =
        widget.allSessions.where((s) => s.groupId == groupId).toList()
          ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

    sessions.removeWhere((s) => s.id == dragged.id);
    sessions.add(dragged);

    final items = <Map<String, dynamic>>[];
    for (int i = 0; i < sessions.length; i++) {
      items.add({'id': sessions[i].id, 'sort_order': i, 'group_id': groupId});
    }
    ref.read(serverProvider.notifier).reorderSessions(items);
  }

  void _createSession() async {
    final group = widget.group;
    final session = await ref
        .read(serverProvider.notifier)
        .createSession(groupId: group.id, cwd: group.defaultCwd);
    ref.read(sessionProvider.notifier).openTab(session.id);
    if (ref.read(uiProvider).isMobile) {
      ref.read(uiProvider.notifier).setSidebarOpen(false);
    }
  }

  void _showGroupContextMenu(Offset position) {
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
        const PopupMenuItem(value: 'edit', child: Text('Edit Group')),
        const PopupMenuItem(value: 'rename', child: Text('Rename Group')),
        const PopupMenuItem(value: 'new_session', child: Text('New Session')),
        const PopupMenuItem(
          value: 'delete',
          child: Text('Delete Group', style: TextStyle(color: Colors.red)),
        ),
      ],
    ).then((value) {
      if (value == null) return;
      if (!mounted) return;
      switch (value) {
        case 'edit':
          showDialog(
            context: context,
            builder: (_) => GroupDialog(group: widget.group),
          );
        case 'rename':
          _showRenameGroupDialog(context);
        case 'new_session':
          _createSession();
        case 'delete':
          ref.read(serverProvider.notifier).deleteGroup(widget.group.id);
      }
    });
  }

  void _showRenameGroupDialog(BuildContext context) {
    final controller = TextEditingController(text: widget.group.name);
    showDialog(
      context: context,
      builder: (ctx) {
        void doRename() {
          final name = controller.text.trim();
          if (name.isNotEmpty) {
            ref
                .read(serverProvider.notifier)
                .updateGroup(widget.group.id, name: name);
            Navigator.pop(ctx);
          }
        }

        return AlertDialog(
          title: const Text('Rename Group'),
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

  void _showSessionContextMenu(Session session, Offset position) {
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
        const PopupMenuItem(
          value: 'rename',
          child: Row(
            children: [
              Text('Rename Session'),
              Spacer(),
              Text('⌘R', style: TextStyle(fontSize: 12, color: Colors.white38)),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'delete',
          child: Text('Delete Session', style: TextStyle(color: Colors.red)),
        ),
      ],
    ).then((value) {
      if (value == null) return;
      switch (value) {
        case 'rename':
          _showRenameSessionDialog(session);
        case 'delete':
          ref.read(serverProvider.notifier).deleteSession(session.id);
          ref.read(sessionProvider.notifier).closeTab(session.id);
      }
    });
  }

  void _showRenameSessionDialog(Session session) {
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
