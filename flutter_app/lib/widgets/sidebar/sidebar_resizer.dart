import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/sidebar_width_provider.dart';

class SidebarResizer extends ConsumerStatefulWidget {
  const SidebarResizer({super.key});

  @override
  ConsumerState<SidebarResizer> createState() => _SidebarResizerState();
}

class _SidebarResizerState extends ConsumerState<SidebarResizer> {
  bool _hovering = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final active = _hovering || _dragging;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => setState(() => _dragging = true),
        onHorizontalDragUpdate: (details) {
          final current = ref.read(sidebarWidthProvider);
          ref
              .read(sidebarWidthProvider.notifier)
              .setLive(current + details.delta.dx);
        },
        onHorizontalDragEnd: (_) {
          setState(() => _dragging = false);
          ref.read(sidebarWidthProvider.notifier).commit();
        },
        onHorizontalDragCancel: () {
          setState(() => _dragging = false);
          ref.read(sidebarWidthProvider.notifier).commit();
        },
        child: Container(
          width: 6,
          color:
              active
                  ? Colors.white.withValues(alpha: 0.15)
                  : Colors.transparent,
        ),
      ),
    );
  }
}
