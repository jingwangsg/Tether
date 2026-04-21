import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tether/models/group.dart';
import 'package:tether/models/session.dart';
import 'package:tether/providers/server_provider.dart';
import 'package:tether/providers/session_provider.dart';
import 'package:tether/providers/ui_provider.dart';
import 'package:tether/widgets/sidebar/sidebar.dart';

Group _group(String id, String name, int sortOrder, {String? parentId}) =>
    Group(id: id, name: name, sortOrder: sortOrder, parentId: parentId);

Session _session(String id, String groupId, {int attentionSeq = 0, int attentionAckSeq = 0}) =>
    Session(
      id: id,
      groupId: groupId,
      name: id,
      shell: 'zsh',
      cols: 80,
      rows: 24,
      cwd: '/tmp',
      isAlive: true,
      createdAt: '',
      lastActive: '',
      attentionSeq: attentionSeq,
      attentionAckSeq: attentionAckSeq,
    );

void main() {
  testWidgets('sidebar renders only top-level projects and no session labels', (tester) async {
    final parent = _group('parent', 'Alpha', 0);
    final child = _group('child', 'Nested', 1, parentId: parent.id);
    final session = _session('alpha-session', parent.id);
    final container = ProviderContainer(
      overrides: [
        serverProvider.overrideWith(
          (ref) => ServerNotifier.test(
            ServerState(isConnected: true, groups: [parent, child], sessions: [session]),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: SizedBox(width: 280, child: Sidebar()))),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Nested'), findsNothing);
    expect(find.text('alpha-session'), findsNothing);
  });

  testWidgets('tapping a project selects it', (tester) async {
    final alpha = _group('alpha', 'Alpha', 0);
    final beta = _group('beta', 'Beta', 1);
    final container = ProviderContainer(
      overrides: [
        serverProvider.overrideWith(
          (ref) => ServerNotifier.test(
            ServerState(isConnected: true, groups: [alpha, beta], sessions: const []),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: SizedBox(width: 280, child: Sidebar()))),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();

    expect(container.read(sessionProvider).selectedProjectId, 'beta');
  });

  testWidgets('sidebar shows cmd digit hints for only the first nine visible projects', (tester) async {
    final groups = List.generate(
      10,
      (index) => _group('project-$index', 'Project ${index + 1}', index),
    );
    final container = ProviderContainer(
      overrides: [
        serverProvider.overrideWith(
          (ref) => ServerNotifier.test(
            ServerState(isConnected: true, groups: groups, sessions: const []),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    container.read(uiProvider.notifier).setDesktopShortcutHints(
          showProjectHints: true,
          showSessionHints: false,
        );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: SizedBox(width: 280, child: Sidebar())),
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (var index = 0; index < 9; index++) {
      expect(
        find.byKey(ValueKey('project-shortcut-hint-project-$index')),
        findsOneWidget,
      );
    }
    expect(
      find.byKey(const ValueKey('project-shortcut-hint-project-9')),
      findsNothing,
    );
  });

  testWidgets('sidebar shows stale banner and disables create actions', (
    tester,
  ) async {
    final alpha = _group('alpha', 'Alpha', 0);
    final container = ProviderContainer(
      overrides: [
        serverProvider.overrideWith(
          (ref) => ServerNotifier.test(
            ServerState(
              isConnected: true,
              isStale: true,
              error: 'refresh failed',
              groups: [alpha],
              sessions: const [],
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: SizedBox(width: 280, child: Sidebar())),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Showing stale data'), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
    final newGroupButton = find.ancestor(
      of: find.byIcon(Icons.create_new_folder_outlined),
      matching: find.byType(IconButton),
    );
    final newSessionButton = find.ancestor(
      of: find.byIcon(Icons.add),
      matching: find.byType(IconButton),
    );
    expect(tester.widget<IconButton>(newGroupButton).onPressed, isNull);
    expect(
      tester.widget<IconButton>(newSessionButton).onPressed,
      isNull,
    );
  });
}
