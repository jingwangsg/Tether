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

Future<Session?> showCreateSessionDialog(
  BuildContext context,
  WidgetRef ref, {
  required Group project,
}) {
  final nameController = TextEditingController();
  final commandController = TextEditingController();
  final cwdController = TextEditingController(text: project.defaultCwd ?? '');
  return showDialog<Session>(
    context: context,
    builder: (ctx) {
      Future<void> submit() async {
        final session = await ref.read(serverProvider.notifier).createSession(
              groupId: project.id,
              name: nameController.text.trim().isEmpty
                  ? null
                  : nameController.text.trim(),
              command: commandController.text.trim().isEmpty
                  ? null
                  : commandController.text.trim(),
              cwd: cwdController.text.trim().isEmpty
                  ? null
                  : cwdController.text.trim(),
            );
        if (ctx.mounted) Navigator.pop(ctx, session);
      }

      return AlertDialog(
        title: Text('New Session in ${project.name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration:
                  const InputDecoration(labelText: 'Session Name'),
            ),
            TextField(
              controller: commandController,
              decoration: const InputDecoration(labelText: 'Command'),
            ),
            TextField(
              controller: cwdController,
              decoration:
                  const InputDecoration(labelText: 'Working Directory'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(onPressed: submit, child: const Text('Create')),
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
