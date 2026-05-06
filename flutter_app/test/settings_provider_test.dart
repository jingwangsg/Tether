import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tether/providers/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ssh host settings load from and persist to preferences', () async {
    SharedPreferences.setMockInitialValues({
      'selected_ssh_host': 'osmo_9000',
      'restart_remote_on_connect': true,
    });

    final notifier = SettingsNotifier();
    await Future<void>.delayed(Duration.zero);

    expect(notifier.state.selectedSshHost, 'osmo_9000');
    expect(notifier.state.restartRemoteOnConnect, isTrue);

    await notifier.setSelectedSshHost('devbox');
    await notifier.setRestartRemoteOnConnect(false);
    var prefs = await SharedPreferences.getInstance();
    expect(notifier.state.selectedSshHost, 'devbox');
    expect(notifier.state.restartRemoteOnConnect, isFalse);
    expect(prefs.getString('selected_ssh_host'), 'devbox');
    expect(prefs.getBool('restart_remote_on_connect'), isFalse);

    await notifier.setSelectedSshHost(null);
    prefs = await SharedPreferences.getInstance();
    expect(notifier.state.selectedSshHost, isNull);
    expect(prefs.containsKey('selected_ssh_host'), isFalse);
  });
}
