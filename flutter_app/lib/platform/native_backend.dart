import 'package:flutter/widgets.dart';
import 'terminal_backend.dart';
import '../providers/server_provider.dart';
import '../widgets/terminal/terminal_controller.dart';
import '../widgets/terminal/terminal_view.dart';

/// macOS backend: renders via native Ghostty while tether-server owns the PTY.
class NativeBackend implements TerminalBackend {
  @override
  bool get isLocalPty => false;

  @override
  String get platformId => 'native';

  @override
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
  }) {
    return TerminalView(
      key: key,
      sessionId: sessionId,
      controller: controller,
      serverConfig: serverConfig,
      isActive: isActive,
      onSessionExited: onSessionExited,
      onTitleChanged: onTitleChanged,
      onForegroundChanged: onForegroundChanged,
    );
  }
}
