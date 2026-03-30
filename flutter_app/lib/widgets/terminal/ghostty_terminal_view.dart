import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Renders a Ghostty terminal surface inside a Flutter PlatformView (macOS).
///
/// Keyboard input:
///   - Printable chars → MethodChannel sendText
///   - Special keys → MethodChannel sendKey (key name + modifiers)
/// Resize is automatic: AppKitView propagates frame changes to Swift which
/// calls ghostty_surface_set_size().
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
    return Focus(
      autofocus: widget.isActive,
      onKeyEvent: _handleKeyEvent,
      child: _buildPlatformView(),
    );
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

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final hw = HardwareKeyboard.instance;
    final ctrl = hw.isControlPressed;
    final shift = hw.isShiftPressed;
    final alt = hw.isAltPressed;
    final meta = hw.isMetaPressed;

    // Let Cmd+C/V/X be handled by the system / PasteService
    if (meta) return KeyEventResult.ignored;

    final key = event.logicalKey;

    // Printable character (no ctrl)
    if (!ctrl && !alt) {
      final char = key.keyLabel;
      if (char.length == 1) {
        sendText(char);
        return KeyEventResult.handled;
      }
    }

    // Ctrl+letter → control character
    if (ctrl && !alt) {
      final char = key.keyLabel;
      if (char.length == 1) {
        final code = char.toUpperCase().codeUnitAt(0) - 64;
        if (code >= 1 && code <= 26) {
          sendText(String.fromCharCode(code));
          return KeyEventResult.handled;
        }
      }
    }

    // Special keys (arrows, function keys, etc.)
    final specialKeys = <LogicalKeyboardKey, String>{
      LogicalKeyboardKey.arrowUp: 'up',
      LogicalKeyboardKey.arrowDown: 'down',
      LogicalKeyboardKey.arrowLeft: 'left',
      LogicalKeyboardKey.arrowRight: 'right',
      LogicalKeyboardKey.home: 'home',
      LogicalKeyboardKey.end: 'end',
      LogicalKeyboardKey.pageUp: 'page_up',
      LogicalKeyboardKey.pageDown: 'page_down',
      LogicalKeyboardKey.backspace: 'backspace',
      LogicalKeyboardKey.delete: 'delete',
      LogicalKeyboardKey.insert: 'insert',
      LogicalKeyboardKey.enter: 'enter',
      LogicalKeyboardKey.tab: 'tab',
      LogicalKeyboardKey.escape: 'escape',
      LogicalKeyboardKey.f1: 'f1',
      LogicalKeyboardKey.f2: 'f2',
      LogicalKeyboardKey.f3: 'f3',
      LogicalKeyboardKey.f4: 'f4',
      LogicalKeyboardKey.f5: 'f5',
      LogicalKeyboardKey.f6: 'f6',
      LogicalKeyboardKey.f7: 'f7',
      LogicalKeyboardKey.f8: 'f8',
      LogicalKeyboardKey.f9: 'f9',
      LogicalKeyboardKey.f10: 'f10',
      LogicalKeyboardKey.f11: 'f11',
      LogicalKeyboardKey.f12: 'f12',
    };

    if (specialKeys.containsKey(key)) {
      final mods = <String>[];
      if (shift) mods.add('shift');
      if (ctrl) mods.add('ctrl');
      if (alt) mods.add('alt');
      sendKey(specialKeys[key]!, modifiers: mods.join(','));
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }
}
