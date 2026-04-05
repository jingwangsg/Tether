import 'dart:async';
import 'dart:math' show min;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/session.dart';
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
  final _terminalAreaKey = GlobalKey<TerminalAreaState>();
  bool _edgeDragActive = false;
  double _dragDistance = 0;
  Timer? _attentionAckTimer;
  String? _pendingAttentionSessionId;
  int? _pendingAttentionSeq;
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_handleGlobalKey);
    _checkMobile();
  }

  @override
  void dispose() {
    _cancelAttentionAck();
    HardwareKeyboard.instance.removeHandler(_handleGlobalKey);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  bool _handleGlobalKey(KeyEvent event) {
    if (event is KeyDownEvent && HardwareKeyboard.instance.isMetaPressed) {
      if (event.logicalKey == LogicalKeyboardKey.keyR) {
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
  void didChangeMetrics() {
    _checkMobile();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    _syncAttentionAck(
      ref.read(sessionProvider).activeSessionId,
      ref.read(serverProvider).sessions,
    );
  }

  void _checkMobile() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final width = MediaQuery.of(context).size.width;
      ref.read(uiProvider.notifier).setMobile(width < 768);
    });
  }

  double _sidebarWidth(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    return min(280.0, screenWidth * 0.85);
  }

  @override
  Widget build(BuildContext context) {
    final uiState = ref.watch(uiProvider);
    final serverState = ref.watch(serverProvider);
    final sessionState = ref.watch(sessionProvider);
    final sidebarW = _sidebarWidth(context);
    _syncAttentionAck(sessionState.activeSessionId, serverState.sessions);

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
                      () => ref.read(uiProvider.notifier).setSidebarOpen(false),
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

  bool get _isAppForeground => _lifecycleState == AppLifecycleState.resumed;

  void _syncAttentionAck(String? activeSessionId, List<Session> sessions) {
    if (!_isAppForeground || activeSessionId == null) {
      _cancelAttentionAck();
      return;
    }

    final activeSession =
        sessions.where((session) => session.id == activeSessionId).firstOrNull;
    if (activeSession == null ||
        !activeSession.needsAttention ||
        activeSession.attentionSeq <= 0) {
      _cancelAttentionAck();
      return;
    }

    if (_pendingAttentionSessionId == activeSession.id &&
        _pendingAttentionSeq == activeSession.attentionSeq &&
        _attentionAckTimer != null) {
      return;
    }

    _cancelAttentionAck();
    _pendingAttentionSessionId = activeSession.id;
    _pendingAttentionSeq = activeSession.attentionSeq;
    _attentionAckTimer = Timer(const Duration(milliseconds: 750), () {
      if (!mounted || !_isAppForeground) return;
      final currentActive = ref.read(sessionProvider).activeSessionId;
      if (currentActive != activeSession.id) return;
      final currentSession =
          ref
              .read(serverProvider)
              .sessions
              .where((session) => session.id == activeSession.id)
              .firstOrNull;
      if (currentSession == null ||
          !currentSession.needsAttention ||
          currentSession.attentionSeq != activeSession.attentionSeq) {
        return;
      }
      unawaited(
        ref
            .read(serverProvider.notifier)
            .ackSessionAttention(activeSession.id, activeSession.attentionSeq),
      );
    });
  }

  void _cancelAttentionAck() {
    _attentionAckTimer?.cancel();
    _attentionAckTimer = null;
    _pendingAttentionSessionId = null;
    _pendingAttentionSeq = null;
  }
}
