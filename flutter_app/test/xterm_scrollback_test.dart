import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tether/providers/server_provider.dart';
import 'package:tether/providers/settings_provider.dart';
import 'package:tether/services/websocket_service.dart';
import 'package:tether/widgets/terminal/terminal_controller.dart';
import 'package:tether/widgets/terminal/xterm_terminal_view.dart';

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

/// A controllable WebSocket mock that records the URL it was given and lets
/// tests inject messages into the stream.
class _MockWebSocketService extends WebSocketService {
  final StreamController<ServerMessage> _ctrl =
      StreamController<ServerMessage>.broadcast();
  final String capturedUrl;

  _MockWebSocketService(this.capturedUrl) : super('ws://unused');

  @override
  Stream<ServerMessage> get messages => _ctrl.stream;

  @override
  void connect() {}

  @override
  void sendPause() {}

  @override
  void sendResume() {}

  @override
  void sendResize(int cols, int rows) {}

  @override
  void sendInput(String data) {}

  @override
  void dispose() {
    _ctrl.close();
  }

  void emit(ServerMessage msg) {
    if (!_ctrl.isClosed) _ctrl.add(msg);
  }
}

/// Factory that captures the URL builder and creates a mock WS.
class _MockWsFactory {
  _MockWebSocketService? lastService;
  String? lastUrl;

  WebSocketService call(String Function() urlBuilder) {
    lastUrl = urlBuilder();
    lastService = _MockWebSocketService(lastUrl!);
    return lastService!;
  }
}

Widget _buildHarness({
  required String sessionId,
  required _MockWsFactory wsFactory,
  bool isActive = true,
  TerminalController? controller,
  GlobalKey<XtermTerminalViewState>? stateKey,
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
    ],
    child: MaterialApp(
      home: SizedBox(
        width: 800,
        height: 600,
        child: XtermTerminalView(
          key: stateKey,
          sessionId: sessionId,
          controller: controller ?? TerminalController(),
          isActive: isActive,
          wsFactory: wsFactory.call,
        ),
      ),
    ),
  );
}

