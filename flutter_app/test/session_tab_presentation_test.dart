import 'package:flutter_test/flutter_test.dart';
import 'package:tether/models/session.dart';
import 'package:tether/utils/session_tab_presentation.dart';

Session _session({
  String? process,
  String? oscTitle,
  String name = 'session-1234',
}) => Session(
  id: 's1',
  groupId: 'g1',
  name: name,
  shell: 'bash',
  cols: 80,
  rows: 24,
  cwd: '/tmp/project',
  isAlive: true,
  createdAt: '',
  lastActive: '',
  foregroundProcess: process,
  oscTitle: oscTitle,
);

void main() {
  test(
    'claude detection keeps the session name and exposes osc title separately',
    () {
      final presentation = deriveSessionTabPresentation(
        _session(process: 'claude', oscTitle: '· Claude Code'),
        const {'s1': 'feature/refactor-shell'},
      );

      expect(presentation.primaryTitle, 'session-1234');
      expect(presentation.secondaryLabel, '· Claude Code');
      expect(presentation.secondaryTooltip, isNull);
    },
  );

  test(
    'codex detection keeps the session name and exposes osc title separately',
    () {
      final presentation = deriveSessionTabPresentation(
        _session(process: 'codex', oscTitle: '✱ Codex'),
        const {'s1': 'server logs'},
      );

      expect(presentation.primaryTitle, 'session-1234');
      expect(presentation.secondaryLabel, '✱ Codex');
      expect(presentation.secondaryTooltip, isNull);
    },
  );

  test('compresses long osc title with env prefix and keeps full tooltip', () {
    final rawTitle =
        '✱ GEAR_SKIP_PIP_INSTALL=1 CLUSTER_TYPE=h100 NUM_GPUS=32 '
        'python groot/vla/omni/scripts/train/n2/launch_.py --fast';

    final presentation = deriveSessionTabPresentation(
      _session(process: 'codex', oscTitle: rawTitle),
      const {'s1': 'server logs'},
    );

    expect(presentation.primaryTitle, 'session-1234');
    expect(presentation.secondaryLabel, '✱ python …/launch_.py…');
    expect(presentation.secondaryTooltip, rawTitle);
  });

  test('truncates long secondary label to max length', () {
    final rawTitle =
        '· python train.py --arg-one value-one --arg-two value-two --arg-three value-three';

    final presentation = deriveSessionTabPresentation(
      _session(process: 'claude', oscTitle: rawTitle),
      const {'s1': 'server logs'},
    );

    final secondary = presentation.secondaryLabel;
    expect(secondary, isNotNull);
    expect(secondary!.length, lessThanOrEqualTo(24));
    expect(secondary.endsWith('…'), isTrue);
    expect(presentation.secondaryTooltip, rawTitle);
  });

  test('falls back to the session name when no agent is active', () {
    final presentation = deriveSessionTabPresentation(_session(), const {
      's1': 'feature/refactor-shell',
    });

    expect(presentation.primaryTitle, 'session-1234');
    expect(presentation.secondaryLabel, isNull);
    expect(presentation.secondaryTooltip, isNull);
  });
}
