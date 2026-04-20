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
  test('claude detection overrides cached terminal title', () {
    final presentation = deriveSessionTabPresentation(
      _session(process: 'claude', oscTitle: '· Claude Code'),
      const {'s1': 'feature/refactor-shell'},
    );

    expect(presentation.primaryTitle, 'Claude Code');
    expect(presentation.secondaryLabel, 'feature/refactor-shell');
  });

  test('codex detection overrides cached terminal title', () {
    final presentation = deriveSessionTabPresentation(
      _session(process: 'codex', oscTitle: '✱ Codex'),
      const {'s1': 'server logs'},
    );

    expect(presentation.primaryTitle, 'Codex');
    expect(presentation.secondaryLabel, 'server logs');
  });

  test('falls back to cached terminal title when no agent is active', () {
    final presentation = deriveSessionTabPresentation(
      _session(),
      const {'s1': 'feature/refactor-shell'},
    );

    expect(presentation.primaryTitle, 'feature/refactor-shell');
  });
}
