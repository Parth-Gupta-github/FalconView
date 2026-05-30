import 'dart:math' as math;
import 'package:flutter/material.dart';

/// North-up compass FAB.
///
/// Tap behaviour is delegated to [onTap] (the parent toggles a "rotation
/// locked" flag). When [locked] is true:
///   * the needle is frozen north-up,
///   * a small padlock badge sits in the corner,
///   * the chip uses an accent background so the active state is obvious
///     at a glance.
///
/// When unlocked the needle follows the current camera [bearing] like a
/// real compass.
class CompassFab extends StatelessWidget {
  final double bearing;
  final bool locked;
  final VoidCallback onTap;

  const CompassFab({
    super.key,
    required this.bearing,
    required this.onTap,
    this.locked = false,
  });

  @override
  Widget build(BuildContext context) {
    final Color bg = locked ? const Color(0xFFE53935) : Colors.white;
    final Color needle = locked ? Colors.white : Colors.redAccent;

    return SizedBox(
      width: 44,
      height: 44,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          FloatingActionButton(
            heroTag: 'compass-fab',
            mini: true,
            onPressed: onTap,
            backgroundColor: bg,
            elevation: 4,
            tooltip: locked
                ? 'Unlock rotation (currently north-up)'
                : 'Lock to north up',
            child: Transform.rotate(
              // Locked → keep the arrow pointing up since gestures can't
              // change the bearing anyway.
              angle: locked ? 0 : -bearing * math.pi / 180.0,
              child: Icon(Icons.navigation, color: needle, size: 22),
            ),
          ),
          if (locked)
            const Positioned(
              right: -2,
              bottom: -2,
              child: _LockBadge(),
            ),
        ],
      ),
    );
  }
}

class _LockBadge extends StatelessWidget {
  const _LockBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: const Color(0xFFE53935), width: 1.5),
      ),
      child: const Icon(
        Icons.lock,
        size: 10,
        color: Color(0xFFE53935),
      ),
    );
  }
}
