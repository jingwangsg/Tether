import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/session.dart';
import '../../providers/server_provider.dart';
import '../../providers/session_provider.dart';
import '../../providers/ui_provider.dart';
import '../../platform/paste_service.dart';
import '../../platform/volume_keys.dart';
import '../../platform/terminal_backend.dart';
import '../../utils/session_interaction.dart';
import 'session_top_bar.dart';
import 'terminal_controller.dart';
import 'terminal_bottom_insets.dart';
import 'terminal_image_paste.dart';
import 'mobile_key_bar.dart';

class TerminalArea extends ConsumerStatefulWidget {
  final TerminalBackend backend;

  const TerminalArea({super.key, required this.backend});

  @override
  ConsumerState<TerminalArea> createState() => TerminalAreaState();
}

class TerminalAreaState extends ConsumerState<TerminalArea> {
  static const int _maxRetainedTerminalViews = 6;

  final Map<String, TerminalController> _terminalControllers = {};
  final List<String> _retainedSessionOrder = <String>[];
  final VolumeKeyService _volumeKeys = VolumeKeyService();
  final PasteService _pasteService = PasteService();
  Set<String>? _pendingInteractiveSessionIds;
  bool _interactiveTabSyncScheduled = false;
  String? _warmSessionId;

  @override
  void initState() {
    super.initState();
    _volumeKeys.setEnabled(true);

    // PasteService is a fallback path for macOS window-level Cmd+V forwarding.
    // The native Ghostty backend now prefers AppKit responder-chain paste.
    // With xterm backend, paste() calls _terminal.paste() which handles bracketed
    // paste mode correctly. Falls back to PasteTextIntent (Actions widget below)
    // if the native handler doesn't claim the shortcut.
    _pasteService.onPaste = (text) {
      final focusCtx = FocusManager.instance.primaryFocus?.context;

      // Strategy A: the currently focused widget is inside a dialog route (e.g. the
      // new-group or rename-group dialog). Forward paste to the text field and block
      // the terminal from receiving it.
      // Checking the focused context's route — not isCurrent on the terminal's route —
      // avoids false-positives from popup menus (showMenu) which push a PopupRoute
      // without taking keyboard focus, so Cmd+V still reaches the terminal normally.
      if (focusCtx != null && ModalRoute.of(focusCtx) is DialogRoute) {
        Actions.maybeInvoke(
          focusCtx,
          const PasteTextIntent(SelectionChangedCause.keyboard),
        );
        return;
      }

      // Strategy B: text field has focus with no dialog open (edge-case safety net).
      if (focusCtx?.widget is EditableText) return;

      // Strategy C: normal terminal paste.
      final activeId = ref.read(sessionProvider).activeSessionId;
      if (activeId == null) return;
      _terminalControllers[activeId]?.paste(text);
    };

    final initialServerState = ref.read(serverProvider);
    if (initialServerState.sessions.isNotEmpty ||
        initialServerState.groups.isNotEmpty) {
      _scheduleInteractiveTabSync(initialServerState);
    }

    ref.listenManual(serverProvider, (previous, next) {
      _scheduleInteractiveTabSync(next);
    });
    ref.listenManual(sessionProvider.select((state) => state.activeSessionId), (
      previous,
      next,
    ) {
      if (previous != null && previous != next) {
        _warmSessionId = previous;
        _touchRetainedSession(previous);
      }
      if (next != null) {
        _touchRetainedSession(next);
        _ackAttentionIfNeeded(next);
      }
    });
  }

