import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart' as xterm;
import '../../platform/terminal_backend.dart';
import '../../providers/server_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/websocket_service.dart';
import 'terminal_controller.dart';

/// Terminal widget that connects to a server-managed PTY via WebSocket.
/// Uses xterm.dart for terminal emulation and rendering.
class XtermTerminalView extends ConsumerStatefulWidget {
  final String sessionId;
  final TerminalController controller;
  final bool isActive;
  final VoidCallback? onSessionExited;
  final void Function(String? title)? onTitleChanged;
  final ForegroundChangedCallback? onForegroundChanged;

  const XtermTerminalView({
    super.key,
    required this.sessionId,
    required this.controller,
    required this.isActive,
    this.onSessionExited,
    this.onTitleChanged,
    this.onForegroundChanged,
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
  int _ackedOffset = 0;
  final List<Uint8List> _pauseBuffer = [];

  // Write batching — flush next microtask
  final List<Uint8List> _writeQueue = [];
  bool _writeScheduled = false;

  // Stateful UTF-8 decoder — maintains state across flushes so multi-byte
  // sequences split across WebSocket message boundaries are reassembled
  // correctly instead of being replaced with U+FFFD.
  final StreamController<List<int>> _bytesInput = StreamController<List<int>>(
    sync: true,
  );

  // Foreground change debounce
  Timer? _foregroundDebounce;

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
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _searchFocusNode.requestFocus(),
      );
      return;
    }
    setState(() {
      _searchOpen = true;
    });
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _searchFocusNode.requestFocus(),
    );
  }

  void _closeSearch() {
    _disposeAllSearchHighlights();
    _searchMatches.clear();
    _searchController.clear();
    setState(() {
      _searchOpen = false;
      _currentMatchIndex = -1;
    });
  }

  void _disposeAllSearchHighlights() {
    for (final h in _searchHighlights) {
      h.dispose();
    }
    _searchHighlights.clear();
    for (final a in _searchAnchors) {
      a.dispose();
    }
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
      setState(() {
        _currentMatchIndex = -1;
      });
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
      _searchHighlights.add(
        _terminalController.highlight(
          p1: p1,
          p2: p2,
          color: const Color(0x40FFFF00),
        ),
      );
    }

    int newIdx = -1;
    if (_searchMatches.isNotEmpty) {
      newIdx = 0;
      _highlightCurrentMatch(newIdx);
      _scrollToMatch(newIdx);
    }

    setState(() {
      _currentMatchIndex = newIdx;
    });
  }

  void _highlightCurrentMatch(int index) {
    _disposeCurrentMatch();
    if (index < 0 || index >= _searchMatches.length) return;
    final match = _searchMatches[index];
    final buffer = _terminal.buffer;
    _currentMatchP1 = buffer.createAnchor(match.col, match.line);
    _currentMatchP2 = buffer.createAnchor(match.col + match.length, match.line);
    _currentMatchHighlight = _terminalController.highlight(
      p1: _currentMatchP1!,
      p2: _currentMatchP2!,
      color: const Color(0x80FF8C00),
    );
  }

  void _nextMatch() {
    if (_searchMatches.isEmpty) return;
    final newIdx = (_currentMatchIndex + 1) % _searchMatches.length;
    _highlightCurrentMatch(newIdx);
    _scrollToMatch(newIdx);
    setState(() {
      _currentMatchIndex = newIdx;
    });
  }

  void _prevMatch() {
    if (_searchMatches.isEmpty) return;
    final newIdx =
        (_currentMatchIndex - 1 + _searchMatches.length) %
        _searchMatches.length;
    _highlightCurrentMatch(newIdx);
    _scrollToMatch(newIdx);
    setState(() {
      _currentMatchIndex = newIdx;
    });
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
  void didChangeDependencies() {
    super.didChangeDependencies();
    widget.controller.attach(
      sendText: sendText,
      paste: paste,
      showSearch: showSearch,
      copy: copySelection,
    );
  }

  @override
  void didUpdateWidget(XtermTerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.detach();
      widget.controller.attach(
        sendText: sendText,
        paste: paste,
        showSearch: showSearch,
        copy: copySelection,
      );
    }
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
      _writeToTerminal(
        utf8.encode('\r\n\x1b[31m[server not connected]\x1b[0m\r\n'),
      );
      return;
    }

    _ws = WebSocketService.withUrlBuilder(_buildWsUrl);
    _ws!.connect();

    _msgSub = _ws!.messages.listen((msg) {
      switch (msg) {
        case OutputMessage():
          _ackedOffset += msg.data.length;
          _writeToTerminal(msg.data);
        case ScrollbackMessage():
          _ackedOffset += msg.data.length;
          _writeToTerminal(msg.data);
        case SessionEventMessage():
          if (msg.event == 'exited') {
            _sessionExited = true;
            _ws?.dispose();
            _ws = null;
            widget.onSessionExited?.call();
          }
        case ForegroundChangedMessage():
          _foregroundDebounce?.cancel();
          _foregroundDebounce = Timer(const Duration(milliseconds: 100), () {
            widget.onForegroundChanged?.call(
              msg.process,
              msg.oscTitle,
            );
          });
        case ConnectionStateMessage():
          if (msg.connected) {
            // Re-send terminal dimensions now that the WebSocket is confirmed.
            // The initial resize from xterm.dart's performLayout may fire before
            // the channel is ready; this ensures the server always has the size.
            final w = _terminal.viewWidth;
            final h = _terminal.viewHeight;
            if (w > 0 && h > 0) {
              _ws?.sendResize(w, h);
            }
          } else if (!_sessionExited) {
            _writeToTerminal(
              utf8.encode('\r\n\x1b[33m[reconnecting...]\x1b[0m\r\n'),
            );
          }
        case PongMessage():
          break;
        case ErrorMessage():
          break;
      }
    });
  }

  String _buildWsUrl() {
    final config = ref.read(serverProvider).config!;
    final wsScheme = config.useTls ? 'wss' : 'ws';
    final queryParts = <String>[];
    if (config.token != null && config.token!.isNotEmpty) {
      queryParts.add('token=${Uri.encodeComponent(config.token!)}');
    }
    if (_ackedOffset > 0) {
      queryParts.add('offset=$_ackedOffset');
    }
    final query = queryParts.isEmpty ? '' : '?${queryParts.join('&')}';
    return '$wsScheme://${config.host}:${config.port}/ws/session/${widget.sessionId}$query';
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

    // Only force-scroll when the user's setting explicitly requests it.
    // Otherwise let xterm.dart's _stickToBottom handle auto-follow — exactly
    // as ghostty lets its terminal engine manage the viewport internally.
    if (ref.read(settingsProvider).scrollToBottomOnOutput) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;
        // ignore: invalid_use_of_protected_member
        _scrollController.position.forcePixels(
          _scrollController.position.maxScrollExtent,
        );
      });
    }
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
    _ws?.sendInput(data);
  }

  /// Send raw text to the PTY (used by MobileKeyBar and paste service).
  void sendText(String text) {
    _ws?.sendInput(text);
    // Snap to live output when user sends input, matching ghostty's
    // scroll-to-bottom-on-keystroke default behavior.  forcePixels always
    // notifies listeners (unlike jumpTo which is a no-op when pixels already
    // equals the target), so xterm's _onScroll re-arms _stickToBottom even
    // after alt-buffer transitions that leave maxScrollExtent at 0.
    if (_scrollController.hasClients) {
      // ignore: invalid_use_of_protected_member
      _scrollController.position.forcePixels(
        _scrollController.position.maxScrollExtent,
      );
    }
  }

  void paste(String text) {
    _terminal.paste(text);
  }

  void copySelection() {
    final selection = _terminalController.selection;
    if (selection == null) return;
    final text = _terminal.buffer.getText(selection);
    Clipboard.setData(ClipboardData(text: text));
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
      position.dx,
      position.dy,
      position.dx,
      position.dy,
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
          copySelection();
          _terminalController.clearSelection();
        case 'paste':
          pasteFromClipboard();
      }
    });
  }

  @override
  void dispose() {
    widget.controller.detach();
    HardwareKeyboard.instance.removeHandler(_handleSearchKey);
    _disposeAllSearchHighlights();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _foregroundDebounce?.cancel();
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
      padding: EdgeInsets.zero,
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
        Positioned(top: 8, right: 8, child: _buildSearchBar()),
      ],
    );
  }

  Widget _buildSearchBar() {
    final count = _searchMatches.length;
    final countText =
        count == 0 ? 'No results' : '${_currentMatchIndex + 1} / $count';

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
            _searchNavButton(
              Icons.keyboard_arrow_up,
              count > 0 ? _prevMatch : null,
            ),
            _searchNavButton(
              Icons.keyboard_arrow_down,
              count > 0 ? _nextMatch : null,
            ),
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
        icon: Icon(
          icon,
          size: 14,
          color: onPressed != null ? Colors.white70 : Colors.white24,
        ),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
        onPressed: onPressed,
      ),
    );
  }
}
