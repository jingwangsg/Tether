import 'dart:io' show Platform;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/mobile_key.dart';

enum ModifierMode { inactive, temporary, locked }

class UiState {
  final bool isMobile;
  final bool showKeyBar;
  final bool sidebarOpen;
  final ModifierMode ctrlMode;
  final ModifierMode altMode;
  final List<MobileKey> mobileKeys;

  const UiState({
    this.isMobile = false,
    this.showKeyBar = false,
    this.sidebarOpen = true,
    this.ctrlMode = ModifierMode.inactive,
    this.altMode = ModifierMode.inactive,
    this.mobileKeys = defaultMobileKeys,
  });

  bool get ctrlActive => ctrlMode != ModifierMode.inactive;
  bool get altActive => altMode != ModifierMode.inactive;

  UiState copyWith({
    bool? isMobile,
    bool? showKeyBar,
    bool? sidebarOpen,
    ModifierMode? ctrlMode,
    ModifierMode? altMode,
    List<MobileKey>? mobileKeys,
  }) {
    return UiState(
      isMobile: isMobile ?? this.isMobile,
      showKeyBar: showKeyBar ?? this.showKeyBar,
      sidebarOpen: sidebarOpen ?? this.sidebarOpen,
      ctrlMode: ctrlMode ?? this.ctrlMode,
      altMode: altMode ?? this.altMode,
      mobileKeys: mobileKeys ?? this.mobileKeys,
    );
  }
}

class UiNotifier extends StateNotifier<UiState> {
  UiNotifier()
      : super(
          Platform.isAndroid
              ? const UiState(isMobile: true, showKeyBar: true, sidebarOpen: false)
              : const UiState(),
        );

  void setMobile(bool isMobile) {
    if (state.isMobile == isMobile) return;
    state = state.copyWith(isMobile: isMobile, sidebarOpen: !isMobile);
  }

  void setShowKeyBar(bool show) {
    if (state.showKeyBar == show) return;
    state = state.copyWith(showKeyBar: show);
  }

  void toggleSidebar() {
    state = state.copyWith(sidebarOpen: !state.sidebarOpen);
  }

  void setSidebarOpen(bool open) {
    state = state.copyWith(sidebarOpen: open);
  }

  // --- Ctrl modifier ---
  void setCtrlTemporary() {
    state = state.copyWith(
      ctrlMode: state.ctrlMode == ModifierMode.inactive
          ? ModifierMode.temporary
          : ModifierMode.inactive,
    );
  }

  void setCtrlLocked() {
    state = state.copyWith(
      ctrlMode: state.ctrlMode == ModifierMode.locked
          ? ModifierMode.inactive
          : ModifierMode.locked,
    );
  }

  // --- Alt modifier ---
  void setAltTemporary() {
    state = state.copyWith(
      altMode: state.altMode == ModifierMode.inactive
          ? ModifierMode.temporary
          : ModifierMode.inactive,
    );
  }

  void setAltLocked() {
    state = state.copyWith(
      altMode: state.altMode == ModifierMode.locked
          ? ModifierMode.inactive
          : ModifierMode.locked,
    );
  }

  /// Deactivate temporary modifiers only; locked modifiers stay.
  void consumeTemporaryModifiers() {
    ModifierMode? newCtrl;
    ModifierMode? newAlt;
    if (state.ctrlMode == ModifierMode.temporary) {
      newCtrl = ModifierMode.inactive;
    }
    if (state.altMode == ModifierMode.temporary) {
      newAlt = ModifierMode.inactive;
    }
    if (newCtrl != null || newAlt != null) {
      state = state.copyWith(ctrlMode: newCtrl, altMode: newAlt);
    }
  }

  void clearModifiers() {
    state = state.copyWith(
      ctrlMode: ModifierMode.inactive,
      altMode: ModifierMode.inactive,
    );
  }

  void setMobileKeys(List<MobileKey> keys) {
    state = state.copyWith(mobileKeys: keys);
  }
}

final uiProvider = StateNotifierProvider<UiNotifier, UiState>((ref) {
  return UiNotifier();
});
