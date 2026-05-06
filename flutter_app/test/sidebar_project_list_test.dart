import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tether/models/group.dart';
import 'package:tether/models/session.dart';
import 'package:tether/models/ssh_host.dart';
import 'package:tether/providers/settings_provider.dart';
import 'package:tether/providers/server_provider.dart';
import 'package:tether/providers/session_provider.dart';
import 'package:tether/providers/ui_provider.dart';
import 'package:tether/widgets/sidebar/sidebar.dart';

Group _group(String id, String name, int sortOrder, {String? parentId}) =>
    Group(id: id, name: name, sortOrder: sortOrder, parentId: parentId);

Group _remoteGroup(String id, String name, int sortOrder, {String? sshHost}) =>
    Group(id: id, name: name, sortOrder: sortOrder, sshHost: sshHost);

Session _session(
  String id,
  String groupId, {
  int attentionSeq = 0,
  int attentionAckSeq = 0,
}) => Session(
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
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('sidebar renders only top-level projects and no session labels', (
    tester,
  ) async {
    final parent = _group('parent', 'Alpha', 0);
    final child = _group('child', 'Nested', 1, parentId: parent.id);
    final session = _session('alpha-session', parent.id);
    final container = ProviderContainer(
      overrides: [
        serverProvider.overrideWith(
          (ref) => ServerNotifier.test(
            ServerState(
              isConnected: true,
              groups: [parent, child],
              sessions: [session],
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
            ServerState(
              isConnected: true,
              groups: [alpha, beta],
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

    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();

    expect(container.read(sessionProvider).selectedProjectId, 'beta');
  });

  testWidgets(
    'sidebar shows cmd digit hints for only the first nine visible projects',
    (tester) async {
      final groups = List.generate(
        10,
        (index) => _group('project-$index', 'Project ${index + 1}', index),
      );
      final container = ProviderContainer(
        overrides: [
          serverProvider.overrideWith(
            (ref) => ServerNotifier.test(
              ServerState(
                isConnected: true,
                groups: groups,
                sessions: const [],
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      container
          .read(uiProvider.notifier)
          .setDesktopShortcutHints(
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
    },
  );

  testWidgets('sidebar shows ssh host badge for remote projects only', (
    tester,
  ) async {
    final local = _group('local', 'Local', 0);
    final remote = _remoteGroup('remote', 'Remote', 1, sshHost: 'prod-box');
    final container = ProviderContainer(
      overrides: [
        serverProvider.overrideWith(
          (ref) => ServerNotifier.test(
            ServerState(isConnected: true, groups: [local, remote]),
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

    expect(find.text('prod-box'), findsOneWidget);
    expect(
      find.descendant(of: find.text('Local'), matching: find.text('prod-box')),
      findsNothing,
    );
  });

  testWidgets('sidebar renders osmo_9000 ssh badge with stable key', (
    tester,
  ) async {
    final local = _group('local', 'Local', 0);
    final remote = _remoteGroup('remote', 'Remote', 1, sshHost: 'osmo_9000');
    final container = ProviderContainer(
      overrides: [
        serverProvider.overrideWith(
          (ref) => ServerNotifier.test(
            ServerState(isConnected: true, groups: [local, remote]),
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

    expect(
      find.byKey(const ValueKey('project-ssh-badge-remote')),
      findsOneWidget,
    );
    expect(find.text('osmo_9000'), findsOneWidget);
  });

  testWidgets(
    'sidebar does not show selected ssh host as a standalone section',
    (tester) async {
      SharedPreferences.setMockInitialValues({'selected_ssh_host': 'devbox'});
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith((ref) => SettingsNotifier()),
          serverProvider.overrideWith(
            (ref) => ServerNotifier.test(
              ServerState(
                isConnected: true,
                sshHosts: [
                  SshHost(host: 'devbox', reachable: true),
                  SshHost(host: 'osmo_9000', reachable: true),
                ],
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

      expect(find.text('devbox'), findsNothing);
      expect(find.text('osmo_9000'), findsNothing);
    },
  );

  testWidgets('sidebar keeps ssh host badge visible in narrow layout', (
    tester,
  ) async {
    final remote = _remoteGroup('remote', 'Remote', 0, sshHost: 'osmo_9000');
    final container = ProviderContainer(
      overrides: [
        serverProvider.overrideWith(
          (ref) => ServerNotifier.test(
            ServerState(isConnected: true, groups: [remote]),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: SizedBox(width: 210, child: Sidebar())),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('project-ssh-badge-remote')),
      findsOneWidget,
    );
    expect(find.text('osmo_9000'), findsOneWidget);
  });

  testWidgets('sidebar supports direct-drag reordering on desktop', (
    tester,
  ) async {
    final alpha = _group('alpha', 'Alpha', 0);
    final beta = _group('beta', 'Beta', 1);
    final notifier = _SidebarTestServerNotifier(
      ServerState(isConnected: true, groups: [alpha, beta], sessions: const []),
    );
    final container = ProviderContainer(
      overrides: [serverProvider.overrideWith((ref) => notifier)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.macOS),
          home: const Scaffold(
            body: SizedBox(width: 280, height: 400, child: Sidebar()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final alphaCenter = tester.getCenter(
      find.byKey(const ValueKey('project-tile-alpha')),
    );
    final gesture = await tester.startGesture(
      alphaCenter,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.moveBy(const Offset(0, 120));
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(notifier.reorderPayloads, isNotEmpty);
    expect(
      notifier.state.groups..sort((a, b) => a.sortOrder.compareTo(b.sortOrder)),
      isA<List<Group>>(),
    );
    expect(
      (List<Group>.from(notifier.state.groups)..sort(
        (a, b) => a.sortOrder.compareTo(b.sortOrder),
      )).map((group) => group.id),
      ['beta', 'alpha'],
    );
  });

  testWidgets(
    'sidebar supports direct-drag reordering in a scrollable project list',
    (tester) async {
      final groups = List.generate(
        12,
        (index) => _group('project-$index', 'Project $index', index),
      );
      final notifier = _SidebarTestServerNotifier(
        ServerState(isConnected: true, groups: groups, sessions: const []),
      );
      final container = ProviderContainer(
        overrides: [serverProvider.overrideWith((ref) => notifier)],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: ThemeData(platform: TargetPlatform.macOS),
            home: const Scaffold(
              body: SizedBox(width: 280, height: 220, child: Sidebar()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final firstCenter = tester.getCenter(
        find.byKey(const ValueKey('project-tile-project-0')),
      );
      final gesture = await tester.startGesture(
        firstCenter,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 20));
      await gesture.moveBy(const Offset(0, 120));
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(notifier.reorderPayloads, isNotEmpty);
      final latestPayload = notifier.reorderPayloads.last;
      final movedIndex = latestPayload.indexWhere(
        (item) => item['id'] == 'project-0',
      );
      expect(movedIndex, greaterThan(0));
    },
  );

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
    expect(tester.widget<IconButton>(newSessionButton).onPressed, isNull);
  });

  testWidgets('sidebar project tile close button deletes project', (
    tester,
  ) async {
    final alpha = _group('alpha', 'Alpha', 0);
    final beta = _group('beta', 'Beta', 1);
    final notifier = _SidebarTestServerNotifier(
      ServerState(isConnected: true, groups: [alpha, beta], sessions: const []),
    );
    final container = ProviderContainer(
      overrides: [serverProvider.overrideWith((ref) => notifier)],
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

    await tester.tap(find.byKey(const ValueKey('project-delete-button-beta')));
    await tester.pumpAndSettle();

    expect(notifier.deletedGroupIds, ['beta']);
    expect(find.text('Beta'), findsNothing);
  });
}

class _SidebarTestServerNotifier extends ServerNotifier {
  _SidebarTestServerNotifier(super.state) : super.test();

  final List<List<Map<String, dynamic>>> reorderPayloads = [];
  final List<String> deletedGroupIds = [];

  @override
  Future<void> reorderGroups(List<Map<String, dynamic>> items) async {
    reorderPayloads.add(items);
    final sortOrders = {
      for (final item in items) item['id'] as String: item['sort_order'] as int,
    };
    state = state.copyWith(
      groups:
          state.groups
              .map(
                (group) => group.copyWith(
                  sortOrder: sortOrders[group.id] ?? group.sortOrder,
                ),
              )
              .toList(),
    );
  }

  @override
  Future<void> deleteGroup(String id) async {
    deletedGroupIds.add(id);
    state = state.copyWith(
      groups: state.groups.where((group) => group.id != id).toList(),
      sessions:
          state.sessions.where((session) => session.groupId != id).toList(),
    );
  }
}
