import 'package:flutter_riverpod/flutter_riverpod.dart';

class OpenTab {
  final String sessionId;

  const OpenTab({required this.sessionId});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OpenTab && sessionId == other.sessionId;

  @override
  int get hashCode => sessionId.hashCode;
}

class SessionState {
  final String? activeSessionId;
  final List<OpenTab> openTabs;

  const SessionState({
    this.activeSessionId,
    this.openTabs = const [],
  });

  SessionState copyWith({
    String? activeSessionId,
    List<OpenTab>? openTabs,
    bool clearActive = false,
  }) {
    return SessionState(
      activeSessionId: clearActive ? null : (activeSessionId ?? this.activeSessionId),
      openTabs: openTabs ?? this.openTabs,
    );
  }
}

class SessionNotifier extends StateNotifier<SessionState> {
  SessionNotifier() : super(const SessionState());

  void openTab(String sessionId) {
    final tab = OpenTab(sessionId: sessionId);
    if (!state.openTabs.contains(tab)) {
      state = state.copyWith(
        openTabs: [...state.openTabs, tab],
        activeSessionId: sessionId,
      );
    } else {
      state = state.copyWith(activeSessionId: sessionId);
    }
  }

  void closeTab(String sessionId) {
    final tabs = state.openTabs.where((t) => t.sessionId != sessionId).toList();
    String? newActive = state.activeSessionId;

    if (state.activeSessionId == sessionId) {
      final oldIdx = state.openTabs.indexWhere((t) => t.sessionId == sessionId);
      if (tabs.isNotEmpty) {
        final newIdx = oldIdx.clamp(0, tabs.length - 1);
        newActive = tabs[newIdx].sessionId;
      } else {
        newActive = null;
      }
    }

    state = SessionState(
      activeSessionId: newActive,
      openTabs: tabs,
    );
  }

  void setActiveSession(String sessionId) {
    state = state.copyWith(activeSessionId: sessionId);
  }

  void reorderTabs(int oldIndex, int newIndex) {
    final tabs = List<OpenTab>.from(state.openTabs);
    final tab = tabs.removeAt(oldIndex);
    tabs.insert(newIndex, tab);
    state = state.copyWith(openTabs: tabs);
  }

  void cleanupStaleTabs(Set<String> validSessionIds) {
    final tabs = state.openTabs
        .where((t) => validSessionIds.contains(t.sessionId))
        .toList();

    if (tabs.length != state.openTabs.length) {
      String? active = state.activeSessionId;
      if (active != null && !validSessionIds.contains(active)) {
        active = tabs.isNotEmpty ? tabs.last.sessionId : null;
      }
      state = SessionState(activeSessionId: active, openTabs: tabs);
    }
  }
}

final sessionProvider = StateNotifierProvider<SessionNotifier, SessionState>((ref) {
  return SessionNotifier();
});
