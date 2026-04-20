import 'package:flutter/widgets.dart';
import 'dart:typed_data';
import '../providers/server_provider.dart';
import '../widgets/terminal/terminal_controller.dart';

typedef ForegroundChangedCallback =
    void Function(
      String? process,
      String? oscTitle,
      int attentionSeq,
      int attentionAckSeq,
    );

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
    bool imagePasteBridgeEnabled = false,
    VoidCallback? onSessionExited,
    ForegroundChangedCallback? onForegroundChanged,
    Future<void> Function(Uint8List data, String mimeType)? onClipboardImage,
  });

  bool get isLocalPty;
  String get platformId;
}
