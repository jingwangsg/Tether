import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/session.dart';
import '../../providers/server_provider.dart';
import '../../providers/session_provider.dart';
import '../../providers/ui_provider.dart';
import '../../utils/session_display.dart';
import '../../utils/session_status.dart';
import '../../utils/shell_dialogs.dart';
import '../shell_shortcut_hint_badge.dart';
import 'session_status_dot.dart';

class SessionTopBar extends ConsumerStatefulWidget {
  final String? projectId;
  final List<Session> sessions;
  final String? activeSessionId;
  final Map<String, String> sessionTitles;
  final ValueNotifier<int> titleRevision;

  const SessionTopBar({
    super.key,
    required this.projectId,
    required this.sessions,
    required this.activeSessionId,
    required this.sessionTitles,
    required this.titleRevision,
  });

  @override
  ConsumerState<SessionTopBar> createState() => _SessionTopBarState();
}

class _SessionTopBarState extends ConsumerState<SessionTopBar> {
  @override
  void initState() {
    super.initState();
    widget.titleRevision.addListener(_onTitleRevision);
  }

  @override
  void didUpdateWidget(covariant SessionTopBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.titleRevision, widget.titleRevision)) {
      oldWidget.titleRevision.removeListener(_onTitleRevision);
      widget.titleRevision.addListener(_onTitleRevision);
    }
  }

  @override
  void dispose() {
    widget.titleRevision.removeListener(_onTitleRevision);
    super.dispose();
  }

  void _onTitleRevision() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _handleSessionAction(Session session, String action) async {
    switch (action) {
      case 'rename':
        await showRenameSessionDialog(context, ref, session);
        return;
      case 'delete':
        final selectedProjectId = ref.read(sessionProvider).selectedProjectId;
        final activeSessionId = ref.read(sessionProvider).activeSessionId;
        try {
          await ref.read(serverProvider.notifier).deleteSession(session.id);
          await ref.read(serverProvider.notifier).refresh();
          if (selectedProjectId != null && activeSessionId == session.id) {
            final remaining = ref
                .read(serverProvider)
                .sessions
                .where((s) => s.groupId == selectedProjectId)
                .where((s) => s.id != session.id)
                .toList()
              ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
            if (remaining.isNotEmpty) {
              ref.read(sessionProvider.notifier).setActiveSession(
                    projectId: selectedProjectId,
                    sessionId: remaining.first.id,
                  );
            }
          }
        } catch (_) {}
        return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final showSessionShortcutHints = ref.watch(
      uiProvider.select((state) => state.showSessionShortcutHints),
    );
    return Container(
      key: const ValueKey('session-top-bar'),
      height: 48,
      color: const Color(0xFF1E1E1E),
      child: ReorderableListView.builder(
        scrollDirection: Axis.horizontal,
        buildDefaultDragHandles: false,
        onReorder: widget.projectId == null
            ? (_, __) {}
            : (oldIndex, newIndex) async {
                if (newIndex > oldIndex) {
                  newIndex--;
                }
                final reordered = List<Session>.from(widget.sessions);
                final moved = reordered.removeAt(oldIndex);
                reordered.insert(newIndex, moved);
                final payload = [
                  for (int i = 0; i < reordered.length; i++)
                    {'id': reordered[i].id, 'sort_order': i, 'group_id': widget.projectId},
                ];
                await ref.read(serverProvider.notifier).reorderSessions(payload);
              },
        itemCount: widget.sessions.length,
        itemBuilder: (context, index) {
          final session = widget.sessions[index];
          final isActive = session.id == widget.activeSessionId;
          final display = getDisplayInfo(session, widget.sessions);
          final status = deriveSessionIndicatorStatus(session, isActive: isActive);
          return ReorderableDelayedDragStartListener(
            key: ValueKey('session-top-tab-${session.id}'),
            index: index,
            child: Semantics(
              identifier: 'session-top-tab-${session.id}',
              label: widget.sessionTitles[session.id] ?? display.displayName,
              selected: isActive,
              child: InkWell(
                onTap: () {
                  if (widget.projectId != null) {
                    ref.read(sessionProvider.notifier).setActiveSession(
                          projectId: widget.projectId!,
                          sessionId: session.id,
                        );
                  }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: isActive ? const Color(0xFF2D2D2D) : const Color(0xFF1E1E1E),
                    border: Border(
                      bottom: BorderSide(
                        color: isActive ? Colors.blue : Colors.transparent,
                        width: 2,
                      ),
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(widget.sessionTitles[session.id] ?? display.displayName,
                        style: TextStyle(
                          color: isActive ? Colors.white : Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                      if (showSessionShortcutHints && index < 9) ...[
                        const SizedBox(width: 8),
                        ShellShortcutHintBadge(
                          key: ValueKey('session-shortcut-hint-${session.id}'),
                          label: '${index + 1}',
                        ),
                      ],
                      if (status != null) ...[
                        const SizedBox(width: 8),
                        SessionStatusDot(
                          key: ValueKey('session-tab-status-${session.id}'),
                          status: status,
                          semanticIdentifier: 'session-tab-status-${session.id}',
                        ),
                      ],
                      const SizedBox(width: 4),
                      PopupMenuButton<String>(
                        padding: EdgeInsets.zero,
                        iconSize: 14,
                        icon: Icon(
                          Icons.more_vert,
                          size: 14,
                          color: isActive ? Colors.white54 : Colors.white24,
                        ),
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'rename', child: Text('Rename Session')),
                          PopupMenuItem(value: 'delete', child: Text('Delete Session')),
                        ],
                        onSelected: (value) => _handleSessionAction(session, value),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
