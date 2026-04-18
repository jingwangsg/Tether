import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tether/widgets/terminal/sync_block_parser.dart';

Uint8List _bytes(List<int> raw) => Uint8List.fromList(raw);

List<int> _collect(List<Uint8List> segments) {
  final out = <int>[];
  for (final s in segments) {
    out.addAll(s);
  }
  return out;
}

void main() {
  group('SyncBlockParser', () {
    test('passes through bytes with no markers unchanged', () {
      final segments = <Uint8List>[];
      final parser = SyncBlockParser(onSegment: segments.add);
      parser.feed(_bytes([1, 2, 3, 4, 5]));
      expect(_collect(segments), [1, 2, 3, 4, 5]);
    });

    test('single chunk with complete sync block emits one segment (markers stripped)', () {
      final segments = <Uint8List>[];
      final parser = SyncBlockParser(onSegment: segments.add);
      final frame = <int>[
        ...SyncBlockParser.syncStart,
        ...'hello'.codeUnits,
        ...SyncBlockParser.syncEnd,
      ];
      parser.feed(_bytes(frame));
      expect(segments.length, 1);
      expect(_collect(segments), 'hello'.codeUnits);
    });

    test('sync block split across two chunks emits one segment after second chunk', () {
      final segments = <Uint8List>[];
      final parser = SyncBlockParser(onSegment: segments.add);
      final first = <int>[
        ...SyncBlockParser.syncStart,
        ...'abc'.codeUnits,
      ];
      final second = <int>[
        ...'def'.codeUnits,
        ...SyncBlockParser.syncEnd,
      ];
      parser.feed(_bytes(first));
      expect(segments, isEmpty, reason: 'inside an open sync block — nothing emitted yet');
      parser.feed(_bytes(second));
      expect(segments.length, 1);
      expect(_collect(segments), 'abcdef'.codeUnits);
    });

    test('pre- and post-marker bytes emit in the correct order', () {
      final segments = <Uint8List>[];
      final parser = SyncBlockParser(onSegment: segments.add);
      final frame = <int>[
        ...'pre '.codeUnits,
        ...SyncBlockParser.syncStart,
        ...'mid'.codeUnits,
        ...SyncBlockParser.syncEnd,
        ...' post'.codeUnits,
      ];
      parser.feed(_bytes(frame));
      expect(_collect(segments), 'pre mid post'.codeUnits);
    });

    test('SYNC_START split across chunk boundary still detected', () {
      final segments = <Uint8List>[];
      final parser = SyncBlockParser(onSegment: segments.add);
      // Split the marker right in the middle.
      final first = <int>[...'abc'.codeUnits, 0x1b, 0x5b, 0x3f];
      final second = <int>[
        0x32, 0x30, 0x32, 0x36, 0x68, // rest of SYNC_START
        ...'xyz'.codeUnits,
        ...SyncBlockParser.syncEnd,
      ];
      parser.feed(_bytes(first));
      // "abc" can be emitted; the 3-byte tail is held as a partial match.
      expect(_collect(segments), 'abc'.codeUnits);
      segments.clear();
      parser.feed(_bytes(second));
      expect(_collect(segments), 'xyz'.codeUnits);
    });

    test(
      'unterminated sync block flushes as safety valve after safetyWindow',
      () async {
        final segments = <Uint8List>[];
        final parser = SyncBlockParser(
          onSegment: segments.add,
          safetyWindow: const Duration(milliseconds: 20),
        );
        final frame = <int>[
          ...SyncBlockParser.syncStart,
          ...'partial'.codeUnits,
          // no SYNC_END
        ];
        parser.feed(_bytes(frame));
        expect(segments, isEmpty);

        // Wait past the safety window.
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(_collect(segments), 'partial'.codeUnits);

        // After safety flush the parser should treat subsequent bytes as
        // outside any sync block — so a plain chunk passes through.
        parser.feed(_bytes('trailing'.codeUnits));
        expect(
          _collect(segments),
          'partial'.codeUnits + 'trailing'.codeUnits,
        );
      },
    );

    test('reset() flushes any buffered bytes and clears state', () {
      final segments = <Uint8List>[];
      final parser = SyncBlockParser(onSegment: segments.add);
      // Buffered 2-byte potential marker prefix.
      parser.feed(_bytes([0x1b, 0x5b]));
      expect(segments, isEmpty);
      parser.reset();
      expect(_collect(segments), [0x1b, 0x5b]);
      segments.clear();

      // After reset, plain bytes flow through.
      parser.feed(_bytes('ok'.codeUnits));
      expect(_collect(segments), 'ok'.codeUnits);
    });

    test('total emitted length across a burst equals sum of unwrapped content', () {
      final segments = <Uint8List>[];
      final parser = SyncBlockParser(onSegment: segments.add);
      final payloads = ['first-batch', 'second', 'third-and-final'];
      final frame = <int>[];
      for (final p in payloads) {
        frame.addAll(SyncBlockParser.syncStart);
        frame.addAll(p.codeUnits);
        frame.addAll(SyncBlockParser.syncEnd);
      }
      parser.feed(_bytes(frame));
      final total = segments.fold<int>(0, (sum, s) => sum + s.length);
      expect(total, payloads.fold<int>(0, (s, p) => s + p.length));
      expect(_collect(segments), payloads.join().codeUnits);
    });
  });
}
