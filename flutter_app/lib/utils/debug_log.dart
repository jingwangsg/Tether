import 'dart:io';

const _debugLogPath = '/tmp/tether-debug.log';

String shortId(String id) => id.length <= 8 ? id : id.substring(0, 8);

void debugLog(String message) {
  final ts = DateTime.now().toIso8601String();
  final line = '$ts $message\n';
  try {
    File(_debugLogPath).writeAsStringSync(line, mode: FileMode.append);
  } catch (_) {}
}
