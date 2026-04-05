import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tether/models/group.dart';
import 'package:tether/models/session.dart';
import 'package:tether/models/ssh_host.dart';
import 'package:tether/providers/server_provider.dart';
import 'package:tether/services/api_service.dart';

class FakeApiService extends ApiService {
  FakeApiService({
    this.reorderGroupsHandler,
    this.reorderSessionsHandler,
    this.listGroupsHandler,
    this.listSessionsHandler,
    this.listSshHostsHandler,
  }) : super(baseUrl: 'http://localhost');

  final Future<void> Function(List<Map<String, dynamic>> items)?
  reorderGroupsHandler;
  final Future<void> Function(List<Map<String, dynamic>> items)?
  reorderSessionsHandler;
  final Future<List<Group>> Function()? listGroupsHandler;
  final Future<List<Session>> Function()? listSessionsHandler;
  final Future<List<SshHost>> Function()? listSshHostsHandler;

  @override
  Future<void> reorderGroups(List<Map<String, dynamic>> items) async {
    await reorderGroupsHandler?.call(items);
  }

  @override
  Future<void> reorderSessions(List<Map<String, dynamic>> items) async {
    await reorderSessionsHandler?.call(items);
  }

  @override
  Future<List<Group>> listGroups() async {
    if (listGroupsHandler != null) {
      return listGroupsHandler!.call();
    }
    return <Group>[];
  }

  @override
  Future<List<Session>> listSessions() async {
    if (listSessionsHandler != null) {
      return listSessionsHandler!.call();
    }
    return <Session>[];
  }

  @override
  Future<List<SshHost>> listSshHosts() async {
    if (listSshHostsHandler != null) {
      return listSshHostsHandler!.call();
    }
    return <SshHost>[];
  }
}

Group _group(String id, String name, int sortOrder) =>
    Group(id: id, name: name, sortOrder: sortOrder);

