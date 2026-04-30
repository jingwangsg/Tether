import '../models/session.dart';
import 'debug_log.dart';

enum SessionToolStatus { waiting, running }

enum SessionIndicatorStatus { waiting, running, attention }

SessionToolStatus? deriveSessionToolStatus(Session session) {
  return deriveToolStatus(
    process: session.foregroundProcess,
    oscTitle: session.oscTitle,
  );
}

SessionToolStatus? deriveToolStatus({
  required String? process,
  required String? oscTitle,
}) {
  if (!_isSupportedTool(process)) {
    return null;
  }

  final prefix = _leadingStatusGlyph(oscTitle);
  if (prefix == null) {
    return null;
  }

  if (prefix == '·') {
    return SessionToolStatus.waiting;
  }

  if (_runningPrefixes.contains(prefix) || _isBrailleSpinner(prefix)) {
    return SessionToolStatus.running;
  }

  return null;
}

SessionIndicatorStatus? deriveSessionIndicatorStatus(
  Session session, {
  required bool isActive,
}) {
  if (session.hasAttention && !isActive) {
    debugLog(
      '[BELL:5:status] session=${shortId(session.id)} -> ATTENTION (attSeq=${session.attentionSeq} ackSeq=${session.attentionAckSeq} isActive=$isActive)',
    );
    return SessionIndicatorStatus.attention;
  }

  final toolStatus = deriveSessionToolStatus(session);
  final result = switch (toolStatus) {
    SessionToolStatus.waiting => SessionIndicatorStatus.waiting,
    SessionToolStatus.running => SessionIndicatorStatus.running,
    null => null,
  };
  if (result != null) {
    debugLog(
      '[BELL:5:status] session=${shortId(session.id)} -> $result (fg=${session.foregroundProcess} osc=${session.oscTitle} attSeq=${session.attentionSeq} ackSeq=${session.attentionAckSeq} isActive=$isActive)',
    );
  }
  return result;
}

bool _isSupportedTool(String? process) {
  return process == 'claude' || process == 'codex';
}

String? _leadingStatusGlyph(String? oscTitle) {
  if (oscTitle == null) {
    return null;
  }

  final trimmed = oscTitle.trimLeft();
  if (trimmed.isEmpty) {
    return null;
  }

  return String.fromCharCode(trimmed.runes.first);
}

const _runningPrefixes = {'*', '✱'};

bool _isBrailleSpinner(String prefix) {
  final codePoint = prefix.runes.first;
  return codePoint >= 0x2800 && codePoint <= 0x28FF;
}