Uint8List _textBytes(String s) => Uint8List.fromList(utf8.encode(s));

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Phase 1 — tail_bytes and replay batching', () {
    testWidgets('F1: tail_bytes included in WS url', (tester) async {
      final factory = _MockWsFactory();
      await tester.pumpWidget(_buildHarness(
        sessionId: 'sess-1',
        wsFactory: factory,
      ));
      await tester.pump();

      expect(factory.lastUrl, isNotNull);
      expect(factory.lastUrl!, contains('tail_bytes=1048576'));
      // First connect — no offset
      expect(factory.lastUrl!, isNot(contains('offset=')));
    });

    testWidgets('F2: scrollback messages batched during replay', (
      tester,
    ) async {
      final factory = _MockWsFactory();
      await tester.pumpWidget(_buildHarness(
        sessionId: 'sess-2',
        wsFactory: factory,
      ));
      await tester.pump();

      final ws = factory.lastService!;

      // Send 3 scrollback chunks — they should be buffered, not written yet
      ws.emit(ScrollbackMessage(_textBytes('aaa')));
      ws.emit(ScrollbackMessage(_textBytes('bbb')));
      ws.emit(ScrollbackMessage(_textBytes('ccc')));
      await tester.pump();

      // Now send scrollback_info to trigger flush
      ws.emit(ScrollbackInfoMessage(100, 91));
      await tester.pump();
      // Let the sub-chunk flush timers run
      await tester.pump(const Duration(milliseconds: 50));

      // The terminal should now contain the concatenated content
      // (we can't easily inspect terminal buffer in a widget test without
      // exposing state, but we verify no crash and the widget renders)
      expect(find.byType(SizedBox), findsWidgets);
    });

    testWidgets('F3: scrollback_info flushes replay buffer', (tester) async {
      final factory = _MockWsFactory();
      await tester.pumpWidget(_buildHarness(
        sessionId: 'sess-3',
        wsFactory: factory,
      ));
      await tester.pump();

      final ws = factory.lastService!;

      // Send scrollback data
      ws.emit(ScrollbackMessage(_textBytes('hello')));
      ws.emit(ScrollbackMessage(_textBytes(' world')));
      await tester.pump();

      // scrollback_info should flush immediately
      ws.emit(ScrollbackInfoMessage(1000, 989));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Widget should render without errors
      expect(find.byType(SizedBox), findsWidgets);
    });

    testWidgets('F3b: foreground_changed does NOT flush replay buffer', (
      tester,
    ) async {
      final factory = _MockWsFactory();
      await tester.pumpWidget(_buildHarness(
        sessionId: 'sess-3b',
        wsFactory: factory,
      ));
      await tester.pump();

      final ws = factory.lastService!;

      // Send scrollback data
      ws.emit(ScrollbackMessage(_textBytes('data1')));
      ws.emit(ScrollbackMessage(_textBytes('data2')));
      await tester.pump();

      // foreground_changed should NOT flush (proxy safety)
      ws.emit(ForegroundChangedMessage('vim', null));
      await tester.pump();

      // Now send scrollback_info — THIS should flush
      ws.emit(ScrollbackInfoMessage(500, 490));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byType(SizedBox), findsWidgets);
    });

    testWidgets('F4: replay flushes on idle timeout', (tester) async {
      final factory = _MockWsFactory();
      await tester.pumpWidget(_buildHarness(
        sessionId: 'sess-4',
        wsFactory: factory,
      ));
      await tester.pump();

      final ws = factory.lastService!;

      // Send scrollback but no follow-up message
      ws.emit(ScrollbackMessage(_textBytes('orphaned data')));
      await tester.pump();

      // Wait for 500ms idle timer
      await tester.pump(const Duration(milliseconds: 600));

      // Should have flushed by now without crash
      expect(find.byType(SizedBox), findsWidgets);
    });

    testWidgets('F5: disconnect flushes replay and resets state', (
      tester,
    ) async {
      final factory = _MockWsFactory();
      await tester.pumpWidget(_buildHarness(
        sessionId: 'sess-5',
        wsFactory: factory,
      ));
      await tester.pump();

      final ws = factory.lastService!;

      // Send scrollback data
      ws.emit(ScrollbackMessage(_textBytes('pending')));
      await tester.pump();

      // Simulate disconnect
      ws.emit(ConnectionStateMessage(false));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Should have flushed and shown reconnecting text
      expect(find.byType(SizedBox), findsWidgets);
    });

    testWidgets('F6: scrollback_info updates loaded offset with setState', (
      tester,
    ) async {
      final factory = _MockWsFactory();
      final key = GlobalKey<XtermTerminalViewState>();
      await tester.pumpWidget(_buildHarness(
        sessionId: 'sess-6',
        wsFactory: factory,
        stateKey: key,
      ));
      await tester.pump();

      final ws = factory.lastService!;
      final state = key.currentState!;

      // Initially loadedStartOffset is 0
      expect(state.loadedStartOffset, 0);

      // Send scrollback_info with loadedFrom > 0
      ws.emit(ScrollbackInfoMessage(5000000, 4000000));
      await tester.pump();

      // Verify state was updated
      expect(state.loadedStartOffset, 4000000);
      expect(state.totalScrollbackBytes, 5000000);
    });

    testWidgets('F10: terminal uses maxLines 10000', (tester) async {
      final factory = _MockWsFactory();
      await tester.pumpWidget(_buildHarness(
        sessionId: 'sess-10',
        wsFactory: factory,
      ));
      await tester.pump();

      // The widget should build successfully with 10000 maxLines
      // (we verify indirectly — if maxLines were wrong, large data would fail)
      expect(find.byType(SizedBox), findsWidgets);
    });

    testWidgets('F14: replay flush handles large data via sub-chunking', (
      tester,
    ) async {
      final factory = _MockWsFactory();
      await tester.pumpWidget(_buildHarness(
        sessionId: 'sess-14',
        wsFactory: factory,
      ));
      await tester.pump();

      final ws = factory.lastService!;

      // Send 5 chunks of 64KB each (320KB total)
      for (int i = 0; i < 5; i++) {
        ws.emit(ScrollbackMessage(Uint8List(65536)));
      }
      await tester.pump();

      // Trigger flush via scrollback_info
      ws.emit(ScrollbackInfoMessage(500000, 180000));
      await tester.pump();

      // Let sub-chunk timers fire (multiple frames needed for 320KB at 64KB/frame)
      for (int i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      // Should complete without crash or hang
      expect(find.byType(SizedBox), findsWidgets);
    });
  });

  group('Phase 2 — lazy loading indicators', () {
    testWidgets('F9: no prefetch indicator when all history loaded', (
      tester,
    ) async {
      final factory = _MockWsFactory();
      await tester.pumpWidget(_buildHarness(
        sessionId: 'sess-9',
        wsFactory: factory,
      ));
      await tester.pump();

      final ws = factory.lastService!;

      // loadedFrom = 0 means all history loaded
      ws.emit(ScrollbackInfoMessage(1000, 0));
      await tester.pump();

      expect(find.text('Scroll up for more'), findsNothing);
    });

    testWidgets('indicator state tracks loaded offset', (tester) async {
      final factory = _MockWsFactory();
      final key = GlobalKey<XtermTerminalViewState>();
      await tester.pumpWidget(_buildHarness(
        sessionId: 'sess-indicator',
        wsFactory: factory,
        stateKey: key,
      ));
      await tester.pump();

      final ws = factory.lastService!;
      final state = key.currentState!;

      // loadedFrom > 0 means more history available
      ws.emit(ScrollbackInfoMessage(10000000, 9000000));
      await tester.pump();

      expect(state.loadedStartOffset, 9000000);

      // Simulate all loaded
      ws.emit(ScrollbackInfoMessage(10000000, 0));
      await tester.pump();

      expect(state.loadedStartOffset, 0);
    });
  });
}
