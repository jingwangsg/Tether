import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../platform/terminal_backend.dart';
import '../../utils/debug_log.dart';
import '../../providers/server_provider.dart';
import '../../services/websocket_service.dart';
import 'terminal_controller.dart';

/// Renders a native Ghostty surface inside a Flutter PlatformView on macOS.
///
/// Terminal bytes flow through the platform view into Ghostty, while
/// session metadata such as foreground process state is subscribed separately
/// via a lightweight WebSocket connection in Dart.
class TerminalView extends StatefulWidget {
  final String sessionId;
  final TerminalController controller;
  final ServerConfig? serverConfig;
  final bool isActive;
  final bool isVisibleInUI;
  final bool imagePasteBridgeEnabled;
  final VoidCallback? onSessionExited;
  final ForegroundChangedCallback? onForegroundChanged;
  final void Function(String title, String body)? onBell;
  final Future<void> Function(Uint8List data, String mimeType)?
  onClipboardImage;
  final WebSocketService Function(String url)? metadataWsFactory;

  const TerminalView({
    super.key,
    required this.sessionId,
    required this.controller,
    required this.serverConfig,
    required this.isActive,
    this.isVisibleInUI = true,
    this.imagePasteBridgeEnabled = false,
    this.onSessionExited,
    this.onForegroundChanged,
    this.onBell,
    this.onClipboardImage,
    this.metadataWsFactory,
  });

  @override
  State<TerminalView> createState() => TerminalViewState();
}

class TerminalViewState extends State<TerminalView> {
  static const _viewType = 'dev.tether/terminal_surface';
  static const _inputChannel = MethodChannel('dev.tether/terminal_input');

  int? _viewId;
  EventChannel? _eventChannel;
  StreamSubscription? _eventSubscription;
  WebSocketService? _metadataWs;
  StreamSubscription? _metadataSubscription;
  bool _didEmitExit = false;

