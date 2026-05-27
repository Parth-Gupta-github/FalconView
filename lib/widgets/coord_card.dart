import 'package:flutter/material.dart';

import '../theme/tactical_theme.dart';

class CoordCard extends StatelessWidget {
  final String coordsText;
  final String? distanceBearingText;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const CoordCard({
    super.key,
    required this.coordsText,
    required this.onTap,
    required this.onLongPress,
    this.distanceBearingText,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: TacticalPalette.panelTranslucent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: TacticalPalette.accent.withValues(alpha: 0.35)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                coordsText,
                style: const TextStyle(
                  color: TacticalPalette.accent,
                  fontFamily: 'monospace',
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.4,
                ),
              ),
              if (distanceBearingText != null) ...[
                const SizedBox(height: 4),
                Text(
                  distanceBearingText!,
                  style: const TextStyle(
                    color: TacticalPalette.textDim,
                    fontFamily: 'monospace',
                    fontSize: 12,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
