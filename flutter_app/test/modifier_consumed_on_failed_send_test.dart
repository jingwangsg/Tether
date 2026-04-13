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

/// WebSocket service that records calls and can be configured as null-like.
class _NullChannelWebSocketService extends WebSocketService {
  _NullChannelWebSocketService() : super('ws://unused');

  final StreamController<ServerMessage> _controller =
      StreamController<ServerMessage>.broadcast();
  final List<String> sentInputs = [];
  bool sendInputReturnValue = false;

  @override
  Stream<ServerMessage> get messages => _controller.stream;

  @override
  void connect() {}

  @override
  bool sendInput(String data) {
    sentInputs.add(data);
    return sendInputReturnValue;
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

class _TestUiNotifier extends UiNotifier {
  _TestUiNotifier(UiState initial) : super() {
    state = initial;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'temporary ctrl modifier is NOT consumed when sendInput returns false',
    (tester) async {
      _NullChannelWebSocketService? wsService;

      final uiNotifier = _TestUiNotifier(const UiState(
        isMobile: true,
        showKeyBar: true,
        sidebarOpen: false,
        ctrlMode: ModifierMode.temporary,
      ));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            serverProvider.overrideWith(
              (_) => ServerNotifier(autoConnect: false)
                ..state = ServerState(
                  isConnected: true,
                  config: ServerConfig(host: 'localhost', port: 7680),
                ),
            ),
            settingsProvider.overrideWith((_) => SettingsNotifier()),
            uiProvider.overrideWith((_) => uiNotifier),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 800,
                height: 600,
                child: XtermTerminalView(
                  sessionId: 'sess-modifier-test',
                  controller: TerminalController(),
                  isActive: true,
                  wsFactory: (urlBuilder) {
                    wsService = _NullChannelWebSocketService();
                    // Simulate a WS where send fails (returns false)
                    wsService!.sendInputReturnValue = false;
                    return wsService!;
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // Ctrl should still be temporary before any input
      expect(uiNotifier.state.ctrlMode, ModifierMode.temporary);

      // Simulate terminal input — this triggers _onTerminalInput
      await tester.tap(find.byType(xterm.TerminalView));
      await tester.pump(const Duration(seconds: 1));
      tester.testTextInput.enterText('  c');
      await tester.idle();
      await tester.pumpAndSettle();

      // The WS returned false from sendInput, so temporary modifier
      // should NOT have been consumed.
      expect(uiNotifier.state.ctrlMode, ModifierMode.temporary,
          reason: 'Temporary ctrl should be preserved when send fails');
    },
  );

  testWidgets(
    'temporary ctrl modifier IS consumed when sendInput returns true',
    (tester) async {
      _NullChannelWebSocketService? wsService;

      final uiNotifier = _TestUiNotifier(const UiState(
        isMobile: true,
        showKeyBar: true,
        sidebarOpen: false,
        ctrlMode: ModifierMode.temporary,
      ));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            serverProvider.overrideWith(
              (_) => ServerNotifier(autoConnect: false)
                ..state = ServerState(
                  isConnected: true,
                  config: ServerConfig(host: 'localhost', port: 7680),
                ),
            ),
            settingsProvider.overrideWith((_) => SettingsNotifier()),
            uiProvider.overrideWith((_) => uiNotifier),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 800,
                height: 600,
                child: XtermTerminalView(
                  sessionId: 'sess-modifier-test2',
                  controller: TerminalController(),
                  isActive: true,
                  wsFactory: (urlBuilder) {
                    wsService = _NullChannelWebSocketService();
                    // Simulate a WS where send succeeds (returns true)
                    wsService!.sendInputReturnValue = true;
                    return wsService!;
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(uiNotifier.state.ctrlMode, ModifierMode.temporary);

      await tester.tap(find.byType(xterm.TerminalView));
      await tester.pump(const Duration(seconds: 1));
      tester.testTextInput.enterText('  c');
      await tester.idle();
      await tester.pumpAndSettle();

      // The WS returned true from sendInput, so temporary modifier
      // should have been consumed.
      expect(uiNotifier.state.ctrlMode, ModifierMode.inactive,
          reason: 'Temporary ctrl should be consumed when send succeeds');
    },
  );
}
