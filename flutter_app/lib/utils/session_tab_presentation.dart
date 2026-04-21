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
  final secondary =
      (session.foregroundProcess == 'claude' ||
              session.foregroundProcess == 'codex') &&
              session.oscTitle != null &&
              session.oscTitle!.isNotEmpty
          ? session.oscTitle
          : null;

  return SessionTabPresentation(
    primaryTitle: session.name,
    secondaryLabel: secondary,
  );
}
