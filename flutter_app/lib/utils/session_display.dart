import 'package:flutter/material.dart';
import '../models/session.dart';

class SessionDisplayInfo {
  final String displayName;
  final IconData icon;
  final Color iconColor;
  final String? iconAsset;
  final String? subtitle;

  const SessionDisplayInfo({
    required this.displayName,
    required this.icon,
    required this.iconColor,
    this.iconAsset,
    this.subtitle,
  });
}

SessionDisplayInfo getDisplayInfo(Session session, List<Session> allSessions) {
  final process = session.foregroundProcess;

  if (process == null) {
    final subtitle = _cwdBasename(session.cwd);
    final displayName = session.name;
    return SessionDisplayInfo(
      displayName: displayName,
      icon: Icons.terminal,
      iconColor: session.isAlive ? Colors.green : Colors.white38,
      subtitle: subtitle.isNotEmpty ? subtitle : null,
    );
  }

  final prettyName = switch (process) {
    'claude' => 'Claude Code',
    'codex' => 'Codex',
    _ => process,
  };

  final displayName = prettyName;

  final IconData icon;
  final Color iconColor;
  String? iconAsset;
  switch (process) {
    case 'claude':
      icon = Icons.auto_awesome;
      iconColor = const Color(0xFFD97757);
      iconAsset = 'assets/icons/claudecode-color.png';
    case 'codex':
      icon = Icons.code;
      iconColor = const Color(0xFF8B5CF6);
      iconAsset = 'assets/icons/codex-color.png';
    default:
      icon = Icons.terminal;
      iconColor = Colors.green;
  }

  return SessionDisplayInfo(
    displayName: displayName,
    icon: icon,
    iconColor: iconColor,
    iconAsset: iconAsset,
    subtitle: session.name,
  );
}

String _cwdBasename(String cwd) {
  final parts = cwd.split('/').where((s) => s.isNotEmpty).toList();
  return parts.isNotEmpty ? parts.last : cwd;
}
