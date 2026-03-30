import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/mobile_key.dart';
import '../../providers/settings_provider.dart';

void showSettingsDialog(BuildContext context, WidgetRef ref) {
  showDialog(
    context: context,
    builder: (ctx) => const _SettingsDialog(),
  );
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
              title: const Text('Show Tab Bar',
                  style: TextStyle(fontSize: 13)),
              subtitle: const Text('Session tabs above terminal',
                  style: TextStyle(fontSize: 11, color: Colors.white38)),
              value: settings.showTabBar,
              dense: true,
              contentPadding: EdgeInsets.zero,
              onChanged: (value) {
                ref.read(settingsProvider.notifier).setShowTabBar(value);
              },
            ),
            const Divider(color: Colors.white12),
            const SizedBox(height: 8),
            const Text('Font',
                style: TextStyle(fontSize: 13, color: Colors.white70)),
            const SizedBox(height: 4),
            DropdownButtonFormField<String>(
              value: _fonts.containsKey(settings.fontFamily)
                  ? settings.fontFamily
                  : 'MesloLGSNF',
              items: _fonts.entries
                  .map((e) => DropdownMenuItem(
                        value: e.key,
                        child: Text(e.value),
                      ))
                  .toList(),
              onChanged: (value) {
                if (value != null) {
                  ref.read(settingsProvider.notifier).setFontFamily(value);
                }
              },
            ),
            const SizedBox(height: 16),
            Text('Font Size: ${settings.fontSize.round()}',
                style: const TextStyle(fontSize: 13, color: Colors.white70)),
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
                const Text('Custom Keys',
                    style: TextStyle(fontSize: 13, color: Colors.white70)),
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
                child: Text('No custom keys',
                    style: TextStyle(fontSize: 12, color: Colors.white38)),
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
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2D2D2D),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(key.label,
                            style: const TextStyle(
                                fontSize: 13, color: Colors.white70)),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _describeValue(key.value),
                          style: const TextStyle(
                              fontSize: 11, color: Colors.white38),
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
                              minWidth: 28, minHeight: 28),
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
            ElevatedButton(
              onPressed: doAdd,
              child: const Text('Add'),
            ),
          ],
        );
      },
    );
  }
}
