import 'package:characters/characters.dart';
import '../models/session.dart';

class SessionTabPresentation {
  final String primaryTitle;
  final String? secondaryLabel;
  final String? secondaryTooltip;

  const SessionTabPresentation({
    required this.primaryTitle,
    this.secondaryLabel,
    this.secondaryTooltip,
  });
}

const int _secondaryMaxLength = 24;
final RegExp _envAssignmentToken = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=\S+$');

SessionTabPresentation deriveSessionTabPresentation(
  Session session,
  Map<String, String> sessionTitles,
) {
  final secondary = _deriveSecondaryLabel(session);

  return SessionTabPresentation(
    primaryTitle: session.name,
    secondaryLabel: secondary?.label,
    secondaryTooltip: secondary?.tooltip,
  );
}

({String label, String? tooltip})? _deriveSecondaryLabel(Session session) {
  final isAgent =
      session.foregroundProcess == 'claude' ||
      session.foregroundProcess == 'codex';
  final rawTitle = session.oscTitle;
  if (!isAgent || rawTitle == null) {
    return null;
  }
  final normalized = _normalizeWhitespace(rawTitle);
  if (normalized.isEmpty) {
    return null;
  }

  final compacted = _compactSecondary(normalized);
  final truncated = _truncateSecondary(compacted);
  final compressed = truncated != normalized;
  return (label: truncated, tooltip: compressed ? normalized : null);
}

String _normalizeWhitespace(String value) {
  return value.replaceAll(RegExp(r'\s+'), ' ').trim();
}

String _compactSecondary(String value) {
  final chars = value.characters;
  var charIndex = 0;
  var statusPrefix = '';

  if (chars.isNotEmpty && _isStatusPrefix(chars.first.runes.first)) {
    statusPrefix = chars.first;
    charIndex = 1;
    final charList = chars.toList();
    while (charIndex < charList.length && charList[charIndex].trim().isEmpty) {
      charIndex++;
    }
  }

  // Convert character index to code-unit offset for substring
  final codeUnitOffset = value.characters.take(charIndex).string.length;
  final body = value.substring(codeUnitOffset).trimLeft();
  if (body.isEmpty) {
    return statusPrefix;
  }

  var tokens = body
      .split(' ')
      .where((token) => token.isNotEmpty)
      .toList(growable: false);
  var start = 0;
  while (start < tokens.length && _envAssignmentToken.hasMatch(tokens[start])) {
    start++;
  }
  if (start > 0 && start < tokens.length) {
    tokens = tokens.sublist(start);
  }

  final compactedTokens = tokens.map(_compactPathToken).toList(growable: false);
  final compactedBody = compactedTokens.join(' ').trim();
  if (statusPrefix.isEmpty) {
    return compactedBody;
  }
  if (compactedBody.isEmpty) {
    return statusPrefix;
  }
  return '$statusPrefix $compactedBody';
}

bool _isStatusPrefix(int rune) {
  if (rune == 0x2731 || rune == 0x00B7 || rune == 0x2022 || rune == 0x002A) {
    return true;
  }
  return rune >= 0x2800 && rune <= 0x28FF;
}

String _compactPathToken(String token) {
  if (!token.contains('/') || token.length <= 24) {
    return token;
  }

  var core = token;
  var leading = '';
  var trailing = '';

  if (core.isNotEmpty && (core.startsWith("'") || core.startsWith('"'))) {
    leading = core[0];
    core = core.substring(1);
  }

  while (core.isNotEmpty && '.,;:'.contains(core[core.length - 1])) {
    trailing = core[core.length - 1] + trailing;
    core = core.substring(0, core.length - 1);
  }

  if (core.isNotEmpty && (core.endsWith("'") || core.endsWith('"'))) {
    trailing = core[core.length - 1] + trailing;
    core = core.substring(0, core.length - 1);
  }

  if (!core.contains('/')) {
    return token;
  }

  final trimmed = core.replaceAll(RegExp(r'/+$'), '');
  if (trimmed.isEmpty) {
    return token;
  }
  final segments = trimmed
      .split('/')
      .where((segment) => segment.isNotEmpty)
      .toList(growable: false);
  if (segments.isEmpty) {
    return token;
  }

  final baseName = segments.last;
  final compacted = core.startsWith('/') ? '/…/$baseName' : '…/$baseName';
  return '$leading$compacted$trailing';
}

String _truncateSecondary(String value) {
  if (value.length <= _secondaryMaxLength) {
    return value;
  }

  final hardLimit = _secondaryMaxLength - 1;
  if (hardLimit <= 0) {
    return '…';
  }

  var truncated = value.substring(0, hardLimit);
  final lastSpace = truncated.lastIndexOf(' ');
  if (lastSpace >= 16) {
    truncated = truncated.substring(0, lastSpace);
  }
  truncated = truncated.trimRight();
  if (truncated.isEmpty) {
    truncated = value.substring(0, hardLimit);
  }
  return '$truncated…';
}
