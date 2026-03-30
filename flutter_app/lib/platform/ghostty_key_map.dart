import 'package:flutter/services.dart';

/// Maps Flutter LogicalKeyboardKey to ghostty key name strings.
/// These strings correspond to the key names in ghostty's C API.
/// See ghostty.h: ghostty_input_key_e
final Map<LogicalKeyboardKey, String> ghosttyKeyMap = {
  // Navigation
  LogicalKeyboardKey.arrowUp: 'up',
  LogicalKeyboardKey.arrowDown: 'down',
  LogicalKeyboardKey.arrowLeft: 'left',
  LogicalKeyboardKey.arrowRight: 'right',
  LogicalKeyboardKey.home: 'home',
  LogicalKeyboardKey.end: 'end',
  LogicalKeyboardKey.pageUp: 'page_up',
  LogicalKeyboardKey.pageDown: 'page_down',

  // Editing
  LogicalKeyboardKey.backspace: 'backspace',
  LogicalKeyboardKey.delete: 'delete',
  LogicalKeyboardKey.insert: 'insert',

  // Special
  LogicalKeyboardKey.enter: 'enter',
  LogicalKeyboardKey.tab: 'tab',
  LogicalKeyboardKey.escape: 'escape',
  LogicalKeyboardKey.space: 'space',

  // Function keys
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

/// Returns the ghostty modifier bitmask string for currently held modifiers.
/// Format: 'shift', 'ctrl', 'alt', 'super' (comma-separated if multiple)
String ghosttyModifiers({
  bool shift = false,
  bool ctrl = false,
  bool alt = false,
  bool meta = false,
}) {
  final mods = <String>[];
  if (shift) mods.add('shift');
  if (ctrl) mods.add('ctrl');
  if (alt) mods.add('alt');
  if (meta) mods.add('super');
  return mods.join(',');
}
