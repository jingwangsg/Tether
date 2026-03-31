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

  // Write batching — flush every 16ms
  final List<Uint8List> _writeQueue = [];
  bool _writeScheduled = false;

  // Foreground change debounce
  Timer? _foregroundDebounce;

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
    _connect();
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
        case ScrollbackMessage():
          _writeToTerminal(msg.data);
        case SessionEventMessage():
          if (msg.event == 'exited') {
            _sessionExited = true;
            widget.onSessionExited?.call();
          }
        case ForegroundChangedMessage():
          _foregroundDebounce?.cancel();
          _foregroundDebounce = Timer(const Duration(milliseconds: 500), () {
            ref.read(serverProvider.notifier).updateForegroundProcess(
              widget.sessionId,
              msg.process,
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

    // Snapshot scroll state before writing. 20px fuzz handles floating-point
    // imprecision at the bottom boundary (logical pixels).
    var wasAtBottom = true;
    var savedOffset = 0.0;
    if (_scrollController.hasClients) {
      final pos = _scrollController.position;
      savedOffset = pos.pixels;
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

    _terminal.write(utf8.decode(merged, allowMalformed: true));

    if (!wasAtBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scrollController.hasClients) {
          // Skip if the user is mid-fling — let the momentum continue uninterrupted.
          if (_scrollController.position.isScrollingNotifier.value) return;
          final maxExtent = _scrollController.position.maxScrollExtent;
          _scrollController.jumpTo(savedOffset.clamp(0.0, maxExtent));
        }
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
    _foregroundDebounce?.cancel();
    _msgSub?.cancel();
    _ws?.dispose();
    _terminalController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    return xterm.TerminalView(
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
  }
}
