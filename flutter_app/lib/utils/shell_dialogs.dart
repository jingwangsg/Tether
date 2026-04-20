import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/group.dart';
import '../models/session.dart';
import '../providers/server_provider.dart';
import '../widgets/sidebar/group_dialog.dart';

Future<Group?> showCreateProjectDialog(BuildContext context) {
  return showDialog<Group>(
    context: context,
    builder: (_) => const GroupDialog(),
  );
}

Future<void> showRenameProjectDialog(
  BuildContext context,
  WidgetRef ref,
  Group project,
) {
  final controller = TextEditingController(text: project.name);
  return showDialog<void>(
    context: context,
    builder: (ctx) {
      Future<void> submit() async {
        final name = controller.text.trim();
        if (name.isEmpty) return;
        await ref
            .read(serverProvider.notifier)
            .updateGroup(project.id, name: name);
        if (ctx.mounted) Navigator.pop(ctx);
      }

      return AlertDialog(
        title: const Text('Rename Project'),
        content: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (_) => submit(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(onPressed: submit, child: const Text('Rename')),
        ],
      );
    },
  );
}

Future<void> showRenameSessionDialog(
  BuildContext context,
  WidgetRef ref,
  Session session,
) {
  final controller = TextEditingController(text: session.name);
  return showDialog<void>(
    context: context,
    builder: (ctx) {
      Future<void> submit() async {
        final name = controller.text.trim();
        if (name.isEmpty) return;
        await ref
            .read(serverProvider.notifier)
            .updateSession(session.id, name: name);
        if (ctx.mounted) Navigator.pop(ctx);
      }

      return AlertDialog(
        title: const Text('Rename Session'),
        content: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (_) => submit(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(onPressed: submit, child: const Text('Rename')),
        ],
      );
    },
  );
}
