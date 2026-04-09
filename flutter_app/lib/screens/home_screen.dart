import 'dart:io' show Platform;
import 'dart:math' show min;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/server_provider.dart';
import '../providers/session_provider.dart';
import '../providers/ui_provider.dart';
import '../platform/terminal_backend.dart';
import '../widgets/sidebar/sidebar.dart';
import '../widgets/terminal/terminal_area.dart';

class HomeScreen extends ConsumerStatefulWidget {
  final TerminalBackend backend;

  const HomeScreen({super.key, required this.backend});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  static const _windowChannel = MethodChannel('dev.tether/window');
  final _terminalAreaKey = GlobalKey<TerminalAreaState>();
  bool _edgeDragActive = false;
  double _dragDistance = 0;
  bool _autoOpenedTestSession = false;

  bool get _usesNativeRenameShortcut => widget.backend.platformId == 'native';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_usesNativeRenameShortcut) {
      _windowChannel.setMethodCallHandler(_handleWindowMethodCall);
    }
    HardwareKeyboard.instance.addHandler(_handleGlobalKey);
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final usedNativeRenameShortcut = oldWidget.backend.platformId == 'native';
    if (usedNativeRenameShortcut == _usesNativeRenameShortcut) {
      return;
    }
    if (usedNativeRenameShortcut) {
      _windowChannel.setMethodCallHandler(null);
    }
    if (_usesNativeRenameShortcut) {
      _windowChannel.setMethodCallHandler(_handleWindowMethodCall);
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleGlobalKey);
    if (_usesNativeRenameShortcut) {
      _windowChannel.setMethodCallHandler(null);
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<dynamic> _handleWindowMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'renameActiveSession':
        _renameActiveSession();
        return null;
      default:
        return null;
    }
  }

  bool _handleGlobalKey(KeyEvent event) {
    if (event is KeyDownEvent && HardwareKeyboard.instance.isMetaPressed) {
      if (event.logicalKey == LogicalKeyboardKey.keyR &&
          !_usesNativeRenameShortcut) {
        _renameActiveSession();
        return true;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyF) {
        _terminalAreaKey.currentState?.showSearchForActiveSession();
        return true;
      }
    }
    return false;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _updateLayout();
    });
  }

  @override
  void didChangeMetrics() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _updateLayout();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Lifecycle tracking available for future use.
  }

  void _updateLayout() {
    final size = MediaQuery.of(context).size;
    final isMobile = Platform.isAndroid || size.width < 768;
    final showKeyBar = Platform.isAndroid || size.width < 768;
    ref.read(uiProvider.notifier).setMobile(isMobile);
    ref.read(uiProvider.notifier).setShowKeyBar(showKeyBar);
  }

  double _sidebarWidth(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    return min(280.0, screenWidth * 0.85);
  }

  @override
  Widget build(BuildContext context) {
    final serverState = ref.watch(serverProvider);
    final sessionState = ref.watch(sessionProvider);
    final uiState = ref.watch(uiProvider);
    final sidebarW = _sidebarWidth(context);
    _maybeAutoOpenTestSession(serverState, sessionState);

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart:
            uiState.isMobile
                ? (details) {
                  final dx = details.globalPosition.dx;
                  final screenWidth = MediaQuery.of(context).size.width;
                  if (!uiState.sidebarOpen && dx < screenWidth / 2) {
                    _edgeDragActive = true;
                    _dragDistance = 0;
                  } else if (uiState.sidebarOpen) {
                    _edgeDragActive = true;
                    _dragDistance = 0;
                  } else {
                    _edgeDragActive = false;
                  }
                }
                : null,
        onHorizontalDragUpdate:
            uiState.isMobile
                ? (details) {
                  if (!_edgeDragActive) return;
                  _dragDistance += details.delta.dx;
                }
                : null,
        onHorizontalDragEnd:
            uiState.isMobile
                ? (details) {
                  if (!_edgeDragActive) return;
                  _edgeDragActive = false;
                  if (!uiState.sidebarOpen && _dragDistance > 80) {
                    ref.read(uiProvider.notifier).setSidebarOpen(true);
                  } else if (uiState.sidebarOpen && _dragDistance < -80) {
                    ref.read(uiProvider.notifier).setSidebarOpen(false);
                  }
                }
                : null,
        child: Padding(
          padding: EdgeInsets.only(
            left: MediaQuery.of(context).padding.left,
            right: MediaQuery.of(context).padding.right,
          ),
          child: Stack(
            children: [
              Row(
                children: [
                  if (!uiState.isMobile && uiState.sidebarOpen) const Sidebar(),
                  Expanded(
                    child: TerminalArea(
                      key: _terminalAreaKey,
                      backend: widget.backend,
                    ),
                  ),
                ],
              ),
              if (uiState.isMobile) ...[
                IgnorePointer(
                  ignoring: !uiState.sidebarOpen,
                  child: GestureDetector(
                    onTap:
                        () =>
                            ref.read(uiProvider.notifier).setSidebarOpen(false),
                    child: AnimatedOpacity(
                      opacity: uiState.sidebarOpen ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOutCubic,
                      child: Container(color: Colors.black54),
                    ),
                  ),
                ),
                AnimatedPositioned(
                  left: uiState.sidebarOpen ? 0 : -sidebarW,
                  top: 0,
                  bottom: 0,
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOutCubic,
                  child: const Sidebar(),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _renameActiveSession() {
    final activeId = ref.read(sessionProvider).activeSessionId;
    if (activeId == null) return;
    final session =
        ref
            .read(serverProvider)
            .sessions
            .where((s) => s.id == activeId)
            .firstOrNull;
    if (session == null) return;

    final nav = Navigator.of(context);
    nav.popUntil((route) => route is! PopupRoute);

    final controller = TextEditingController(text: session.name);
    showDialog(
      context: context,
      builder: (ctx) {
        void doRename() {
          final name = controller.text.trim();
          if (name.isNotEmpty) {
            ref
                .read(serverProvider.notifier)
                .updateSession(session.id, name: name);
            Navigator.pop(ctx);
          }
        }

        return AlertDialog(
          title: const Text('Rename Session'),
          content: TextField(
            controller: controller,
            autofocus: true,
            onSubmitted: (_) => doRename(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(onPressed: doRename, child: const Text('Rename')),
          ],
        );
      },
    );
  }

  void _maybeAutoOpenTestSession(
    ServerState serverState,
    SessionState sessionState,
  ) {
    if (_autoOpenedTestSession || sessionState.activeSessionId != null) {
      return;
    }
    final targetName =
        Platform.environment['TETHER_TEST_AUTO_OPEN_SESSION_NAME'];
    if (targetName == null || targetName.isEmpty) {
      return;
    }
    String? targetSessionId;
    for (final session in serverState.sessions) {
      if (session.name == targetName) {
        targetSessionId = session.id;
        break;
      }
    }
    if (targetSessionId == null) {
      return;
    }
    _autoOpenedTestSession = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      ref.read(sessionProvider.notifier).openTab(targetSessionId!);
    });
  }
}
