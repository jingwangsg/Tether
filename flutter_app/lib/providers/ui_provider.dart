import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/mobile_key.dart';

class UiState {
  final bool isMobile;
  final bool sidebarOpen;
  final bool ctrlActive;
  final bool altActive;
  final List<MobileKey> mobileKeys;

  const UiState({
    this.isMobile = false,
    this.sidebarOpen = true,
    this.ctrlActive = false,
    this.altActive = false,
    this.mobileKeys = defaultMobileKeys,
  });

  UiState copyWith({
    bool? isMobile,
    bool? sidebarOpen,
    bool? ctrlActive,
    bool? altActive,
    List<MobileKey>? mobileKeys,
  }) {
    return UiState(
      isMobile: isMobile ?? this.isMobile,
      sidebarOpen: sidebarOpen ?? this.sidebarOpen,
      ctrlActive: ctrlActive ?? this.ctrlActive,
      altActive: altActive ?? this.altActive,
      mobileKeys: mobileKeys ?? this.mobileKeys,
    );
  }
}

class UiNotifier extends StateNotifier<UiState> {
  UiNotifier() : super(const UiState());

  void setMobile(bool isMobile) {
    state = state.copyWith(
      isMobile: isMobile,
      sidebarOpen: !isMobile,
    );
  }

  void toggleSidebar() {
    state = state.copyWith(sidebarOpen: !state.sidebarOpen);
  }

  void setSidebarOpen(bool open) {
    state = state.copyWith(sidebarOpen: open);
  }

  void toggleCtrl() {
    state = state.copyWith(ctrlActive: !state.ctrlActive);
  }

  void toggleAlt() {
    state = state.copyWith(altActive: !state.altActive);
  }

  void clearModifiers() {
    state = state.copyWith(ctrlActive: false, altActive: false);
  }

  void setMobileKeys(List<MobileKey> keys) {
    state = state.copyWith(mobileKeys: keys);
  }
}

final uiProvider = StateNotifierProvider<UiNotifier, UiState>((ref) {
  return UiNotifier();
});
