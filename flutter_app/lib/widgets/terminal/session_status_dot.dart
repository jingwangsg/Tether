import 'package:flutter/material.dart';
import '../../utils/session_status.dart';

class SessionStatusDot extends StatefulWidget {
  final SessionToolStatus status;

  const SessionStatusDot({super.key, required this.status});

  @override
  State<SessionStatusDot> createState() => _SessionStatusDotState();
}

class _SessionStatusDotState extends State<SessionStatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant SessionStatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.status != widget.status) {
      _syncAnimation();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _syncAnimation() {
    if (widget.status == SessionToolStatus.running) {
      if (!_controller.isAnimating) {
        _controller.repeat(reverse: true);
      }
      return;
    }

    _controller.stop();
    _controller.value = 1;
  }

  @override
  Widget build(BuildContext context) {
    final color = switch (widget.status) {
      SessionToolStatus.waiting => const Color(0xFFF2C94C),
      SessionToolStatus.running => const Color(0xFF34C759),
    };

    if (widget.status == SessionToolStatus.waiting) {
      return _buildDot(color: color, opacity: 1, scale: 1, glow: 0);
    }

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final pulse = Curves.easeInOut.transform(_controller.value);
        return _buildDot(
          color: color,
          opacity: 0.55 + (pulse * 0.45),
          scale: 0.88 + (pulse * 0.22),
          glow: 2 + (pulse * 6),
        );
      },
    );
  }

  Widget _buildDot({
    required Color color,
    required double opacity,
    required double scale,
    required double glow,
  }) {
    final decoration = BoxDecoration(
      shape: BoxShape.circle,
      color: color,
      boxShadow:
          glow <= 0
              ? null
              : [
                BoxShadow(
                  color: color.withValues(alpha: 0.45),
                  blurRadius: glow,
                  spreadRadius: glow / 8,
                ),
              ],
    );

    return SizedBox(
      width: 10,
      height: 10,
      child: Center(
        child: Opacity(
          opacity: opacity,
          child: Transform.scale(
            scale: scale,
            child: Container(width: 8, height: 8, decoration: decoration),
          ),
        ),
      ),
    );
  }
}
