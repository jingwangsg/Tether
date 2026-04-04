import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/mobile_key.dart';
import '../../providers/settings_provider.dart';

void showSettingsDialog(BuildContext context, WidgetRef ref) {
  showDialog(context: context, builder: (ctx) => const _SettingsDialog());
}

class _SettingsDialog extends ConsumerWidget {
  const _SettingsDialog();

  static const _fonts = {
    'MesloLGSNF': 'MesloLGS NF',
    'JetBrainsMono': 'JetBrains Mono',
    'monospace': 'System Monospace',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);

    return AlertDialog(
      title: const Text('Settings'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              title: const Text('Show Tab Bar', style: TextStyle(fontSize: 13)),
              subtitle: const Text(
                'Session tabs above terminal',
                style: TextStyle(fontSize: 11, color: Colors.white38),
              ),
              value: settings.showTabBar,
              dense: true,
              contentPadding: EdgeInsets.zero,
              onChanged: (value) {
                ref.read(settingsProvider.notifier).setShowTabBar(value);
              },
            ),
            SwitchListTile(
              title: const Text(
                'Scroll to Bottom on Output',
                style: TextStyle(fontSize: 13),
              ),
              subtitle: const Text(
                'Always follow new terminal output',
                style: TextStyle(fontSize: 11, color: Colors.white38),
              ),
              value: settings.scrollToBottomOnOutput,
              dense: true,
              contentPadding: EdgeInsets.zero,
              onChanged: (value) {
                ref
                    .read(settingsProvider.notifier)
                    .setScrollToBottomOnOutput(value);
              },
            ),
            const Divider(color: Colors.white12),
            const SizedBox(height: 8),
            const _HotkeyRow(),
            const Divider(color: Colors.white12),
            const SizedBox(height: 8),
            const Text(
              'Font',
              style: TextStyle(fontSize: 13, color: Colors.white70),
            ),
            const SizedBox(height: 4),
            DropdownButtonFormField<String>(
              initialValue:
                  _fonts.containsKey(settings.fontFamily)
                      ? settings.fontFamily
                      : 'MesloLGSNF',
              items:
                  _fonts.entries
                      .map(
                        (e) => DropdownMenuItem(
                          value: e.key,
                          child: Text(e.value),
                        ),
                      )
                      .toList(),
              onChanged: (value) {
                if (value != null) {
                  ref.read(settingsProvider.notifier).setFontFamily(value);
                }
              },
            ),
            const SizedBox(height: 16),
            Text(
              'Font Size: ${settings.fontSize.round()}',
              style: const TextStyle(fontSize: 13, color: Colors.white70),
            ),
            Slider(
              value: settings.fontSize.clamp(10, 24),
              min: 10,
              max: 24,
              divisions: 14,
              label: settings.fontSize.round().toString(),
              onChanged: (value) {
                ref.read(settingsProvider.notifier).setFontSize(value);
              },
            ),
            const SizedBox(height: 16),
            const Divider(color: Colors.white12),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text(
                  'Custom Keys',
                  style: TextStyle(fontSize: 13, color: Colors.white70),
                ),
                const Spacer(),
                SizedBox(
                  height: 28,
                  child: TextButton.icon(
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('Add', style: TextStyle(fontSize: 12)),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed: () => _showAddKeyDialog(context, ref),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            if (settings.customKeys.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'No custom keys',
                  style: TextStyle(fontSize: 12, color: Colors.white38),
                ),
              )
            else
              ...settings.customKeys.asMap().entries.map((entry) {
                final idx = entry.key;
                final key = entry.value;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2D2D2D),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          key.label,
                          style: const TextStyle(
                            fontSize: 13,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _describeValue(key.value),
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white38,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      SizedBox(
                        width: 28,
                        height: 28,
                        child: IconButton(
                          icon: const Icon(Icons.close, size: 14),
                          color: Colors.white38,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 28,
                            minHeight: 28,
                          ),
                          onPressed: () {
                            ref
                                .read(settingsProvider.notifier)
                                .removeCustomKey(idx);
                          },
                        ),
                      ),
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }

  String _describeValue(String value) {
    if (value.length == 1) {
      final code = value.codeUnitAt(0);
      if (code >= 1 && code <= 26) {
        return 'Ctrl+${String.fromCharCode(code + 64)}';
      }
    }
    if (value.startsWith('\x1b') && value.length == 2) {
      return 'Alt+${value[1]}';
    }
    return value;
  }

  void _showAddKeyDialog(BuildContext context, WidgetRef ref) {
    final labelController = TextEditingController();
    final valueController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) {
        void doAdd() {
          final label = labelController.text.trim();
          final rawValue = valueController.text.trim();
          if (label.isNotEmpty && rawValue.isNotEmpty) {
            final value = parseKeyCombo(rawValue);
            ref
                .read(settingsProvider.notifier)
                .addCustomKey(MobileKey(label: label, value: value));
            Navigator.pop(ctx);
          }
        }

        return AlertDialog(
          title: const Text('Add Custom Key'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: labelController,
                decoration: const InputDecoration(
                  labelText: 'Label',
                  hintText: 'e.g. C-c',
                ),
                autofocus: true,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: valueController,
                decoration: const InputDecoration(
                  labelText: 'Key combo',
                  hintText: 'e.g. Ctrl+C, Alt+D',
                ),
                onSubmitted: (_) => doAdd(),
              ),
              const SizedBox(height: 8),
              const Text(
                'Formats: Ctrl+C, Alt+X, or raw text',
                style: TextStyle(fontSize: 11, color: Colors.white38),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(onPressed: doAdd, child: const Text('Add')),
          ],
        );
      },
    );
  }
}

