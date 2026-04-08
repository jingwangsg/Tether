import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/mobile_key.dart';
import '../../providers/settings_provider.dart';
import '../../providers/ui_provider.dart';

class MobileKeyBar extends ConsumerStatefulWidget {
  final void Function(String data) onKeyPress;
  final VoidCallback? onCopy;
  final VoidCallback? onPaste;

  const MobileKeyBar({
    super.key,
    required this.onKeyPress,
    this.onCopy,
    this.onPaste,
  });

  @override
  ConsumerState<MobileKeyBar> createState() => _MobileKeyBarState();
}

class _MobileKeyBarState extends ConsumerState<MobileKeyBar> {
  // Double-tap detection per modifier
  bool _ctrlWaitingForDoubleTap = false;
  Timer? _ctrlDoubleTapTimer;
  bool _altWaitingForDoubleTap = false;
  Timer? _altDoubleTapTimer;

  // Long-press auto-repeat
  Timer? _repeatDelayTimer;
  Timer? _repeatTimer;

  @override
  void dispose() {
    _ctrlDoubleTapTimer?.cancel();
    _altDoubleTapTimer?.cancel();
    _repeatDelayTimer?.cancel();
    _repeatTimer?.cancel();
    super.dispose();
  }

  void _handleModifierTap(String modifier) {
    final uiNotifier = ref.read(uiProvider.notifier);
    final uiState = ref.read(uiProvider);

    if (modifier == 'ctrl') {
      final currentMode = uiState.ctrlMode;
      if (currentMode == ModifierMode.inactive) {
        uiNotifier.setCtrlTemporary();
        HapticFeedback.lightImpact();
        _ctrlWaitingForDoubleTap = true;
        _ctrlDoubleTapTimer?.cancel();
        _ctrlDoubleTapTimer = Timer(const Duration(milliseconds: 300), () {
          _ctrlWaitingForDoubleTap = false;
        });
      } else if (currentMode == ModifierMode.temporary && _ctrlWaitingForDoubleTap) {
        _ctrlDoubleTapTimer?.cancel();
        _ctrlWaitingForDoubleTap = false;
        uiNotifier.setCtrlLocked();
        HapticFeedback.heavyImpact();
      } else {
        // temporary (after timeout) or locked → inactive
        if (currentMode == ModifierMode.locked) {
          uiNotifier.setCtrlLocked(); // toggles locked → inactive
        } else {
          uiNotifier.setCtrlTemporary(); // toggles temporary → inactive
        }
        HapticFeedback.lightImpact();
      }
    } else if (modifier == 'alt') {
      final currentMode = uiState.altMode;
      if (currentMode == ModifierMode.inactive) {
        uiNotifier.setAltTemporary();
        HapticFeedback.lightImpact();
        _altWaitingForDoubleTap = true;
        _altDoubleTapTimer?.cancel();
        _altDoubleTapTimer = Timer(const Duration(milliseconds: 300), () {
          _altWaitingForDoubleTap = false;
        });
      } else if (currentMode == ModifierMode.temporary && _altWaitingForDoubleTap) {
        _altDoubleTapTimer?.cancel();
        _altWaitingForDoubleTap = false;
        uiNotifier.setAltLocked();
        HapticFeedback.heavyImpact();
      } else {
        if (currentMode == ModifierMode.locked) {
          uiNotifier.setAltLocked();
        } else {
          uiNotifier.setAltTemporary();
        }
        HapticFeedback.lightImpact();
      }
    }
  }

  String _applyModifiers(String value, UiState uiState) {
    if (!uiState.ctrlActive && !uiState.altActive) return value;

    // Keys that skip modifier application
    if (value == '\x1b' || value == '\t' || value == '\x1b[Z') {
      return value;
    }

    // CSI arrow sequences: \x1b[A/B/C/D → \x1b[1;{mod}A/B/C/D
    final csiMatch = RegExp(r'^\x1b\[([A-D])$').firstMatch(value);
    if (csiMatch != null) {
      final letter = csiMatch.group(1)!;
      final mod = 1 + (uiState.altActive ? 2 : 0) + (uiState.ctrlActive ? 4 : 0);
      return '\x1b[1;$mod$letter';
    }

    // Single-character keys
    String result = value;
    if (uiState.ctrlActive && result.length == 1) {
      final code = result.toUpperCase().codeUnitAt(0) - 64;
      if (code >= 0 && code <= 31) {
        result = String.fromCharCode(code);
      }
    }
    if (uiState.altActive) {
      result = '\x1b$result';
    }
    return result;
  }

  void _sendKey(MobileKey key) {
    final uiState = ref.read(uiProvider);
    final modified = _applyModifiers(key.value, uiState);
    widget.onKeyPress(modified);
  }

