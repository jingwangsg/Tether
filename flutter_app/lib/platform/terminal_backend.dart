import 'package:flutter/widgets.dart';

/// Abstract interface for platform-specific terminal rendering.
/// macOS uses GhosttyBackend (libghostty + Metal).
/// Android (future) uses TermuxBackend or XtermBackend.
abstract class TerminalBackend {
  Widget createTerminalWidget({
    required String sessionId,
    String? command,
    String? cwd,
    required bool isActive,
    VoidCallback? onSessionExited,
    void Function(String? title)? onTitleChanged,
  });

  bool get isLocalPty;
  String get platformId;
}
