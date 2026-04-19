import 'package:flutter_test/flutter_test.dart';
import 'package:tether/providers/session_provider.dart';

void main() {
  group('SessionNotifier project scope', () {
    test('selectProject exposes the remembered active session for that project', () {
      final notifier = SessionNotifier()
        ..setActiveSession(projectId: 'alpha', sessionId: 'alpha-1')
        ..setActiveSession(projectId: 'beta', sessionId: 'beta-1')
        ..selectProject('alpha');

      expect(notifier.state.selectedProjectId, 'alpha');
      expect(notifier.state.activeSessionId, 'alpha-1');

      notifier.selectProject('beta');

      expect(notifier.state.selectedProjectId, 'beta');
      expect(notifier.state.activeSessionId, 'beta-1');
    });

    test('syncProjects falls back to the first surviving project', () {
      final notifier = SessionNotifier()
        ..setActiveSession(projectId: 'beta', sessionId: 'beta-1')
        ..selectProject('beta');

      notifier.syncProjects(['alpha']);

      expect(notifier.state.selectedProjectId, 'alpha');
      expect(notifier.state.activeSessionId, isNull);
    });

    test('cleanupSessions clears only stale remembered sessions', () {
      final notifier = SessionNotifier()
        ..setActiveSession(projectId: 'alpha', sessionId: 'alpha-1')
        ..setActiveSession(projectId: 'beta', sessionId: 'beta-1')
        ..selectProject('beta');

      notifier.cleanupSessions({'alpha-1'});

      expect(notifier.state.activeSessionIdFor('alpha'), 'alpha-1');
      expect(notifier.state.activeSessionIdFor('beta'), isNull);
      expect(notifier.state.activeSessionId, isNull);
    });
  });
}
