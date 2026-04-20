import '../models/group.dart';
import '../models/session.dart';
import '../models/ssh_host.dart';

class ServerSnapshotDiff {
  final List<Group> groups;
  final List<Session> mergedSessions;
  final List<SshHost> sshHosts;
  final bool groupsChanged;
  final bool groupsStructureChanged;
  final bool sessionsChanged;
  final bool sessionsStructureChanged;
  final bool sshHostsChanged;

  const ServerSnapshotDiff({
    required this.groups,
    required this.mergedSessions,
    required this.sshHosts,
    required this.groupsChanged,
    required this.groupsStructureChanged,
    required this.sessionsChanged,
    required this.sessionsStructureChanged,
    required this.sshHostsChanged,
  });

  bool get hasChanges => groupsChanged || sessionsChanged || sshHostsChanged;
}

ServerSnapshotDiff diffServerSnapshot({
  required List<Group> currentGroups,
  required List<Session> currentSessions,
  required List<SshHost> currentSshHosts,
  required List<Group> refreshedGroups,
  required List<Session> refreshedSessions,
  required List<SshHost> refreshedSshHosts,
}) {
  final mergedSessions =
      refreshedSessions.map((session) {
        final current =
            currentSessions.where((item) => item.id == session.id).firstOrNull;
        var merged = session;

        if (session.foregroundProcess == null && current?.foregroundProcess != null) {
          merged = merged.copyWith(
            foregroundProcess: current!.foregroundProcess,
            oscTitle: current.oscTitle,
          );
        }

        if (current != null &&
            (current.attentionSeq > merged.attentionSeq ||
                current.attentionAckSeq > merged.attentionAckSeq)) {
          merged = merged.copyWith(
            attentionSeq:
                current.attentionSeq > merged.attentionSeq
                    ? current.attentionSeq
                    : merged.attentionSeq,
            attentionAckSeq:
                current.attentionAckSeq > merged.attentionAckSeq
                    ? current.attentionAckSeq
                    : merged.attentionAckSeq,
          );
        }

        return merged;
      }).toList();

  final groupsChanged = !_groupsEqual(currentGroups, refreshedGroups);
  final sessionsChanged = !_sessionsRenderEqual(currentSessions, refreshedSessions);
  final sessionsStructureChanged =
      !_sessionsStructureEqual(currentSessions, mergedSessions);
  final sshHostsChanged = !_sshHostsEqual(currentSshHosts, refreshedSshHosts);

  return ServerSnapshotDiff(
    groups: refreshedGroups,
    mergedSessions: mergedSessions,
    sshHosts: refreshedSshHosts,
    groupsChanged: groupsChanged,
    groupsStructureChanged: groupsChanged,
    sessionsChanged: sessionsChanged,
    sessionsStructureChanged: sessionsStructureChanged,
    sshHostsChanged: sshHostsChanged,
  );
}

bool _groupsEqual(List<Group> a, List<Group> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    final ga = a[i], gb = b[i];
    if (ga.id != gb.id ||
        ga.name != gb.name ||
        ga.parentId != gb.parentId ||
        ga.sortOrder != gb.sortOrder ||
        ga.defaultCwd != gb.defaultCwd ||
        ga.sshHost != gb.sshHost) {
      return false;
    }
  }
  return true;
}

bool _sessionsRenderEqual(List<Session> a, List<Session> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    final sa = a[i], sb = b[i];
    if (sa.id != sb.id ||
        sa.groupId != sb.groupId ||
        sa.name != sb.name ||
        sa.shell != sb.shell ||
        sa.cols != sb.cols ||
        sa.rows != sb.rows ||
        sa.cwd != sb.cwd ||
        sa.isAlive != sb.isAlive ||
        sa.sortOrder != sb.sortOrder ||
        sa.foregroundProcess != sb.foregroundProcess ||
        sa.oscTitle != sb.oscTitle ||
        sa.attentionSeq != sb.attentionSeq ||
        sa.attentionAckSeq != sb.attentionAckSeq) {
      return false;
    }
  }
  return true;
}

bool _sessionsStructureEqual(List<Session> a, List<Session> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    final sa = a[i], sb = b[i];
    if (sa.id != sb.id ||
        sa.groupId != sb.groupId ||
        sa.name != sb.name ||
        sa.shell != sb.shell ||
        sa.cols != sb.cols ||
        sa.rows != sb.rows ||
        sa.cwd != sb.cwd ||
        sa.isAlive != sb.isAlive ||
        sa.sortOrder != sb.sortOrder) {
      return false;
    }
  }
  return true;
}

bool _sshHostsEqual(List<SshHost> a, List<SshHost> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    final ha = a[i], hb = b[i];
    if (ha.host != hb.host ||
        ha.hostname != hb.hostname ||
        ha.user != hb.user ||
        ha.port != hb.port ||
        ha.reachable != hb.reachable) {
      return false;
    }
  }
  return true;
}
