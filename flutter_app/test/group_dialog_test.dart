import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tether/models/group.dart';
import 'package:tether/models/ssh_host.dart';
import 'package:tether/providers/server_provider.dart';
import 'package:tether/services/api_service.dart';
import 'package:tether/widgets/sidebar/group_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Group makeGroup({String? defaultCwd, String? sshHost}) {
    return Group(
      id: 'group-1',
      name: 'Group',
      defaultCwd: defaultCwd,
      sshHost: sshHost,
    );
  }

  Finder pathField() => find.byWidgetPredicate(
    (widget) => widget is TextField && widget.decoration?.labelText == 'Path',
  );

  Finder hostField() => find.byWidgetPredicate(
    (widget) =>
        widget is DropdownButtonFormField<String?> &&
        widget.decoration?.labelText == 'Host',
  );

  Future<void> pumpDialog(
    WidgetTester tester, {
    required ServerState state,
    Group? group,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          groupDialogServerStateProvider.overrideWith((ref) => state),
        ],
        child: MaterialApp(home: Scaffold(body: GroupDialog(group: group))),
      ),
    );
    await tester.pump();
  }

  String pathText(WidgetTester tester) {
    return tester
        .widgetList<EditableText>(find.byType(EditableText))
        .last
        .controller
        .text;
  }

  FocusNode pathFocusNode(WidgetTester tester) {
    return tester
        .widgetList<EditableText>(find.byType(EditableText))
        .last
        .focusNode;
  }

  DropdownButtonFormField<String?> hostDropdown(WidgetTester tester) {
    return tester.widget<DropdownButtonFormField<String?>>(hostField());
  }

  DropdownButton<String?> hostDropdownButton(WidgetTester tester) {
    return tester.widget<DropdownButton<String?>>(
      find.byWidgetPredicate((widget) => widget is DropdownButton<String?>),
    );
  }

  testWidgets(
    'tab selects the first completion and arrow down selects the next one',
    (tester) async {
      final api = ApiService(
        baseUrl: 'http://example.test',
        client: MockClient((request) async {
          expect(request.url.path, '/api/completions');
          final path = request.url.queryParameters['path'];
          final results = switch (path) {
            '~/a' => ['~/alpha/', '~/amber/'],
            _ => <String>[],
          };

          return http.Response(jsonEncode(results), 200);
        }),
      );

      await pumpDialog(
        tester,
        state: ServerState(api: api, isConnected: true),
        group: makeGroup(defaultCwd: ''),
      );

      await tester.enterText(pathField(), '~/a');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      expect(find.text('~/alpha/'), findsOneWidget);
      expect(find.text('~/amber/'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(pathText(tester), '~/alpha/');

      await tester.enterText(pathField(), '~/a');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      expect(pathText(tester), '~/amber/');
    },
  );

  testWidgets(
    'remote completion failure shows inline status instead of a silent popup',
    (tester) async {
      final api = ApiService(
        baseUrl: 'http://example.test',
        client: MockClient((request) async {
          expect(request.url.path, '/api/completions/remote');
          return http.Response('Permission denied (publickey).', 503);
        }),
      );

      await pumpDialog(
        tester,
        state: ServerState(
          api: api,
          isConnected: true,
          sshHosts: [SshHost(host: 'bad-host', reachable: true)],
        ),
        group: makeGroup(defaultCwd: '', sshHost: 'bad-host'),
      );

      await tester.enterText(pathField(), '~/project');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      expect(
        find.text(
          'Remote completion unavailable: Permission denied (publickey).',
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('group-dialog-completions')),
        findsNothing,
      );
    },
  );

  testWidgets('new group excludes only explicitly unreachable ssh hosts', (
    tester,
  ) async {
    await pumpDialog(
      tester,
      state: ServerState(
        isConnected: true,
        sshHosts: [
          SshHost(host: 'up-host', reachable: true),
          SshHost(host: 'down-host', reachable: false),
          SshHost(host: 'unknown-host'),
        ],
      ),
    );

    final dropdown = hostDropdown(tester);
    final dropdownButton = hostDropdownButton(tester);
    expect(
      dropdownButton.items!.map((item) => item.value).toList(),
      equals([null, 'up-host', 'unknown-host']),
    );
    expect(dropdown.initialValue, isNull);
  });

  testWidgets(
    'edit group keeps the current unreachable host in the disabled dropdown',
    (tester) async {
      await pumpDialog(
        tester,
        state: ServerState(
          isConnected: true,
          sshHosts: [
            SshHost(host: 'up-host', reachable: true),
            SshHost(host: 'down-host', reachable: false),
          ],
        ),
        group: makeGroup(defaultCwd: '', sshHost: 'down-host'),
      );

      final dropdown = hostDropdown(tester);
      final dropdownButton = hostDropdownButton(tester);
      expect(
        dropdownButton.items!.map((item) => item.value).toList(),
        equals([null, 'down-host', 'up-host']),
      );
      expect(dropdown.initialValue, 'down-host');
      expect(dropdown.onChanged, isNull);
    },
  );

  testWidgets('remote host connecting shows neutral inline status', (
    tester,
  ) async {
    final api = ApiService(
      baseUrl: 'http://example.test',
      client: MockClient((request) async {
        expect(request.url.path, '/api/completions/remote');
        return http.Response('remote_host_connecting', 503);
      }),
    );

    await pumpDialog(
      tester,
      state: ServerState(
        api: api,
        isConnected: true,
        sshHosts: [SshHost(host: 'slow-host', reachable: true)],
      ),
      group: makeGroup(defaultCwd: '', sshHost: 'slow-host'),
    );

    await tester.enterText(pathField(), '~/project');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(find.text('Remote host connecting…'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('group-dialog-completions')),
      findsNothing,
    );

    final statusText = tester.widget<Text>(
      find.byKey(const ValueKey('group-dialog-completion-status')),
    );
    expect(statusText.style?.color, Colors.white54);
  });

  testWidgets('unreachable ssh host short-circuits before calling the API', (
    tester,
  ) async {
    final api = ApiService(
      baseUrl: 'http://example.test',
      client: MockClient((request) async {
        fail('completion API should not be called for unreachable ssh hosts');
      }),
    );

    await pumpDialog(
      tester,
      state: ServerState(
        api: api,
        isConnected: true,
        sshHosts: [SshHost(host: 'down-host', reachable: false)],
      ),
      group: makeGroup(defaultCwd: '', sshHost: 'down-host'),
    );

    await tester.enterText(pathField(), '~/project');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(find.text('SSH host unreachable'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('group-dialog-completions')),
      findsNothing,
    );
  });

  testWidgets('stale completion responses do not overwrite the newest result', (
    tester,
  ) async {
    final pending = <String, Completer<http.Response>>{};
    final api = ApiService(
      baseUrl: 'http://example.test',
      client: MockClient((request) {
        final path = request.url.queryParameters['path']!;
        return pending.putIfAbsent(path, Completer<http.Response>.new).future;
      }),
    );

    await pumpDialog(
      tester,
      state: ServerState(api: api, isConnected: true),
      group: makeGroup(defaultCwd: ''),
    );

    await tester.enterText(pathField(), '~/a');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    await tester.enterText(pathField(), '~/b');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    pending['~/b']!.complete(http.Response(jsonEncode(['~/beta/']), 200));
    await tester.pump();

    pending['~/a']!.complete(http.Response(jsonEncode(['~/alpha/']), 200));
    await tester.pump();

    expect(find.text('~/beta/'), findsOneWidget);
    expect(find.text('~/alpha/'), findsNothing);
  });

  testWidgets('tab falls through when the completion popup is hidden', (
    tester,
  ) async {
    final api = ApiService(
      baseUrl: 'http://example.test',
      client: MockClient((request) async {
        expect(request.url.path, '/api/completions');
        return http.Response(jsonEncode(<String>[]), 200);
      }),
    );

    await pumpDialog(
      tester,
      state: ServerState(api: api, isConnected: true),
      group: makeGroup(defaultCwd: ''),
    );

    await tester.tap(pathField());
    await tester.pump();
    expect(pathFocusNode(tester).hasFocus, isTrue);

    await tester.enterText(pathField(), '~/z');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(find.text('No matching directories'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('group-dialog-completions')),
      findsNothing,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(pathText(tester), '~/z');
    expect(pathFocusNode(tester).hasFocus, isFalse);
  });
}
