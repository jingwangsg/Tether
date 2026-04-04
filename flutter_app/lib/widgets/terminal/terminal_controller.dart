import 'package:flutter/widgets.dart';

class TerminalController {
  void Function(String text)? _sendText;
  void Function(String text)? _paste;
  VoidCallback? _showSearch;

  void attach({
    required void Function(String text) sendText,
    required void Function(String text) paste,
    required VoidCallback showSearch,
  }) {
    _sendText = sendText;
    _paste = paste;
    _showSearch = showSearch;
  }

  void detach() {
    _sendText = null;
    _paste = null;
    _showSearch = null;
  }

  void sendText(String text) => _sendText?.call(text);

  void paste(String text) => _paste?.call(text);

  void showSearch() => _showSearch?.call();
}
