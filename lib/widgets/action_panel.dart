import 'package:flutter/material.dart';

import '../theme/tactical_theme.dart';

enum MapMode { none, mark, track, ruler }

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
        color: TacticalPalette.panelTranslucent,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: TacticalPalette.accent.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          _ActionButton(
            label: 'MARK',
            active: mode == MapMode.mark,
            onTap: () => onModeToggled(MapMode.mark),
          ),
          _ActionButton(
            label: 'TRACK',
            active: mode == MapMode.track,
            onTap: () => onModeToggled(MapMode.track),
          ),
          _ActionButton(
            label: 'RULER',
            active: mode == MapMode.ruler,
            onTap: () => onModeToggled(MapMode.ruler),
          ),
          _ActionButton(
            label: 'CLR',
            active: false,
            onTap: onClear,
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _ActionButton({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final Color bg = active ? TacticalPalette.accent : TacticalPalette.panel;
    final Color fg = active ? Colors.black : TacticalPalette.accent;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: Material(
          color: bg,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            child: Container(
              height: 44,
              alignment: Alignment.center,
              child: Text(
                label,
                style: TextStyle(
                  color: fg,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                  fontSize: 13,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
