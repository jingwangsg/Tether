import 'dart:io';

const _debugLogPath = '/tmp/tether-debug.log';

void debugLog(String message) {
  final ts = DateTime.now().toIso8601String();
  final line = '$ts $message\n';
  try {
    File(_debugLogPath).writeAsStringSync(line, mode: FileMode.append);
  } catch (_) {}
}
