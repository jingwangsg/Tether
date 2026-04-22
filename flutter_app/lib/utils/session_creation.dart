import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/group.dart';
import '../models/session.dart';
import '../providers/server_provider.dart';
import '../providers/session_provider.dart';
import 'shell_dialogs.dart';

List<Group> _topLevelProjects(List<Group> groups) =>
    groups.where((group) => group.parentId == null).toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

Group? _resolveTargetProject(WidgetRef ref, {Group? preferredProject}) {
  if (preferredProject != null) {
    return preferredProject;
  }

  final serverState = ref.read(serverProvider);
  final projects = _topLevelProjects(serverState.groups);
  final selectedProjectId = ref.read(sessionProvider).selectedProjectId;

  return projects
          .where((project) => project.id == selectedProjectId)
          .firstOrNull ??
      projects.firstOrNull;
}

Future<Session?> createSessionInCurrentProject(
  BuildContext context,
  WidgetRef ref, {
  Group? preferredProject,
}) async {
  var project = _resolveTargetProject(ref, preferredProject: preferredProject);
  if (project == null) {
    project = await showCreateProjectDialog(context);
    if (project == null || !context.mounted) {
      return null;
    }
  }

  final session = await ref
      .read(serverProvider.notifier)
      .createSession(groupId: project.id);

  if (!context.mounted) {
    return session;
  }

  ref.read(sessionProvider.notifier)
    ..selectProject(project.id)
    ..setActiveSession(projectId: project.id, sessionId: session.id);
  return session;
}
