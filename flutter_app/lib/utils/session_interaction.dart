import '../models/group.dart';
import '../models/session.dart';

Group? groupForSession(Session session, Iterable<Group> groups) {
  return groups.where((group) => group.id == session.groupId).firstOrNull;
}

bool isDeadLocalSession(Session session, Iterable<Group> groups) {
  final group = groupForSession(session, groups);
  return !session.isAlive && !(group?.isRemote ?? false);
}

bool isSessionInteractive(Session session, Iterable<Group> groups) {
  return !isDeadLocalSession(session, groups);
}

Set<String> interactiveSessionIds(
  Iterable<Session> sessions,
  Iterable<Group> groups,
) {
  return sessions
      .where((session) => isSessionInteractive(session, groups))
      .map((session) => session.id)
      .toSet();
}
