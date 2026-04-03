import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart' as xterm;
import '../../providers/server_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/websocket_service.dart';

/// Terminal widget that connects to a server-managed PTY via WebSocket.
/// Uses xterm.dart for terminal emulation and rendering.
class XtermTerminalView extends ConsumerStatefulWidget {
  final String sessionId;
  final bool isActive;
  final VoidCallback? onSessionExited;
  final void Function(String? title)? onTitleChanged;

  const XtermTerminalView({
    super.key,
    required this.sessionId,
    required this.isActive,
    this.onSessionExited,
    this.onTitleChanged,
  });

  @override
  ConsumerState<XtermTerminalView> createState() => XtermTerminalViewState();
}

class XtermTerminalViewState extends ConsumerState<XtermTerminalView> {
  late final xterm.Terminal _terminal;
  late final xterm.TerminalController _terminalController;
  late final ScrollController _scrollController;
  WebSocketService? _ws;
  StreamSubscription? _msgSub;
  bool _isPaused = false;
  bool _sessionExited = false;
  final List<Uint8List> _pauseBuffer = [];

  // Write batching — flush next microtask
  final List<Uint8List> _writeQueue = [];
  bool _writeScheduled = false;

  // Stateful UTF-8 decoder — maintains state across flushes so multi-byte
  // sequences split across WebSocket message boundaries are reassembled
  // correctly instead of being replaced with U+FFFD.
  final StreamController<List<int>> _bytesInput =
      StreamController<List<int>>(sync: true);

  // Foreground change debounce
  Timer? _foregroundDebounce;

  // Tool state (running/waiting) detected from output activity
  Timer? _toolStateTimer;

  // Timestamp of last user input sent — used to suppress echo false positives
  DateTime? _lastInputSentAt;

