import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
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

  ForegroundChangedMessage(this.process, this.oscTitle);
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
            ),
          );
        default:
          break;
      }
    } catch (e) {
      // Malformed message, ignore
    }
  }

  void sendInput(String data) {
    _send({'type': 'input', 'data': base64Encode(utf8.encode(data))});
  }

  void sendResize(int cols, int rows) {
    _send({'type': 'resize', 'cols': cols, 'rows': rows});
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

  void _send(Map<String, dynamic> message) {
    _channel?.sink.add(jsonEncode(message));
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
    _channel?.sink.close();
    _channel = null;
    _messageController.close();
  }
}
