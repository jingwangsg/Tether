import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:web_socket_channel/web_socket_channel.dart';

/// Message types sent by the server
sealed class ServerMessage {}

class OutputMessage extends ServerMessage {
  final Uint8List data;
  OutputMessage(this.data);
}

class ScrollbackMessage extends ServerMessage {
  final Uint8List data;
  ScrollbackMessage(this.data);
}

class SessionEventMessage extends ServerMessage {
  final String event;
  final int? exitCode;
  SessionEventMessage(this.event, this.exitCode);
}

class PongMessage extends ServerMessage {}

class ErrorMessage extends ServerMessage {
  final String message;
  ErrorMessage(this.message);
}

class ForegroundChangedMessage extends ServerMessage {
  final String? process;
  final String? oscTitle;
  final int attentionSeq;
  final int attentionAckSeq;

  ForegroundChangedMessage(
    this.process,
    this.oscTitle,
    this.attentionSeq,
    this.attentionAckSeq,
  );
}

class ScrollbackInfoMessage extends ServerMessage {
  final int totalBytes;
  final int loadedFrom;
  ScrollbackInfoMessage(this.totalBytes, this.loadedFrom);
}

class ConnectionStateMessage extends ServerMessage {
  final bool connected;
  ConnectionStateMessage(this.connected);
}

/// Manages a WebSocket connection to a single terminal session.
/// Supports auto-reconnect with exponential backoff.
class WebSocketService {
  final String Function() _urlBuilder;
  WebSocketChannel? _channel;
  final _messageController = StreamController<ServerMessage>.broadcast();
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  bool _disposed = false;
  bool _autoReconnect = true;
  int _reconnectAttempts = 0;
  // True only after receiving the first message from the server, confirming the
  // connection is actually usable (not just that connect() was called).
  bool _confirmed = false;
  static const _maxReconnectDelay = Duration(seconds: 30);

  // Bounded outbound queue for messages sent while disconnected.
  static const maxPendingInput = 64;
  final List<Map<String, dynamic>> _pendingInput = [];
  Map<String, dynamic>? _pendingResize;

  @visibleForTesting
  List<Map<String, dynamic>> get pendingInput =>
      List.unmodifiable(_pendingInput);

  @visibleForTesting
  Map<String, dynamic>? get pendingResize => _pendingResize;

  /// Flush and return pending messages. Exposed for testing.
  @visibleForTesting
  List<Map<String, dynamic>> flushPendingForTest() {
    final items = List<Map<String, dynamic>>.from(_pendingInput);
    if (_pendingResize != null) {
      items.add(_pendingResize!);
      _pendingResize = null;
    }
    _pendingInput.clear();
    return items;
  }

  WebSocketService(String url) : _urlBuilder = (() => url);

  WebSocketService.withUrlBuilder(String Function() urlBuilder)
    : _urlBuilder = urlBuilder;

  Stream<ServerMessage> get messages => _messageController.stream;
  bool get isConnected => _channel != null;

  void connect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _confirmed = false;

    try {
      _channel = WebSocketChannel.connect(Uri.parse(_urlBuilder()));
    } catch (e) {
      _scheduleReconnect();
      return;
    }

    _channel!.stream.listen(
      _onMessage,
      onError: (error) {
        _channel = null;
        _confirmed = false;
        _stopPing();
        _messageController.add(ConnectionStateMessage(false));
        if (_autoReconnect && !_disposed) {
          _scheduleReconnect();
        }
      },
      onDone: () {
        _channel = null;
        _confirmed = false;
        _stopPing();
        if (!_disposed) {
          _messageController.add(ConnectionStateMessage(false));
          if (_autoReconnect) {
            _scheduleReconnect();
          }
        }
      },
    );

