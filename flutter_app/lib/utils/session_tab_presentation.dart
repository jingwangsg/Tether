import '../models/session.dart';

class SessionTabPresentation {
  final String primaryTitle;
  final String? secondaryLabel;

  const SessionTabPresentation({
    required this.primaryTitle,
    this.secondaryLabel,
  });
}

SessionTabPresentation deriveSessionTabPresentation(
  Session session,
  Map<String, String> sessionTitles,
) {
  switch (session.foregroundProcess) {
    case 'claude':
      return SessionTabPresentation(
        primaryTitle: 'Claude Code',
        secondaryLabel: sessionTitles[session.id] ?? session.name,
      );
    case 'codex':
      return SessionTabPresentation(
        primaryTitle: 'Codex',
        secondaryLabel: sessionTitles[session.id] ?? session.name,
      );
    default:
      return SessionTabPresentation(
        primaryTitle: sessionTitles[session.id] ?? session.name,
        secondaryLabel: null,
      );
  }
}
