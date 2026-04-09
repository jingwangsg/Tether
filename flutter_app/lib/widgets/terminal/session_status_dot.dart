import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../utils/session_status.dart';

class SessionStatusDot extends StatefulWidget {
  final SessionIndicatorStatus status;

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
    switch (widget.status) {
      case SessionIndicatorStatus.running:
        _controller
          ..stop()
          ..duration = const Duration(milliseconds: 900)
          ..repeat(reverse: true);
        return;
      case SessionIndicatorStatus.attention:
        _controller
          ..stop()
          ..duration = const Duration(milliseconds: 2200)
          ..repeat();
        return;
      case SessionIndicatorStatus.waiting:
        _controller.stop();
        _controller.value = 1;
        return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = switch (widget.status) {
      SessionIndicatorStatus.waiting => const Color(0xFFF2C94C),
      SessionIndicatorStatus.running => const Color(0xFF34C759),
      SessionIndicatorStatus.attention => const Color(0xFFF8D25C),
    };

    if (widget.status == SessionIndicatorStatus.waiting) {
      return _buildDot(color: color, opacity: 1, scale: 1, glow: 0);
    }

    if (widget.status == SessionIndicatorStatus.attention) {
      return AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final phase = _controller.value;
          final shakeWindow = phase < 0.32 ? phase / 0.32 : 1.0;
          final rotation =
              phase < 0.32
                  ? 0.26 *
                      Curves.easeOut.transform(1 - shakeWindow * 0.65) *
                      math.sin(shakeWindow * math.pi * 4)
                  : 0.0;
          final glow = phase < 0.28 ? 4.5 - (phase * 5) : 1.4;
          return _buildBell(
            color: color,
            opacity: 0.92,
            scale: 0.96 + (phase < 0.14 ? phase * 0.28 : 0.04),
            glow: glow,
            rotation: rotation,
          );
        },
      );
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
      width: 12,
      height: 12,
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

  Widget _buildBell({
    required Color color,
    required double opacity,
    required double scale,
    required double glow,
    required double rotation,
  }) {
    return SizedBox(
      width: 12,
      height: 12,
      child: Center(
        child: Opacity(
          opacity: opacity,
          child: Transform.rotate(
            angle: rotation,
            child: Transform.scale(
              scale: scale,
              child: Icon(
                Icons.notifications_active_rounded,
                size: 12,
                color: color,
                shadows: [
                  Shadow(color: color.withValues(alpha: 0.4), blurRadius: glow),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
