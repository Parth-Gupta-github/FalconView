import 'package:flutter/material.dart';

import '../theme/tactical_theme.dart';

enum MapMode { none, mark, track, ruler, area }

class ActionPanel extends StatelessWidget {
  final MapMode mode;
  final ValueChanged<MapMode> onModeToggled;
  final VoidCallback onClear;

  const ActionPanel({
    super.key,
    required this.mode,
    required this.onModeToggled,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: TacticalPalette.panel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: TacticalPalette.divider),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          _ActionButton(
            icon: Icons.place_outlined,
            label: 'MARK',
            tooltip: 'Drop pins on the map · tap a pin to fly to it',
            active: mode == MapMode.mark,
            onTap: () => onModeToggled(MapMode.mark),
          ),
          _ActionButton(
            icon: Icons.timeline,
            label: 'TRACK',
            tooltip: 'Route from your location to a tapped destination',
            active: mode == MapMode.track,
            onTap: () => onModeToggled(MapMode.track),
          ),
          _ActionButton(
            icon: Icons.straighten,
            label: 'RULER',
            tooltip: 'Measure distance between two points',
            active: mode == MapMode.ruler,
            onTap: () => onModeToggled(MapMode.ruler),
          ),
          _ActionButton(
            icon: Icons.crop_free,
            label: 'AREA',
            tooltip: 'Draw a polygon to download that exact area offline',
            active: mode == MapMode.area,
            onTap: () => onModeToggled(MapMode.area),
          ),
          _ActionButton(
            icon: Icons.delete_sweep_outlined,
            label: 'CLR',
            tooltip: 'Clear all markers, rulers, routes, and areas',
            active: false,
            destructive: true,
            onTap: onClear,
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String tooltip;
  final bool active;
  final bool destructive;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.active,
    required this.onTap,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final Color bg = active
        ? TacticalPalette.accent
        : (destructive ? TacticalPalette.panel : TacticalPalette.accentSoft);
    final Color fg = active
        ? Colors.white
        : (destructive ? TacticalPalette.error : TacticalPalette.accent);
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: Tooltip(
          message: tooltip,
          waitDuration: const Duration(milliseconds: 400),
          child: Material(
            color: bg,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: onTap,
              child: Container(
                height: 52,
                alignment: Alignment.center,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, color: fg, size: 18),
                    const SizedBox(height: 2),
                    Text(
                      label,
                      style: TextStyle(
                        color: fg,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
