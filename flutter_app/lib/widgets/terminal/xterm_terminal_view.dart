import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:xterm/xterm.dart' as xterm;
import '../../platform/terminal_backend.dart';
import '../../providers/server_provider.dart';
import '../../providers/settings_provider.dart';
import '../../providers/ui_provider.dart';
import '../../services/websocket_service.dart';
import 'mobile_key_bar.dart' show applyMobileModifiers;
import 'semantic_prompt_state.dart';
import 'selection_handles_overlay.dart';
import 'terminal_controller.dart';

/// Expanded word separators for terminal output. Includes all xterm defaults
/// plus common code/terminal delimiters so double-tap / long-press word
/// selection produces smaller, more useful ranges in dense output.
const terminalWordSeparators = <int>{
  0,
  // xterm defaults
  0x20, // ' '
  0x2E, // '.'
  0x3A, // ':'
  0x2D, // '-'
  0x5C, // '\'
  0x22, // '"'
  0x2A, // '*'
  0x2B, // '+'
  0x2F, // '/'
  // Additional terminal/code delimiters
  0x7C, // '|'
  0x28, // '('
  0x29, // ')'
  0x5B, // '['
  0x5D, // ']'
  0x7B, // '{'
  0x7D, // '}'
  0x3C, // '<'
  0x3E, // '>'
  0x3D, // '='
  0x2C, // ','
  0x3B, // ';'
  0x60, // '`'
  0x27, // "'"
  0x09, // tab
};

/// Terminal widget that connects to a server-managed PTY via WebSocket.
/// Uses xterm.dart for terminal emulation and rendering.
class XtermTerminalView extends ConsumerStatefulWidget {
  final String sessionId;
  final TerminalController controller;
  final bool isActive;
  final VoidCallback? onSessionExited;
  final void Function(String? title)? onTitleChanged;
  final ForegroundChangedCallback? onForegroundChanged;
  final WebSocketService Function(String Function() urlBuilder)? wsFactory;
  final Future<Uint8List?> Function(int offset, int limit)? scrollbackFetcher;

  const XtermTerminalView({
    super.key,
    required this.sessionId,
    required this.controller,
    required this.isActive,
    this.onSessionExited,
    this.onTitleChanged,
    this.onForegroundChanged,
    this.wsFactory,
    this.scrollbackFetcher,
  });

  @override
  ConsumerState<XtermTerminalView> createState() => XtermTerminalViewState();
}