  bool _searchOpen = false;
  int? _searchTotal;
  int? _searchSelected;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    debugLog('[SWITCH:flutter] initState session=${shortId(widget.sessionId)} isActive=${widget.isActive} isVisible=${widget.isVisibleInUI}');
    HardwareKeyboard.instance.addHandler(_handleSearchKey);
    widget.controller.attach(
      sendText: sendText,
      paste: paste,
      showSearch: showSearch,
      performAction: _performAction,
    );
    _syncMetadataConnection();
  }

  @override
  void didUpdateWidget(TerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    debugLog('[SWITCH:flutter] didUpdateWidget session=${shortId(widget.sessionId)} isActive: ${oldWidget.isActive}->${widget.isActive} isVisible: ${oldWidget.isVisibleInUI}->${widget.isVisibleInUI} viewId=$_viewId');
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.detach();
      widget.controller.attach(
        sendText: sendText,
        paste: paste,
        showSearch: showSearch,
        performAction: _performAction,
      );
    }
    if (oldWidget.isActive != widget.isActive && _viewId != null) {
      debugLog('[SWITCH:flutter] setActive(${widget.isActive}) session=${shortId(widget.sessionId)} viewId=$_viewId');
      _inputChannel.invokeMethod('setActive', {
        'viewId': _viewId,
        'active': widget.isActive,
      });
    }
    if (oldWidget.isVisibleInUI != widget.isVisibleInUI && _viewId != null) {
      debugLog('[SWITCH:flutter] setVisibleInUI(${widget.isVisibleInUI}) session=${shortId(widget.sessionId)} viewId=$_viewId');
      _inputChannel.invokeMethod('setVisibleInUI', {
        'viewId': _viewId,
        'visible': widget.isVisibleInUI,
      });
    }
    if (oldWidget.imagePasteBridgeEnabled != widget.imagePasteBridgeEnabled &&
        _viewId != null) {
      _inputChannel.invokeMethod('setImagePasteBridgeEnabled', {
        'viewId': _viewId,
        'enabled': widget.imagePasteBridgeEnabled,
      });
    }
    if (oldWidget.sessionId != widget.sessionId ||
        oldWidget.serverConfig?.baseUrl != widget.serverConfig?.baseUrl ||
        oldWidget.serverConfig?.token != widget.serverConfig?.token) {
      _disconnectMetadata();
      _didEmitExit = false;
    }
    _syncMetadataConnection();
  }

  bool _handleSearchKey(KeyEvent event) {
    if (!_searchOpen || event is! KeyDownEvent) return false;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _closeSearch();
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      if (HardwareKeyboard.instance.isShiftPressed) {
        _navigateSearch(previous: true);
      } else {
        _navigateSearch(previous: false);
      }
      return true;
    }
    return false;
  }

  void _disconnectMetadata() {
    _metadataSubscription?.cancel();
    _metadataSubscription = null;
    _metadataWs?.dispose();
    _metadataWs = null;
  }

  void _syncMetadataConnection() {
    if (!widget.isActive || widget.serverConfig == null) {
      if (_metadataWs != null) {
        debugLog('[BELL:2:tv] session=${widget.sessionId.substring(0, 8)} disconnecting metadata ws (isActive=${widget.isActive})');
      }
      _disconnectMetadata();
      return;
    }
    if (_metadataWs != null) {
      return;
    }
    debugLog('[BELL:2:tv] session=${widget.sessionId.substring(0, 8)} connecting metadata ws');
    _connectMetadata();
  }

  void _connectMetadata() {
    final config = widget.serverConfig;
    if (config == null) return;

    final wsScheme = config.useTls ? 'wss' : 'ws';
    var url =
        '$wsScheme://${config.host}:${config.port}/ws/session/${widget.sessionId}?mode=events';
    if (config.token != null && config.token!.isNotEmpty) {
      url += '&token=${Uri.encodeComponent(config.token!)}';
    }

    final ws = widget.metadataWsFactory?.call(url) ?? WebSocketService(url);
    _metadataWs = ws;
    ws.connect();
    _metadataSubscription = ws.messages.listen((message) {
      switch (message) {
        case ForegroundChangedMessage():
          debugLog('[BELL:2:tv] session=${widget.sessionId.substring(0, 8)} onForegroundChanged process=${message.process} osc=${message.oscTitle} attSeq=${message.attentionSeq} ackSeq=${message.attentionAckSeq} isActive=${widget.isActive}');
          widget.onForegroundChanged?.call(
            message.process,
            message.oscTitle,
            message.attentionSeq,
            message.attentionAckSeq,
          );
        case SessionEventMessage():
          if (message.event == 'exited') {
            _emitExit();
          }
        default:
          break;
      }
    });
  }

  void _emitExit() {
    if (_didEmitExit) return;
    _didEmitExit = true;
    widget.onSessionExited?.call();
    _metadataWs?.dispose();
    _metadataWs = null;
    _metadataSubscription?.cancel();
    _metadataSubscription = null;
  }

  void _onPlatformViewCreated(int viewId) {
    if (_viewId != null && _viewId != viewId) {
      _eventSubscription?.cancel();
      _inputChannel.invokeMethod('destroyView', {'viewId': _viewId});
    }
    _viewId = viewId;
    _eventChannel = EventChannel('dev.tether/terminal_events/$viewId');
    _eventSubscription = _eventChannel!.receiveBroadcastStream().listen(
      _onEvent,
    );

    _inputChannel.invokeMethod('setActive', {
      'viewId': viewId,
      'active': widget.isActive,
    });
    _inputChannel.invokeMethod('setVisibleInUI', {
      'viewId': viewId,
      'visible': widget.isVisibleInUI,
    });
    _inputChannel.invokeMethod('setImagePasteBridgeEnabled', {
      'viewId': viewId,
      'enabled': widget.imagePasteBridgeEnabled,
    });
  }

  void _onEvent(dynamic event) {
    if (event is! Map) return;
    final type = event['type'] as String?;
    switch (type) {
      case 'exited':
        _emitExit();
      case 'search_start':
        _openSearch(needle: event['value'] as String?);
      case 'search_end':
        _closeSearch(informNative: false);
      case 'search_total':
        setState(() {
          _searchTotal = event['value'] as int?;
        });
      case 'search_selected':
        setState(() {
          _searchSelected = event['value'] as int?;
        });
      case 'bell':
        final title = event['title'] as String? ?? '';
        final body = event['body'] as String? ?? '';
        debugLog('[BELL:2:tv] session=${widget.sessionId.substring(0, 8)} BELL event title=$title body=$body');
        widget.onBell?.call(title, body);
      case 'clipboard_image':
        final data = event['data'];
        final mimeType = event['mimeType'] as String?;
        if (data is Uint8List && mimeType != null) {
          unawaited(widget.onClipboardImage?.call(data, mimeType));
        }
    }
  }

  void sendText(String text) {
    if (_viewId == null) return;
    _inputChannel.invokeMethod('sendText', {'viewId': _viewId, 'text': text});
  }

  void paste(String text) => sendText(text);

  void showSearch() {
    _openSearch();
    _performAction('start_search');
  }

  void _performAction(String action) {
    if (_viewId == null) return;
    _inputChannel.invokeMethod('performAction', {
      'viewId': _viewId,
      'action': action,
    });
  }

  void _openSearch({String? needle}) {
    setState(() {
      _searchOpen = true;
      if (needle != null) {
        _searchController.text = needle;
        _searchController.selection = TextSelection.collapsed(
          offset: needle.length,
        );
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _searchFocusNode.requestFocus();
      }
    });
  }

  void _closeSearch({bool informNative = true}) {
    if (!_searchOpen && !informNative) return;
    setState(() {
      _searchOpen = false;
      _searchTotal = null;
      _searchSelected = null;
      _searchController.clear();
    });
    if (informNative) {
      _performAction('end_search');
    }
  }

  void _updateSearch(String value) {
    setState(() {
      _searchSelected = null;
    });
    _performAction('search:$value');
  }

  void _navigateSearch({required bool previous}) {
    _performAction(previous ? 'search:previous' : 'search:next');
  }

  @override
  void dispose() {
    debugLog('[SWITCH:flutter] dispose session=${shortId(widget.sessionId)} viewId=$_viewId');
    widget.controller.detach();
    HardwareKeyboard.instance.removeHandler(_handleSearchKey);
    _searchController.dispose();
    _searchFocusNode.dispose();
    _disconnectMetadata();
    _eventSubscription?.cancel();
    if (_viewId != null) {
      _inputChannel.invokeMethod('destroyView', {'viewId': _viewId});
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isMacOS) {
      return const Center(
        child: Text(
          'Terminal is only supported on macOS',
          style: TextStyle(color: Colors.white54),
        ),
      );
    }

    if (widget.serverConfig == null) {
      return const Center(
        child: Text(
          'Terminal server is not connected',
          style: TextStyle(color: Colors.white54),
        ),
      );
    }

    final terminal = AppKitView(
      key: ValueKey(
        '${widget.sessionId}:${widget.serverConfig!.baseUrl}:${widget.serverConfig!.token ?? ''}',
      ),
      viewType: _viewType,
      onPlatformViewCreated: _onPlatformViewCreated,
      creationParams: {
        'sessionId': widget.sessionId,
        'serverBaseUrl': widget.serverConfig!.baseUrl,
        if (widget.serverConfig!.token != null)
          'authToken': widget.serverConfig!.token!,
      },
      creationParamsCodec: const StandardMessageCodec(),
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        terminal,
        // Keep the platform view mounted across search open/close so Flutter
        // doesn't tear down and recreate the native Ghostty surface.
        if (_searchOpen) Positioned(top: 8, right: 8, child: _buildSearchBar()),
      ],
    );
  }

  Widget _buildSearchBar() {
    final total = _searchTotal;
    final selected = _searchSelected;
    final countText = switch ((total, selected)) {
      (null, _) => '',
      (0, _) => 'No results',
      (final t?, final s?) => '${s + 1} / $t',
      (final t?, _) => '1 / $t',
    };

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
                  onChanged: _updateSearch,
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
              total == null || total == 0
                  ? null
                  : () => _navigateSearch(previous: true),
            ),
            _searchNavButton(
              Icons.keyboard_arrow_down,
              total == null || total == 0
                  ? null
                  : () => _navigateSearch(previous: false),
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
