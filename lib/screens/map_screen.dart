import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/place.dart';
import '../services/location_service.dart';
import '../util/coordinate_formatter.dart';
import '../util/geo_math.dart';
import '../widgets/action_panel.dart';
import '../widgets/compass_fab.dart';
import '../widgets/coord_card.dart';
import '../widgets/search_card.dart';
import 'search_screen.dart';

const String _kLibertyStyle = 'https://tiles.openfreemap.org/styles/liberty';
const LatLng _kInitialCenter = LatLng(22.7196, 75.8577);
const double _kInitialZoom = 11;
const String _kCoordFormatPrefKey = 'coord_format';

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
  LatLng? _currentGps;
  CoordinateFormat _coordFormat = CoordinateFormat.decimal;

  @override
  void initState() {
    super.initState();
    _loadCoordFormat();
  }

  Future<void> _loadCoordFormat() async {
    final prefs = await SharedPreferences.getInstance();
    final int? idx = prefs.getInt(_kCoordFormatPrefKey);
    if (idx != null && idx >= 0 && idx < CoordinateFormat.values.length) {
      if (!mounted) return;
      setState(() => _coordFormat = CoordinateFormat.values[idx]);
    }
  }

  Future<void> _saveCoordFormat(CoordinateFormat fmt) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kCoordFormatPrefKey, fmt.index);
  }

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
      CoordinateFormatter.format(c.latitude, c.longitude, _coordFormat);

  String? _distanceBearingLine() {
    final Place? place = _selectedPlace;
    final LatLng? gps = _currentGps;
    if (place == null || gps == null) return null;
    final double meters = GeoMath.haversineMeters(
      gps.latitude,
      gps.longitude,
      place.center.latitude,
      place.center.longitude,
    );
    final double bearing = GeoMath.initialBearingDegrees(
      gps.latitude,
      gps.longitude,
      place.center.latitude,
      place.center.longitude,
    );
    return '${GeoMath.formatDistance(meters)} · ${GeoMath.formatBearing(bearing)}';
  }

  Future<void> _refreshGpsForBearing() async {
    try {
      final Position pos = await _locationService.currentPosition();
      if (!mounted) return;
      setState(() => _currentGps = LatLng(pos.latitude, pos.longitude));
    } on LocationDenied {
      // Keep _currentGps null — distance/bearing line will simply not show.
    }
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
    unawaited(_refreshGpsForBearing());
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
    final CoordinateFormat next = _coordFormat.next();
    setState(() => _coordFormat = next);
    _saveCoordFormat(next);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Format: ${next.label}')),
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
      setState(() => _currentGps = LatLng(pos.latitude, pos.longitude));
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
                      constraints: const BoxConstraints(maxWidth: 260),
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

