import 'package:flutter_test/flutter_test.dart';
import 'package:tether/models/session.dart';
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

  group('deriveSessionIndicatorStatus', () {
    Session session({
      String? process,
      String? oscTitle,
      int attentionSeq = 0,
      int attentionAckSeq = 0,
    }) {
      return Session(
        id: 's1',
        groupId: 'g1',
        name: 'agent',
        shell: 'bash',
        cols: 80,
        rows: 24,
        cwd: '/tmp',
        isAlive: true,
        createdAt: '',
        lastActive: '',
        foregroundProcess: process,
        oscTitle: oscTitle,
        attentionSeq: attentionSeq,
        attentionAckSeq: attentionAckSeq,
      );
    }

    test(
      'prefers bell indicator for unattended completed background session',
      () {
        final indicator = deriveSessionIndicatorStatus(
          session(
            process: 'claude',
            oscTitle: '· Claude Code',
            attentionSeq: 1,
            attentionAckSeq: 0,
          ),
          isActive: false,
        );

        expect(indicator, SessionIndicatorStatus.attention);
      },
    );

    test('suppresses bell indicator for active session', () {
      final indicator = deriveSessionIndicatorStatus(
        session(
          process: 'claude',
          oscTitle: '· Claude Code',
          attentionSeq: 1,
          attentionAckSeq: 0,
        ),
        isActive: true,
      );

      expect(indicator, SessionIndicatorStatus.waiting);
    });
  });
}
