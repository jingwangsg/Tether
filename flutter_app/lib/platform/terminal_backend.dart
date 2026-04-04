import 'package:flutter/widgets.dart';
import '../providers/server_provider.dart';
import '../widgets/terminal/terminal_controller.dart';

/// Abstract interface for platform-specific terminal rendering.
/// macOS uses NativeBackend (Metal).
/// Android (future) uses TermuxBackend or XtermBackend.
abstract class TerminalBackend {
  Widget createTerminalWidget({
    Key? key,
    required String sessionId,
    required TerminalController controller,
    required ServerConfig? serverConfig,
    String? command,
    String? cwd,
    required bool isActive,
    VoidCallback? onSessionExited,
    void Function(String? title)? onTitleChanged,
    void Function(String? process, String? toolState)? onForegroundChanged,
  });

  bool get isLocalPty;
  String get platformId;
}
