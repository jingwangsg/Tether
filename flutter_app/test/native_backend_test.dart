import 'package:flutter_test/flutter_test.dart';
import 'package:tether/platform/native_backend.dart';

void main() {
  test('native backend retains up to 50 terminal views by default', () {
    final backend = NativeBackend();
    expect(backend.retainedTerminalViewCap, 50);
  });
}
