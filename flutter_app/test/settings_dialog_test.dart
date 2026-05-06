import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tether/models/remote_host_status.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tether/models/ssh_host.dart';
import 'package:tether/providers/server_provider.dart';
import 'package:tether/providers/settings_provider.dart';
import 'package:tether/widgets/sidebar/settings_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('settings dialog no longer shows the old tab-bar toggle', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith((ref) => SettingsNotifier()),
        serverProvider.overrideWith((ref) => ServerNotifier.test()),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const _SettingsHarness(),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('Show Tab Bar'), findsNothing);
    expect(find.text('Scroll to Bottom on Output'), findsOneWidget);
  });

  testWidgets('settings dialog persists the selected ssh host', (tester) async {
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
        child: const _SettingsHarness(),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('None'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('osmo_9000').last);
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('selected_ssh_host'), 'osmo_9000');
  });

  testWidgets('settings dialog persists restart before connect', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith((ref) => SettingsNotifier()),
        serverProvider.overrideWith((ref) => ServerNotifier.test()),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const _SettingsHarness(),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restart before connect'));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('restart_remote_on_connect'), isTrue);
  });

  testWidgets('settings dialog shows remote status and host actions', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'selected_ssh_host': 'osmo_9000'});
    final notifier = _DeployRecordingServerNotifier(
      ServerState(
        isConnected: true,
        sshHosts: [SshHost(host: 'osmo_9000', reachable: true)],
        remoteHosts: const [
          RemoteHostStatus(
            host: 'osmo_9000',
            status: RemoteHostConnectionStatus.ready,
            tunnelPort: 49152,
          ),
        ],
      ),
    );
    final container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith((ref) => SettingsNotifier()),
        serverProvider.overrideWith((ref) => notifier),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const _SettingsHarness(),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Ready'), findsOneWidget);
    expect(find.text('Restart'), findsOneWidget);

    await tester.tap(find.text('Deploy'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restart'));
    await tester.pumpAndSettle();

    expect(notifier.deployedHosts, ['osmo_9000']);
    expect(notifier.restartedHosts, ['osmo_9000']);
    expect(find.text('Restarted'), findsOneWidget);
  });
}

class _SettingsHarness extends ConsumerWidget {
  const _SettingsHarness();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      home: Scaffold(
        body: Consumer(
          builder: (context, ref, _) {
            return TextButton(
              onPressed: () => showSettingsDialog(context, ref),
              child: const Text('Open'),
            );
          },
        ),
      ),
    );
  }
}

class _DeployRecordingServerNotifier extends ServerNotifier {
  _DeployRecordingServerNotifier(super.state) : super.test();

  final List<String> deployedHosts = [];
  final List<String> restartedHosts = [];

  @override
  Future<RemoteHostStatus> deployRemoteHost(String host) async {
    deployedHosts.add(host);
    return RemoteHostStatus(
      host: host,
      status: RemoteHostConnectionStatus.ready,
      tunnelPort: 49152,
    );
  }

  @override
  Future<RemoteHostStatus> restartRemoteHost(String host) async {
    restartedHosts.add(host);
    return RemoteHostStatus(
      host: host,
      status: RemoteHostConnectionStatus.ready,
      tunnelPort: 49152,
    );
  }
}
