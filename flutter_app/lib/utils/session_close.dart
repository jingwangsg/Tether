import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/session.dart';
import '../providers/server_provider.dart';
import '../providers/session_provider.dart';

Future<void> closeSession(WidgetRef ref, Session session) async {
  final selectedProjectId = ref.read(sessionProvider).selectedProjectId;
  final activeSessionId = ref.read(sessionProvider).activeSessionId;

  await ref.read(serverProvider.notifier).deleteSession(session.id);

  if (selectedProjectId == null || activeSessionId != session.id) {
    return;
  }

  final remaining =
      ref
          .read(serverProvider)
          .sessions
          .where((candidate) => candidate.groupId == selectedProjectId)
          .where((candidate) => candidate.id != session.id)
          .toList()
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

  if (remaining.isNotEmpty) {
    ref
        .read(sessionProvider.notifier)
        .setActiveSession(
          projectId: selectedProjectId,
          sessionId: remaining.first.id,
        );
  }
}
