import 'package:flutter/foundation.dart' show setEquals;
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
import 'ghostty_terminal_view.dart';
import 'mobile_key_bar.dart';

class TerminalArea extends ConsumerStatefulWidget {
  final TerminalBackend backend;

  const TerminalArea({super.key, required this.backend});

  @override
  ConsumerState<TerminalArea> createState() => _TerminalAreaState();
}

class _TerminalAreaState extends ConsumerState<TerminalArea> {
  final Map<String, GlobalKey<GhosttyTerminalViewState>> _terminalKeys = {};
  final VolumeKeyService _volumeKeys = VolumeKeyService();
  final PasteService _pasteService = PasteService();
  Set<String> _lastValidSessionIds = {};
  // OSC title per session — used for tab display only, NOT persisted to server.
  // The stored session.name stays as session-<hash> unless the user renames it.
  final Map<String, String> _sessionTitles = {};

  @override
  void initState() {
    super.initState();
    _volumeKeys.setEnabled(true);

    _pasteService.onPaste = (text) {
      final activeId = ref.read(sessionProvider).activeSessionId;
      if (activeId == null) return;
      _terminalKeys[activeId]?.currentState?.paste(text);
    };

    ref.listenManual(serverProvider, (previous, next) {
      final validIds = next.sessions.map((e) => e.id).toSet();
      if (!setEquals(_lastValidSessionIds, validIds)) {
        _lastValidSessionIds = validIds;
        ref.read(sessionProvider.notifier).cleanupStaleTabs(validIds);
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
    final sessState = ref.watch(sessionProvider);
    final settings = ref.watch(settingsProvider);
    final uiState = ref.watch(uiProvider);
    final openTabs = sessState.openTabs;
    final activeId = sessState.activeSessionId;
    final sessions = ref.watch(serverProvider.select((s) => s.sessions));

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
                  children: openTabs.map((tab) {
                    final isActive = tab.sessionId == activeId;
                    final session = sessions
                        .where((s) => s.id == tab.sessionId)
                        .firstOrNull;

                    _terminalKeys.putIfAbsent(
                      tab.sessionId,
                      () => GlobalKey<GhosttyTerminalViewState>(),
                    );

                    return Offstage(
                      offstage: !isActive,
                      child: widget.backend.createTerminalWidget(
                        sessionId: tab.sessionId,
                        command: session?.shell,
                        cwd: session?.cwd,
                        isActive: isActive,
                        onSessionExited: () {
                          ref.read(sessionProvider.notifier).closeTab(tab.sessionId);
                        },
                        onTitleChanged: (title) {
                          if (title == null || title.isEmpty) return;
                          // Strip control chars and Private Use Area (nerd font glyphs → renders as 〓)
                          final clean = title
                              .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '')
                              .replaceAll(RegExp(r'[\uE000-\uF8FF]'), '')
                              .replaceAll(RegExp(r'[\uDB80-\uDBFF][\uDC00-\uDFFF]'), '')
                              .trim();
                          if (clean.isEmpty) return;

                          // Detect foreground tool from OSC title (mirrors Tether's sticky-OSC logic).
                          // Empty titles are already filtered above — they won't clear an active process.
                          final lower = clean.toLowerCase();
                          String? detectedProcess;
                          if (lower.contains('claude')) detectedProcess = 'claude';
                          else if (lower.contains('codex')) detectedProcess = 'codex';

                          final currentProcess = ref.read(serverProvider)
                              .sessions.where((s) => s.id == tab.sessionId).firstOrNull?.foregroundProcess;

                          if (detectedProcess != null) {
                            if (detectedProcess != currentProcess) {
                              ref.read(serverProvider.notifier)
                                  .updateForegroundProcess(tab.sessionId, detectedProcess, null);
                            }
                          } else if (currentProcess != null) {
                            // Non-tool, non-empty title → tool exited, shell reclaimed the title
                            ref.read(serverProvider.notifier)
                                .updateForegroundProcess(tab.sessionId, null, null);
                          }

                          // Store locally for tab display when no process is active
                          setState(() { _sessionTitles[tab.sessionId] = clean; });
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
                      _terminalKeys[id]?.currentState?.sendText(data);
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
      _terminalKeys[activeId]?.currentState?.paste(data!.text!);
    }
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
            final session = sessions
                .where((s) => s.id == tab.sessionId)
                .firstOrNull;

            if (session == null) {
              return SizedBox.shrink(key: ValueKey('missing_${tab.sessionId}'));
            }

            final display = getDisplayInfo(session, sessions);
            final oscTitle = sessionTitles[tab.sessionId];
            final hasProcess = session.foregroundProcess != null;
            // When a process (claude/codex) is active: getDisplayInfo() already shows the right name+icon.
            // When no process: use OSC title (directory) or session-<hash> as fallback.
            final tabDisplayName = hasProcess ? display.displayName : (oscTitle ?? display.displayName);
            final tabSubtitle = hasProcess ? session.name : (oscTitle != null ? session.name : display.subtitle);

            return ReorderableDelayedDragStartListener(
              key: ValueKey(tab.sessionId),
              index: index,
              child: GestureDetector(
                onTap: () {
                  ref.read(sessionProvider.notifier).setActiveSession(tab.sessionId);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: isActive ? const Color(0xFF2D2D2D) : const Color(0xFF1E1E1E),
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
                              child: Image.asset(display.iconAsset!, width: 14, height: 14),
                            )
                          : Icon(
                              display.icon,
                              size: 14,
                              color: isActive ? display.iconColor : display.iconColor.withValues(alpha: 0.5),
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
                                color: isActive ? Colors.white38 : Colors.white24,
                                fontSize: 10,
                              ),
                            ),
                        ],
                      ),
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
                          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                          onPressed: () {
                            ref.read(sessionProvider.notifier).closeTab(tab.sessionId);
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
