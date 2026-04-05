import 'package:flutter_test/flutter_test.dart';
import 'package:tether/utils/session_status.dart';

void main() {
  group('deriveToolStatus', () {
    test('returns waiting for dot-prefixed Claude Code title', () {
      final status = deriveToolStatus(
        process: 'claude',
        oscTitle: '· Claude Code',
      );

      expect(status, SessionToolStatus.waiting);
    });

    test('returns running for star-prefixed Codex title', () {
      final status = deriveToolStatus(process: 'codex', oscTitle: '✱ Codex');

      expect(status, SessionToolStatus.running);
    });

    test('returns running for braille spinner prefix', () {
      final status = deriveToolStatus(
        process: 'claude',
        oscTitle: '⠋ Claude Code',
      );

      expect(status, SessionToolStatus.running);
    });

    test('returns null for unsupported tools', () {
      final status = deriveToolStatus(process: 'vim', oscTitle: '· vim');

      expect(status, isNull);
    });

    test('returns null when tool title has no status prefix', () {
      final status = deriveToolStatus(
        process: 'claude',
        oscTitle: 'Claude Code',
      );

      expect(status, isNull);
    });
  });
}
