import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../models/place.dart';
import '../services/location_service.dart';
import '../widgets/action_panel.dart';
import '../widgets/compass_fab.dart';
import '../widgets/coord_card.dart';
import '../widgets/search_card.dart';
import 'search_screen.dart';

const String _kLibertyStyle = 'https://tiles.openfreemap.org/styles/liberty';
const LatLng _kInitialCenter = LatLng(22.7196, 75.8577);
const double _kInitialZoom = 11;

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  MapLibreMapController? _controller;
  final LocationService _locationService = LocationService();

  LatLng _mapCenter = _kInitialCenter;
  double _bearing = 0;
  MapMode _mode = MapMode.none;
  Place? _selectedPlace;

  void _onMapCreated(MapLibreMapController controller) {
    _controller = controller;
    controller.addListener(_onControllerChanged);
  }

  void _onControllerChanged() {
    final CameraPosition? pos = _controller?.cameraPosition;
    if (pos == null) return;
    setState(() {
      _mapCenter = pos.target;
      _bearing = pos.bearing;
    });
  }

  @override
  void dispose() {
    _controller?.removeListener(_onControllerChanged);
    super.dispose();
  }

  String _formatCoords(LatLng c) =>
      '${c.latitude.toStringAsFixed(5)}, ${c.longitude.toStringAsFixed(5)}';

  String? _distanceBearingLine() {
    if (_selectedPlace == null) return null;
    // Placeholder — real GeoMath lands in chunk 3.
    return '12.4 km · 045° NE';
  }

  Future<void> _openSearch() async {
    final Place? result = await Navigator.of(context).push<Place>(
      MaterialPageRoute(builder: (_) => const SearchScreen()),
    );
    if (result == null || !mounted) return;
    await _controller?.animateCamera(
      CameraUpdate.newLatLngZoom(result.center, 13),
    );
    setState(() => _selectedPlace = result);
    if (!mounted) return;
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
      const SnackBar(content: Text('Format cycling lands in chunk 3')),
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

  Future<void> _onResetBearing() async {
    await _controller?.animateCamera(
      CameraUpdate.bearingTo(0),
      duration: const Duration(milliseconds: 400),
    );
    await _controller?.animateCamera(
      CameraUpdate.tiltTo(0),
      duration: const Duration(milliseconds: 400),
    );
  }

  Future<void> _onRecenter() async {
    try {
      final Position pos = await _locationService.currentPosition();
      if (!mounted) return;
      await _controller?.animateCamera(
        CameraUpdate.newLatLngZoom(LatLng(pos.latitude, pos.longitude), 16),
      );
    } on LocationDenied catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not get location: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          MapLibreMap(
            styleString: _kLibertyStyle,
            initialCameraPosition: const CameraPosition(
              target: _kInitialCenter,
              zoom: _kInitialZoom,
            ),
            onMapCreated: _onMapCreated,
            trackCameraPosition: true,
            compassEnabled: false,
            myLocationEnabled: true,
            myLocationRenderMode: MyLocationRenderMode.normal,
            myLocationTrackingMode: MyLocationTrackingMode.none,
            rotateGesturesEnabled: true,
            tiltGesturesEnabled: true,
          ),
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