  // Search state
  bool _searchOpen = false;
  final List<({int line, int col, int length})> _searchMatches = [];
  int _currentMatchIndex = -1;
  final List<xterm.TerminalHighlight> _searchHighlights = [];
  final List<xterm.CellAnchor> _searchAnchors = [];
  xterm.TerminalHighlight? _currentMatchHighlight;
  xterm.CellAnchor? _currentMatchP1;
  xterm.CellAnchor? _currentMatchP2;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _terminalController = xterm.TerminalController();
    _terminal = xterm.Terminal(maxLines: 5000);
    _terminal.onOutput = _onTerminalInput;
    _terminal.onTitleChange = (title) {
      widget.onTitleChanged?.call(title);
    };
    _terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      _ws?.sendResize(width, height);
    };
    _bytesInput.stream
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((text) => _terminal.write(text));
    HardwareKeyboard.instance.addHandler(_handleSearchKey);
    _connect();
  }

  bool _handleSearchKey(KeyEvent event) {
    if (!_searchOpen) return false;
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _closeSearch();
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      if (HardwareKeyboard.instance.isShiftPressed) {
        _prevMatch();
      } else {
        _nextMatch();
      }
      return true;
    }
    return false;
  }

  void showSearch() {
    if (_searchOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _searchFocusNode.requestFocus());
      return;
    }
    setState(() { _searchOpen = true; });
    WidgetsBinding.instance.addPostFrameCallback((_) => _searchFocusNode.requestFocus());
  }

  void _closeSearch() {
    _disposeAllSearchHighlights();
    _searchMatches.clear();
    _searchController.clear();
    setState(() { _searchOpen = false; _currentMatchIndex = -1; });
  }

  void _disposeAllSearchHighlights() {
    for (final h in _searchHighlights) h.dispose();
    _searchHighlights.clear();
    for (final a in _searchAnchors) a.dispose();
    _searchAnchors.clear();
    _disposeCurrentMatch();
  }

  void _disposeCurrentMatch() {
    _currentMatchHighlight?.dispose();
    _currentMatchHighlight = null;
    _currentMatchP1?.dispose();
    _currentMatchP1 = null;
    _currentMatchP2?.dispose();
    _currentMatchP2 = null;
  }

  void _runSearch(String query) {
    _disposeAllSearchHighlights();
    _searchMatches.clear();

    if (query.isEmpty) {
      setState(() { _currentMatchIndex = -1; });
      return;
    }

    final buffer = _terminal.buffer;
    final lowerQuery = query.toLowerCase();

    for (int i = 0; i < buffer.height; i++) {
      final lineText = buffer.lines[i].getText();
      final lowerLine = lineText.toLowerCase();
      int start = 0;
      while (true) {
        final idx = lowerLine.indexOf(lowerQuery, start);
        if (idx < 0) break;
        _searchMatches.add((line: i, col: idx, length: lowerQuery.length));
        start = idx + 1;
      }
    }

    // Yellow highlights for all matches
    for (final match in _searchMatches) {
      final p1 = buffer.createAnchor(match.col, match.line);
      final p2 = buffer.createAnchor(match.col + match.length, match.line);
      _searchAnchors.addAll([p1, p2]);
      _searchHighlights.add(_terminalController.highlight(
        p1: p1, p2: p2, color: const Color(0x40FFFF00),
      ));
    }

    int newIdx = -1;
    if (_searchMatches.isNotEmpty) {
      newIdx = 0;
      _highlightCurrentMatch(newIdx);
      _scrollToMatch(newIdx);
    }

    setState(() { _currentMatchIndex = newIdx; });
  }

  void _highlightCurrentMatch(int index) {
    _disposeCurrentMatch();
    if (index < 0 || index >= _searchMatches.length) return;
    final match = _searchMatches[index];
    final buffer = _terminal.buffer;
    _currentMatchP1 = buffer.createAnchor(match.col, match.line);
    _currentMatchP2 = buffer.createAnchor(match.col + match.length, match.line);
    _currentMatchHighlight = _terminalController.highlight(
      p1: _currentMatchP1!, p2: _currentMatchP2!, color: const Color(0x80FF8C00),
    );
  }

  void _nextMatch() {
    if (_searchMatches.isEmpty) return;
    final newIdx = (_currentMatchIndex + 1) % _searchMatches.length;
    _highlightCurrentMatch(newIdx);
    _scrollToMatch(newIdx);
    setState(() { _currentMatchIndex = newIdx; });
  }

  void _prevMatch() {
    if (_searchMatches.isEmpty) return;
    final newIdx = (_currentMatchIndex - 1 + _searchMatches.length) % _searchMatches.length;
    _highlightCurrentMatch(newIdx);
    _scrollToMatch(newIdx);
    setState(() { _currentMatchIndex = newIdx; });
  }

  void _scrollToMatch(int index) {
    if (index < 0 || index >= _searchMatches.length) return;
    if (!_scrollController.hasClients) return;
    final scrollBack = _terminal.buffer.scrollBack;
    if (scrollBack <= 0) return;
    final maxExtent = _scrollController.position.maxScrollExtent;
    if (maxExtent <= 0) return;
    final lineHeight = maxExtent / scrollBack;
    final match = _searchMatches[index];
    final targetOffset = (match.line * lineHeight).clamp(0.0, maxExtent);
    _scrollController.animateTo(
      targetOffset,
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
    );
  }

  @override
  void didUpdateWidget(XtermTerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive != widget.isActive) {
      if (widget.isActive) {
        _resume();
      } else {
        _pause();
      }
    }
  }

  void _connect() {
    final serverState = ref.read(serverProvider);
    if (!serverState.isConnected || serverState.config == null) {
      _writeToTerminal(utf8.encode('\r\n\x1b[31m[server not connected]\x1b[0m\r\n'));
      return;
    }

    final config = serverState.config!;
    final wsScheme = config.useTls ? 'wss' : 'ws';
    var url = '$wsScheme://${config.host}:${config.port}/ws/session/${widget.sessionId}';
    if (config.token != null && config.token!.isNotEmpty) {
      url += '?token=${Uri.encodeComponent(config.token!)}';
    }

    _ws = WebSocketService(url);
    _ws!.connect();

    _msgSub = _ws!.messages.listen((msg) {
      switch (msg) {
        case OutputMessage():
          _writeToTerminal(msg.data);
          _onToolOutput();
        case ScrollbackMessage():
          _writeToTerminal(msg.data);
        case SessionEventMessage():
          if (msg.event == 'exited') {
            _sessionExited = true;
            widget.onSessionExited?.call();
          }
        case ForegroundChangedMessage():
          if (msg.process == null) {
            _toolStateTimer?.cancel();
            _toolStateTimer = null;
          }
          _foregroundDebounce?.cancel();
          _foregroundDebounce = Timer(const Duration(milliseconds: 100), () {
            ref.read(serverProvider.notifier).updateForegroundProcess(
              widget.sessionId,
              msg.process,
              toolState: msg.toolState,
            );
          });
        case ConnectionStateMessage():
          if (!msg.connected && !_sessionExited) {
            _writeToTerminal(utf8.encode('\r\n\x1b[33m[reconnecting...]\x1b[0m\r\n'));
          }
        case PongMessage():
          break;
        case ErrorMessage():
          break;
      }
    });
  }

  /// Update toolState based on terminal output activity.
  /// Called on every OutputMessage — if a known tool (claude/codex) is the
  /// foreground process, marks it "running" immediately and schedules a
  /// transition to "waiting" after 350ms of output silence.
  void _onToolOutput() {
    final sessions = ref.read(serverProvider).sessions;
    final session = sessions.where((s) => s.id == widget.sessionId).firstOrNull;
    final process = session?.foregroundProcess;
    if (process != 'claude' && process != 'codex') return;

    // Suppress Running if output arrived shortly after user input — likely echo.
    final lastInput = _lastInputSentAt;
    if (lastInput != null &&
        DateTime.now().difference(lastInput) < const Duration(milliseconds: 150)) {
      return;
    }

    if (session?.toolState != 'running') {
      ref.read(serverProvider.notifier).updateForegroundProcess(
        widget.sessionId, process, toolState: 'running',
      );
    }

    _toolStateTimer?.cancel();
    _toolStateTimer = Timer(const Duration(milliseconds: 350), () {
      final s = ref.read(serverProvider)
          .sessions.where((s) => s.id == widget.sessionId).firstOrNull;
      if (s?.foregroundProcess == process) {
        ref.read(serverProvider.notifier).updateForegroundProcess(
          widget.sessionId, process, toolState: 'waiting',
        );
      }
    });
  }

  void _writeToTerminal(Uint8List data) {
    if (_isPaused) {
      _pauseBuffer.add(data);
      return;
    }
    _writeQueue.add(data);
    _scheduleFlush();
  }

  void _scheduleFlush() {
    if (_writeScheduled) return;
    _writeScheduled = true;
    Timer.run(_flushWrites);
  }

  void _flushWrites() {
    _writeScheduled = false;
    if (!mounted || _writeQueue.isEmpty) return;

    // Capture pre-write bottom state.  After an alt-buffer exit the stored
    // maxScrollExtent jumps from 0 to a large value while pixels stays at 0,
    // so the post-frame "near bottom" check alone would miss the transition.
    var wasAtBottom = true;
    if (_scrollController.hasClients) {
      final pos = _scrollController.position;
      wasAtBottom = pos.pixels >= pos.maxScrollExtent - 20.0;
    }

    int totalLen = 0;
    for (final chunk in _writeQueue) {
      totalLen += chunk.length;
    }
    final merged = Uint8List(totalLen);
    int offset = 0;
    for (final chunk in _writeQueue) {
      merged.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    _writeQueue.clear();

    _bytesInput.add(merged);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final pos = _scrollController.position;
      final maxExtent = pos.maxScrollExtent;
      // Scroll to bottom when:
      //  • the setting forces it, OR
      //  • we were at the bottom before writing (covers alt-buffer exit), OR
      //  • we're still at/near the bottom after the frame.
      // When none hold, xterm's _stickToBottom=false preserves the user's
      // scroll position naturally — no jumpTo needed.
      final isNowAtBottom = pos.pixels >= maxExtent - 20.0;
      final shouldScroll =
          ref.read(settingsProvider).scrollToBottomOnOutput ||
          wasAtBottom ||
          isNowAtBottom;
      if (shouldScroll) {
        _scrollController.jumpTo(maxExtent);
      }
    });
  }

  void _pause() {
    _isPaused = true;
    _ws?.sendPause();
  }

  void _resume() {
    _isPaused = false;
    if (_pauseBuffer.isNotEmpty) {
      for (final chunk in _pauseBuffer) {
        _writeQueue.add(chunk);
      }
      _pauseBuffer.clear();
      _scheduleFlush();
    }
    _ws?.sendResume();
  }

  void _onTerminalInput(String data) {
    _lastInputSentAt = DateTime.now();
    _ws?.sendInput(data);
  }

  /// Send raw text to the PTY (used by MobileKeyBar and paste service).
  void sendText(String text) {
    _lastInputSentAt = DateTime.now();
    _ws?.sendInput(text);
    // Snap to live output when user sends input, matching ghostty's
    // scroll-to-bottom-on-keystroke default behavior.  forcePixels always
    // notifies listeners (unlike jumpTo which is a no-op when pixels already
    // equals the target), so xterm's _onScroll re-arms _stickToBottom even
    // after alt-buffer transitions that leave maxScrollExtent at 0.
    if (_scrollController.hasClients) {
      _scrollController.position.forcePixels(
        _scrollController.position.maxScrollExtent,
      );
    }
  }

  void paste(String text) {
    _terminal.paste(text);
  }

  Future<void> pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) {
      _terminal.paste(data!.text!);
    }
  }

  void _showContextMenu(BuildContext context, Offset position) {
    final hasSelection = _terminalController.selection != null;
    final rect = RelativeRect.fromLTRB(
      position.dx, position.dy, position.dx, position.dy,
    );
    showMenu<String>(
      context: context,
      position: rect,
      items: [
        PopupMenuItem(
          value: 'copy',
          enabled: hasSelection,
          child: const Text('Copy'),
        ),
        const PopupMenuItem(value: 'paste', child: Text('Paste')),
      ],
    ).then((value) {
      if (value == null) return;
      switch (value) {
        case 'copy':
          final selection = _terminalController.selection;
          if (selection != null) {
            final text = _terminal.buffer.getText(selection);
            Clipboard.setData(ClipboardData(text: text));
            _terminalController.clearSelection();
          }
        case 'paste':
          pasteFromClipboard();
      }
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleSearchKey);
    _disposeAllSearchHighlights();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _foregroundDebounce?.cancel();
    _toolStateTimer?.cancel();
    _msgSub?.cancel();
    _ws?.dispose();
    _bytesInput.close();
    _terminalController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final terminalView = xterm.TerminalView(
      _terminal,
      controller: _terminalController,
      scrollController: _scrollController,
      textStyle: xterm.TerminalStyle(
        fontSize: settings.fontSize,
        fontFamily: settings.fontFamily,
      ),
      onSecondaryTapDown: (details, cellOffset) {
        _showContextMenu(context, details.globalPosition);
      },
    );

    if (!_searchOpen) return terminalView;

    return Stack(
      children: [
        terminalView,
        Positioned(
          top: 8,
          right: 8,
          child: _buildSearchBar(),
        ),
      ],
    );
  }

  Widget _buildSearchBar() {
    final count = _searchMatches.length;
    final countText = count == 0
        ? 'No results'
        : '${_currentMatchIndex + 1} / $count';

    return Material(
      color: Colors.transparent,
      child: Container(
        width: 300,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xCC1E1E1E),
          border: Border.all(color: Colors.white12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Expanded(
              child: SizedBox(
                height: 28,
                child: TextField(
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  onChanged: _runSearch,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  cursorColor: Colors.white,
                  decoration: const InputDecoration(
                    hintText: 'Search...',
                    hintStyle: TextStyle(color: Colors.white38, fontSize: 13),
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                    isDense: true,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              countText,
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
            _searchNavButton(Icons.keyboard_arrow_up, count > 0 ? _prevMatch : null),
            _searchNavButton(Icons.keyboard_arrow_down, count > 0 ? _nextMatch : null),
            _searchNavButton(Icons.close, _closeSearch),
          ],
        ),
      ),
    );
  }

  Widget _searchNavButton(IconData icon, VoidCallback? onPressed) {
    return SizedBox(
      width: 24,
      height: 24,
      child: IconButton(
        icon: Icon(icon, size: 14, color: onPressed != null ? Colors.white70 : Colors.white24),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
        onPressed: onPressed,
      ),
    );
  }
}
