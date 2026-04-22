import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/group.dart';
import '../../models/session.dart';
import '../../providers/server_provider.dart';
import '../../providers/session_provider.dart';

class NotificationBell extends ConsumerWidget {
  const NotificationBell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(serverProvider.select((s) => s.sessions));
    final groups = ref.watch(serverProvider.select((s) => s.groups));
    final attentionSessions =
        sessions.where((s) => s.hasAttention).toList(growable: false);
    final count = attentionSessions.length;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        IconButton(
          icon: Icon(
            count > 0 ? Icons.notifications_active : Icons.notifications_none,
            size: 18,
          ),
          color: count > 0 ? Colors.amber : Colors.white54,
          tooltip: count > 0 ? '$count unread' : 'No notifications',
          onPressed:
              count > 0
                  ? () => _showNotificationList(
                    context,
                    ref,
                    attentionSessions,
                    groups,
                  )
                  : null,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        ),
        if (count > 0)
          Positioned(
            right: 2,
            top: 2,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: const BoxDecoration(
                color: Colors.red,
                shape: BoxShape.circle,
              ),
              constraints: const BoxConstraints(minWidth: 14, minHeight: 14),
              child: Text(
                '$count',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
      ],
    );
  }

  void _showNotificationList(
    BuildContext context,
    WidgetRef ref,
    List<Session> attentionSessions,
    List<Group> groups,
  ) {
    final groupMap = {for (final g in groups) g.id: g};
    final button = context.findRenderObject() as RenderBox;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(
          Offset(0, button.size.height),
          ancestor: overlay,
        ),
        button.localToGlobal(
          button.size.bottomRight(Offset.zero),
          ancestor: overlay,
        ),
      ),
      Offset.zero & overlay.size,
    );

    showMenu<String>(
      context: context,
      position: position,
      color: const Color(0xFF252525),
      constraints: const BoxConstraints(maxWidth: 320, maxHeight: 400),
      items: [
        for (final session in attentionSessions)
          PopupMenuItem<String>(
            value: session.id,
            height: 44,
            child: Row(
              children: [
                const Icon(
                  Icons.notifications_active,
                  size: 14,
                  color: Colors.amber,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        session.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        groupMap[session.groupId]?.name ?? '',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        const PopupMenuItem<String>(
          value: '__clear_all__',
          height: 36,
          child: Center(
            child: Text(
              'Clear All',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ),
        ),
      ],
    ).then((value) {
      if (value == null) return;
      if (value == '__clear_all__') {
        _clearAll(ref, attentionSessions);
        return;
      }
      _jumpToSession(ref, value, attentionSessions, groups);
    });
  }

  void _jumpToSession(
    WidgetRef ref,
    String sessionId,
    List<Session> sessions,
    List<Group> groups,
  ) {
    final session = sessions.where((s) => s.id == sessionId).firstOrNull;
    if (session == null) return;
    ref.read(sessionProvider.notifier)
      ..selectProject(session.groupId)
      ..setActiveSession(projectId: session.groupId, sessionId: session.id);
  }

  void _clearAll(WidgetRef ref, List<Session> sessions) {
    for (final session in sessions) {
      ref.read(serverProvider.notifier).ackSessionAttention(session.id);
    }
  }
}
