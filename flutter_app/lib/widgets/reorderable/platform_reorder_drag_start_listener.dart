import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

class PlatformReorderDragStartListener extends StatelessWidget {
  final Widget child;
  final int index;
  final Axis axis;
  final bool enabled;

  const PlatformReorderDragStartListener({
    super.key,
    required this.child,
    required this.index,
    required this.axis,
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
      return _AxisReorderDragStartListener(
        index: index,
        axis: axis,
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

class _AxisReorderDragStartListener extends ReorderableDragStartListener {
  final Axis axis;

  const _AxisReorderDragStartListener({
    required super.child,
    required super.index,
    required this.axis,
    super.enabled,
  });

  @override
  MultiDragGestureRecognizer createRecognizer() {
    return switch (axis) {
      Axis.horizontal => HorizontalMultiDragGestureRecognizer(debugOwner: this),
      Axis.vertical => VerticalMultiDragGestureRecognizer(debugOwner: this),
    };
  }
}
