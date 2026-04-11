import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/mobile_key.dart';
import '../../providers/settings_provider.dart';
import '../../providers/ui_provider.dart';

const _mobileToolbarBackground = Color(0xFF1E1E1E);
const _mobileToolbarButtonColor = Color(0xFF2D2D2D);
const _mobileToolbarActiveColor = Color(0xFF4A4A4A);
const _mobileToolbarLockedColor = Color(0xFF1A3A5C);

String applyMobileModifiers(String value, UiState uiState) {
  if (!uiState.ctrlActive && !uiState.altActive) return value;

  if (value == '\x1b' || value == '\t' || value == '\x1b[Z') {
    return value;
  }

  final mod = 1 + (uiState.altActive ? 2 : 0) + (uiState.ctrlActive ? 4 : 0);

  final csiLetterMatch = RegExp(r'^\x1b\[([A-DFH])$').firstMatch(value);
  if (csiLetterMatch != null) {
    final letter = csiLetterMatch.group(1)!;
    return '\x1b[1;${mod}$letter';
  }

  final csiTildeMatch = RegExp(r'^\x1b\[(\d+)~$').firstMatch(value);
  if (csiTildeMatch != null) {
    final code = csiTildeMatch.group(1)!;
    return '\x1b[$code;${mod}~';
  }

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

List<List<T>> splitBalancedRows<T>(List<T> items, int rowCount) {
  final rows = List.generate(rowCount, (_) => <T>[]);
  if (items.isEmpty) return rows;

  final baseCount = items.length ~/ rowCount;
  final extra = items.length % rowCount;
  var start = 0;
  for (var rowIndex = 0; rowIndex < rowCount; rowIndex++) {
    final count = baseCount + (rowIndex < extra ? 1 : 0);
    rows[rowIndex] = items.sublist(start, start + count);
    start += count;
  }
  return rows;
}

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
  bool _ctrlWaitingForDoubleTap = false;
  Timer? _ctrlDoubleTapTimer;
  bool _altWaitingForDoubleTap = false;
  Timer? _altDoubleTapTimer;
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
      } else if (currentMode == ModifierMode.temporary &&
          _ctrlWaitingForDoubleTap) {
        _ctrlDoubleTapTimer?.cancel();
        _ctrlWaitingForDoubleTap = false;
        uiNotifier.setCtrlLocked();
        HapticFeedback.heavyImpact();
      } else {
        if (currentMode == ModifierMode.locked) {
          uiNotifier.setCtrlLocked();
        } else {
          uiNotifier.setCtrlTemporary();
        }
        HapticFeedback.lightImpact();
      }
      return;
    }

    final currentMode = uiState.altMode;
    if (currentMode == ModifierMode.inactive) {
      uiNotifier.setAltTemporary();
      HapticFeedback.lightImpact();
      _altWaitingForDoubleTap = true;
      _altDoubleTapTimer?.cancel();
      _altDoubleTapTimer = Timer(const Duration(milliseconds: 300), () {
        _altWaitingForDoubleTap = false;
      });
    } else if (currentMode == ModifierMode.temporary &&
        _altWaitingForDoubleTap) {
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

  void _sendKey(MobileKey key) {
    final uiState = ref.read(uiProvider);
    final modified = applyMobileModifiers(key.value, uiState);
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
    final shortestSide = MediaQuery.of(context).size.shortestSide;
    final isTablet = shortestSide >= 600;
    final items = <_ToolbarItem>[
      _ToolbarItem.action(label: 'Copy', onTap: widget.onCopy),
      _ToolbarItem.action(label: 'Paste', onTap: widget.onPaste),
      ...uiState.mobileKeys.map(_ToolbarItem.key),
      ...settings.customKeys.map(_ToolbarItem.key),
    ];
    final rows = splitBalancedRows(items, 2);

    return LayoutBuilder(
      builder: (context, constraints) {
        final rowCount = rows.fold<int>(0, (maxCount, row) {
          return row.length > maxCount ? row.length : maxCount;
        });
        final compact = constraints.maxWidth < 380 || rowCount >= 7;
        final rowGap = compact ? 4.0 : 6.0;
        final buttonHeight = isTablet ? 38.0 : (compact ? 28.0 : 32.0);
        final fontSize = isTablet ? 13.0 : (compact ? 10.0 : 11.0);
        final borderRadius = BorderRadius.circular(isTablet ? 10 : 8);

        return Container(
          key: const ValueKey('mobile-key-bar'),
          color: _mobileToolbarBackground,
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) ...[
                _buildRow(
                  key: ValueKey('mobile-key-row-$rowIndex'),
                  row: rows[rowIndex],
                  uiState: uiState,
                  fontSize: fontSize,
                  gap: rowGap,
                  buttonHeight: buttonHeight,
                  borderRadius: borderRadius,
                ),
                if (rowIndex < rows.length - 1) SizedBox(height: rowGap),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildRow({
    required Key key,
    required List<_ToolbarItem> row,
    required UiState uiState,
    required double fontSize,
    required double gap,
    required double buttonHeight,
    required BorderRadius borderRadius,
  }) {
    return Row(
      key: key,
      children: [
        for (var index = 0; index < row.length; index++) ...[
          Expanded(
            child: _buildToolbarItem(
              row[index],
              uiState: uiState,
              fontSize: fontSize,
              buttonHeight: buttonHeight,
              borderRadius: borderRadius,
            ),
          ),
          if (index < row.length - 1) SizedBox(width: gap),
        ],
      ],
    );
  }

  Widget _buildToolbarItem(
    _ToolbarItem item, {
    required UiState uiState,
    required double fontSize,
    required double buttonHeight,
    required BorderRadius borderRadius,
  }) {
    if (item.key == null) {
      return _buildActionButton(
        label: item.label!,
        onTap: item.onTap,
        fontSize: fontSize,
        buttonHeight: buttonHeight,
        borderRadius: borderRadius,
      );
    }

    final key = item.key!;
    if (key.isModifier) {
      return _buildModifierKey(
        key,
        uiState: uiState,
        fontSize: fontSize,
        buttonHeight: buttonHeight,
        borderRadius: borderRadius,
      );
    }

    return _buildRegularKey(
      key,
      fontSize: fontSize,
      buttonHeight: buttonHeight,
      borderRadius: borderRadius,
    );
  }

  Widget _buildActionButton({
    required String label,
    required VoidCallback? onTap,
    required double fontSize,
    required double buttonHeight,
    required BorderRadius borderRadius,
  }) {
    return SizedBox(
      height: buttonHeight,
      child: Material(
        color: _mobileToolbarButtonColor,
        borderRadius: borderRadius,
        child: InkWell(
          key: ValueKey('mobile-toolbar-button-$label'),
          borderRadius: borderRadius,
          onTap: onTap,
          child: Center(
            child: _MobileButtonLabel(
              label: label,
              fontSize: fontSize,
              color: onTap == null ? Colors.white24 : Colors.white70,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildModifierKey(
    MobileKey key, {
    required UiState uiState,
    required double fontSize,
    required double buttonHeight,
    required BorderRadius borderRadius,
  }) {
    final mode = key.value == 'ctrl' ? uiState.ctrlMode : uiState.altMode;

    Color bgColor;
    Color textColor;
    FontWeight fontWeight;
    var showLock = false;

    switch (mode) {
      case ModifierMode.inactive:
        bgColor = _mobileToolbarButtonColor;
        textColor = Colors.white70;
        fontWeight = FontWeight.normal;
      case ModifierMode.temporary:
        bgColor = _mobileToolbarActiveColor;
        textColor = Colors.blue;
        fontWeight = FontWeight.bold;
      case ModifierMode.locked:
        bgColor = _mobileToolbarLockedColor;
        textColor = Colors.blueAccent;
        fontWeight = FontWeight.bold;
        showLock = true;
    }

    return SizedBox(
      height: buttonHeight,
      child: Material(
        color: bgColor,
        borderRadius: borderRadius,
        child: InkWell(
          key: ValueKey('mobile-toolbar-button-${key.label}'),
          borderRadius: borderRadius,
          onTap: () => _handleModifierTap(key.value),
          child: Center(
            child: _MobileButtonLabel(
              label: key.label,
              fontSize: fontSize,
              color: textColor,
              fontWeight: fontWeight,
              trailingIcon:
                  showLock
                      ? Icon(Icons.lock, size: fontSize, color: textColor)
                      : null,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRegularKey(
    MobileKey key, {
    required double fontSize,
    required double buttonHeight,
    required BorderRadius borderRadius,
  }) {
    return SizedBox(
      height: buttonHeight,
      child: Material(
        color: _mobileToolbarButtonColor,
        borderRadius: borderRadius,
        child: GestureDetector(
          key: ValueKey('mobile-toolbar-button-${key.label}'),
          behavior: HitTestBehavior.opaque,
          onTap: () => _handleKeyTap(key),
          onLongPressStart: (_) => _handleKeyLongPressStart(key),
          onLongPressEnd: (_) => _handleKeyLongPressEnd(),
          onLongPressCancel: _handleKeyLongPressEnd,
          child: Center(
            child: _MobileButtonLabel(
              label: key.label,
              fontSize: fontSize,
              color: Colors.white70,
            ),
          ),
        ),
      ),
    );
  }
}

class MobileFloatingNavPad extends ConsumerStatefulWidget {
  final void Function(String data) onKeyPress;

  const MobileFloatingNavPad({super.key, required this.onKeyPress});

  @override
  ConsumerState<MobileFloatingNavPad> createState() =>
      _MobileFloatingNavPadState();
}

class _MobileFloatingNavPadState extends ConsumerState<MobileFloatingNavPad> {
  Timer? _repeatDelayTimer;
  Timer? _repeatTimer;

  @override
  void dispose() {
    _repeatDelayTimer?.cancel();
    _repeatTimer?.cancel();
    super.dispose();
  }

  void _sendKey(MobileKey key) {
    final uiState = ref.read(uiProvider);
    final modified = applyMobileModifiers(key.value, uiState);
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
    final shortestSide = MediaQuery.of(context).size.shortestSide;
    final isTablet = shortestSide >= 600;
    final gap = isTablet ? 6.0 : 5.0;
    final padding = isTablet ? 8.0 : 6.0;
    final handleHeight = isTablet ? 18.0 : 16.0;
    final buttonSize = isTablet ? 44.0 : 38.0;
    final fontSize = isTablet ? 11.5 : 10.5;
    final navRowCount = defaultMobileNavigationRows.length;
    final padSize = Size(
      (padding * 2) + (buttonSize * 3) + (gap * 2),
      (padding * 2) + handleHeight + 4 + (buttonSize * navRowCount) + (gap * (navRowCount - 1)),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth <= 0 || constraints.maxHeight <= 0) {
          return const SizedBox.shrink();
        }

        final areaSize = constraints.biggest;
        final position = _resolveFloatingPadOffset(
          areaSize: areaSize,
          padSize: padSize,
          storedOffset: uiState.floatingNavOffset,
        );

        return Stack(
          children: [
            Positioned(
              left: position.dx,
              top: position.dy,
              child: Material(
                key: const ValueKey('mobile-floating-nav-pad'),
                color: const Color(0xB31E1E1E),
                borderRadius: BorderRadius.circular(isTablet ? 16 : 14),
                child: Container(
                  width: padSize.width,
                  padding: EdgeInsets.all(padding),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(isTablet ? 16 : 14),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GestureDetector(
                        key: const ValueKey('mobile-floating-nav-drag-handle'),
                        behavior: HitTestBehavior.translucent,
                        onPanUpdate: (details) {
                          final current =
                              ref.read(uiProvider).floatingNavOffset ??
                              position;
                          ref
                              .read(uiProvider.notifier)
                              .setFloatingNavOffset(
                                _clampFloatingPadOffset(
                                  offset: current + details.delta,
                                  areaSize: areaSize,
                                  padSize: padSize,
                                ),
                              );
                        },
                        child: SizedBox(
                          height: handleHeight,
                          child: Center(
                            child: Container(
                              width: 32,
                              height: 4,
                              decoration: BoxDecoration(
                                color: Colors.white30,
                                borderRadius: BorderRadius.circular(999),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      for (
                        var rowIndex = 0;
                        rowIndex < defaultMobileNavigationRows.length;
                        rowIndex++
                      ) ...[
                        Row(
                          children: [
                            for (
                              var colIndex = 0;
                              colIndex <
                                  defaultMobileNavigationRows[rowIndex].length;
                              colIndex++
                            ) ...[
                              Expanded(
                                child: _buildNavCell(
                                  key:
                                      defaultMobileNavigationRows[rowIndex][colIndex],
                                  buttonSize: buttonSize,
                                  fontSize: fontSize,
                                ),
                              ),
                              if (colIndex <
                                  defaultMobileNavigationRows[rowIndex].length -
                                      1)
                                SizedBox(width: gap),
                            ],
                          ],
                        ),
                        if (rowIndex < defaultMobileNavigationRows.length - 1)
                          SizedBox(height: gap),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildNavCell({
    required MobileKey? key,
    required double buttonSize,
    required double fontSize,
  }) {
    if (key == null) {
      return SizedBox(height: buttonSize);
    }

    return SizedBox(
      height: buttonSize,
      child: Material(
        color: _mobileToolbarButtonColor.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(10),
        child: GestureDetector(
          key: ValueKey('mobile-floating-nav-button-${key.label}'),
          behavior: HitTestBehavior.opaque,
          onTap: () => _handleKeyTap(key),
          onLongPressStart: (_) => _handleKeyLongPressStart(key),
          onLongPressEnd: (_) => _handleKeyLongPressEnd(),
          onLongPressCancel: _handleKeyLongPressEnd,
          child: Center(
            child: _MobileButtonLabel(
              label: key.label,
              fontSize: fontSize,
              color: Colors.white70,
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolbarItem {
  const _ToolbarItem.key(this.key) : label = null, onTap = null;

  const _ToolbarItem.action({required this.label, required this.onTap})
    : key = null;

  final MobileKey? key;
  final String? label;
  final VoidCallback? onTap;
}

class _MobileButtonLabel extends StatelessWidget {
  final String label;
  final double fontSize;
  final Color color;
  final FontWeight fontWeight;
  final Widget? trailingIcon;

  const _MobileButtonLabel({
    required this.label,
    required this.fontSize,
    required this.color,
    this.fontWeight = FontWeight.w500,
    this.trailingIcon,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.visible,
              style: TextStyle(
                color: color,
                fontSize: fontSize,
                fontWeight: fontWeight,
              ),
            ),
            if (trailingIcon != null) ...[
              const SizedBox(width: 3),
              trailingIcon!,
            ],
          ],
        ),
      ),
    );
  }
}

Offset _resolveFloatingPadOffset({
  required Size areaSize,
  required Size padSize,
  required Offset? storedOffset,
}) {
  final defaultOffset = Offset(
    areaSize.width - padSize.width - 16,
    areaSize.height - padSize.height - 16,
  );
  return _clampFloatingPadOffset(
    offset: storedOffset ?? defaultOffset,
    areaSize: areaSize,
    padSize: padSize,
  );
}

Offset _clampFloatingPadOffset({
  required Offset offset,
  required Size areaSize,
  required Size padSize,
}) {
  final maxX = areaSize.width - padSize.width - 8;
  final maxY = areaSize.height - padSize.height - 8;
  return Offset(
    offset.dx.clamp(8.0, maxX < 8 ? 8.0 : maxX),
    offset.dy.clamp(8.0, maxY < 8 ? 8.0 : maxY),
  );
}
