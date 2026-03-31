import 'package:flutter/widgets.dart';
import 'terminal_backend.dart';
import '../widgets/terminal/ghostty_terminal_view.dart';

/// macOS backend: renders via libghostty (Metal, local PTY).
class GhosttyBackend implements TerminalBackend {
  @override
  bool get isLocalPty => true;

  @override
  String get platformId => 'ghostty';

  @override
  Widget createTerminalWidget({
    Key? key,
    required String sessionId,
    String? command,
    String? cwd,
    required bool isActive,
    VoidCallback? onSessionExited,
    void Function(String? title)? onTitleChanged,
  }) {
    return GhosttyTerminalView(
      key: key,
      sessionId: sessionId,
      command: command,
      cwd: cwd,
      isActive: isActive,
      onSessionExited: onSessionExited,
      onTitleChanged: onTitleChanged,
    );
  }
}
