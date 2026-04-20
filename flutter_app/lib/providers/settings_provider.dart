import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/mobile_key.dart';

class TerminalSettings {
  static const double defaultFontSize = 14;

  final String fontFamily;
  final double fontSize;
  final List<MobileKey> customKeys;
  final String? globalHotkey;
  final bool scrollToBottomOnOutput;

  const TerminalSettings({
    this.fontFamily = 'MesloLGSNF',
    this.fontSize = defaultFontSize,
    this.customKeys = defaultCustomKeys,
    this.globalHotkey,
    this.scrollToBottomOnOutput = false,
  });

  TerminalSettings copyWith({
    String? fontFamily,
    double? fontSize,
    List<MobileKey>? customKeys,
    String? globalHotkey,
    bool clearHotkey = false,
    bool? scrollToBottomOnOutput,
  }) {
    return TerminalSettings(
      fontFamily: fontFamily ?? this.fontFamily,
      fontSize: fontSize ?? this.fontSize,
      customKeys: customKeys ?? this.customKeys,
      globalHotkey: clearHotkey ? null : (globalHotkey ?? this.globalHotkey),
      scrollToBottomOnOutput:
          scrollToBottomOnOutput ?? this.scrollToBottomOnOutput,
    );
  }
}

class SettingsNotifier extends StateNotifier<TerminalSettings> {
  SettingsNotifier() : super(const TerminalSettings()) {
    _load();
  }

  static const _keyFontFamily = 'terminal_font_family';
  static const _keyFontSize = 'terminal_font_size';
  static const _keyCustomKeys = 'custom_mobile_keys';
  static const _keyGlobalHotkey = 'global_hotkey';
  static const _keyScrollToBottomOnOutput = 'scroll_to_bottom_on_output';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final fontFamily = prefs.getString(_keyFontFamily);
    final fontSize = prefs.getDouble(_keyFontSize);
    final customKeysJson = prefs.getString(_keyCustomKeys);
    final globalHotkey = prefs.getString(_keyGlobalHotkey);
    final scrollToBottomOnOutput = prefs.getBool(_keyScrollToBottomOnOutput);
    List<MobileKey>? customKeys;
    if (customKeysJson != null) {
      final list = jsonDecode(customKeysJson) as List;
      customKeys =
          list
              .map((e) => MobileKey.fromJson(e as Map<String, dynamic>))
              .toList();
    }
    state = TerminalSettings(
      fontFamily: fontFamily ?? state.fontFamily,
      fontSize: fontSize ?? state.fontSize,
      customKeys: customKeys ?? state.customKeys,
      globalHotkey: globalHotkey,
      scrollToBottomOnOutput:
          scrollToBottomOnOutput ?? state.scrollToBottomOnOutput,
    );
    if (globalHotkey != null) _applyHotkey(globalHotkey);
  }

  Future<void> setFontFamily(String fontFamily) async {
    state = state.copyWith(fontFamily: fontFamily);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyFontFamily, fontFamily);
  }

  Future<void> setFontSize(double fontSize) async {
    state = state.copyWith(fontSize: fontSize);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyFontSize, fontSize);
  }

  Future<void> setCustomKeys(List<MobileKey> keys) async {
    state = state.copyWith(customKeys: keys);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _keyCustomKeys,
      jsonEncode(keys.map((k) => k.toJson()).toList()),
    );
  }

  Future<void> setGlobalHotkey(String? hotkey) async {
    state =
        hotkey != null
            ? state.copyWith(globalHotkey: hotkey)
            : state.copyWith(clearHotkey: true);
    final prefs = await SharedPreferences.getInstance();
    if (hotkey != null) {
      await prefs.setString(_keyGlobalHotkey, hotkey);
    } else {
      await prefs.remove(_keyGlobalHotkey);
    }
    _applyHotkey(hotkey);
  }

  void _applyHotkey(String? hotkey) {
    if (!Platform.isMacOS) return;
    const channel = MethodChannel('dev.tether/window');
    if (hotkey != null) {
      channel.invokeMethod('setGlobalHotkey', {'hotkey': hotkey});
    } else {
      channel.invokeMethod('clearGlobalHotkey');
    }
  }

  Future<void> setScrollToBottomOnOutput(bool value) async {
    state = state.copyWith(scrollToBottomOnOutput: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyScrollToBottomOnOutput, value);
  }

  Future<void> addCustomKey(MobileKey key) async {
    await setCustomKeys([...state.customKeys, key]);
  }

  Future<void> removeCustomKey(int index) async {
    final keys = [...state.customKeys];
    keys.removeAt(index);
    await setCustomKeys(keys);
  }
}

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, TerminalSettings>((ref) {
      return SettingsNotifier();
    });
