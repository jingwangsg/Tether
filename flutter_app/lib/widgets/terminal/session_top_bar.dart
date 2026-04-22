import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/session.dart';
import '../../providers/server_provider.dart';
import '../../providers/session_provider.dart';
import '../../providers/ui_provider.dart';
import '../../utils/session_close.dart';
import '../../utils/session_tab_presentation.dart';
import '../../utils/session_status.dart';
import '../../utils/test_event_logger.dart';
import '../reorderable/platform_reorder_drag_start_listener.dart';
import '../shell_shortcut_hint_badge.dart';
import 'session_status_dot.dart';

class SessionTopBar extends ConsumerWidget {
  final String? projectId;
  final List<Session> sessions;
  final String? activeSessionId;

  const SessionTopBar({
    super.key,
    required this.projectId,
    required this.sessions,
    required this.activeSessionId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Future<void> closeCurrentSession(Session session) async {
      try {
        await closeSession(ref, session);
      } catch (_) {}
    }

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
        onReorder:
            projectId == null
                ? (_, __) {}
                : (oldIndex, newIndex) async {
                  if (newIndex > oldIndex) {
                    newIndex--;
                  }
                  final reordered = List<Session>.from(sessions);
                  final moved = reordered.removeAt(oldIndex);
                  reordered.insert(newIndex, moved);
                  final payload = [
                    for (int i = 0; i < reordered.length; i++)
                      {
                        'id': reordered[i].id,
                        'sort_order': i,
                        'group_id': projectId,
                      },
                  ];
                  await ref
                      .read(serverProvider.notifier)
                      .reorderSessions(payload);
                },
        itemCount: sessions.length,
        itemBuilder: (context, index) {
          final session = sessions[index];
          final isActive = session.id == activeSessionId;
          final presentation = deriveSessionTabPresentation(session, const {});
          final secondaryForA11y =
              presentation.secondaryTooltip ?? presentation.secondaryLabel;
          final status = deriveSessionIndicatorStatus(
            session,
            isActive: isActive,
          );
          if (status != null) {
            TestEventLogger.instance.log('session_tab_status_visible', {
              'session_id': session.id,
              'project_id': projectId,
              'status': switch (status) {
                SessionIndicatorStatus.waiting => 'waiting',
                SessionIndicatorStatus.running => 'running',
                SessionIndicatorStatus.attention => 'attention',
              },
            });
          }
          return PlatformReorderDragStartListener(
            key: ValueKey('session-top-tab-${session.id}'),
            index: index,
            child: Material(
              color: Colors.transparent,
              child: Semantics(
                identifier: 'session-top-tab-${session.id}',
                label:
                    secondaryForA11y == null
                        ? presentation.primaryTitle
                        : '${presentation.primaryTitle} | $secondaryForA11y',
                selected: isActive,
                child: GestureDetector(
                  onSecondaryTapUp: (details) {
                    _showTabContextMenu(
                      context,
                      ref,
                      session,
                      details.globalPosition,
                    );
                  },
                  child: InkWell(
                  onTap: () {
                    if (projectId != null) {
                      ref
                          .read(sessionProvider.notifier)
                          .setActiveSession(
                            projectId: projectId!,
                            sessionId: session.id,
                          );
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color:
                          isActive
                              ? const Color(0xFF2D2D2D)
                              : const Color(0xFF1E1E1E),
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
                        Flexible(
                          child: Text(
                            presentation.primaryTitle,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: isActive ? Colors.white : Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        if (presentation.secondaryLabel
                            case final String secondary) ...[
                          const SizedBox(width: 6),
                          Text(
                            '|',
                            style: TextStyle(
                              color: isActive ? Colors.white30 : Colors.white24,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child:
                                presentation.secondaryTooltip == null
                                    ? Text(
                                      secondary,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color:
                                            isActive
                                                ? Colors.white54
                                                : Colors.white38,
                                        fontSize: 12,
                                      ),
                                    )
                                    : Tooltip(
                                      message: presentation.secondaryTooltip!,
                                      child: Text(
                                        secondary,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color:
                                              isActive
                                                  ? Colors.white54
                                                  : Colors.white38,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                          ),
                        ],
                        if (showSessionShortcutHints && index < 9) ...[
                          const SizedBox(width: 8),
                          ShellShortcutHintBadge(
                            key: ValueKey(
                              'session-shortcut-hint-${session.id}',
                            ),
                            label: '${index + 1}',
                          ),
                        ],
                        if (status != null) ...[
                          const SizedBox(width: 8),
                          SessionStatusDot(
                            key: ValueKey('session-tab-status-${session.id}'),
                            status: status,
                            semanticIdentifier:
                                'session-tab-status-${session.id}',
                          ),
                        ],
                        const SizedBox(width: 4),
                        IconButton(
                          key: ValueKey('session-close-button-${session.id}'),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(
                            width: 20,
                            height: 20,
                          ),
                          splashRadius: 12,
                          tooltip: 'Close session',
                          onPressed: () => closeCurrentSession(session),
                          icon: Icon(
                            Icons.close,
                            size: 14,
                            color: isActive ? Colors.white54 : Colors.white24,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _showTabContextMenu(
    BuildContext context,
    WidgetRef ref,
    Session session,
    Offset position,
  ) {
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      color: const Color(0xFF252525),
      items: [
        PopupMenuItem<String>(
          value: 'mark_unread',
          height: 36,
          child: Row(
            children: [
              Icon(
                session.hasAttention
                    ? Icons.mark_email_read
                    : Icons.mark_email_unread,
                size: 14,
                color: Colors.white54,
              ),
              const SizedBox(width: 8),
              Text(
                session.hasAttention ? 'Mark as Read' : 'Mark as Unread',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    ).then((value) {
      if (value == 'mark_unread') {
        if (session.hasAttention) {
          ref
              .read(serverProvider.notifier)
              .ackSessionAttention(session.id);
        } else {
          ref
              .read(serverProvider.notifier)
              .markSessionBell(session.id);
        }
      }
    });
  }
}
