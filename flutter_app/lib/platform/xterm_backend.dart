import 'package:flutter/widgets.dart';
import 'terminal_backend.dart';
import '../widgets/terminal/xterm_terminal_view.dart';

/// WebSocket backend: connects to server-managed PTY via WebSocket.
/// PTY lifecycle is tied to the server process, not the Flutter app —
/// sessions survive frontend restarts as long as the server keeps running.
class XtermBackend implements TerminalBackend {
  @override
  bool get isLocalPty => false;

  @override
  String get platformId => 'xterm';

  @override
  Widget createTerminalWidget({
    Key? key,
    required String sessionId,
    String? command,  // ignored: server already knows the shell from DB
    String? cwd,      // ignored: server already knows the cwd from DB
    required bool isActive,
    VoidCallback? onSessionExited,
    void Function(String? title)? onTitleChanged,
  }) {
    return XtermTerminalView(
      key: key,
      sessionId: sessionId,
      isActive: isActive,
      onSessionExited: onSessionExited,
      onTitleChanged: onTitleChanged,
    );
  }
}