    // Start pinging so the server can reply, triggering _onMessage which
    // confirms the connection and resets the backoff counter.
    _startPing();
  }

  void _scheduleReconnect() {
    if (_disposed || !_autoReconnect) return;
    final delay = _calculateBackoff();
    _reconnectTimer = Timer(delay, () {
      if (!_disposed) {
        _reconnectAttempts++;
        connect();
      }
    });
  }

  Duration _calculateBackoff() {
    final seconds = min(
      pow(2, _reconnectAttempts).toInt(),
      _maxReconnectDelay.inSeconds,
    );
    return Duration(seconds: seconds);
  }

  void _onMessage(dynamic raw) {
    if (raw is! String) return;

    // First message received — connection is confirmed usable.
    if (!_confirmed) {
      _confirmed = true;
      _reconnectAttempts = 0;
      _flushPending();
      _messageController.add(ConnectionStateMessage(true));
    }

    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final type = json['type'] as String?;

      switch (type) {
        case 'output':
          final b64 = json['data'] as String;
          _messageController.add(OutputMessage(base64Decode(b64)));
        case 'scrollback':
          final b64 = json['data'] as String;
          _messageController.add(ScrollbackMessage(base64Decode(b64)));
        case 'session_event':
          _messageController.add(
            SessionEventMessage(
              json['event'] as String? ?? '',
              json['exit_code'] as int?,
            ),
          );
        case 'pong':
          _messageController.add(PongMessage());
        case 'foreground_changed':
          _messageController.add(
            ForegroundChangedMessage(
              json['process'] as String?,
              json['osc_title'] as String?,
              (json['attention_seq'] as num?)?.toInt() ?? 0,
              (json['attention_ack_seq'] as num?)?.toInt() ?? 0,
            ),
          );
        case 'scrollback_info':
          _messageController.add(
            ScrollbackInfoMessage(
              (json['total_bytes'] as num).toInt(),
              (json['loaded_from'] as num).toInt(),
            ),
          );
        default:
          break;
      }
    } catch (e) {
      // Malformed message, ignore
    }
  }

  bool sendInput(String data) {
    final msg = {'type': 'input', 'data': base64Encode(utf8.encode(data))};
    if (_channel != null) {
      _channel!.sink.add(jsonEncode(msg));
      return true;
    }
    // Buffer while disconnected — return false so callers know
    // the input was not actually delivered to the server yet.
    _pendingInput.add(msg);
    while (_pendingInput.length > maxPendingInput) {
      _pendingInput.removeAt(0);
    }
    return false;
  }

  void sendResize(int cols, int rows) {
    final msg = {'type': 'resize', 'cols': cols, 'rows': rows};
    if (_channel != null) {
      _channel!.sink.add(jsonEncode(msg));
    } else {
      // Keep only the latest pending resize
      _pendingResize = msg;
    }
  }

  void sendPing() {
    _send({'type': 'ping'});
  }

  void sendPause() {
    _send({'type': 'pause'});
  }

  void sendResume() {
    _send({'type': 'resume'});
  }

  bool _send(Map<String, dynamic> message) {
    if (_channel == null) return false;
    _channel!.sink.add(jsonEncode(message));
    return true;
  }

  void _flushPending() {
    if (_channel == null) return;
    // Flush pending resize first (server needs dimensions before input)
    if (_pendingResize != null) {
      _channel!.sink.add(jsonEncode(_pendingResize!));
      _pendingResize = null;
    }
    for (final msg in _pendingInput) {
      _channel!.sink.add(jsonEncode(msg));
    }
    _pendingInput.clear();
  }

  void _startPing() {
    _pingTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      sendPing();
    });
  }

  void _stopPing() {
    _pingTimer?.cancel();
    _pingTimer = null;
  }

  void dispose() {
    _disposed = true;
    _autoReconnect = false;
    _confirmed = false;
    _reconnectTimer?.cancel();
    _stopPing();
    _pendingInput.clear();
    _pendingResize = null;
    _channel?.sink.close();
    _channel = null;
    _messageController.close();
  }
}
