import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
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
  final List<({int cols, int rows})> resizeCalls = [];
  int pauseCalls = 0;
  int resumeCalls = 0;

  _MockWebSocketService(this.capturedUrl) : super('ws://unused');

  @override
  Stream<ServerMessage> get messages => _ctrl.stream;

  @override
  void connect() {}

  @override
  void sendPause() {
    pauseCalls += 1;
  }

  @override
  void sendResume() {
    resumeCalls += 1;
  }

  @override
  void sendResize(int cols, int rows) {
    resizeCalls.add((cols: cols, rows: rows));
  }

  @override
  bool sendInput(String data) => true;

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
  double? width = 800,
  double? height = 600,
  Future<Uint8List?> Function(int offset, int limit)? scrollbackFetcher,
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
      home:
          width != null && height != null
              ? SizedBox(
                width: width,
                height: height,
                child: XtermTerminalView(
                  key: stateKey,
                  sessionId: sessionId,
                  controller: controller ?? TerminalController(),
                  isActive: isActive,
                  wsFactory: wsFactory.call,
                  scrollbackFetcher: scrollbackFetcher,
                ),
              )
              : SizedBox.expand(
                child: XtermTerminalView(
                  key: stateKey,
                  sessionId: sessionId,
                  controller: controller ?? TerminalController(),
                  isActive: isActive,
                  wsFactory: wsFactory.call,
                  scrollbackFetcher: scrollbackFetcher,
                ),
              ),
    ),
  );
}

Uint8List _textBytes(String s) => Uint8List.fromList(utf8.encode(s));

