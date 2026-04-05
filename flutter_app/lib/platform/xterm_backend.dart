import 'package:flutter/widgets.dart';
import 'terminal_backend.dart';
import '../providers/server_provider.dart';
import '../widgets/terminal/terminal_controller.dart';
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
    required TerminalController controller,
    required ServerConfig? serverConfig,
    String? command, // ignored: server already knows the shell from DB
    String? cwd, // ignored: server already knows the cwd from DB
    required bool isActive,
    VoidCallback? onSessionExited,
    void Function(String? title)? onTitleChanged,
    ForegroundChangedCallback? onForegroundChanged,
  }) {
    return XtermTerminalView(
      key: key,
      sessionId: sessionId,
      controller: controller,
      isActive: isActive,
      onSessionExited: onSessionExited,
      onTitleChanged: onTitleChanged,
      onForegroundChanged: onForegroundChanged,
    );
  }
}
