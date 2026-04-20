import '../models/session.dart';
import 'session_status.dart';

/// Aggregates the highest-priority [SessionIndicatorStatus] per project.
///
/// Callers must pass already-visible sessions (use [visibleSessions] first).
Map<String, SessionIndicatorStatus> summarizeProjectStatuses({
  required Iterable<Session> sessions,
  required String? selectedProjectId,
  required String? activeSessionId,
}) {
  final summary = <String, SessionIndicatorStatus>{};

  for (final session in sessions) {
    final status = deriveSessionIndicatorStatus(
      session,
      isActive:
          selectedProjectId == session.groupId &&
          activeSessionId == session.id,
    );
    if (status == null) {
      continue;
    }

    final previous = summary[session.groupId];
    if (previous == null || _priority(status) < _priority(previous)) {
      summary[session.groupId] = status;
    }
  }

  return summary;
}

int _priority(SessionIndicatorStatus status) {
  switch (status) {
    case SessionIndicatorStatus.attention:
      return 0;
    case SessionIndicatorStatus.waiting:
      return 1;
    case SessionIndicatorStatus.running:
      return 2;
  }
}
