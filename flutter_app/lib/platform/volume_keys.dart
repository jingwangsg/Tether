import 'dart:async';
import 'package:flutter/services.dart';

enum VolumeKeyEvent { up, down }

/// Listens for volume key presses on Android via platform channel.
/// On macOS this is a no-op.
class VolumeKeyService {
  static const _channel = MethodChannel('dev.tether/volume_keys');
  final _controller = StreamController<VolumeKeyEvent>.broadcast();
  bool _enabled = false;

  Stream<VolumeKeyEvent> get events => _controller.stream;
  bool get enabled => _enabled;

  VolumeKeyService() {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    if (!_enabled) return;
    switch (call.method) {
      case 'volumeUp':
        _controller.add(VolumeKeyEvent.up);
      case 'volumeDown':
        _controller.add(VolumeKeyEvent.down);
    }
  }

  void setEnabled(bool enabled) {
    _enabled = enabled;
    _channel
        .invokeMethod('setEnabled', {'enabled': enabled})
        .catchError((_) {});
  }

  void dispose() {
    _enabled = false;
    _controller.close();
  }
}