  @override
  void dispose() {
    _pasteService.dispose();
    _volumeKeys.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final navState = ref.watch(sessionProvider);
    final uiState = ref.watch(uiProvider);
    final selectedProjectId = navState.selectedProjectId;
    final groups = ref.watch(serverProvider.select((s) => s.groups));
    final sessions = ref.watch(serverProvider.select((s) => s.sessions));
    final serverConfig = ref.watch(serverProvider.select((s) => s.config));
    final media = MediaQuery.of(context);
    final bottomInset = media.viewInsets.bottom;
    final bottomPadding = mobileKeyBarBottomPaddingForMediaQuery(media);
    final bottomObstruction = terminalBottomObstructionForMediaQuery(
      media,
      showKeyBar: uiState.showKeyBar,
    );

    final interactiveSessions =
        sessions.where((s) => isSessionInteractive(s, groups)).toList();
    final interactiveSessionIds = interactiveSessions.map((s) => s.id).toSet();

    // Derive project sessions: filter to selected project, interactive only, sorted.
    final projectSessions =
        interactiveSessions
            .where((s) => s.groupId == selectedProjectId)
            .toList()
          ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

    // Derive active session id, falling back to first project session.
    var activeId = navState.activeSessionId;
    if (activeId == null || !projectSessions.any((s) => s.id == activeId)) {
      activeId = projectSessions.firstOrNull?.id;
      if (activeId != null &&
          activeId != navState.activeSessionId &&
          selectedProjectId != null) {
        final fallbackId = activeId;
        final projId = selectedProjectId;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            ref
                .read(sessionProvider.notifier)
                .setActiveSession(
                  projectId: projId,
                  sessionId: fallbackId,
                  selectProject: false,
                );
          }
        });
      }
    }

    _terminalControllers.removeWhere(
      (id, _) => !interactiveSessionIds.contains(id),
    );
    final retainedSessionIds = _resolveRetainedSessionIds(
      interactiveSessionIds: interactiveSessionIds,
      activeSessionId: activeId,
    );
    final sessionsById = {
      for (final session in interactiveSessions) session.id: session,
    };
    final retainedSessions = _retainedSessionOrder
        .where(retainedSessionIds.contains)
        .map((id) => sessionsById[id])
        .whereType<Session>()
        .toList(growable: false);

    Widget content;
    if (projectSessions.isEmpty) {
      content = const Expanded(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.terminal, size: 64, color: Colors.white24),
              SizedBox(height: 16),
              Text(
                'No sessions in this project',
                style: TextStyle(color: Colors.white38, fontSize: 16),
              ),
              SizedBox(height: 8),
              Text(
                'Select a session from the sidebar or create a new one',
                style: TextStyle(color: Colors.white24, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    } else {
      content = Expanded(
        child: Column(
          children: [
            SessionTopBar(
              projectId: selectedProjectId,
              sessions: projectSessions,
              activeSessionId: activeId,
            ),
            Expanded(
              child: ClipRect(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ...retainedSessions.map((session) {
                      final isActive = session.id == activeId;
                      final isVisibleInUI = isActive;
                      final group =
                          groups
                              .where((g) => g.id == session.groupId)
                              .firstOrNull;

                      final terminalController = _terminalControllers
                          .putIfAbsent(session.id, TerminalController.new);

                      return Offstage(
                        offstage: !isVisibleInUI,
                        child: widget.backend.createTerminalWidget(
                          key: ValueKey(
                            '${widget.backend.platformId}:${session.id}',
                          ),
                          sessionId: session.id,
                          controller: terminalController,
                          serverConfig: serverConfig,
                          command: session.shell,
                          cwd: session.cwd,
                          isActive: isActive,
                          isVisibleInUI: isVisibleInUI,
                          imagePasteBridgeEnabled: shouldEnableImagePasteBridge(
                            session: session,
                            group: group,
                          ),
                          onSessionExited: () {
                            ref.read(serverProvider.notifier).refresh();
                          },
                          onForegroundChanged:
                              (
                                process,
                                oscTitle,
                                attentionSeq,
                                attentionAckSeq,
                              ) => _handleSessionStatusUpdate(
                                sessionId: session.id,
                                process: process,
                                oscTitle: oscTitle,
                                attentionSeq: attentionSeq,
                                attentionAckSeq: attentionAckSeq,
                                isActive: isActive,
                              ),
                          onClipboardImage: (data, mimeType) {
                            return _handleClipboardImage(
                              sessionId: session.id,
                              data: data,
                              mimeType: mimeType,
                            );
                          },
                        ),
                      );
                    }),
                    // Reserve space at the bottom for the MobileKeyBar
                    // overlay (and the soft keyboard when it's up) so the
                    // draggable floating nav pad's default position never
                    // lands beneath the keybar / keyboard — its taps would
                    // otherwise be intercepted by the overlay.
                    if (uiState.showKeyBar && projectSessions.isNotEmpty)
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 0,
                        bottom: bottomObstruction,
                        child: MobileFloatingNavPad(
                          onKeyPress: (data) {
                            final id =
                                ref.read(sessionProvider).activeSessionId;
                            if (id != null) {
                              _terminalControllers[id]?.sendText(data);
                            }
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Actions(
      actions: {
        PasteTextIntent: CallbackAction<PasteTextIntent>(
          onInvoke: (_) {
            _pasteToActiveTerminal();
            return null;
          },
        ),
      },
      child: Focus(
        autofocus: true,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(child: Column(children: [content])),
            if (uiState.showKeyBar)
              Positioned(
                left: 0,
                right: 0,
                bottom: bottomInset,
                child: Container(
                  color: const Color(0xFF1E1E1E),
                  padding: EdgeInsets.only(
                    bottom: bottomInset > 0 ? 0 : bottomPadding,
                  ),
                  child: MobileKeyBar(
                    onKeyPress: (data) {
                      final id = ref.read(sessionProvider).activeSessionId;
                      if (id != null) {
                        _terminalControllers[id]?.sendText(data);
                      }
                    },
                    onCopy: () {
                      final id = ref.read(sessionProvider).activeSessionId;
                      if (id != null) _terminalControllers[id]?.copy();
                    },
                    onPaste: () => _pasteToActiveTerminal(),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _pasteToActiveTerminal() async {
    final activeId = ref.read(sessionProvider).activeSessionId;
    if (activeId == null) return;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) {
      _terminalControllers[activeId]?.paste(data!.text!);
    }
  }

  void showSearchForActiveSession() {
    final activeId = ref.read(sessionProvider).activeSessionId;
    if (activeId == null) return;
    _terminalControllers[activeId]?.showSearch();
  }

  void performActionOnActiveSession(String action) {
    final activeId = ref.read(sessionProvider).activeSessionId;
    if (activeId == null) return;
    _terminalControllers[activeId]?.performAction(action);
  }

  Future<void> _handleClipboardImage({
    required String sessionId,
    required Uint8List data,
    required String mimeType,
  }) async {
    final serverState = ref.read(serverProvider);
    final api = serverState.api;
    if (api == null) return;

    final session =
        serverState.sessions.where((item) => item.id == sessionId).firstOrNull;
    final group =
        session == null
            ? null
            : serverState.groups
                .where((item) => item.id == session.groupId)
                .firstOrNull;

    final coordinator = TerminalImagePasteCoordinator(
      upload: api.uploadClipboardImage,
    );
    final outcome = await coordinator.handle(
      sessionId: sessionId,
      session: session,
      group: group,
      image: ClipboardImagePayload(data: data, mimeType: mimeType),
    );

    final injectedText = outcome.injectedText;
    if (injectedText != null) {
      _terminalControllers[sessionId]?.sendText(injectedText);
    }

    final errorMessage = outcome.errorMessage;
    if (errorMessage != null && mounted) {
      ScaffoldMessenger.maybeOf(context)
        ?..removeCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(errorMessage)));
    }
  }

  void _scheduleInteractiveTabSync(ServerState serverState) {
    _pendingInteractiveSessionIds = interactiveSessionIds(
      serverState.sessions,
      serverState.groups,
    );
    if (_interactiveTabSyncScheduled) return;
    _interactiveTabSyncScheduled = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _interactiveTabSyncScheduled = false;
      if (!mounted) return;
      final validIds = _pendingInteractiveSessionIds ?? const <String>{};
      _pendingInteractiveSessionIds = null;
      ref.read(sessionProvider.notifier).cleanupSessions(validIds);
    });
  }

  void _touchRetainedSession(String sessionId) {
    _retainedSessionOrder.remove(sessionId);
    _retainedSessionOrder.insert(0, sessionId);
  }

  void _ensureRetainedSession(String sessionId) {
    if (_retainedSessionOrder.contains(sessionId)) return;
    _retainedSessionOrder.insert(0, sessionId);
  }

  Set<String> _resolveRetainedSessionIds({
    required Set<String> interactiveSessionIds,
    required String? activeSessionId,
  }) {
    _retainedSessionOrder.removeWhere(
      (id) => !interactiveSessionIds.contains(id),
    );
    if (_warmSessionId != null &&
        !interactiveSessionIds.contains(_warmSessionId)) {
      _warmSessionId = null;
    }

    if (activeSessionId != null &&
        interactiveSessionIds.contains(activeSessionId)) {
      _touchRetainedSession(activeSessionId);
    }
    if (_warmSessionId != null &&
        interactiveSessionIds.contains(_warmSessionId)) {
      _ensureRetainedSession(_warmSessionId!);
    }

    final pinnedIds = <String>{
      if (activeSessionId != null &&
          interactiveSessionIds.contains(activeSessionId))
        activeSessionId,
      if (_warmSessionId != null &&
          interactiveSessionIds.contains(_warmSessionId))
        _warmSessionId!,
    };

    while (_retainedSessionOrder.length > _maxRetainedTerminalViews) {
      final evictionIndex = _retainedSessionOrder.lastIndexWhere(
        (id) => !pinnedIds.contains(id),
      );
      if (evictionIndex == -1) break;
      _retainedSessionOrder.removeAt(evictionIndex);
    }

    return _retainedSessionOrder.toSet();
  }

  void _handleSessionStatusUpdate({
    required String sessionId,
    required String? process,
    required String? oscTitle,
    required int attentionSeq,
    required int attentionAckSeq,
    required bool isActive,
  }) {
    ref
        .read(serverProvider.notifier)
        .updateForegroundProcess(
          sessionId,
          process,
          oscTitle: oscTitle,
          attentionSeq: attentionSeq,
          attentionAckSeq: attentionAckSeq,
        );
    if (isActive && attentionSeq > attentionAckSeq) {
      _ackAttentionIfNeeded(sessionId);
    }
  }

  void _ackAttentionIfNeeded(String sessionId) {
    final session =
        ref
            .read(serverProvider)
            .sessions
            .where((item) => item.id == sessionId)
            .firstOrNull;
    if (session == null || !session.hasAttention) {
      return;
    }
    ref.read(serverProvider.notifier).ackSessionAttention(sessionId).catchError(
      (_) {
        return null;
      },
    );
  }
}
