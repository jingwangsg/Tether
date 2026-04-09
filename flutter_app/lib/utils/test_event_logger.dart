import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, FileMode, Platform;

class TestEventLogger {
  TestEventLogger._();

  static final TestEventLogger instance = TestEventLogger._();
  static final String? _path = _resolvePath();
  Future<void> _pending = Future.value();

  static String? _resolvePath() {
    final env = Platform.environment;
    final path =
        env['TETHER_APP_TEST_LOG_PATH'] ?? env['TETHER_TERMINAL_TEST_LOG_PATH'];
    if (path == null || path.isEmpty) {
      return null;
    }
    return path;
  }

  void log(String event, [Map<String, Object?> payload = const {}]) {
    final path = _path;
    if (path == null) {
      return;
    }

    final entry = <String, Object?>{
      'event': event,
      'source': 'flutter',
      'timestamp': DateTime.now().toIso8601String(),
      ...payload,
    };

    final line = '${jsonEncode(entry)}\n';
    _pending = _pending.catchError((_) {}).then((_) async {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsString(line, mode: FileMode.append, flush: true);
    });
  }
}
