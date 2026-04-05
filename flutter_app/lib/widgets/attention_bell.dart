import 'package:flutter/material.dart';

class AttentionBell extends StatelessWidget {
  final int count;
  final double iconSize;
  final Color color;

  const AttentionBell({
    super.key,
    this.count = 0,
    this.iconSize = 16,
    this.color = const Color(0xFFFFC107),
  });

  @override
  Widget build(BuildContext context) {
    final icon = Icon(
      Icons.notifications_active_outlined,
      size: iconSize,
      color: color,
    );
    if (count <= 0) {
      return icon;
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        icon,
        Positioned(
          top: -4,
          right: -6,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(999),
            ),
            constraints: const BoxConstraints(minWidth: 14),
            child: Text(
              count > 9 ? '9+' : '$count',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.black,
                fontSize: 9,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
