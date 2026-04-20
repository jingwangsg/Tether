import 'package:flutter_riverpod/flutter_riverpod.dart';

class SessionState {
  final String? selectedProjectId;
  final Map<String, String> activeSessionIdByProject;

  const SessionState({
    this.selectedProjectId,
    this.activeSessionIdByProject = const {},
  });

  SessionState copyWith({
    String? selectedProjectId,
    bool clearSelectedProject = false,
    Map<String, String>? activeSessionIdByProject,
  }) {
    return SessionState(
      selectedProjectId:
          clearSelectedProject ? null : (selectedProjectId ?? this.selectedProjectId),
      activeSessionIdByProject:
          activeSessionIdByProject ?? this.activeSessionIdByProject,
    );
  }

  String? activeSessionIdFor(String? projectId) {
    if (projectId == null) {
      return null;
    }
    return activeSessionIdByProject[projectId];
  }

  String? get activeSessionId => activeSessionIdFor(selectedProjectId);
}

class SessionNotifier extends StateNotifier<SessionState> {
  SessionNotifier() : super(const SessionState());

  void selectProject(String? projectId) {
    if (projectId == state.selectedProjectId) {
      return;
    }
    state = state.copyWith(
      selectedProjectId: projectId,
      clearSelectedProject: projectId == null,
    );
  }

  void setActiveSession({
    required String projectId,
    required String sessionId,
    bool selectProject = true,
  }) {
    final nextMap = Map<String, String>.from(state.activeSessionIdByProject)
      ..[projectId] = sessionId;
    state = state.copyWith(
      selectedProjectId: selectProject ? projectId : state.selectedProjectId,
      activeSessionIdByProject: nextMap,
    );
  }

  void syncProjects(List<String> projectIds) {
    final validIds = projectIds.toSet();
    final nextMap = Map<String, String>.fromEntries(
      state.activeSessionIdByProject.entries.where((entry) => validIds.contains(entry.key)),
    );
    final nextSelected =
        validIds.contains(state.selectedProjectId) ? state.selectedProjectId : projectIds.firstOrNull;
    state = SessionState(
      selectedProjectId: nextSelected,
      activeSessionIdByProject: nextMap,
    );
  }

  void cleanupSessions(Set<String> validSessionIds) {
    final nextMap = <String, String>{};
    for (final entry in state.activeSessionIdByProject.entries) {
      if (validSessionIds.contains(entry.value)) {
        nextMap[entry.key] = entry.value;
      }
    }
    state = state.copyWith(activeSessionIdByProject: nextMap);
  }
}

final sessionProvider =
    StateNotifierProvider<SessionNotifier, SessionState>((ref) => SessionNotifier());
