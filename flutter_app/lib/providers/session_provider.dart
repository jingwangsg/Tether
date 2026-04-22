import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../utils/debug_log.dart';
import '../utils/test_event_logger.dart';

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
    TestEventLogger.instance.log('project_selected', {
      'project_id': projectId,
      'active_session_id': state.activeSessionId,
    });
  }

  void setActiveSession({
    required String projectId,
    required String sessionId,
    bool selectProject = true,
  }) {
    final nextMap = Map<String, String>.from(state.activeSessionIdByProject)
      ..[projectId] = sessionId;
    final nextSelected = selectProject ? projectId : state.selectedProjectId;
    if (nextSelected == state.selectedProjectId &&
        _sameRememberedSessions(nextMap, state.activeSessionIdByProject)) {
      return;
    }
    state = state.copyWith(
      selectedProjectId: nextSelected,
      activeSessionIdByProject: nextMap,
    );
    TestEventLogger.instance.log('active_session_selected', {
      'project_id': projectId,
      'session_id': sessionId,
      'selected_project_id': state.selectedProjectId,
    });
  }

  void syncProjects(List<String> projectIds) {
    final validIds = projectIds.toSet();
    final nextMap = Map<String, String>.fromEntries(
      state.activeSessionIdByProject.entries.where((entry) => validIds.contains(entry.key)),
    );
    final nextSelected =
        validIds.contains(state.selectedProjectId) ? state.selectedProjectId : projectIds.firstOrNull;

    if (nextSelected == state.selectedProjectId &&
        _sameRememberedSessions(nextMap, state.activeSessionIdByProject)) {
      return;
    }

    debugLog('[SWITCH:session] syncProjects selected: ${state.selectedProjectId?.substring(0, 8)} -> ${nextSelected?.substring(0, 8)} projectCount=${projectIds.length}');
    state = SessionState(
      selectedProjectId: nextSelected,
      activeSessionIdByProject: nextMap,
    );
  }

  void cleanupSessions(Set<String> validSessionIds) {
    final nextMap = <String, String>{};
    final removedEntries = <String, String>{};
    for (final entry in state.activeSessionIdByProject.entries) {
      if (validSessionIds.contains(entry.value)) {
        nextMap[entry.key] = entry.value;
      } else {
        removedEntries[entry.key] = entry.value;
      }
    }

    if (_sameRememberedSessions(nextMap, state.activeSessionIdByProject)) {
      return;
    }

    debugLog('[SWITCH:session] cleanupSessions removed=$removedEntries remaining=$nextMap validCount=${validSessionIds.length} activeSessionId=${state.activeSessionId?.substring(0, 8)}');
    state = state.copyWith(activeSessionIdByProject: nextMap);
  }
}

bool _sameRememberedSessions(Map<String, String> a, Map<String, String> b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}

final sessionProvider =
    StateNotifierProvider<SessionNotifier, SessionState>((ref) => SessionNotifier());
