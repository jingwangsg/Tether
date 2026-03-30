import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Renders a Ghostty terminal surface inside a Flutter PlatformView (macOS).
///
/// Keyboard input is handled entirely at the AppKit level (Swift side):
///   mouseDown: → first responder → keyDown: / NSTextInputClient.insertText:
/// This widget only handles paste (via sendText MethodChannel).
///
/// EventChannel receives:
///   {type: "title", value: "..."} → onTitleChanged
///   {type: "exited"}             → onSessionExited
class GhosttyTerminalView extends StatefulWidget {
  final String sessionId;
  final String? command;
  final String? cwd;
  final bool isActive;
  final VoidCallback? onSessionExited;
  final void Function(String? title)? onTitleChanged;

  const GhosttyTerminalView({
    super.key,
    required this.sessionId,
    this.command,
    this.cwd,
    required this.isActive,
    this.onSessionExited,
    this.onTitleChanged,
  });

  @override
  State<GhosttyTerminalView> createState() => GhosttyTerminalViewState();
}

class GhosttyTerminalViewState extends State<GhosttyTerminalView> {
  static const _viewType = 'dev.tether/ghostty_surface';
  static const _inputChannel = MethodChannel('dev.tether/ghostty_input');

  int? _viewId;
  EventChannel? _eventChannel;

  @override
  void didUpdateWidget(GhosttyTerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive != widget.isActive && _viewId != null) {
      _inputChannel.invokeMethod('setActive', {
        'viewId': _viewId,
        'active': widget.isActive,
      });
    }
  }

  void _onPlatformViewCreated(int viewId) {
    _viewId = viewId;
    _eventChannel = EventChannel('dev.tether/ghostty_events/$viewId');
    _eventChannel!.receiveBroadcastStream().listen(_onEvent);

    if (!widget.isActive) {
      _inputChannel.invokeMethod('setActive', {
        'viewId': viewId,
        'active': false,
      });
    }
  }

  void _onEvent(dynamic event) {
    if (event is! Map) return;
    final type = event['type'] as String?;
    switch (type) {
      case 'title':
        widget.onTitleChanged?.call(event['value'] as String?);
      case 'exited':
        widget.onSessionExited?.call();
    }
  }

  /// Send raw text (printable characters, paste) to the terminal.
  void sendText(String text) {
    if (_viewId == null) return;
    _inputChannel.invokeMethod('sendText', {
      'viewId': _viewId,
      'text': text,
    });
  }

  /// Send a named key with modifiers (arrows, function keys, etc.).
  void sendKey(String keyName, {String modifiers = ''}) {
    if (_viewId == null) return;
    _inputChannel.invokeMethod('sendKey', {
      'viewId': _viewId,
      'key': keyName,
      'modifiers': modifiers,
    });
  }

  /// Paste text with bracketed paste if the terminal supports it.
  void paste(String text) => sendText(text);

  @override
  Widget build(BuildContext context) {
    return _buildPlatformView();
  }

  Widget _buildPlatformView() {
    if (!Platform.isMacOS) {
      return const Center(
        child: Text(
          'Ghostty terminal is only supported on macOS',
          style: TextStyle(color: Colors.white54),
        ),
      );
    }

    return AppKitView(
      viewType: _viewType,
      onPlatformViewCreated: _onPlatformViewCreated,
      creationParams: {
        'sessionId': widget.sessionId,
        if (widget.command != null) 'command': widget.command!,
        if (widget.cwd != null) 'cwd': widget.cwd!,
      },
      creationParamsCodec: const StandardMessageCodec(),
    );
  }

}
