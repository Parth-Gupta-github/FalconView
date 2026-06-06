import 'dart:async';

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

  // CLR confirmation gate. First tap arms it (label flips to "TAP AGAIN",
  // background goes solid red); a second tap within [_clrConfirmWindow]
  // actually invokes [widget.onClear]. The timer resets the gate on its own
  // if the user wanders off, so an accidental first tap never silently
  // primes a destructive second tap later.
  static const Duration _clrConfirmWindow = Duration(seconds: 3);
  bool _clrConfirming = false;
  Timer? _clrConfirmTimer;

  void _toggle() => setState(() => _collapsed = !_collapsed);

  void _handleClrTap() {
    if (_clrConfirming) {
      _clrConfirmTimer?.cancel();
      _clrConfirmTimer = null;
      setState(() => _clrConfirming = false);
      widget.onClear();
      return;
    }
    setState(() => _clrConfirming = true);
    _clrConfirmTimer?.cancel();
    _clrConfirmTimer = Timer(_clrConfirmWindow, () {
      if (mounted) setState(() => _clrConfirming = false);
    });
  }

  @override
  void dispose() {
    _clrConfirmTimer?.cancel();
    super.dispose();
  }

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
                label: _clrConfirming ? 'CONFIRM' : 'CLR',
                tooltip: _clrConfirming
                    ? 'Tap again to clear everything'
                    : 'Clear all markers, rulers, routes, and areas',
                active: false,
                destructive: true,
                confirming: _clrConfirming,
                onTap: _handleClrTap,
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
  /// Emphatic "are you sure?" state for destructive actions. Inverts the
  /// destructive colour pair (solid red bg, white fg) so the user sees the
  /// button has *changed* and a second tap will commit. Animates so the
  /// transition reads as a distinct event, not just a re-render.
  final bool confirming;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.active,
    required this.onTap,
    this.destructive = false,
    this.confirming = false,
  });

  @override
  Widget build(BuildContext context) {
    final Color bg;
    final Color fg;
    if (confirming) {
      bg = TacticalPalette.error;
      fg = Colors.white;
    } else if (active) {
      bg = TacticalPalette.accent;
      fg = Colors.white;
    } else if (destructive) {
      bg = TacticalPalette.panel;
      fg = TacticalPalette.error;
    } else {
      bg = TacticalPalette.accentSoft;
      fg = TacticalPalette.accent;
    }
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: Tooltip(
          message: tooltip,
          waitDuration: const Duration(milliseconds: 400),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Material(
              color: Colors.transparent,
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
                      AnimatedDefaultTextStyle(
                        duration: const Duration(milliseconds: 180),
                        style: TextStyle(
                          color: fg,
                          fontWeight: FontWeight.w700,
                          letterSpacing: confirming ? 1.4 : 0.8,
                          fontSize: confirming ? 10 : 11,
                        ),
                        child: Text(label),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