class XtermTerminalViewState extends ConsumerState<XtermTerminalView>
    with WidgetsBindingObserver {
  late xterm.Terminal _terminal;
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
  StreamController<List<int>> _bytesInput = StreamController<List<int>>(
    sync: true,
  );
  StreamSubscription? _decoderSub;

  // Replay buffering — batch scrollback messages to avoid incremental scrolling
  bool _isReplaying = true;
  final List<Uint8List> _replayBuffer = [];
  Timer? _replayFlushTimer;

  // Scrollback lazy loading state
  int _loadedStartOffset = 0;
  @visibleForTesting
  int get loadedStartOffset => _loadedStartOffset;
  int totalScrollbackBytes = 0;
  final List<Uint8List> _rawBytesCache = [];
  int _rawBytesCacheSize = 0;
  bool _hasTruncatedRawBytesCache = false;
  static const _maxCacheSize = 5 * 1024 * 1024; // 5MB
  int _currentMaxLines = 10000;
  final TerminalSemanticPromptState _semanticPromptState =
      TerminalSemanticPromptState();
  Timer? _semanticResizeRebuildTimer;
  bool _isRebuildingSemanticResize = false;
  bool _needsFollowupSemanticResize = false;
  int _semanticResizeRebuildCount = 0;
  int? _lastKnownCols;

  // Prefetch state
  bool _isPrefetching = false;
  xterm.Terminal? _prefetchedTerminal;
  int _prefetchStartOffset = 0;
  Uint8List? _prefetchedData;
  int _prefetchCacheSnapshot = 0; // cache length when prefetch was built

  // Foreground change debounce
  Timer? _foregroundDebounce;

  // Search state
  bool _searchOpen = false;
  bool _appLifecycleActive = true;
  GlobalKey<xterm.TerminalViewState>? _xtermViewKey;
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
    _xtermViewKey = GlobalKey<xterm.TerminalViewState>();
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    _appLifecycleActive =
        lifecycleState == null || lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _scrollController = ScrollController();
    _scrollController.addListener(_onScrollChanged);
    _terminalController = xterm.TerminalController();
    _terminal = _createTerminal(maxLines: 10000);
    _bindDecoderPipeline();
    HardwareKeyboard.instance.addHandler(_handleSearchKey);
    _connect();
    _syncEffectiveActiveState(forceRelayoutOnResume: false);
  }

  xterm.Terminal _createTerminal({required int maxLines}) {
    final terminal = xterm.Terminal(
      maxLines: maxLines,
      wordSeparators: terminalWordSeparators,
    );
    _configureTerminal(terminal);
    return terminal;
  }

  void _configureTerminal(xterm.Terminal terminal) {
    terminal.onOutput = _onTerminalInput;
    terminal.onTitleChange = (title) {
      widget.onTitleChanged?.call(title);
    };
    terminal.onPrivateOSC =
        (code, args) => _handlePrivateOsc(terminal, code, args);
    if (_semanticPromptState.shouldUseResizeRecovery) {
      terminal.reflowEnabled = false;
    }
    terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      _ws?.sendResize(width, height);
      final previousCols = _lastKnownCols;
      _lastKnownCols = width;
      // Only rebuild when char column count changes. Row-only changes (e.g.
      // Android soft keyboard show/hide) do not re-wrap content, so skipping
      // the rebuild avoids a cascade of expensive replays on every keyboard
      // toggle while Claude Code / Codex are running.
      if (!_semanticPromptState.shouldUseResizeRecovery ||
          _isRebuildingSemanticResize ||
          previousCols == null ||
          previousCols == width) {
        return;
      }
      _scheduleSemanticResizeRebuild();
    };
  }

  void _handlePrivateOsc(
    xterm.Terminal terminal,
    String code,
    List<String> args,
  ) {
    final changed = _semanticPromptState.handlePrivateOsc(code, args);
    if (!changed) return;
    terminal.reflowEnabled = !_semanticPromptState.shouldUseResizeRecovery;
  }

  void _scheduleSemanticResizeRebuild() {
    if (_isRebuildingSemanticResize) {
      _needsFollowupSemanticResize = true;
      return;
    }
    _semanticResizeRebuildTimer?.cancel();
    _semanticResizeRebuildTimer = Timer(const Duration(milliseconds: 16), () {
      unawaited(_rebuildTerminalFromCache());
    });
  }

  Future<List<Uint8List>?> _semanticResizeReplayChunks() async {
    if (!_hasTruncatedRawBytesCache && _rawBytesCacheSize >= _ackedOffset) {
      return List<Uint8List>.from(_rawBytesCache);
    }

    if (widget.scrollbackFetcher != null) {
      final data = await widget.scrollbackFetcher!(_loadedStartOffset, _ackedOffset);
      return data == null ? null : <Uint8List>[data];
    }

    final serverState = ref.read(serverProvider);
    if (!serverState.isConnected || serverState.config == null) {
      return null;
    }

    if (_ackedOffset <= 0) {
      return null;
    }

    final config = serverState.config!;
    final uri = Uri.parse(
      '${config.baseUrl}/api/sessions/${widget.sessionId}/scrollback'
      '?offset=$_loadedStartOffset&limit=$_ackedOffset',
    );
    final headers = <String, String>{};
    if (config.token != null && config.token!.isNotEmpty) {
      headers['Authorization'] = 'Bearer ${config.token}';
    }

    final response = await http.get(uri, headers: headers);
    if (response.statusCode != 200) {
      return null;
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return <Uint8List>[base64Decode(json['data'] as String)];
  }

  Future<void> _rebuildTerminalFromCache() async {
    if (!mounted ||
        _isRebuildingSemanticResize ||
        !_semanticPromptState.shouldUseResizeRecovery) {
      return;
    }
    _isRebuildingSemanticResize = true;
    _semanticResizeRebuildCount += 1;
    _isPaused = true;
    _writeScheduled = false;

    if (_writeQueue.isNotEmpty) {
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
    }

    try {
      final replayChunks = await _semanticResizeReplayChunks();
      if (!mounted || replayChunks == null) {
        _finishSemanticResizeRebuild();
        return;
      }

      final oldScrollBack = _terminal.buffer.scrollBack;
      double scrollRatio = 0.0;
      if (_scrollController.hasClients && oldScrollBack > 0) {
        final maxExtent = _scrollController.position.maxScrollExtent;
        if (maxExtent > 0) {
          scrollRatio = _scrollController.position.pixels / maxExtent;
        }
      }

      _terminalController.clearSelection();
      _disposeAllSearchHighlights();
      _searchMatches.clear();
      if (_searchOpen) {
        _searchController.clear();
        _currentMatchIndex = -1;
      }

      _decoderSub?.cancel();
      _bytesInput.close();
      _bytesInput = StreamController<List<int>>(sync: true);

      final rebuiltTerminal = _createTerminal(maxLines: _currentMaxLines);
      final replayDecoder = StreamController<List<int>>(sync: true);
      replayDecoder.stream
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen((text) => rebuiltTerminal.write(text));
      for (final chunk in replayChunks) {
        replayDecoder.add(chunk);
      }
      replayDecoder.close();

      _terminal = rebuiltTerminal;
      _bindDecoderPipeline();
      if (mounted) {
        setState(() {});
      }

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scrollController.hasClients) {
          final maxExtent = _scrollController.position.maxScrollExtent;
          final newScrollBack = _terminal.buffer.scrollBack;
          if (maxExtent > 0 && newScrollBack > 0 && oldScrollBack > 0) {
            final oldAbsoluteLine = (scrollRatio * oldScrollBack).round();
            final lineHeight = maxExtent / newScrollBack;
            final offset = (oldAbsoluteLine * lineHeight).clamp(0.0, maxExtent);
            _scrollController.jumpTo(offset);
          }
        }
        _finishSemanticResizeRebuild();
      });
    } catch (_) {
      _finishSemanticResizeRebuild();
    }
  }

  void _finishSemanticResizeRebuild() {
    _isPaused = false;
    if (_pauseBuffer.isNotEmpty) {
      for (final chunk in _pauseBuffer) {
        _writeQueue.add(chunk);
      }
      _pauseBuffer.clear();
      _scheduleFlush();
    }
    final shouldReplayAgain = _needsFollowupSemanticResize;
    _needsFollowupSemanticResize = false;
    _isRebuildingSemanticResize = false;
    _ws?.sendResume();
    if (shouldReplayAgain) {
      _scheduleSemanticResizeRebuild();
    }
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
      performAction: _performAction,
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
        performAction: _performAction,
      );
    }
    if (oldWidget.isActive != widget.isActive) {
      _syncEffectiveActiveState(forceRelayoutOnResume: true);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final lifecycleActive = state == AppLifecycleState.resumed;
    if (_appLifecycleActive == lifecycleActive) return;
    _appLifecycleActive = lifecycleActive;
    _syncEffectiveActiveState(forceRelayoutOnResume: lifecycleActive);
  }

  void _connect() {
    final serverState = ref.read(serverProvider);
    if (!serverState.isConnected || serverState.config == null) {
      _writeToTerminal(
        utf8.encode('\r\n\x1b[31m[server not connected]\x1b[0m\r\n'),
      );
      return;
    }

    _ws =
        widget.wsFactory != null
            ? widget.wsFactory!(_buildWsUrl)
            : WebSocketService.withUrlBuilder(_buildWsUrl);
    _ws!.connect();

    _msgSub = _ws!.messages.listen((msg) {
      switch (msg) {
        case OutputMessage():
          if (_isReplaying) _flushReplayBuffer();
          _ackedOffset += msg.data.length;
          _cacheRawBytes(msg.data);
          _writeToTerminal(msg.data);
        case ScrollbackMessage():
          _ackedOffset += msg.data.length;
          _cacheRawBytes(msg.data);
          if (_isReplaying) {
            _replayBuffer.add(msg.data);
            _resetReplayFlushTimer();
          } else {
            _writeToTerminal(msg.data);
          }
        case ScrollbackInfoMessage():
          // scrollback_info is the reliable "replay done" signal — the server
          // sends it after ALL scrollback chunks, on both local and proxy paths.
          // Flush the replay buffer here so the terminal renders immediately.
          if (_isReplaying) _flushReplayBuffer();
          totalScrollbackBytes = msg.totalBytes;
          final newOffset = msg.loadedFrom;
          if (newOffset != _loadedStartOffset) {
            setState(() {
              _loadedStartOffset = newOffset;
            });
          }
        case SessionEventMessage():
          if (_isReplaying) _flushReplayBuffer();
          if (msg.event == 'exited') {
            _sessionExited = true;
            _ws?.dispose();
            _ws = null;
            widget.onSessionExited?.call();
          }
        case ForegroundChangedMessage():
          // Do NOT flush replay buffer here — the SSH proxy path may inject
          // a cached foreground_changed before scrollback frames arrive.
          _foregroundDebounce?.cancel();
          _foregroundDebounce = Timer(const Duration(milliseconds: 100), () {
            widget.onForegroundChanged?.call(
              msg.process,
              msg.oscTitle,
              msg.attentionSeq,
              msg.attentionAckSeq,
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
            if (_isReplaying) _flushReplayBuffer();
            _isReplaying = true; // Reset for next reconnect
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
    // Always send tail_bytes — server prioritises offset when both present
    queryParts.add('tail_bytes=1048576');
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
    if (_isPaused) {
      _pauseBuffer.addAll(_writeQueue);
      _writeQueue.clear();
      return;
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

  void _bindDecoderPipeline() {
    _decoderSub?.cancel();
    _decoderSub = _bytesInput.stream
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((text) => _terminal.write(text));
  }

  void _resetReplayFlushTimer() {
    _replayFlushTimer?.cancel();
    _replayFlushTimer = Timer(const Duration(milliseconds: 500), () {
      if (_isReplaying) _flushReplayBuffer();
    });
  }

  void _flushReplayBuffer() {
    _replayFlushTimer?.cancel();
    _replayFlushTimer = null;
    _isReplaying = false;
    if (_replayBuffer.isEmpty) return;
    // Write in 64KB sub-chunks across microtasks to avoid blocking UI
    final chunks = List<Uint8List>.from(_replayBuffer);
    _replayBuffer.clear();
    _flushChunked(chunks, 0);
  }

  void _flushChunked(List<Uint8List> chunks, int index) {
    if (!mounted || index >= chunks.length) return;
    const maxPerFrame = 65536; // 64KB per microtask
    int written = 0;
    while (index < chunks.length &&
        written + chunks[index].length <= maxPerFrame) {
      _writeToTerminal(chunks[index]);
      written += chunks[index].length;
      index++;
    }
    if (index < chunks.length) {
      Timer.run(() => _flushChunked(chunks, index));
    }
  }

  void _onScrollChanged() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final maxExtent = pos.maxScrollExtent;
    if (maxExtent <= 0) return;

    final ratio = pos.pixels / maxExtent;

    // Trigger prefetch when within 15% of the top and more history available
    if (ratio < 0.15 &&
        _loadedStartOffset > 0 &&
        !_isPrefetching &&
        _prefetchedTerminal == null) {
      _startPrefetch();
    }

    // Trigger terminal swap when at the very top and prefetch is ready
    if (pos.pixels <= 0 && _prefetchedTerminal != null) {
      _performTerminalSwap();
    }
  }

  Future<void> _startPrefetch() async {
    if (_isPrefetching || _loadedStartOffset <= 0) return;
    setState(() {
      _isPrefetching = true;
    });

    final serverState = ref.read(serverProvider);
    if (!serverState.isConnected || serverState.config == null) {
      _isPrefetching = false;
      return;
    }
    final config = serverState.config!;

    final fetchEnd = _loadedStartOffset;
    const fetchSize = 1048576; // 1MB
    final fetchStart = max(0, fetchEnd - fetchSize);
    final limit = fetchEnd - fetchStart;

    try {
      final uri = Uri.parse(
        '${config.baseUrl}/api/sessions/${widget.sessionId}/scrollback'
        '?offset=$fetchStart&limit=$limit',
      );
      final headers = <String, String>{};
      if (config.token != null && config.token!.isNotEmpty) {
        headers['Authorization'] = 'Bearer ${config.token}';
      }
      final resp = await http.get(uri, headers: headers);
      if (resp.statusCode != 200) {
        _isPrefetching = false;
        return;
      }

      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final b64Data = json['data'] as String;
      final fetchedBytes = base64Decode(b64Data);

      if (!mounted) {
        _isPrefetching = false;
        return;
      }

      // Build background terminal with all data (prefetched + cached)
      _currentMaxLines += 5000;
      final bgTerminal = _createTerminal(maxLines: _currentMaxLines);

      // Process prefetched (older) bytes through a fresh decoder
      final bgDecoder = StreamController<List<int>>(sync: true);
      bgDecoder.stream
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen((text) => bgTerminal.write(text));
      bgDecoder.add(fetchedBytes);

      // Process cached (current) bytes
      for (final chunk in _rawBytesCache) {
        bgDecoder.add(chunk);
      }
      bgDecoder.close();

      _prefetchedTerminal = bgTerminal;
      _prefetchStartOffset = fetchStart;
      _prefetchedData = fetchedBytes;
      _prefetchCacheSnapshot = _rawBytesCache.length;
      if (mounted) {
        setState(() {
          _isPrefetching = false;
        });
      }

      // If user is already at the top, swap immediately
      if (_scrollController.hasClients &&
          _scrollController.position.pixels <= 0) {
        _performTerminalSwap();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isPrefetching = false;
        });
      }
    }
  }

  void _performTerminalSwap() {
    final newTerminal = _prefetchedTerminal;
    if (newTerminal == null) return;
    _prefetchedTerminal = null;

    // 1. Pause WebSocket writes and drain pending write queue
    _isPaused = true;
    _writeScheduled = false;
    // Flush any pending writes to the OLD terminal so _rawBytesCache is consistent
    if (_writeQueue.isNotEmpty) {
      int totalLen = 0;
      for (final chunk in _writeQueue) {
        totalLen += chunk.length;
      }
      final merged = Uint8List(totalLen);
      int off = 0;
      for (final chunk in _writeQueue) {
        merged.setRange(off, off + chunk.length, chunk);
        off += chunk.length;
      }
      _writeQueue.clear();
      _bytesInput.add(merged);
    }

    // 2. Capture the user's actual scroll position from the scroll controller
    //    (not cursorY which is relative to the viewport, not the scrollback)
    final oldScrollBack = _terminal.buffer.scrollBack;
    double scrollRatio = 0.0;
    if (_scrollController.hasClients && oldScrollBack > 0) {
      final maxExtent = _scrollController.position.maxScrollExtent;
      if (maxExtent > 0) {
        scrollRatio = _scrollController.position.pixels / maxExtent;
      }
    }

    // 3. Clean up search and selection state that references old terminal buffer
    _terminalController.clearSelection();
    _disposeAllSearchHighlights();
    _searchMatches.clear();
    if (_searchOpen) {
      _searchController.clear();
      _currentMatchIndex = -1;
    }

    // 4. Rebuild decoder pipeline for the new terminal
    _decoderSub?.cancel();
    _bytesInput.close();
    _bytesInput = StreamController<List<int>>(sync: true);

    // 5. Replay any live output that arrived between prefetch and swap
    //    into the new terminal so it doesn't go missing.
    if (_prefetchCacheSnapshot < _rawBytesCache.length) {
      final bgDecoder = StreamController<List<int>>(sync: true);
      bgDecoder.stream
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen((text) => newTerminal.write(text));
      for (int i = _prefetchCacheSnapshot; i < _rawBytesCache.length; i++) {
        bgDecoder.add(_rawBytesCache[i]);
      }
      bgDecoder.close();
    }

    // 6. Swap terminal
    _terminal = newTerminal;
    _configureTerminal(_terminal);

    // 7. Bind decoder to new terminal
    _bindDecoderPipeline();

    // 8. Update loaded range and prepend prefetched data to cache
    if (_prefetchedData != null) {
      _rawBytesCache.insert(0, _prefetchedData!);
      _rawBytesCacheSize += _prefetchedData!.length;
      _prefetchedData = null;
      // Evict from the TAIL (newest) when over limit — we just prepended
      // older data at index 0 and want to keep it for future rebuilds.
      while (_rawBytesCacheSize > _maxCacheSize && _rawBytesCache.length > 1) {
        final removed = _rawBytesCache.removeLast();
        _rawBytesCacheSize -= removed.length;
      }
    }
    _loadedStartOffset = _prefetchStartOffset;

    // 9. Rebuild widget with new terminal
    setState(() {});

    // 10. Restore scroll position after rebuild
    //    The new terminal has more lines (prepended history). We captured the
    //    old scroll ratio (how far the user was from the top in the old buffer).
    //    Map that to the new buffer by computing the absolute line the user was
    //    viewing, then adding the number of new lines prepended.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final maxExtent = _scrollController.position.maxScrollExtent;
      if (maxExtent > 0) {
        // The old scroll ratio maps to a position in the old terminal.
        // New terminal = prefetched older lines + old lines.
        // The old content starts at (newScrollBack - oldScrollBack) lines in.
        final newScrollBack = _terminal.buffer.scrollBack;
        if (newScrollBack > 0 && oldScrollBack > 0) {
          final oldAbsoluteLine = (scrollRatio * oldScrollBack).round();
          final prependedLines = newScrollBack - oldScrollBack;
          final newLine = prependedLines + oldAbsoluteLine;
          final lineHeight = maxExtent / newScrollBack;
          final offset = (newLine * lineHeight).clamp(0.0, maxExtent);
          _scrollController.jumpTo(offset);
        }
      }

      // 10. Flush pause buffer and resume
      _isPaused = false;
      if (_pauseBuffer.isNotEmpty) {
        for (final chunk in _pauseBuffer) {
          _writeQueue.add(chunk);
        }
        _pauseBuffer.clear();
        _scheduleFlush();
      }
      final shouldReplayAgain = _needsFollowupSemanticResize;
      _needsFollowupSemanticResize = false;
      _isRebuildingSemanticResize = false;
      _ws?.sendResume();
      if (shouldReplayAgain) {
        _scheduleSemanticResizeRebuild();
      }
    });
  }

  void _cacheRawBytes(Uint8List data) {
    _rawBytesCache.add(data);
    _rawBytesCacheSize += data.length;
    // Evict oldest chunks if cache exceeds limit
    while (_rawBytesCacheSize > _maxCacheSize && _rawBytesCache.isNotEmpty) {
      final removed = _rawBytesCache.removeAt(0);
      _rawBytesCacheSize -= removed.length;
      _hasTruncatedRawBytesCache = true;
    }
  }

  void _pause() {
    _isPaused = true;
    if (_writeQueue.isNotEmpty) {
      _pauseBuffer.addAll(_writeQueue);
      _writeQueue.clear();
    }
    _writeScheduled = false;
    _ws?.sendPause();
  }

  void _syncEffectiveActiveState({required bool forceRelayoutOnResume}) {
    final shouldBeActive = widget.isActive && _appLifecycleActive;
    if (shouldBeActive) {
      if (_isPaused) {
        _resume(forceRelayout: forceRelayoutOnResume);
      }
    } else {
      if (!_isPaused) {
        _pause();
      }
    }
  }

  void _sendCurrentSize() {
    final width = _terminal.viewWidth;
    final height = _terminal.viewHeight;
    if (width > 0 && height > 0) {
      _ws?.sendResize(width, height);
    }
  }

  void _resume({bool forceRelayout = false}) {
    if (forceRelayout && mounted) {
      setState(() {
        _xtermViewKey = GlobalKey<xterm.TerminalViewState>();
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _resumeAfterLayout();
      });
      return;
    }
    _resumeAfterLayout();
  }

  void _resumeAfterLayout() {
    _isPaused = false;
    if (_pauseBuffer.isNotEmpty) {
      for (final chunk in _pauseBuffer) {
        _writeQueue.add(chunk);
      }
      _pauseBuffer.clear();
      _scheduleFlush();
    }
    _sendCurrentSize();
    _ws?.sendResume();
  }

  void _onTerminalInput(String data) {
    final uiState = ref.read(uiProvider);
    final output = applyMobileModifiers(data, uiState);
    final sent = _ws?.sendInput(output) ?? false;

    if (sent &&
        (uiState.ctrlMode == ModifierMode.temporary ||
            uiState.altMode == ModifierMode.temporary)) {
      ref.read(uiProvider.notifier).consumeTemporaryModifiers();
    }
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

  void _performAction(String action) {
    if (action == 'increase_font_size:1') {
      final current = ref.read(settingsProvider).fontSize;
      ref.read(settingsProvider.notifier).setFontSize(
        (current + 1).clamp(10, 24),
      );
    } else if (action == 'decrease_font_size:1') {
      final current = ref.read(settingsProvider).fontSize;
      ref.read(settingsProvider.notifier).setFontSize(
        (current - 1).clamp(10, 24),
      );
    } else if (action == 'reset_font_size') {
      ref.read(settingsProvider.notifier).setFontSize(
        TerminalSettings.defaultFontSize,
      );
    }
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
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_handleSearchKey);
    _scrollController.removeListener(_onScrollChanged);
    _disposeAllSearchHighlights();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _foregroundDebounce?.cancel();
    _replayFlushTimer?.cancel();
    _semanticResizeRebuildTimer?.cancel();
    _msgSub?.cancel();
    _ws?.dispose();
    _decoderSub?.cancel();
    _bytesInput.close();
    _terminalController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final uiState = ref.watch(uiProvider);
    final terminalView = xterm.TerminalView(
      key: _xtermViewKey,
      _terminal,
      controller: _terminalController,
      scrollController: _scrollController,
      padding: EdgeInsets.zero,
      deleteDetection: true,
      keyboardType: TextInputType.visiblePassword,
      hardwareKeyboardOnly: uiState.softKeyboardLocked,
      textStyle: xterm.TerminalStyle(
        fontSize: settings.fontSize,
        fontFamily: settings.fontFamily,
      ),
      onSecondaryTapDown: (details, cellOffset) {
        _showContextMenu(context, details.globalPosition);
      },
    );

    Widget terminalWidget = terminalView;
    if (Platform.isAndroid) {
      terminalWidget = SelectionHandlesOverlay(
        terminalController: _terminalController,
        xtermViewKey: _xtermViewKey!,
        terminal: _terminal,
        onCopy: copySelection,
        onPaste: pasteFromClipboard,
        scrollController: _scrollController,
        child: terminalView,
      );
    }

    final showTopIndicator = _loadedStartOffset > 0 || _isPrefetching;

    if (!_searchOpen && !showTopIndicator) return terminalWidget;

    return Stack(
      children: [
        terminalWidget,
        if (_searchOpen) Positioned(top: 8, right: 8, child: _buildSearchBar()),
        if (showTopIndicator)
          Positioned(
            top: 4,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xCC1E1E1E),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _isPrefetching ? 'Loading...' : 'Scroll up for more',
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                ),
              ),
            ),
          ),
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

  @visibleForTesting
  bool get semanticPromptSeen => _semanticPromptState.hasSeenSemanticPrompt;

  @visibleForTesting
  bool get terminalReflowEnabled => _terminal.reflowEnabled;

  @visibleForTesting
  int get semanticResizeRebuildCount => _semanticResizeRebuildCount;

  @visibleForTesting
  void debugTriggerSemanticResizeRebuild() {
    _scheduleSemanticResizeRebuild();
  }

  @visibleForTesting
  void debugMarkReplayCacheTruncated() {
    _hasTruncatedRawBytesCache = true;
  }

  @visibleForTesting
  String get debugTerminalText {
    final buffer = _terminal.buffer;
    final lines = <String>[];
    for (int i = 0; i < buffer.lines.length; i++) {
      lines.add(buffer.lines[i].getText());
    }
    return lines.join('\n');
  }
}
