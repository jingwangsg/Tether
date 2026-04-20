import 'dart:io' show Platform;
import 'dart:math' show min;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/group.dart';
import '../models/session.dart';
import '../providers/server_provider.dart';
import '../providers/session_provider.dart';
import '../providers/sidebar_width_provider.dart';
import '../providers/ui_provider.dart';
import '../platform/terminal_backend.dart';
import '../utils/session_creation.dart';
import '../utils/shell_dialogs.dart';
import '../widgets/sidebar/sidebar.dart';
import '../widgets/sidebar/sidebar_resizer.dart';
import '../widgets/terminal/terminal_area.dart';

class HomeScreen extends ConsumerStatefulWidget {
  final TerminalBackend backend;

  const HomeScreen({super.key, required this.backend});

  static String? fontZoomAction(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.equal ||
        key == LogicalKeyboardKey.add ||
        key == LogicalKeyboardKey.numpadAdd) {
      return 'increase_font_size:1';
    }
    if (key == LogicalKeyboardKey.minus ||
        key == LogicalKeyboardKey.numpadSubtract) {
      return 'decrease_font_size:1';
    }
    if (key == LogicalKeyboardKey.digit0 || key == LogicalKeyboardKey.numpad0) {
      return 'reset_font_size';
    }
    return null;
  }

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  static const _windowChannel = MethodChannel('dev.tether/window');
  static const _sidebarOpenEdgeWidth = 24.0;
  final _terminalAreaKey = GlobalKey<TerminalAreaState>();
  bool _edgeDragActive = false;
  double _dragDistance = 0;
  bool _autoOpenedTestSession = false;

  bool get _usesNativeShellShortcuts => widget.backend.platformId == 'native';

  bool _isNativeOwnedShellShortcut(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return false;
    }

    final projectIndex = _digitIndex(event.logicalKey);
    if (HardwareKeyboard.instance.isMetaPressed) {
      if (event.logicalKey == LogicalKeyboardKey.keyN ||
          event.logicalKey == LogicalKeyboardKey.keyT ||
          event.logicalKey == LogicalKeyboardKey.keyR ||
          projectIndex != null) {
        return true;
      }
    }

    if (HardwareKeyboard.instance.isControlPressed && projectIndex != null) {
      return true;
    }

    return false;
  }

  void _syncDesktopShortcutHintsFromKeyboard() {
    if (_usesNativeShellShortcuts) {
      return;
    }
    ref.read(uiProvider.notifier).setDesktopShortcutHints(
          showProjectHints: HardwareKeyboard.instance.isMetaPressed,
          showSessionHints: HardwareKeyboard.instance.isControlPressed,
        );
  }

  void _clearDesktopShortcutHints() {
    ref.read(uiProvider.notifier).clearDesktopShortcutHints();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_usesNativeShellShortcuts) {
      _windowChannel.setMethodCallHandler(_handleWindowMethodCall);
    }
    HardwareKeyboard.instance.addHandler(_handleGlobalKey);
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final usedNativeShellShortcuts = oldWidget.backend.platformId == 'native';
    if (usedNativeShellShortcuts == _usesNativeShellShortcuts) {
      return;
    }
    if (usedNativeShellShortcuts) {
      _windowChannel.setMethodCallHandler(null);
    }
    if (_usesNativeShellShortcuts) {
      _windowChannel.setMethodCallHandler(_handleWindowMethodCall);
    }
  }

  @override
  void deactivate() {
    _clearDesktopShortcutHints();
    super.deactivate();
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleGlobalKey);
    if (_usesNativeShellShortcuts) {
      _windowChannel.setMethodCallHandler(null);
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<dynamic> _handleWindowMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'renameActiveSession':
        _performShellAction('renameCurrentSession');
        return null;
      case 'performShellAction':
        final args = Map<String, dynamic>.from(
          call.arguments as Map? ?? const {},
        );
        await _performShellAction(
          args['action'] as String,
          index: args['index'] as int?,
        );
        return null;
      case 'setShellShortcutHints':
        final args = Map<String, dynamic>.from(
          call.arguments as Map? ?? const {},
        );
        ref.read(uiProvider.notifier).setDesktopShortcutHints(
              showProjectHints: args['showProjectHints'] as bool? ?? false,
              showSessionHints: args['showSessionHints'] as bool? ?? false,
            );
        return null;
      default:
        return null;
    }
  }

  bool _handleGlobalKey(KeyEvent event) {
    _syncDesktopShortcutHintsFromKeyboard();

    if (event is KeyUpEvent) {
      _syncDesktopShortcutHintsFromKeyboard();
      return false;
    }

    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;

    if (_usesNativeShellShortcuts && _isNativeOwnedShellShortcut(event)) {
      return false;
    }

    if (HardwareKeyboard.instance.isMetaPressed) {
      if (event is KeyDownEvent) {
        if (event.logicalKey == LogicalKeyboardKey.keyN) {
          _performShellAction('newProject');
          return true;
        }
        if (event.logicalKey == LogicalKeyboardKey.keyT) {
          _performShellAction('newSession');
          return true;
        }
        if (event.logicalKey == LogicalKeyboardKey.keyR &&
            HardwareKeyboard.instance.isShiftPressed) {
          _performShellAction('renameCurrentSession');
          return true;
        }
        if (event.logicalKey == LogicalKeyboardKey.keyR) {
          _performShellAction('renameCurrentProject');
          return true;
        }
        if (event.logicalKey == LogicalKeyboardKey.keyF) {
          _terminalAreaKey.currentState?.showSearchForActiveSession();
          return true;
        }
        if (event.logicalKey == LogicalKeyboardKey.keyB && Platform.isMacOS) {
          ref.read(uiProvider.notifier).toggleSidebar();
          return true;
        }
        final projectIndex = _digitIndex(event.logicalKey);
        if (projectIndex != null) {
          _performShellAction('selectProjectByNumber', index: projectIndex);
          return true;
        }
      }
      // Font zoom: supports key repeat
      final fontAction = HomeScreen.fontZoomAction(event.logicalKey);
      if (fontAction != null) {
        _terminalAreaKey.currentState?.performActionOnActiveSession(fontAction);
        return true;
      }
    }

    if (event is KeyDownEvent && HardwareKeyboard.instance.isControlPressed) {
      final sessionIndex = _digitIndex(event.logicalKey);
      if (sessionIndex != null) {
        _performShellAction('selectSessionByNumber', index: sessionIndex);
        return true;
      }
    }

    return false;
  }

  int? _digitIndex(LogicalKeyboardKey key) {
    final digits = {
      LogicalKeyboardKey.digit1: 0,
      LogicalKeyboardKey.digit2: 1,
      LogicalKeyboardKey.digit3: 2,
      LogicalKeyboardKey.digit4: 3,
      LogicalKeyboardKey.digit5: 4,
      LogicalKeyboardKey.digit6: 5,
      LogicalKeyboardKey.digit7: 6,
      LogicalKeyboardKey.digit8: 7,
      LogicalKeyboardKey.digit9: 8,
    };
    return digits[key];
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
    final groups = ref.watch(serverProvider.select((s) => s.groups));
    final sessions = ref.watch(serverProvider.select((s) => s.sessions));
    final sessionState = ref.watch(sessionProvider);
    final uiState = ref.watch(uiProvider);
    final sidebarW = _sidebarWidth(context);
    _maybeAutoOpenTestSession(groups, sessions, sessionState);

    return PopScope<void>(
      canPop: !uiState.isMobile,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop || !uiState.isMobile || !uiState.sidebarOpen) {
          return;
        }
        ref.read(uiProvider.notifier).setSidebarOpen(false);
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF121212),
        // TerminalArea manages keyboard and bottom-safe-area insets manually
        // so the terminal, floating nav pad, and MobileKeyBar all agree on
        // the same bottom obstruction.
        resizeToAvoidBottomInset: false,
        body: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragStart:
              uiState.isMobile
                  ? (details) {
                    final currentUiState = ref.read(uiProvider);
                    if (currentUiState.selectionGestureActive) {
                      _edgeDragActive = false;
                      _dragDistance = 0;
                      return;
                    }
                    final dx = details.globalPosition.dx;
                    if (!currentUiState.sidebarOpen &&
                        dx <= _sidebarOpenEdgeWidth) {
                      _edgeDragActive = true;
                      _dragDistance = 0;
                    } else if (currentUiState.sidebarOpen) {
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
                    if (ref.read(uiProvider).selectionGestureActive) {
                      _edgeDragActive = false;
                      _dragDistance = 0;
                      return;
                    }
                    _dragDistance += details.delta.dx;
                  }
                  : null,
          onHorizontalDragEnd:
              uiState.isMobile
                  ? (details) {
                    if (!_edgeDragActive) return;
                    final currentUiState = ref.read(uiProvider);
                    _edgeDragActive = false;
                    if (currentUiState.selectionGestureActive) {
                      _dragDistance = 0;
                      return;
                    }
                    if (!currentUiState.sidebarOpen && _dragDistance > 80) {
                      ref.read(uiProvider.notifier).setSidebarOpen(true);
                    } else if (currentUiState.sidebarOpen &&
                        _dragDistance < -80) {
                      ref.read(uiProvider.notifier).setSidebarOpen(false);
                    }
                    _dragDistance = 0;
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
                    if (!uiState.isMobile && uiState.sidebarOpen) ...[
                      Sidebar(width: ref.watch(sidebarWidthProvider)),
                      const SidebarResizer(),
                    ],
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
                          () => ref
                              .read(uiProvider.notifier)
                              .setSidebarOpen(false),
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
      ),
    );
  }

  Future<void> _performShellAction(String action, {int? index}) async {
    _clearDesktopShortcutHints();
    final serverState = ref.read(serverProvider);
    final projects =
        serverState.groups.where((g) => g.parentId == null).toList()
          ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    final selectedProjectId = ref.read(sessionProvider).selectedProjectId;
    final selectedProject =
        projects.where((p) => p.id == selectedProjectId).firstOrNull;
    final activeSessionId = ref.read(sessionProvider).activeSessionId;
    final activeSession =
        serverState.sessions.where((s) => s.id == activeSessionId).firstOrNull;

    switch (action) {
      case 'newProject':
        final project = await showCreateProjectDialog(context);
        if (project == null || !mounted) return;
        await createSessionInCurrentProject(
          context,
          ref,
          preferredProject: project,
        );
        return;
      case 'newSession':
        await createSessionInCurrentProject(context, ref);
        return;
      case 'renameCurrentProject':
        if (selectedProject != null) {
          await showRenameProjectDialog(context, ref, selectedProject);
        }
        return;
      case 'renameCurrentSession':
        if (activeSession != null) {
          await showRenameSessionDialog(context, ref, activeSession);
        }
        return;
      case 'selectProjectByNumber':
        if (index != null && index >= 0 && index < projects.length) {
          ref.read(sessionProvider.notifier).selectProject(projects[index].id);
        }
        return;
      case 'selectSessionByNumber':
        if (selectedProject == null) return;
        final sessions =
            serverState.sessions
                .where((s) => s.groupId == selectedProject.id)
                .toList()
              ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
        if (index != null && index >= 0 && index < sessions.length) {
          ref
              .read(sessionProvider.notifier)
              .setActiveSession(
                projectId: selectedProject.id,
                sessionId: sessions[index].id,
              );
        }
        return;
    }
  }

  void _maybeAutoOpenTestSession(
    List<Group> groups,
    List<Session> sessions,
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
    Session? targetSession;
    for (final session in sessions) {
      if (session.name == targetName) {
        targetSession = session;
        break;
      }
    }
    if (targetSession == null) {
      return;
    }
    _autoOpenedTestSession = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final target = targetSession!;
      ref.read(sessionProvider.notifier)
        ..selectProject(target.groupId)
        ..setActiveSession(
          projectId: target.groupId,
          sessionId: target.id,
        );
    });
  }
}
