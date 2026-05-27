import 'dart:math' as math;
import 'package:flutter/material.dart';

class CompassFab extends StatelessWidget {
  final double bearing;
  final VoidCallback onTap;

  const CompassFab({
    super.key,
    required this.bearing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 44,
      child: FloatingActionButton(
        heroTag: 'compass-fab',
        mini: true,
        onPressed: onTap,
        backgroundColor: Colors.white,
        elevation: 4,
        child: Transform.rotate(
          angle: -bearing * math.pi / 180.0,
          child: const Icon(Icons.navigation, color: Colors.redAccent, size: 22),
        ),
      ),
    );
  }
}
