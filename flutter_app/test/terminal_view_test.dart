import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tether/providers/server_provider.dart';
import 'package:tether/services/websocket_service.dart';
import 'package:tether/widgets/terminal/terminal_controller.dart';
import 'package:tether/widgets/terminal/terminal_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeMacosPlatformViewsController platformViews;
  final List<String> terminalActions = <String>[];
  final List<bool> activationChanges = <bool>[];

  setUp(() {
    platformViews =
        _FakeMacosPlatformViewsController()
          ..registerViewType('dev.tether/terminal_surface');
    terminalActions.clear();
    activationChanges.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.tether/terminal_input'),
          (call) async {
            if (call.method == 'performAction') {
              final args = call.arguments as Map<dynamic, dynamic>;
              terminalActions.add(args['action'] as String);
            }
            if (call.method == 'setActive') {
              final args = call.arguments as Map<dynamic, dynamic>;
              activationChanges.add(args['active'] as bool);
            }
            return null;
          },
        );
  });

  tearDown(() async {
    await platformViews.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.tether/terminal_input'),
          null,
        );
  });

  testWidgets('search toggle does not recreate native AppKitView', (
    tester,
  ) async {
    final key = GlobalKey<TerminalViewState>();

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 640,
            height: 480,
            child: TerminalView(
              key: key,
              sessionId: 'session-1',
              controller: TerminalController(),
              serverConfig: ServerConfig(host: 'localhost', port: 7680),
              isActive: true,
              metadataWsFactory: (_) => _FakeWebSocketService(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(platformViews.createCount, 1);
    expect(platformViews.disposeCount, 0);
    expect(platformViews.views, hasLength(1));

    final initialViewId = platformViews.views.values.single.id;

    key.currentState!.showSearch();
    await tester.pump();

    expect(find.text('Search...'), findsOneWidget);
    expect(platformViews.createCount, 1);
    expect(platformViews.disposeCount, 0);
    expect(platformViews.views.values.single.id, initialViewId);
    expect(terminalActions, <String>['start_search']);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();

    expect(find.text('Search...'), findsNothing);
    expect(platformViews.createCount, 1);
    expect(platformViews.disposeCount, 0);
    expect(platformViews.views.values.single.id, initialViewId);
    expect(terminalActions, <String>['start_search', 'end_search']);
  });

  testWidgets('active session toggles do not recreate native AppKitView', (
    tester,
  ) async {
    final controller = TerminalController();

    Widget buildTerminal({required bool isActive}) {
      return MaterialApp(
        home: Center(
          child: SizedBox(
            width: 640,
            height: 480,
            child: TerminalView(
              sessionId: 'session-1',
              controller: controller,
              serverConfig: ServerConfig(host: 'localhost', port: 7680),
              isActive: isActive,
              metadataWsFactory: (_) => _FakeWebSocketService(),
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(buildTerminal(isActive: true));
    await tester.pump();

    expect(platformViews.createCount, 1);
    expect(platformViews.disposeCount, 0);
    final initialViewId = platformViews.views.values.single.id;

    await tester.pumpWidget(buildTerminal(isActive: false));
    await tester.pump();
    await tester.pumpWidget(buildTerminal(isActive: true));
    await tester.pump();

    expect(platformViews.createCount, 1);
    expect(platformViews.disposeCount, 0);
    expect(platformViews.views.values.single.id, initialViewId);
    expect(activationChanges, <bool>[false, true]);
  });
}

class _FakeWebSocketService extends WebSocketService {
  _FakeWebSocketService() : super('ws://unused');

  @override
  Stream<ServerMessage> get messages => const Stream<ServerMessage>.empty();

  @override
  void connect() {}

  @override
  void dispose() {}
}

class _FakeMacosPlatformViewsController {
  _FakeMacosPlatformViewsController() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform_views, _onMethodCall);
  }

  final Map<int, _FakeAppKitView> views = <int, _FakeAppKitView>{};
  final Set<String> _registeredViewTypes = <String>{};
  int createCount = 0;
  int disposeCount = 0;

  void registerViewType(String viewType) {
    _registeredViewTypes.add(viewType);
  }

  Future<void> dispose() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform_views, null);
  }

  Future<dynamic> _onMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'create':
        final args = call.arguments as Map<dynamic, dynamic>;
        final id = args['id'] as int;
        final viewType = args['viewType'] as String;
        final creationParams = args['params'] as Uint8List?;

        if (!_registeredViewTypes.contains(viewType)) {
          throw PlatformException(
            code: 'error',
            message: 'Unregistered platform view type: $viewType',
          );
        }
        views[id] = _FakeAppKitView(
          id: id,
          viewType: viewType,
          creationParams: creationParams,
        );
        createCount++;
        return null;
      case 'dispose':
        final id = call.arguments as int;
        views.remove(id);
        disposeCount++;
        return null;
      case 'acceptGesture':
      case 'rejectGesture':
        return null;
    }

    return null;
  }
}

class _FakeAppKitView {
  const _FakeAppKitView({
    required this.id,
    required this.viewType,
    this.creationParams,
  });

  final int id;
  final String viewType;
  final Uint8List? creationParams;
}