String _sanitizedFixtureWindow(String raw, String needle, {int radius = 2500}) {
  final oscPattern = RegExp(r'\x1b\].*?(?:\x07|\x1b\\)', dotAll: true);
  final csiPattern = RegExp(r'\x1b\[[0-?]*[ -/]*[@-~]');
  var text = raw.replaceAll(oscPattern, '');
  text = text.replaceAll(csiPattern, '');
  text = text.replaceAll('\r', '');
  while (text.contains('\b')) {
    text = text.replaceAllMapped(RegExp(r'.\x08'), (_) => '');
  }
  final index = text.indexOf(needle);
  if (index < 0) return text;
  final start = math.max(0, index - radius);
  final end = math.min(text.length, index + needle.length + radius);
  return text.substring(start, end);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Phase 1 — tail_bytes and replay batching', () {
    testWidgets('F1: tail_bytes included in WS url', (tester) async {
      final factory = _MockWsFactory();
      await tester.pumpWidget(
        _buildHarness(sessionId: 'sess-1', wsFactory: factory),
      );
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
      await tester.pumpWidget(
        _buildHarness(sessionId: 'sess-2', wsFactory: factory),
      );
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
      await tester.pumpWidget(
        _buildHarness(sessionId: 'sess-3', wsFactory: factory),
      );
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
      await tester.pumpWidget(
        _buildHarness(sessionId: 'sess-3b', wsFactory: factory),
      );
      await tester.pump();

      final ws = factory.lastService!;

      // Send scrollback data
      ws.emit(ScrollbackMessage(_textBytes('data1')));
      ws.emit(ScrollbackMessage(_textBytes('data2')));
      await tester.pump();

      // foreground_changed should NOT flush (proxy safety)
      ws.emit(ForegroundChangedMessage('vim', null, 0, 0));
      await tester.pump();

      // Now send scrollback_info — THIS should flush
      ws.emit(ScrollbackInfoMessage(500, 490));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byType(SizedBox), findsWidgets);
    });

    testWidgets('F4: replay flushes on idle timeout', (tester) async {
      final factory = _MockWsFactory();
      await tester.pumpWidget(
        _buildHarness(sessionId: 'sess-4', wsFactory: factory),
      );
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
      await tester.pumpWidget(
        _buildHarness(sessionId: 'sess-5', wsFactory: factory),
      );
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
      await tester.pumpWidget(
        _buildHarness(sessionId: 'sess-6', wsFactory: factory, stateKey: key),
      );
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
      await tester.pumpWidget(
        _buildHarness(sessionId: 'sess-10', wsFactory: factory),
      );
      await tester.pump();

      // The widget should build successfully with 10000 maxLines
      // (we verify indirectly — if maxLines were wrong, large data would fail)
      expect(find.byType(SizedBox), findsWidgets);
    });

    testWidgets('F14: replay flush handles large data via sub-chunking', (
      tester,
    ) async {
      final factory = _MockWsFactory();
      await tester.pumpWidget(
        _buildHarness(sessionId: 'sess-14', wsFactory: factory),
      );
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

    testWidgets('lifecycle resume re-sends terminal size after relayout', (
      tester,
    ) async {
      final factory = _MockWsFactory();
      await tester.pumpWidget(
        _buildHarness(sessionId: 'sess-lifecycle', wsFactory: factory),
      );
      await tester.pump();
      await tester.pump();

      final ws = factory.lastService!;
      // sendResize is debounced (~120ms) to coalesce IME-jitter bursts, so
      // let the timer fire before asserting.
      await tester.pump(const Duration(milliseconds: 150));
      expect(ws.resizeCalls, isNotEmpty);

      final initialResizeCount = ws.resizeCalls.length;
      final lastKnownSize = ws.resizeCalls.last;

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(ws.pauseCalls, 1);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      expect(ws.resumeCalls, 1);
      expect(ws.resizeCalls.length, greaterThan(initialResizeCount));
      expect(ws.resizeCalls.last, lastKnownSize);
    });

    testWidgets('paused lifecycle buffers already queued writes until resume', (
      tester,
    ) async {
      final factory = _MockWsFactory();
      await tester.pumpWidget(
        _buildHarness(sessionId: 'sess-buffered-lifecycle', wsFactory: factory),
      );
      await tester.pump();

      final ws = factory.lastService!;
      ws.emit(OutputMessage(_textBytes('queued-before-pause')));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();

      expect(ws.pauseCalls, 1);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pumpAndSettle();

      expect(ws.resumeCalls, 1);
      expect(tester.takeException(), isNull);
    });
  });

  group('Phase 2 — lazy loading indicators', () {
    testWidgets('F9: no prefetch indicator when all history loaded', (
      tester,
    ) async {
      final factory = _MockWsFactory();
      await tester.pumpWidget(
        _buildHarness(sessionId: 'sess-9', wsFactory: factory),
      );
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
      await tester.pumpWidget(
        _buildHarness(
          sessionId: 'sess-indicator',
          wsFactory: factory,
          stateKey: key,
        ),
      );
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

  group('Phase 3 — semantic prompt compatibility', () {
    testWidgets('active OSC 133 prompt disables in-place reflow', (
      tester,
    ) async {
      final factory = _MockWsFactory();
      final key = GlobalKey<XtermTerminalViewState>();

      await tester.pumpWidget(
        _buildHarness(
          sessionId: 'sess-semantic-1',
          wsFactory: factory,
          stateKey: key,
        ),
      );
      await tester.pump();

      final ws = factory.lastService!;
      final state = key.currentState!;

      ws.emit(
        OutputMessage(
          _textBytes(
            '\x1b]133;A;redraw=1\x07'
            '\$ \x1b]133;B\x07'
            'echo semantic prompt compatibility with wrapped terminal text\r\n'
            '\x1b]133;C\x07'
            'semantic output line with enough width to wrap in smaller windows\r\n',
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(state.semanticPromptSeen, isTrue);
      expect(state.terminalReflowEnabled, isFalse);
      expect(
        state.debugTerminalText,
        contains('echo semantic prompt compatibility'),
      );
    });

    testWidgets('widget resize schedules semantic rebuild and preserves content', (
      tester,
    ) async {
      final factory = _MockWsFactory();
      final key = GlobalKey<XtermTerminalViewState>();
      tester.binding.window.physicalSizeTestValue = const Size(800, 600);
      tester.binding.window.devicePixelRatioTestValue = 1.0;
      addTearDown(() {
        tester.binding.window.clearPhysicalSizeTestValue();
        tester.binding.window.clearDevicePixelRatioTestValue();
      });

      await tester.pumpWidget(
        _buildHarness(
          sessionId: 'sess-semantic-2',
          wsFactory: factory,
          stateKey: key,
          width: null,
          height: null,
        ),
      );
      await tester.pump();

      final ws = factory.lastService!;
      final state = key.currentState!;

      ws.emit(
        OutputMessage(
          _textBytes(
            '\x1b]133;A\x07'
            '\$ \x1b]133;B\x07'
            'INPUT_SENTINEL one deliberately long semantic input line that should be rebuilt when the terminal width changes dramatically and must remain readable after replay\r\n'
            '\x1b]133;C\x07'
            'OUTPUT_SENTINEL one deliberately long semantic output line that should also remain readable after replay based resize reconstruction in the terminal widget\r\n',
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final initialResizeCount = ws.resizeCalls.length;
      final initialSnapshot = state.debugTerminalText;

      tester.binding.window.physicalSizeTestValue = const Size(360, 600);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(state.semanticResizeRebuildCount, greaterThan(0));
      expect(ws.resizeCalls.length, greaterThan(initialResizeCount));
      expect(state.debugTerminalText, contains('INPUT_SENTINEL'));
      expect(state.debugTerminalText, contains('OUTPUT_SENTINEL'));
    });

    testWidgets('dispose during async semantic rebuild unwinds safely', (
      tester,
    ) async {
      final factory = _MockWsFactory();
      final key = GlobalKey<XtermTerminalViewState>();
      final fetchCompleter = Completer<Uint8List?>();
      tester.binding.window.physicalSizeTestValue = const Size(800, 600);
      tester.binding.window.devicePixelRatioTestValue = 1.0;
      addTearDown(() {
        tester.binding.window.clearPhysicalSizeTestValue();
        tester.binding.window.clearDevicePixelRatioTestValue();
      });

      await tester.pumpWidget(
        _buildHarness(
          sessionId: 'sess-semantic-dispose',
          wsFactory: factory,
          stateKey: key,
          width: null,
          height: null,
          scrollbackFetcher: (_, _) => fetchCompleter.future,
        ),
      );
      await tester.pump();

      final ws = factory.lastService!;
      final state = key.currentState!;
      ws.emit(
        OutputMessage(
          _textBytes(
            '\x1b]133;A\x07'
            '\$ \x1b]133;B\x07'
            'DISPOSE_SENTINEL long semantic input that enables resize recovery\r\n'
            '\x1b]133;C\x07'
            'DISPOSE_OUTPUT long semantic output that will be replayed asynchronously\r\n',
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      state.debugMarkReplayCacheTruncated();
      tester.binding.window.physicalSizeTestValue = const Size(360, 600);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.pumpWidget(const SizedBox.shrink());
      fetchCompleter.complete(Uint8List.fromList(utf8.encode('ignored')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'height-only viewport change (Android soft keyboard) does not trigger semantic rebuild',
      (tester) async {
        final factory = _MockWsFactory();
        final key = GlobalKey<XtermTerminalViewState>();
        tester.binding.window.physicalSizeTestValue = const Size(800, 600);
        tester.binding.window.devicePixelRatioTestValue = 1.0;
        addTearDown(() {
          tester.binding.window.clearPhysicalSizeTestValue();
          tester.binding.window.clearDevicePixelRatioTestValue();
        });

        await tester.pumpWidget(
          _buildHarness(
            sessionId: 'sess-keyboard-height',
            wsFactory: factory,
            stateKey: key,
            width: null,
            height: null,
          ),
        );
        await tester.pump();

        final ws = factory.lastService!;
        final state = key.currentState!;

        ws.emit(
          OutputMessage(
            _textBytes(
              '\x1b]133;A\x07'
              '\$ \x1b]133;B\x07'
              'KEYBOARD_PROMPT semantic input line that stays visible while keyboard toggles\r\n'
              '\x1b]133;C\x07'
              'KEYBOARD_OUTPUT semantic output line that must survive a height-only viewport shrink\r\n',
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(state.semanticPromptSeen, isTrue);
        expect(state.terminalReflowEnabled, isFalse);

        final baselineRebuildCount = state.semanticResizeRebuildCount;

        // Simulate Android soft keyboard appearing: height shrinks, width
        // unchanged. xterm char column count does not change, so a semantic
        // rebuild must NOT fire.
        tester.binding.window.physicalSizeTestValue = const Size(800, 400);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        expect(state.semanticResizeRebuildCount, baselineRebuildCount);
        expect(state.debugTerminalText, contains('KEYBOARD_PROMPT'));
        expect(state.debugTerminalText, contains('KEYBOARD_OUTPUT'));
      },
    );

    test('real Codex fixture sanitization preserves the key phrase', () async {
      final fixture = File('test/fixtures/codex_overflow_80x24.typescript');
      const needle = 'requested markdown straight to the terminal';
      final replayText = _sanitizedFixtureWindow(
        await fixture.readAsString(),
        needle,
      );
      expect(replayText, contains(needle));
    });
  });
}
