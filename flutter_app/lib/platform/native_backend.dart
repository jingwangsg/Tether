import 'package:flutter/widgets.dart';
import 'dart:typed_data';
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
  int get retainedTerminalViewCap => 50;

  @override
  Widget createTerminalWidget({
    Key? key,
    required String sessionId,
    required TerminalController controller,
    required ServerConfig? serverConfig,
    String? command,
    String? cwd,
    required bool isActive,
    bool isVisibleInUI = true,
    bool imagePasteBridgeEnabled = false,
    VoidCallback? onSessionExited,
    ForegroundChangedCallback? onForegroundChanged,
    void Function(String title, String body)? onBell,
    Future<void> Function(Uint8List data, String mimeType)? onClipboardImage,
  }) {
    return TerminalView(
      key: key,
      sessionId: sessionId,
      controller: controller,
      serverConfig: serverConfig,
      isActive: isActive,
      isVisibleInUI: isVisibleInUI,
      imagePasteBridgeEnabled: imagePasteBridgeEnabled,
      onSessionExited: onSessionExited,
      onForegroundChanged: onForegroundChanged,
      onBell: onBell,
      onClipboardImage: onClipboardImage,
    );
  }
}
