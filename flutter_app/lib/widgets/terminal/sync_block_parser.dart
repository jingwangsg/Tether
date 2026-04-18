import 'dart:async';
import 'dart:typed_data';

/// Streaming parser for DEC Mode 2026 synchronized-update blocks.
///
/// The Rust server's anti-flicker pipeline (see
/// `crates/tether-server/src/pty/anti_flicker.rs`) wraps each coalesced PTY
/// flush in `\x1b[?2026h` … `\x1b[?2026l`. This parser reassembles those
/// blocks on the client side so xterm.dart receives exactly one
/// `terminal.write()` per atomic update — the fix for Ink-based TUIs
/// (Codex, Claude Code) rendering as half-drawn frames on Android.
///
/// Bytes outside any sync block are emitted immediately. Bytes inside a
/// block are buffered until the closing marker arrives; if no end marker
/// arrives within [safetyWindow] the buffered content is flushed anyway so
/// a dropped end marker can never wedge the pipeline. Markers are never
/// emitted — only the content between them.
///
/// The parser is *not* applied to scrollback replay bytes (those are raw on
/// the wire), only to live `OutputMessage` frames.
class SyncBlockParser {
  SyncBlockParser({
    required this.onSegment,
    this.safetyWindow = const Duration(milliseconds: 50),
  });

  /// DEC Mode 2026 begin-synchronized-update marker.
  static final Uint8List syncStart = Uint8List.fromList([
    0x1b, 0x5b, 0x3f, 0x32, 0x30, 0x32, 0x36, 0x68, // ESC [ ? 2 0 2 6 h
  ]);

  /// DEC Mode 2026 end-synchronized-update marker.
  static final Uint8List syncEnd = Uint8List.fromList([
    0x1b, 0x5b, 0x3f, 0x32, 0x30, 0x32, 0x36, 0x6c, // ESC [ ? 2 0 2 6 l
  ]);

  /// Invoked with unwrapped bytes ready to be forwarded to `terminal.write()`.
  /// Callers also use the segment length to advance scrollback offsets, so
  /// the emitted lengths must exclude the DEC 2026 markers.
  final void Function(Uint8List segment) onSegment;

  /// How long to hold buffered sync-block content while waiting for the end
  /// marker. Matches codeman's `app.js` safety valve so one lost marker
  /// cannot stall the terminal.
  final Duration safetyWindow;

  final BytesBuilder _buffer = BytesBuilder(copy: false);
  bool _insideSync = false;
  Timer? _safetyTimer;

  /// Feed raw WS bytes into the parser; emits one or more segments via
  /// [onSegment]. Safe to call with empty chunks.
  void feed(Uint8List chunk) {
    if (chunk.isEmpty) return;
    _buffer.add(chunk);
    _consume();
  }

  /// Flush any buffered bytes (pre-sync tail or in-progress sync content) and
  /// reset. Call on disposal / reconnection so the next session starts clean.
  void reset() {
    _safetyTimer?.cancel();
    _safetyTimer = null;
    final remaining = _buffer.takeBytes();
    _buffer.clear();
    if (remaining.isNotEmpty) {
      onSegment(remaining);
    }
    _insideSync = false;
  }

  void _consume() {
    // Iterate until the buffer is exhausted or we can't make progress.
    while (true) {
      final bytes = _buffer.toBytes();
      if (bytes.isEmpty) return;

      if (!_insideSync) {
        final startIdx = _indexOf(bytes, syncStart);
        if (startIdx < 0) {
          // No full SYNC_START; emit everything that can't be a partial
          // marker prefix and keep the possibly-partial tail for later.
          final keepFrom = _trailingPartialMatch(bytes, syncStart);
          if (keepFrom > 0) {
            onSegment(Uint8List.sublistView(bytes, 0, keepFrom));
          }
          _buffer.clear();
          _buffer.add(Uint8List.sublistView(bytes, keepFrom));
          return;
        }
        // Emit pre-marker bytes, drop the marker itself, enter sync mode.
        if (startIdx > 0) {
          onSegment(Uint8List.sublistView(bytes, 0, startIdx));
        }
        _buffer.clear();
        _buffer.add(
          Uint8List.sublistView(bytes, startIdx + syncStart.length),
        );
        _insideSync = true;
        _armSafetyTimer();
        continue;
      }

      // Inside a sync block: hold bytes until SYNC_END arrives.
      final endIdx = _indexOf(bytes, syncEnd);
      if (endIdx < 0) {
        // Nothing to emit yet — wait for more data or the safety timer.
        return;
      }
      final content = Uint8List.sublistView(bytes, 0, endIdx);
      onSegment(content);
      _buffer.clear();
      _buffer.add(Uint8List.sublistView(bytes, endIdx + syncEnd.length));
      _insideSync = false;
      _cancelSafetyTimer();
    }
  }

  void _armSafetyTimer() {
    _cancelSafetyTimer();
    _safetyTimer = Timer(safetyWindow, _onSafetyTimeout);
  }

  void _cancelSafetyTimer() {
    _safetyTimer?.cancel();
    _safetyTimer = null;
  }

  void _onSafetyTimeout() {
    _safetyTimer = null;
    if (!_insideSync) return;
    final buffered = _buffer.takeBytes();
    _buffer.clear();
    _insideSync = false;
    if (buffered.isNotEmpty) {
      onSegment(buffered);
    }
  }

  /// Find the first occurrence of [needle] inside [haystack]. Returns -1 if
  /// absent. Simple O(n*m) scan — markers are tiny and the buffer is small.
  static int _indexOf(Uint8List haystack, Uint8List needle) {
    if (needle.isEmpty || needle.length > haystack.length) return -1;
    outer:
    for (var i = 0; i <= haystack.length - needle.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) continue outer;
      }
      return i;
    }
    return -1;
  }

  /// Returns the offset at which [haystack] has a trailing partial match of
  /// [needle], or `haystack.length` if no partial match exists. The returned
  /// offset is the first byte we must *keep* (in case the rest of [needle]
  /// arrives in a later chunk).
  static int _trailingPartialMatch(Uint8List haystack, Uint8List needle) {
    final maxPrefix =
        haystack.length < needle.length - 1
            ? haystack.length
            : needle.length - 1;
    for (var len = maxPrefix; len > 0; len--) {
      var matched = true;
      for (var i = 0; i < len; i++) {
        if (haystack[haystack.length - len + i] != needle[i]) {
          matched = false;
          break;
        }
      }
      if (matched) {
        return haystack.length - len;
      }
    }
    return haystack.length;
  }
}
