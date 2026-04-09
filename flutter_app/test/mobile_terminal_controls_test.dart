import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tether/models/group.dart';
import 'package:tether/models/mobile_key.dart';
import 'package:tether/models/session.dart';
import 'package:tether/platform/terminal_backend.dart';
import 'package:tether/providers/server_provider.dart';
import 'package:tether/providers/session_provider.dart';
import 'package:tether/providers/ui_provider.dart';
import 'package:tether/widgets/terminal/mobile_key_bar.dart';
import 'package:tether/widgets/terminal/terminal_area.dart';
import 'package:tether/widgets/terminal/terminal_controller.dart';

Group _group(String id) => Group(id: id, name: id);

Session _session(String id, {required String groupId}) {
  return Session(
    id: id,
    groupId: groupId,
    name: id,
    shell: 'bash',
    cols: 80,
    rows: 24,
    cwd: '/tmp/$id',
    isAlive: true,
    createdAt: '',
    lastActive: '',
  );
}

ProviderContainer _container({
  required ServerState serverState,
  UiState? uiState,
}) {
  return ProviderContainer(
    overrides: [
      serverProvider.overrideWith((ref) => _TestServerNotifier(serverState)),
      if (uiState != null)
        uiProvider.overrideWith((ref) => _TestUiNotifier(uiState)),
    ],
  );
}

Future<void> _pumpWithContainer(
  WidgetTester tester,
  ProviderContainer container,
  Widget child,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Scaffold(body: child)),
    ),
  );
  await tester.pumpAndSettle();
}

int _buttonCountForRow(WidgetTester tester, String key) {
  final row = tester.widget<Row>(find.byKey(ValueKey(key)));
  return row.children.whereType<Expanded>().length;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'mobile key bar renders two balanced rows and no horizontal list',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final pressed = <String>[];

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 390,
                child: MobileKeyBar(onKeyPress: pressed.add),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ListView), findsNothing);
      expect(find.byKey(const ValueKey('mobile-key-row-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('mobile-key-row-1')), findsOneWidget);

      final firstRowCount = _buttonCountForRow(tester, 'mobile-key-row-0');
      final secondRowCount = _buttonCountForRow(tester, 'mobile-key-row-1');
      expect((firstRowCount - secondRowCount).abs(), lessThanOrEqualTo(1));

      await tester.tap(find.byKey(const ValueKey('mobile-toolbar-button-~')));
      await tester.tap(find.byKey(const ValueKey('mobile-toolbar-button-/')));
      await tester.pump();

      expect(pressed, ['~', '/']);
    },
  );

  testWidgets('mobile key bar button width expands with available width', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Future<Size> pumpAtWidth(double width) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: width,
                child: MobileKeyBar(onKeyPress: (_) {}),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return tester.getSize(
        find.byKey(const ValueKey('mobile-toolbar-button-Esc')),
      );
    }

    final compactSize = await pumpAtWidth(360);
    final wideSize = await pumpAtWidth(720);

    expect(wideSize.width, greaterThan(compactSize.width));
  });

  testWidgets('floating nav pad sends keys and updates position on drag', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final pressed = <String>[];

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 430,
              height: 500,
              child: MobileFloatingNavPad(onKeyPress: pressed.add),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final padFinder = find.byKey(const ValueKey('mobile-floating-nav-pad'));
    final handleFinder = find.byKey(
      const ValueKey('mobile-floating-nav-drag-handle'),
    );

    final initialTopLeft = tester.getTopLeft(padFinder);

    await tester.tap(
      find.byKey(const ValueKey('mobile-floating-nav-button-\u2190')),
    );
    await tester.pump();

    expect(pressed, ['\x1b[D']);

    await tester.drag(handleFinder, const Offset(-48, -36));
    await tester.pumpAndSettle();

    final movedTopLeft = tester.getTopLeft(padFinder);
    expect(movedTopLeft.dx, lessThan(initialTopLeft.dx));
    expect(movedTopLeft.dy, lessThan(initialTopLeft.dy));
  });

  testWidgets('terminal area shows split controls and routes input correctly', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final group = _group('local');
    final session = _session('session-1', groupId: group.id);
    final backend = _FakeTerminalBackend();
    final container = _container(
      serverState: ServerState(
        isConnected: true,
        groups: [group],
        sessions: [session],
      ),
      uiState: const UiState(
        isMobile: true,
        showKeyBar: true,
        sidebarOpen: false,
        mobileKeys: defaultMobileToolbarKeys,
      ),
    );
    addTearDown(container.dispose);

    container.read(sessionProvider.notifier).openTab(session.id);

    await _pumpWithContainer(tester, container, TerminalArea(backend: backend));

    expect(find.byKey(const ValueKey('mobile-key-bar')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('mobile-floating-nav-pad')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('mobile-toolbar-button-~')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('mobile-toolbar-button-/')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('mobile-toolbar-button-\u2190')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('mobile-floating-nav-button-\u2190')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('mobile-toolbar-button-/')));
    await tester.tap(
      find.byKey(const ValueKey('mobile-floating-nav-button-\u2192')),
    );
    await tester.pump();

    expect(backend.sentText, ['/', '\x1b[C']);
  });
}

class _TestServerNotifier extends ServerNotifier {
  _TestServerNotifier(super.state) : super.test();
}

class _TestUiNotifier extends UiNotifier {
  _TestUiNotifier(UiState initial) : super() {
    state = initial;
  }
}

class _FakeTerminalBackend implements TerminalBackend {
  final List<String> sentText = [];

  @override
  bool get isLocalPty => false;

  @override
  String get platformId => 'fake';

  @override
  Widget createTerminalWidget({
    Key? key,
    required String sessionId,
    required TerminalController controller,
    required ServerConfig? serverConfig,
    String? command,
    String? cwd,
    required bool isActive,
    bool imagePasteBridgeEnabled = false,
    VoidCallback? onSessionExited,
    void Function(String? title)? onTitleChanged,
    ForegroundChangedCallback? onForegroundChanged,
    Future<void> Function(Uint8List data, String mimeType)? onClipboardImage,
  }) {
    controller.attach(
      sendText: sentText.add,
      paste: sentText.add,
      showSearch: () {},
      copy: () {},
    );
    return Container(key: key);
  }
}
