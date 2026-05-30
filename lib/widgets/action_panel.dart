import 'package:flutter/material.dart';

import '../theme/tactical_theme.dart';

enum MapMode { none, mark, track, ruler, area }

/// Bottom action bar with MARK / TRACK / RULER / AREA / CLR plus a manual
/// chevron tab that collapses the panel to free up vertical space. When
/// collapsed and a mode is active, the chevron shows the mode's icon so the
/// user retains context.
class ActionPanel extends StatefulWidget {
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
  State<ActionPanel> createState() => _ActionPanelState();
}

class _ActionPanelState extends State<ActionPanel> {
  bool _collapsed = false;

  void _toggle() => setState(() => _collapsed = !_collapsed);

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      alignment: Alignment.bottomCenter,
      child: _collapsed ? _buildCollapsed() : _buildExpanded(),
    );
  }

  Widget _buildExpanded() {
    return Container(
      key: const ValueKey<String>('action-panel-expanded'),
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _ChevronTab(
            collapsed: false,
            mode: widget.mode,
            onTap: _toggle,
          ),
          Row(
            children: <Widget>[
              _ActionButton(
                icon: Icons.place_outlined,
                label: 'MARK',
                tooltip: 'Drop pins on the map · tap a pin to fly to it',
                active: widget.mode == MapMode.mark,
                onTap: () => widget.onModeToggled(MapMode.mark),
              ),
              _ActionButton(
                icon: Icons.timeline,
                label: 'TRACK',
                tooltip: 'Route from your location to a tapped destination',
                active: widget.mode == MapMode.track,
                onTap: () => widget.onModeToggled(MapMode.track),
              ),
              _ActionButton(
                icon: Icons.straighten,
                label: 'RULER',
                tooltip: 'Measure distance between two points',
                active: widget.mode == MapMode.ruler,
                onTap: () => widget.onModeToggled(MapMode.ruler),
              ),
              _ActionButton(
                icon: Icons.crop_free,
                label: 'AREA',
                tooltip:
                    'Draw a polygon to download that exact area offline',
                active: widget.mode == MapMode.area,
                onTap: () => widget.onModeToggled(MapMode.area),
              ),
              _ActionButton(
                icon: Icons.delete_sweep_outlined,
                label: 'CLR',
                tooltip: 'Clear all markers, rulers, routes, and areas',
                active: false,
                destructive: true,
                onTap: widget.onClear,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCollapsed() {
    return Align(
      key: const ValueKey<String>('action-panel-collapsed'),
      alignment: Alignment.bottomCenter,
      child: Material(
        color: TacticalPalette.panel,
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: TacticalPalette.divider),
        ),
        child: _ChevronTab(
          collapsed: true,
          mode: widget.mode,
          onTap: _toggle,
        ),
      ),
    );
  }
}

/// The drag-handle-style chevron tab. Doubles as a mode indicator when the
/// panel is collapsed (shows the active mode icon next to the arrow).
class _ChevronTab extends StatelessWidget {
  final bool collapsed;
  final MapMode mode;
  final VoidCallback onTap;

  const _ChevronTab({
    required this.collapsed,
    required this.mode,
    required this.onTap,
  });

  IconData? _iconForMode(MapMode m) {
    switch (m) {
      case MapMode.mark:
        return Icons.place_outlined;
      case MapMode.track:
        return Icons.timeline;
      case MapMode.ruler:
        return Icons.straighten;
      case MapMode.area:
        return Icons.crop_free;
      case MapMode.none:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final IconData? modeIcon = _iconForMode(mode);
    return Tooltip(
      message: collapsed ? 'Show action bar' : 'Hide action bar',
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (collapsed && modeIcon != null) ...<Widget>[
                Icon(modeIcon, size: 16, color: TacticalPalette.accent),
                const SizedBox(width: 8),
                Container(
                  width: 1,
                  height: 14,
                  color: TacticalPalette.divider,
                ),
                const SizedBox(width: 8),
              ],
              Icon(
                collapsed ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                size: 18,
                color: TacticalPalette.textDim,
              ),
            ],
          ),
        ),
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
