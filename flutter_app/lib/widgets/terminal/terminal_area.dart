import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/server_provider.dart';
import '../../providers/session_provider.dart';
import '../../providers/settings_provider.dart';
import '../../providers/ui_provider.dart';
import '../../platform/paste_service.dart';
import '../../platform/volume_keys.dart';
import '../../platform/terminal_backend.dart';
import '../../utils/session_display.dart';
import '../../utils/session_interaction.dart';
import '../../utils/session_status.dart';
import 'session_status_dot.dart';
import 'terminal_controller.dart';
import 'mobile_key_bar.dart';

class TerminalArea extends ConsumerStatefulWidget {
  final TerminalBackend backend;

  const TerminalArea({super.key, required this.backend});

  @override
  ConsumerState<TerminalArea> createState() => TerminalAreaState();
}

class TerminalAreaState extends ConsumerState<TerminalArea> {
  final Map<String, TerminalController> _terminalControllers = {};
  final VolumeKeyService _volumeKeys = VolumeKeyService();
  final PasteService _pasteService = PasteService();
  Set<String>? _pendingInteractiveSessionIds;
  bool _interactiveTabSyncScheduled = false;
  // OSC title per session — used for tab display only, NOT persisted to server.
  // The stored session.name stays as session-<hash> unless the user renames it.
  final Map<String, String> _sessionTitles = {};

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
  }

  @override
  void dispose() {
    _pasteService.dispose();
    _volumeKeys.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sessState = ref.watch(sessionProvider);
    final settings = ref.watch(settingsProvider);
    final uiState = ref.watch(uiProvider);
    final openTabs = sessState.openTabs;
    final activeId = sessState.activeSessionId;
    final sessions = ref.watch(serverProvider.select((s) => s.sessions));
    final serverConfig = ref.watch(serverProvider.select((s) => s.config));

    // Prune maps for sessions that are no longer open to prevent unbounded growth.
    final openIds = openTabs.map((t) => t.sessionId).toSet();
    _terminalControllers.removeWhere((id, _) => !openIds.contains(id));
    _sessionTitles.removeWhere((id, _) => !openIds.contains(id));

    Widget content;
    if (openTabs.isEmpty) {
      content = const Expanded(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.terminal, size: 64, color: Colors.white24),
              SizedBox(height: 16),
              Text(
                'No sessions open',
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
            if (settings.showTabBar)
              _TerminalTabBar(
                openTabs: openTabs,
                activeId: activeId,
                sessionTitles: _sessionTitles,
              ),
            Expanded(
              child: ClipRect(
                child: Stack(
                  fit: StackFit.expand,
                  children:
                      openTabs.map((tab) {
                        final isActive = tab.sessionId == activeId;
                        final session =
                            sessions
                                .where((s) => s.id == tab.sessionId)
                                .firstOrNull;

                        final terminalController = _terminalControllers
                            .putIfAbsent(tab.sessionId, TerminalController.new);

                        return Offstage(
                          offstage: !isActive,
                          child: widget.backend.createTerminalWidget(
                            key: ValueKey(
                              '${widget.backend.platformId}:${tab.sessionId}',
                            ),
                            sessionId: tab.sessionId,
                            controller: terminalController,
                            serverConfig: serverConfig,
                            command: session?.shell,
                            cwd: session?.cwd,
                            isActive: isActive,
                            onSessionExited: () {
                              ref
                                  .read(sessionProvider.notifier)
                                  .closeTab(tab.sessionId);
                            },
                            onTitleChanged: (title) {
                              if (title == null || title.isEmpty) return;
                              // Strip control chars and Private Use Area (nerd font glyphs → renders as 〓)
                              final clean =
                                  title
                                      .replaceAll(
                                        RegExp(r'[\x00-\x1F\x7F]'),
                                        '',
                                      )
                                      .replaceAll(
                                        RegExp(r'[\uE000-\uF8FF]'),
                                        '',
                                      )
                                      .replaceAll(
                                        RegExp(
                                          r'[\uDB80-\uDBFF][\uDC00-\uDFFF]',
                                        ),
                                        '',
                                      )
                                      .trim();
                              if (clean.isEmpty) return;

                              // Store locally for tab display when no process is active
                              setState(() {
                                _sessionTitles[tab.sessionId] = clean;
                              });
                            },
                            onForegroundChanged: (process, oscTitle) {
                              ref
                                  .read(serverProvider.notifier)
                                  .updateForegroundProcess(
                                    tab.sessionId,
                                    process,
                                    oscTitle: oscTitle,
                                  );
                            },
                          ),
                        );
                      }).toList(),
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
        child: Column(
          children: [
            content,
            if (uiState.isMobile)
              Container(
                color: const Color(0xFF1E1E1E),
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).padding.bottom,
                ),
                child: MobileKeyBar(
                  onKeyPress: (data) {
                    final id = ref.read(sessionProvider).activeSessionId;
                    if (id != null) {
                      _terminalControllers[id]?.sendText(data);
                    }
                  },
                  onCopy: () {},
                  onPaste: () => _pasteToActiveTerminal(),
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
      ref.read(sessionProvider.notifier).cleanupStaleTabs(validIds);
    });
  }
}

class _TerminalTabBar extends ConsumerWidget {
  final List<OpenTab> openTabs;
  final String? activeId;
  final Map<String, String> sessionTitles;

  const _TerminalTabBar({
    required this.openTabs,
    required this.activeId,
    required this.sessionTitles,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(serverProvider.select((s) => s.sessions));

    return Container(
      height: 48,
      color: const Color(0xFF1E1E1E),
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: ReorderableListView.builder(
          scrollDirection: Axis.horizontal,
          buildDefaultDragHandles: false,
          onReorder: (oldIndex, newIndex) {
            if (newIndex > oldIndex) newIndex--;
            ref.read(sessionProvider.notifier).reorderTabs(oldIndex, newIndex);
          },
          proxyDecorator: (child, index, animation) {
            return Material(
              color: Colors.transparent,
              elevation: 4,
              child: child,
            );
          },
          itemCount: openTabs.length,
          itemBuilder: (context, index) {
            final tab = openTabs[index];
            final isActive = tab.sessionId == activeId;
            final session =
                sessions.where((s) => s.id == tab.sessionId).firstOrNull;

            if (session == null) {
              return SizedBox.shrink(key: ValueKey('missing_${tab.sessionId}'));
            }

            final display = getDisplayInfo(session, sessions);
            final oscTitle = sessionTitles[tab.sessionId];
            final hasProcess = session.foregroundProcess != null;
            // When a process (claude/codex) is active: getDisplayInfo() already shows the right name+icon.
            // When no process: use OSC title (directory) or session-<hash> as fallback.
            final tabDisplayName =
                hasProcess
                    ? display.displayName
                    : (oscTitle ?? display.displayName);
            final tabSubtitle =
                hasProcess
                    ? session.name
                    : (oscTitle != null ? session.name : display.subtitle);
            final status = deriveSessionToolStatus(session);

            return ReorderableDelayedDragStartListener(
              key: ValueKey(tab.sessionId),
              index: index,
              child: GestureDetector(
                onTap: () {
                  ref
                      .read(sessionProvider.notifier)
                      .setActiveSession(tab.sessionId);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color:
                        isActive
                            ? const Color(0xFF2D2D2D)
                            : const Color(0xFF1E1E1E),
                    border: Border(
                      bottom: BorderSide(
                        color: isActive ? Colors.blue : Colors.transparent,
                        width: 2,
                      ),
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      display.iconAsset != null
                          ? Opacity(
                            opacity: isActive ? 1.0 : 0.5,
                            child: Image.asset(
                              display.iconAsset!,
                              width: 14,
                              height: 14,
                            ),
                          )
                          : Icon(
                            display.icon,
                            size: 14,
                            color:
                                isActive
                                    ? display.iconColor
                                    : display.iconColor.withValues(alpha: 0.5),
                          ),
                      const SizedBox(width: 6),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tabDisplayName,
                            style: TextStyle(
                              color: isActive ? Colors.white : Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                          if (tabSubtitle != null)
                            Text(
                              tabSubtitle,
                              style: TextStyle(
                                color:
                                    isActive ? Colors.white38 : Colors.white24,
                                fontSize: 10,
                              ),
                            ),
                        ],
                      ),
                      if (status != null) ...[
                        const SizedBox(width: 8),
                        SessionStatusDot(
                          key: ValueKey('session-tab-status-${tab.sessionId}'),
                          status: status,
                        ),
                      ],
                      const SizedBox(width: 6),
                      SizedBox(
                        width: 28,
                        height: 28,
                        child: IconButton(
                          icon: Icon(
                            Icons.close,
                            size: 14,
                            color: isActive ? Colors.white54 : Colors.white24,
                          ),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 28,
                            minHeight: 28,
                          ),
                          onPressed: () {
                            ref
                                .read(sessionProvider.notifier)
                                .closeTab(tab.sessionId);
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
