import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SidebarWidthNotifier extends StateNotifier<double> {
  SidebarWidthNotifier() : super(defaultWidth) {
    _load();
  }

  static const double defaultWidth = 280.0;
  static const double minWidth = 200.0;
  static const double maxWidth = 600.0;
  static const _key = 'sidebar_width_v1';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getDouble(_key);
    if (saved != null) {
      state = saved.clamp(minWidth, maxWidth);
    }
  }

  /// Update width in memory only — use during drag for smooth updates.
  void setLive(double width) {
    final clamped = width.clamp(minWidth, maxWidth);
    if (clamped == state) return;
    state = clamped;
  }

  /// Persist the current state to SharedPreferences.
  Future<void> commit() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_key, state);
  }
}

final sidebarWidthProvider =
    StateNotifierProvider<SidebarWidthNotifier, double>(
      (ref) => SidebarWidthNotifier(),
    );
