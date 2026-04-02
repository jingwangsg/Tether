import 'package:flutter/material.dart';

/// Small pulsing/static dot badge shown on the tool icon when claude/codex is active.
/// Green pulse = running (tool is thinking), amber static = waiting for user input.
class ToolStateDot extends StatefulWidget {
  final String? toolState;
  const ToolStateDot(this.toolState, {super.key});

  @override
  State<ToolStateDot> createState() => _ToolStateDotState();
}

class _ToolStateDotState extends State<ToolStateDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
    _opacity = Tween<double>(begin: 0.3, end: 1.0).animate(_ctrl);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.toolState == null) return const SizedBox.shrink();

    final isRunning = widget.toolState == 'running';
    final color = isRunning
        ? const Color(0xFF4CAF50) // green
        : const Color(0xFFFF9800); // amber

    final dot = Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
    );

    if (isRunning) {
      return AnimatedBuilder(
        animation: _opacity,
        builder: (_, __) => Opacity(opacity: _opacity.value, child: dot),
      );
    }
    return dot;
  }
}
