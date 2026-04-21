import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class PlatformReorderDragStartListener extends StatelessWidget {
  final Widget child;
  final int index;
  final bool enabled;

  const PlatformReorderDragStartListener({
    super.key,
    required this.child,
    required this.index,
    this.enabled = true,
  });

  bool _useImmediateDesktopDrag(TargetPlatform platform) {
    if (kIsWeb) {
      return false;
    }
    return switch (platform) {
      TargetPlatform.macOS ||
      TargetPlatform.windows ||
      TargetPlatform.linux => true,
      _ => false,
    };
  }

  @override
  Widget build(BuildContext context) {
    if (_useImmediateDesktopDrag(Theme.of(context).platform)) {
      return ReorderableDragStartListener(
        index: index,
        enabled: enabled,
        child: child,
      );
    }

    return ReorderableDelayedDragStartListener(
      index: index,
      enabled: enabled,
      child: child,
    );
  }
}
