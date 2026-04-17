import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class RecentPathsNotifier
    extends StateNotifier<Map<String, List<String>>> {
  RecentPathsNotifier() : super(const {}) {
    _load();
  }

  static const _key = 'recent_paths_by_host_v1';
  static const _maxPerHost = 10;

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final restored = <String, List<String>>{};
      decoded.forEach((key, value) {
        if (key is! String || value is! List) return;
        final paths = value.whereType<String>().toList();
        if (paths.isNotEmpty) restored[key] = paths;
      });
      state = restored;
    } catch (_) {
      // Corrupt payload — ignore and start fresh.
    }
  }

  List<String> pathsFor(String localityKey) =>
      state[localityKey] ?? const <String>[];

  Future<void> record({
    required String localityKey,
    required String path,
  }) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return;

    final existing = state[localityKey] ?? const <String>[];
    final updated = <String>[
      trimmed,
      ...existing.where((p) => p != trimmed),
    ];
    if (updated.length > _maxPerHost) {
      updated.removeRange(_maxPerHost, updated.length);
    }

    state = {...state, localityKey: updated};

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(state));
  }
}

final recentPathsProvider =
    StateNotifierProvider<RecentPathsNotifier, Map<String, List<String>>>(
      (ref) => RecentPathsNotifier(),
    );
