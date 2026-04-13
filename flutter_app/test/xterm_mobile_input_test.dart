import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tether/providers/server_provider.dart';
import 'package:tether/providers/settings_provider.dart';
import 'package:tether/providers/ui_provider.dart';
import 'package:tether/services/websocket_service.dart';
import 'package:tether/widgets/terminal/terminal_controller.dart';
import 'package:tether/widgets/terminal/xterm_terminal_view.dart';
import 'package:xterm/xterm.dart' as xterm;

class _RecordingWebSocketService extends WebSocketService {
  _RecordingWebSocketService() : super('ws://unused');

  final StreamController<ServerMessage> _controller =
      StreamController<ServerMessage>.broadcast();
  final List<String> sentInputs = [];

  @override
  Stream<ServerMessage> get messages => _controller.stream;

  @override
  void connect() {}

  @override
  bool sendInput(String data) {
    sentInputs.add(data);
    return true;
  }

  @override
  void sendPause() {}

  @override
  void sendResume() {}

  @override
  void sendResize(int cols, int rows) {}

  @override
  void dispose() {
    _controller.close();
  }
}

class _MockWsFactory {
  _RecordingWebSocketService? service;

  WebSocketService call(String Function() urlBuilder) {
    service = _RecordingWebSocketService();
    return service!;
  }
}

class _TestUiNotifier extends UiNotifier {
  _TestUiNotifier(UiState initial) : super() {
    state = initial;
  }
}

Widget _buildHarness({
  required _MockWsFactory wsFactory,
  required UiState uiState,
}) {
  SharedPreferences.setMockInitialValues({});
  return ProviderScope(
    overrides: [
      serverProvider.overrideWith(
        (_) => ServerNotifier(autoConnect: false)
          ..state = ServerState(
            isConnected: true,
            config: ServerConfig(host: 'localhost', port: 7680),
          ),
      ),
      settingsProvider.overrideWith((_) => SettingsNotifier()),
      uiProvider.overrideWith((_) => _TestUiNotifier(uiState)),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 800,
          height: 600,
          child: XtermTerminalView(
            sessionId: 'sess-mobile-input',
            controller: TerminalController(),
            isActive: true,
            wsFactory: wsFactory.call,
          ),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('virtual ctrl applies to ordinary text input', (tester) async {
    final factory = _MockWsFactory();

    await tester.pumpWidget(
      _buildHarness(
        wsFactory: factory,
        uiState: const UiState(
          isMobile: true,
          showKeyBar: true,
          sidebarOpen: false,
          ctrlMode: ModifierMode.temporary,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byType(xterm.TerminalView));
    await tester.pump(const Duration(seconds: 1));

    tester.testTextInput.enterText('  c');
    await tester.idle();
    await tester.pumpAndSettle();

    expect(factory.service!.sentInputs, ['\x03']);
  });

  testWidgets('keyboard lock enables hardware-keyboard-only mode', (
    tester,
  ) async {
    final factory = _MockWsFactory();

    await tester.pumpWidget(
      _buildHarness(
        wsFactory: factory,
        uiState: const UiState(
          isMobile: true,
          showKeyBar: true,
          sidebarOpen: false,
          softKeyboardLocked: true,
        ),
      ),
    );
    await tester.pump();

    final terminalView = tester.widget<xterm.TerminalView>(
      find.byType(xterm.TerminalView),
    );
    expect(terminalView.hardwareKeyboardOnly, isTrue);
  });
}
