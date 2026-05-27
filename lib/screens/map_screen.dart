import 'package:flutter/material.dart';

import '../models/place.dart';
import '../theme/tactical_theme.dart';
import '../widgets/action_panel.dart';
import '../widgets/compass_fab.dart';
import '../widgets/coord_card.dart';
import '../widgets/search_card.dart';
import 'search_screen.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  // Placeholder state — wired to real MapLibre callbacks in the next pass.
  LatLng _mapCenter = const LatLng(22.7196, 75.8577);
  double _bearing = 0;
  MapMode _mode = MapMode.none;
  Place? _selectedPlace;

  String _formatCoords(LatLng c) =>
      '${c.latitude.toStringAsFixed(5)}, ${c.longitude.toStringAsFixed(5)}';

  String? _distanceBearingLine() {
    if (_selectedPlace == null) return null;
    // Placeholder values; real geo math comes with GeoMath util.
    return '12.4 km · 045° NE';
  }

  Future<void> _openSearch() async {
    final Place? result = await Navigator.of(context).push<Place>(
      MaterialPageRoute(builder: (_) => const SearchScreen()),
    );
    if (result == null || !mounted) return;
    setState(() {
      _mapCenter = result.center;
      _selectedPlace = result;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Flew to ${result.name}')),
    );
  }

  void _onCoordCardTap() {
    if (_selectedPlace != null) {
      setState(() => _selectedPlace = null);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Long-press to change format')),
      );
    }
  }

  void _onCoordCardLongPress() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Format: DMS')),
    );
  }

  void _onModeToggled(MapMode tapped) {
    setState(() {
      _mode = (_mode == tapped) ? MapMode.none : tapped;
    });
  }

  void _onClear() {
    setState(() {
      _mode = MapMode.none;
      _selectedPlace = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Cleared')),
    );
  }

  void _onResetBearing() {
    setState(() => _bearing = 0);
  }

  void _onRecenter() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Recenter on GPS (wire geolocator next)')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          _MapPlaceholder(center: _mapCenter),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SearchCard(onTap: _openSearch),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.topLeft,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 240),
                      child: CoordCard(
                        coordsText: _formatCoords(_mapCenter),
                        distanceBearingText: _distanceBearingLine(),
                        onTap: _onCoordCardTap,
                        onLongPress: _onCoordCardLongPress,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            right: 16,
            bottom: 96,
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CompassFab(bearing: _bearing, onTap: _onResetBearing),
                  const SizedBox(height: 10),
                  FloatingActionButton(
                    heroTag: 'gps-fab',
                    onPressed: _onRecenter,
                    child: const Icon(Icons.my_location),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: SafeArea(
              top: false,
              child: ActionPanel(
                mode: _mode,
                onModeToggled: _onModeToggled,
                onClear: _onClear,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MapPlaceholder extends StatelessWidget {
  final LatLng center;
  const _MapPlaceholder({required this.center});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFD8E5DC), Color(0xFFB7CFC0)],
        ),
      ),
      child: CustomPaint(
        painter: _GridPainter(),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: TacticalPalette.panelTranslucent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              'Map placeholder\n${center.latitude.toStringAsFixed(4)}, ${center.longitude.toStringAsFixed(4)}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: TacticalPalette.accent,
                fontFamily: 'monospace',
                fontSize: 12,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black12
      ..strokeWidth = 1;
    const step = 48.0;
    for (double x = 0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