  void _handleKeyTap(MobileKey key) {
    HapticFeedback.selectionClick();
    _sendKey(key);
    ref.read(uiProvider.notifier).consumeTemporaryModifiers();
  }

  void _handleKeyLongPressStart(MobileKey key) {
    HapticFeedback.selectionClick();
    _sendKey(key);
    _repeatDelayTimer?.cancel();
    _repeatTimer?.cancel();
    _repeatDelayTimer = Timer(const Duration(milliseconds: 400), () {
      _repeatTimer = Timer.periodic(const Duration(milliseconds: 80), (_) {
        _sendKey(key);
      });
    });
  }

  void _handleKeyLongPressEnd() {
    _repeatDelayTimer?.cancel();
    _repeatTimer?.cancel();
    _repeatDelayTimer = null;
    _repeatTimer = null;
    ref.read(uiProvider.notifier).consumeTemporaryModifiers();
  }

  @override
  Widget build(BuildContext context) {
    final uiState = ref.watch(uiProvider);
    final settings = ref.watch(settingsProvider);
    final allKeys = [...uiState.mobileKeys, ...settings.customKeys];
    final shortestSide = MediaQuery.of(context).size.shortestSide;
    final isTablet = shortestSide >= 600;
    final barHeight = isTablet ? 44.0 : 40.0;
    final buttonMinWidth = isTablet ? 48.0 : 38.0;
    final fontSize = isTablet ? 14.0 : 13.0;

    return Container(
      height: barHeight,
      color: const Color(0xFF1E1E1E),
      child: Row(
        children: [
          _buildActionButton(
            icon: Icons.content_copy,
            onTap: widget.onCopy,
            minWidth: buttonMinWidth,
          ),
          _buildActionButton(
            icon: Icons.content_paste,
            onTap: widget.onPaste,
            minWidth: buttonMinWidth,
          ),
          Container(width: 1, height: 24, color: Colors.white12),
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: allKeys.length,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              itemBuilder: (context, index) {
                final key = allKeys[index];
                if (key.isModifier) {
                  return _buildModifierKey(key, uiState, buttonMinWidth, fontSize);
                }
                return _buildRegularKey(key, buttonMinWidth, fontSize);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required VoidCallback? onTap,
    required double minWidth,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
      child: Material(
        color: const Color(0xFF2D2D2D),
        borderRadius: BorderRadius.circular(4),
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: onTap,
          child: Container(
            constraints: BoxConstraints(minWidth: minWidth),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Icon(icon, size: 16, color: Colors.white70),
          ),
        ),
      ),
    );
  }

  Widget _buildModifierKey(
    MobileKey key,
    UiState uiState,
    double minWidth,
    double fontSize,
  ) {
    final mode = key.value == 'ctrl' ? uiState.ctrlMode : uiState.altMode;

    Color bgColor;
    Color textColor;
    FontWeight fontWeight;
    bool showLock = false;

    switch (mode) {
      case ModifierMode.inactive:
        bgColor = const Color(0xFF2D2D2D);
        textColor = Colors.white70;
        fontWeight = FontWeight.normal;
      case ModifierMode.temporary:
        bgColor = const Color(0xFF4A4A4A);
        textColor = Colors.blue;
        fontWeight = FontWeight.bold;
      case ModifierMode.locked:
        bgColor = const Color(0xFF1A3A5C);
        textColor = Colors.blueAccent;
        fontWeight = FontWeight.bold;
        showLock = true;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
      child: Material(
        color: bgColor,
        borderRadius: BorderRadius.circular(4),
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: () => _handleModifierTap(key.value),
          child: Container(
            constraints: BoxConstraints(minWidth: minWidth + 6),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  key.label,
                  style: TextStyle(
                    color: textColor,
                    fontSize: fontSize,
                    fontWeight: fontWeight,
                  ),
                ),
                if (showLock) ...[
                  const SizedBox(width: 2),
                  Icon(Icons.lock, size: 10, color: textColor),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRegularKey(MobileKey key, double minWidth, double fontSize) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
      child: Material(
        color: const Color(0xFF2D2D2D),
        borderRadius: BorderRadius.circular(4),
        child: GestureDetector(
          onTap: () => _handleKeyTap(key),
          onLongPressStart: (_) => _handleKeyLongPressStart(key),
          onLongPressEnd: (_) => _handleKeyLongPressEnd(),
          onLongPressCancel: () => _handleKeyLongPressEnd(),
          child: Container(
            constraints: BoxConstraints(minWidth: minWidth + 6),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              key.label,
              style: TextStyle(
                color: Colors.white70,
                fontSize: fontSize,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
