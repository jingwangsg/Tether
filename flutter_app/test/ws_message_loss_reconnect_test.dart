import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tether/services/websocket_service.dart';

void main() {
  group('WebSocketService pending input queue', () {
    test('sendInput buffers when disconnected and pendingInput is non-empty', () {
      final service = WebSocketService('ws://unused');
      // Do NOT call connect — channel is null

      // sendInput should return true (buffered) and queue the message
      final result = service.sendInput('hello');
      expect(result, isTrue, reason: 'sendInput should return true when buffered');
      expect(service.pendingInput, isNotEmpty,
          reason: 'pendingInput should contain the buffered message');
      expect(service.pendingInput.length, 1);

      service.dispose();
    });

    test('pending input is bounded to maxPendingInput items', () {
      final service = WebSocketService('ws://unused');

      // Fill beyond max
      for (int i = 0; i < 80; i++) {
        service.sendInput('msg-$i');
      }

      expect(service.pendingInput.length, lessThanOrEqualTo(64),
          reason: 'pendingInput should not exceed max bound');

      service.dispose();
    });

    test('pending resize keeps only the latest', () {
      final service = WebSocketService('ws://unused');

      service.sendResize(80, 24);
      service.sendResize(120, 40);

      // There should be exactly one resize in the pending queue
      expect(service.pendingResize, isNotNull);
      expect(service.pendingResize!['cols'], 120);
      expect(service.pendingResize!['rows'], 40);

      service.dispose();
    });

    test('queue is flushed on first confirmed inbound message', () {
      final service = WebSocketService('ws://unused');

      // Buffer some input while disconnected
      service.sendInput('buffered1');
      service.sendInput('buffered2');
      expect(service.pendingInput.length, 2);

      // Simulate connection confirmation by calling confirmAndFlush
      // (In real code, _onMessage does this on first message)
      final flushed = service.flushPendingForTest();
      expect(flushed, isNotEmpty,
          reason: 'flushPending should return buffered items');
      expect(service.pendingInput, isEmpty,
          reason: 'pendingInput should be empty after flush');

      service.dispose();
    });
  });
}
