import 'package:flutter/services.dart';

/// Receives paste: selector events forwarded from native macOS code.
class PasteService {
  static const _channel = MethodChannel('dev.tether/paste');
  void Function(String text)? onPaste;

  PasteService() {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    if (call.method == 'pasteText') {
      final text = call.arguments['text'] as String?;
      if (text != null) {
        onPaste?.call(text);
      }
    }
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
  }
}