String _formatHotkey(String s) {
  return s
      .split('+')
      .map((p) {
        return switch (p) {
          'cmd' => '⌘',
          'shift' => '⇧',
          'ctrl' => '⌃',
          'alt' => '⌥',
          'space' => 'Space',
          _ => p.toUpperCase(),
        };
      })
      .join('');
}

class _HotkeyRow extends ConsumerStatefulWidget {
  const _HotkeyRow();

  @override
  ConsumerState<_HotkeyRow> createState() => _HotkeyRowState();
}

class _HotkeyRowState extends ConsumerState<_HotkeyRow> {
  bool _recording = false;

  @override
  void dispose() {
    if (_recording) {
      HardwareKeyboard.instance.removeHandler(_captureKey);
    }
    super.dispose();
  }

  void _startRecording() {
    setState(() => _recording = true);
    HardwareKeyboard.instance.addHandler(_captureKey);
  }

  bool _captureKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;

    // Cancel on Escape
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _stopRecording();
      return true;
    }

    // Ignore pure modifier presses
    final modifierKeys = {
      LogicalKeyboardKey.metaLeft,
      LogicalKeyboardKey.metaRight,
      LogicalKeyboardKey.shiftLeft,
      LogicalKeyboardKey.shiftRight,
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.controlRight,
      LogicalKeyboardKey.altLeft,
      LogicalKeyboardKey.altRight,
    };
    if (modifierKeys.contains(event.logicalKey)) return false;

    final kb = HardwareKeyboard.instance;
    // Require at least one modifier
    if (!kb.isMetaPressed &&
        !kb.isShiftPressed &&
        !kb.isControlPressed &&
        !kb.isAltPressed) {
      return false;
    }

    final parts = <String>[];
    if (kb.isMetaPressed) parts.add('cmd');
    if (kb.isShiftPressed) parts.add('shift');
    if (kb.isControlPressed) parts.add('ctrl');
    if (kb.isAltPressed) parts.add('alt');

    // Only accept space or keys with a printable character so the Swift side
    // can match via charactersIgnoringModifiers (non-printable keys like arrows
    // have no reliable cross-platform label).
    final String keyLabel;
    if (event.logicalKey == LogicalKeyboardKey.space) {
      keyLabel = 'space';
    } else {
      // Use keyLabel (modifier-independent) instead of event.character, which
      // on macOS produces Option-layer glyphs (e.g. opt+z → 'Ω' instead of 'z').
      final ch = event.logicalKey.keyLabel.toLowerCase();
      if (!RegExp(r'^[a-z0-9]$').hasMatch(ch)) return false;
      keyLabel = ch;
    }
    parts.add(keyLabel);

    final hotkey = parts.join('+');
    ref.read(settingsProvider.notifier).setGlobalHotkey(hotkey);
    _stopRecording();
    return true;
  }

  void _stopRecording() {
    HardwareKeyboard.instance.removeHandler(_captureKey);
    if (mounted) setState(() => _recording = false);
  }

  @override
  Widget build(BuildContext context) {
    final hotkey = ref.watch(settingsProvider).globalHotkey;

    return Row(
      children: [
        const Text(
          'Global Hotkey',
          style: TextStyle(fontSize: 13, color: Colors.white70),
        ),
        const Spacer(),
        if (_recording)
          const Text(
            'Press key combo…',
            style: TextStyle(fontSize: 12, color: Colors.white38),
          )
        else
          Text(
            hotkey != null ? _formatHotkey(hotkey) : 'Not set',
            style: TextStyle(
              fontSize: 12,
              color: hotkey != null ? Colors.white70 : Colors.white38,
            ),
          ),
        const SizedBox(width: 8),
        SizedBox(
          height: 28,
          child: TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            onPressed: _recording ? _stopRecording : _startRecording,
            child: Text(
              _recording ? 'Cancel' : 'Set',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ),
        if (hotkey != null && !_recording) ...[
          const SizedBox(width: 4),
          SizedBox(
            width: 28,
            height: 28,
            child: IconButton(
              icon: const Icon(Icons.close, size: 14),
              color: Colors.white38,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed:
                  () =>
                      ref.read(settingsProvider.notifier).setGlobalHotkey(null),
            ),
          ),
        ],
      ],
    );
  }
}
