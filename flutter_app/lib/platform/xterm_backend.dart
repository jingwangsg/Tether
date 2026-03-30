import 'package:flutter/widgets.dart';
import 'terminal_backend.dart';

/// Stub backend for Android/fallback. Not yet implemented.
class XtermBackend implements TerminalBackend {
  @override
  bool get isLocalPty => false;

  @override
  String get platformId => 'xterm';

  @override
  Widget createTerminalWidget({
    required String sessionId,
    String? command,
    String? cwd,
    required bool isActive,
    VoidCallback? onSessionExited,
    void Function(String? title)? onTitleChanged,
  }) {
    throw UnimplementedError('XtermBackend is not implemented for this platform');
  }
}
