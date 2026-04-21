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
  test('claude detection keeps the session name and exposes osc title separately', () {
    final presentation = deriveSessionTabPresentation(
      _session(process: 'claude', oscTitle: '· Claude Code'),
      const {'s1': 'feature/refactor-shell'},
    );

    expect(presentation.primaryTitle, 'session-1234');
    expect(presentation.secondaryLabel, '· Claude Code');
  });

  test('codex detection keeps the session name and exposes osc title separately', () {
    final presentation = deriveSessionTabPresentation(
      _session(process: 'codex', oscTitle: '✱ Codex'),
      const {'s1': 'server logs'},
    );

    expect(presentation.primaryTitle, 'session-1234');
    expect(presentation.secondaryLabel, '✱ Codex');
  });

  test('falls back to the session name when no agent is active', () {
    final presentation = deriveSessionTabPresentation(
      _session(),
      const {'s1': 'feature/refactor-shell'},
    );

    expect(presentation.primaryTitle, 'session-1234');
    expect(presentation.secondaryLabel, isNull);
  });
}
