import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tether/providers/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('selected ssh host loads from and persists to preferences', () async {
    SharedPreferences.setMockInitialValues({'selected_ssh_host': 'osmo_9000'});

    final notifier = SettingsNotifier();
    await Future<void>.delayed(Duration.zero);

    expect(notifier.state.selectedSshHost, 'osmo_9000');

    await notifier.setSelectedSshHost('devbox');
    var prefs = await SharedPreferences.getInstance();
    expect(notifier.state.selectedSshHost, 'devbox');
    expect(prefs.getString('selected_ssh_host'), 'devbox');

    await notifier.setSelectedSshHost(null);
    prefs = await SharedPreferences.getInstance();
    expect(notifier.state.selectedSshHost, isNull);
    expect(prefs.containsKey('selected_ssh_host'), isFalse);
  });
}
