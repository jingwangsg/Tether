import 'package:flutter/widgets.dart';

class TerminalController {
  void Function(String text)? _sendText;
  void Function(String text)? _paste;
  VoidCallback? _showSearch;
  VoidCallback? _copy;
  void Function(String action)? _performAction;

  void attach({
    required void Function(String text) sendText,
    required void Function(String text) paste,
    required VoidCallback showSearch,
    VoidCallback? copy,
    void Function(String action)? performAction,
  }) {
    _sendText = sendText;
    _paste = paste;
    _showSearch = showSearch;
    _copy = copy;
    _performAction = performAction;
  }

  void detach() {
    _sendText = null;
    _paste = null;
    _showSearch = null;
    _copy = null;
    _performAction = null;
  }

  void sendText(String text) => _sendText?.call(text);

  void paste(String text) => _paste?.call(text);

  void showSearch() => _showSearch?.call();

  void copy() => _copy?.call();

  void performAction(String action) => _performAction?.call(action);
}
