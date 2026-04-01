import 'package:flutter/widgets.dart';
import 'terminal_backend.dart';
import '../widgets/terminal/terminal_view.dart';

/// macOS backend: renders via native Metal (local PTY).
class NativeBackend implements TerminalBackend {
  @override
  bool get isLocalPty => true;

  @override
  String get platformId => 'native';

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
    return TerminalView(
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