Session _session(
  String id, {
  required String groupId,
  required int sortOrder,
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
  sortOrder: sortOrder,
);

List<String> _sortedGroupIds(List<Group> groups) {
  final copy = List<Group>.from(groups)
    ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  return copy.map((group) => group.id).toList();
}

List<Session> _sortedSessionsInGroup(List<Session> sessions, String groupId) {
  final copy =
      sessions.where((session) => session.groupId == groupId).toList()
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  return copy;
}

List<Group> _applyGroupItems(
  List<Group> groups,
  List<Map<String, dynamic>> items,
) {
  final sortOrders = {
    for (final item in items) item['id'] as String: item['sort_order'] as int,
  };
  return groups
      .map(
        (group) =>
            group.copyWith(sortOrder: sortOrders[group.id] ?? group.sortOrder),
      )
      .toList();
}

List<Session> _applySessionItems(
  List<Session> sessions,
  List<Map<String, dynamic>> items,
) {
  final updates = {
    for (final item in items)
      item['id'] as String: (
        sortOrder: item['sort_order'] as int,
        groupId: item['group_id'] as String?,
      ),
  };
  return sessions.map((session) {
    final update = updates[session.id];
    if (update == null) {
      return session;
    }
    return session.copyWith(
      sortOrder: update.sortOrder,
      groupId: update.groupId ?? session.groupId,
    );
  }).toList();
}

void main() {
  group('ServerNotifier reorder', () {
    test(
      'optimistically reorders groups before the API round-trip completes',
      () async {
        final alpha = _group('alpha', 'Alpha', 0);
        final beta = _group('beta', 'Beta', 1);
        final completer = Completer<void>();
        final api = FakeApiService(
          reorderGroupsHandler: (_) => completer.future,
          listGroupsHandler:
              () async => [
                beta.copyWith(sortOrder: 0),
                alpha.copyWith(sortOrder: 1),
              ],
        );
        final notifier = ServerNotifier.test(
          ServerState(api: api, isConnected: true, groups: [alpha, beta]),
        );

        final future = notifier.reorderGroups([
          {'id': beta.id, 'sort_order': 0},
          {'id': alpha.id, 'sort_order': 1},
        ]);

        expect(_sortedGroupIds(notifier.state.groups), ['beta', 'alpha']);

        completer.complete();
        await future;

        expect(_sortedGroupIds(notifier.state.groups), ['beta', 'alpha']);
      },
    );

    test(
      'optimistically moves sessions across groups before the API call finishes',
      () async {
        final source = _group('source', 'Source', 0);
        final target = _group('target', 'Target', 1);
        final dragged = _session('dragged', groupId: source.id, sortOrder: 0);
        final existing = _session('existing', groupId: target.id, sortOrder: 0);
        final completer = Completer<void>();
        final api = FakeApiService(
          reorderSessionsHandler: (_) => completer.future,
          listGroupsHandler: () async => [source, target],
          listSessionsHandler:
              () async => [
                dragged.copyWith(groupId: target.id, sortOrder: 0),
                existing.copyWith(sortOrder: 1),
              ],
        );
        final notifier = ServerNotifier.test(
          ServerState(
            api: api,
            isConnected: true,
            groups: [source, target],
            sessions: [dragged, existing],
          ),
        );

        final future = notifier.reorderSessions([
          {'id': dragged.id, 'sort_order': 0, 'group_id': target.id},
          {'id': existing.id, 'sort_order': 1, 'group_id': target.id},
        ]);

        final optimisticTarget = _sortedSessionsInGroup(
          notifier.state.sessions,
          target.id,
        );
        expect(optimisticTarget.map((session) => session.id), [
          'dragged',
          'existing',
        ]);

        completer.complete();
        await future;

        final refreshedTarget = _sortedSessionsInGroup(
          notifier.state.sessions,
          target.id,
        );
        expect(refreshedTarget.map((session) => session.id), [
          'dragged',
          'existing',
        ]);
      },
    );

    test(
      'rolls back optimistic session moves when the API call fails',
      () async {
        final source = _group('source', 'Source', 0);
        final target = _group('target', 'Target', 1);
        final dragged = _session('dragged', groupId: source.id, sortOrder: 0);
        final existing = _session('existing', groupId: target.id, sortOrder: 0);
        final api = FakeApiService(
          reorderSessionsHandler:
              (_) => Future<void>.error(StateError('reorder failed')),
          listGroupsHandler: () async => [source, target],
          listSessionsHandler: () async => [dragged, existing],
        );
        final notifier = ServerNotifier.test(
          ServerState(
            api: api,
            isConnected: true,
            groups: [source, target],
            sessions: [dragged, existing],
          ),
        );

        final future = notifier.reorderSessions([
          {'id': dragged.id, 'sort_order': 0, 'group_id': target.id},
          {'id': existing.id, 'sort_order': 1, 'group_id': target.id},
        ]);

        final optimisticTarget = _sortedSessionsInGroup(
          notifier.state.sessions,
          target.id,
        );
        expect(optimisticTarget.map((session) => session.id), [
          'dragged',
          'existing',
        ]);

        await expectLater(future, throwsA(isA<StateError>()));

        final sourceSessions = _sortedSessionsInGroup(
          notifier.state.sessions,
          source.id,
        );
        final targetSessions = _sortedSessionsInGroup(
          notifier.state.sessions,
          target.id,
        );
        expect(sourceSessions.map((session) => session.id), ['dragged']);
        expect(targetSessions.map((session) => session.id), ['existing']);
        expect(sourceSessions.single.sortOrder, 0);
        expect(targetSessions.single.sortOrder, 0);
      },
    );

    test(
      'preserves foreground updates when a session reorder later rolls back',
      () async {
        final source = _group('source', 'Source', 0);
        final target = _group('target', 'Target', 1);
        final dragged = _session('dragged', groupId: source.id, sortOrder: 0);
        final existing = _session('existing', groupId: target.id, sortOrder: 0);
        final completer = Completer<void>();
        final api = FakeApiService(
          reorderSessionsHandler: (_) => completer.future,
          listGroupsHandler: () async => [source, target],
          listSessionsHandler: () async => [dragged, existing],
        );
        final notifier = ServerNotifier.test(
          ServerState(
            api: api,
            isConnected: true,
            groups: [source, target],
            sessions: [dragged, existing],
          ),
        );

        final future = notifier.reorderSessions([
          {'id': dragged.id, 'sort_order': 0, 'group_id': target.id},
          {'id': existing.id, 'sort_order': 1, 'group_id': target.id},
        ]);

        notifier.updateForegroundProcess(
          dragged.id,
          'claude',
          oscTitle: 'claude: waiting',
        );

        completer.completeError(StateError('reorder failed'));
        await expectLater(future, throwsA(isA<StateError>()));

        final restored = notifier.state.sessions.firstWhere(
          (session) => session.id == dragged.id,
        );
        expect(restored.groupId, source.id);
        expect(restored.sortOrder, 0);
        expect(restored.foregroundProcess, 'claude');
        expect(restored.oscTitle, 'claude: waiting');
      },
    );

    test(
      'does not let a failed older group reorder override a newer successful one',
      () async {
        final alpha = _group('alpha', 'Alpha', 0);
        final beta = _group('beta', 'Beta', 1);
        final gamma = _group('gamma', 'Gamma', 2);
        final firstCompleter = Completer<void>();
        var reorderCall = 0;
        var serverGroups = [alpha, beta, gamma];
        final api = FakeApiService(
          reorderGroupsHandler: (items) {
            reorderCall++;
            if (reorderCall == 1) {
              return firstCompleter.future;
            }
            serverGroups = _applyGroupItems(serverGroups, items);
            return Future.value();
          },
          listGroupsHandler: () async => serverGroups,
        );
        final notifier = ServerNotifier.test(
          ServerState(api: api, isConnected: true, groups: serverGroups),
        );

        final firstFuture = notifier.reorderGroups([
          {'id': gamma.id, 'sort_order': 0},
          {'id': alpha.id, 'sort_order': 1},
          {'id': beta.id, 'sort_order': 2},
        ]);

        final secondFuture = notifier.reorderGroups([
          {'id': beta.id, 'sort_order': 0},
          {'id': gamma.id, 'sort_order': 1},
          {'id': alpha.id, 'sort_order': 2},
        ]);

        await secondFuture;
        expect(_sortedGroupIds(notifier.state.groups), [
          'beta',
          'gamma',
          'alpha',
        ]);

        firstCompleter.completeError(StateError('first reorder failed'));
        await expectLater(firstFuture, throwsA(isA<StateError>()));

        expect(_sortedGroupIds(notifier.state.groups), [
          'beta',
          'gamma',
          'alpha',
        ]);
      },
    );

    test(
      'does not let a failed older session reorder override a newer successful one',
      () async {
        final source = _group('source', 'Source', 0);
        final target = _group('target', 'Target', 1);
        final dragged = _session('dragged', groupId: source.id, sortOrder: 0);
        final alpha = _session('alpha', groupId: target.id, sortOrder: 0);
        final beta = _session('beta', groupId: target.id, sortOrder: 1);
        final firstCompleter = Completer<void>();
        var reorderCall = 0;
        var serverSessions = [dragged, alpha, beta];
        final api = FakeApiService(
          reorderSessionsHandler: (items) {
            reorderCall++;
            if (reorderCall == 1) {
              return firstCompleter.future;
            }
            serverSessions = _applySessionItems(serverSessions, items);
            return Future.value();
          },
          listGroupsHandler: () async => [source, target],
          listSessionsHandler: () async => serverSessions,
        );
        final notifier = ServerNotifier.test(
          ServerState(
            api: api,
            isConnected: true,
            groups: [source, target],
            sessions: serverSessions,
          ),
        );

        final firstFuture = notifier.reorderSessions([
          {'id': dragged.id, 'sort_order': 0, 'group_id': target.id},
          {'id': alpha.id, 'sort_order': 1, 'group_id': target.id},
          {'id': beta.id, 'sort_order': 2, 'group_id': target.id},
        ]);

        final secondFuture = notifier.reorderSessions([
          {'id': beta.id, 'sort_order': 0, 'group_id': target.id},
          {'id': dragged.id, 'sort_order': 1, 'group_id': target.id},
          {'id': alpha.id, 'sort_order': 2, 'group_id': target.id},
        ]);

        await secondFuture;
        expect(
          _sortedSessionsInGroup(
            notifier.state.sessions,
            target.id,
          ).map((session) => session.id),
          ['beta', 'dragged', 'alpha'],
        );

        firstCompleter.completeError(StateError('first reorder failed'));
        await expectLater(firstFuture, throwsA(isA<StateError>()));

        expect(
          _sortedSessionsInGroup(
            notifier.state.sessions,
            target.id,
          ).map((session) => session.id),
          ['beta', 'dragged', 'alpha'],
        );
      },
    );
  });
}
