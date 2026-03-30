// Demo 5 — Flutter + libghostty + MethodChannel input.
// Full integration: Ghostty terminal inside Flutter PlatformView.
//
// Success criteria:
//   - Terminal renders inside Flutter window
//   - Typing printable chars works
//   - Tab completion works
//   - Ctrl+C works
//   - Cmd+V pastes correctly
//   - Resize works
//
// Run: flutter run -d macos (from demos/demo5_integration/)
// Requires: ghostty libs in macos/Runner/ghostty/ + Xcode project configured.

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const Demo5App());
}

class Demo5App extends StatelessWidget {
  const Demo5App({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Demo 5 — Ghostty in Flutter',
      debugShowCheckedModeBanner: false,
      home: _Demo5Home(),
    );
  }
}

class _Demo5Home extends StatefulWidget {
  const _Demo5Home();

  @override
  State<_Demo5Home> createState() => _Demo5HomeState();
}

class _Demo5HomeState extends State<_Demo5Home> {
  static const _inputChannel = MethodChannel('dev.tether/ghostty_input');
  static const _pasteChannel = MethodChannel('dev.tether/paste');

  int? _viewId;
  String _title = 'Demo 5 — Ghostty in Flutter';

  @override
  void initState() {
    super.initState();
    _pasteChannel.setMethodCallHandler(_handlePaste);
  }

  Future<dynamic> _handlePaste(MethodCall call) async {
    if (call.method == 'pasteText' && _viewId != null) {
      final text = call.arguments['text'] as String? ?? '';
      await _inputChannel.invokeMethod('sendText', {
        'viewId': _viewId,
        'text': text,
      });
    }
  }

  void _onPlatformViewCreated(int viewId) {
    _viewId = viewId;
    final eventChannel = EventChannel('dev.tether/ghostty_events/$viewId');
    eventChannel.receiveBroadcastStream().listen((event) {
      if (event is Map) {
        if (event['type'] == 'title') {
          setState(() => _title = event['value'] as String? ?? _title);
        }
      }
    });
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (_viewId == null) return KeyEventResult.ignored;

    final hw = HardwareKeyboard.instance;
    final ctrl = hw.isControlPressed;
    final meta = hw.isMetaPressed;

    // Let Cmd shortcuts through to the system
    if (meta) return KeyEventResult.ignored;

    final key = event.logicalKey;

    // Printable characters (no ctrl)
    if (!ctrl) {
      final char = key.keyLabel;
      if (char.length == 1) {
        _inputChannel.invokeMethod('sendText', {'viewId': _viewId, 'text': char});
        return KeyEventResult.handled;
      }
    }

    // Ctrl+letter → control char
    if (ctrl) {
      final char = key.keyLabel;
      if (char.length == 1) {
        final code = char.toUpperCase().codeUnits.first - 64;
        if (code >= 1 && code <= 26) {
          _inputChannel.invokeMethod('sendText', {
            'viewId': _viewId,
            'text': String.fromCharCode(code),
          });
          return KeyEventResult.handled;
        }
      }
    }

    // Special keys
    final specialKeys = {
      LogicalKeyboardKey.arrowUp: 'up',
      LogicalKeyboardKey.arrowDown: 'down',
      LogicalKeyboardKey.arrowLeft: 'left',
      LogicalKeyboardKey.arrowRight: 'right',
      LogicalKeyboardKey.enter: 'enter',
      LogicalKeyboardKey.tab: 'tab',
      LogicalKeyboardKey.escape: 'escape',
      LogicalKeyboardKey.backspace: 'backspace',
      LogicalKeyboardKey.delete: 'delete',
      LogicalKeyboardKey.home: 'home',
      LogicalKeyboardKey.end: 'end',
      LogicalKeyboardKey.pageUp: 'page_up',
      LogicalKeyboardKey.pageDown: 'page_down',
    };
    if (specialKeys.containsKey(key)) {
      _inputChannel.invokeMethod('sendKey', {
        'viewId': _viewId,
        'key': specialKeys[key],
        'modifiers': ctrl ? 'ctrl' : '',
      });
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        autofocus: true,
        onKeyEvent: _handleKey,
        child: Column(
          children: [
            // Title bar
            Container(
              height: 32,
              color: const Color(0xFF1E1E1E),
              alignment: Alignment.center,
              child: Text(
                _title,
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),
            // Terminal
            Expanded(
              child: Platform.isMacOS
                  ? AppKitView(
                      viewType: 'dev.tether/ghostty_surface',
                      onPlatformViewCreated: _onPlatformViewCreated,
                      creationParams: <String, dynamic>{
                        'sessionId': 'demo5',
                        'command': '',
                        'cwd': '',
                      },
                      creationParamsCodec: const StandardMessageCodec(),
                    )
                  : const Center(
                      child: Text(
                        'macOS only',
                        style: TextStyle(color: Colors.white54),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
