import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/mobile_key.dart';
import '../../providers/settings_provider.dart';
import '../../providers/ui_provider.dart';

class MobileKeyBar extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final uiState = ref.watch(uiProvider);
    final uiNotifier = ref.read(uiProvider.notifier);
    final settings = ref.watch(settingsProvider);
    final allKeys = [...uiState.mobileKeys, ...settings.customKeys];

    return Container(
      height: 40,
      color: const Color(0xFF1E1E1E),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
            child: Material(
              color: const Color(0xFF2D2D2D),
              borderRadius: BorderRadius.circular(4),
              child: InkWell(
                borderRadius: BorderRadius.circular(4),
                onTap: onCopy,
                child: Container(
                  constraints: const BoxConstraints(minWidth: 40),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: const Icon(Icons.content_copy, size: 16, color: Colors.white70),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
            child: Material(
              color: const Color(0xFF2D2D2D),
              borderRadius: BorderRadius.circular(4),
              child: InkWell(
                borderRadius: BorderRadius.circular(4),
                onTap: onPaste,
                child: Container(
                  constraints: const BoxConstraints(minWidth: 40),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: const Icon(Icons.content_paste, size: 16, color: Colors.white70),
                ),
              ),
            ),
          ),
          Container(width: 1, height: 24, color: Colors.white12),
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: allKeys.length,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              itemBuilder: (context, index) {
                final key = allKeys[index];
                final isActive = (key.value == 'ctrl' && uiState.ctrlActive) ||
                    (key.value == 'alt' && uiState.altActive);

                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                  child: Material(
                    color: isActive ? const Color(0xFF4A4A4A) : const Color(0xFF2D2D2D),
                    borderRadius: BorderRadius.circular(4),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: () => _handleKeyPress(key, uiState, uiNotifier),
                      child: Container(
                        constraints: const BoxConstraints(minWidth: 44),
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text(
                          key.label,
                          style: TextStyle(
                            color: isActive ? Colors.blue : Colors.white70,
                            fontSize: 13,
                            fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _handleKeyPress(MobileKey key, UiState uiState, UiNotifier uiNotifier) {
    if (key.isModifier) {
      if (key.value == 'ctrl') {
        uiNotifier.toggleCtrl();
      } else if (key.value == 'alt') {
        uiNotifier.toggleAlt();
      }
      return;
    }

    String finalValue = key.value;

    if (uiState.ctrlActive && finalValue.length == 1) {
      final code = finalValue.toUpperCase().codeUnitAt(0) - 64;
      if (code >= 0 && code <= 31) {
        finalValue = String.fromCharCode(code);
      }
      uiNotifier.clearModifiers();
    }

    if (uiState.altActive) {
      finalValue = '\x1b$finalValue';
      uiNotifier.clearModifiers();
    }

    onKeyPress(finalValue);
  }
}
