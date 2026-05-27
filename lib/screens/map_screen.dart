import 'dart:async';
import 'dart:math' show Point;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../models/place.dart';
import '../services/geo_math.dart';
import '../services/location_service.dart';
import '../services/routing_service.dart';
import '../widgets/action_panel.dart';
import '../widgets/compass_fab.dart';
import '../widgets/coord_card.dart';
import '../theme/tactical_theme.dart';
import '../widgets/search_card.dart';
import 'search_screen.dart';

const String _kLibertyStyle = 'https://tiles.openfreemap.org/styles/liberty';
const LatLng _kInitialCenter = LatLng(22.7196, 75.8577);
const double _kInitialZoom = 11;

const String _kRulerSourceId = 'ruler-src';
const String _kRulerLayerId = 'ruler-layer';
const String _kMarkPinImageId = 'mark-pin-red';

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

  final List<Symbol> _markSymbols = <Symbol>[];
  bool _markPinReady = false;

  LatLng? _rulerA;
  Circle? _rulerCircleA;
  Circle? _rulerCircleB;
  bool _rulerLayerAdded = false;

  Line? _trackLine;
  LatLng? _trackFrom;
  Circle? _trackFromCircle;
  Circle? _trackToCircle;
  final RoutingService _routing = RoutingService();
  int _routingSeq = 0;

  Circle? _gpsHalo;
  Circle? _gpsDot;

  OverlayEntry? _toastEntry;
  Timer? _toastTimer;

  final GlobalKey _actionPanelKey = GlobalKey();

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
    _toastTimer?.cancel();
    _toastEntry?.remove();
    _toastEntry = null;
    _controller?.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _showTopToast(String message, {bool error = false}) {
    _toastTimer?.cancel();
    _toastEntry?.remove();
    _toastEntry = null;

    final OverlayState? overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    final MediaQueryData mq = MediaQuery.of(context);
    final double topInset = mq.padding.top + 12 + 52 + 12;

    final OverlayEntry entry = OverlayEntry(
      builder: (_) => Positioned(
        top: topInset,
        right: 16,
        child: Material(
          color: Colors.transparent,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: mq.size.width * 0.7),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: TacticalPalette.panel,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: error ? TacticalPalette.error : TacticalPalette.divider,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.1),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    error ? Icons.error_outline : Icons.info_outline,
                    size: 18,
                    color: error ? TacticalPalette.error : TacticalPalette.accent,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      message,
                      style: const TextStyle(
                        color: TacticalPalette.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    _toastEntry = entry;
    overlay.insert(entry);
    _toastTimer = Timer(const Duration(milliseconds: 2200), () {
      _toastEntry?.remove();
      _toastEntry = null;
    });
  }

  String _formatCoords(LatLng c) =>
      '${c.latitude.toStringAsFixed(5)}, ${c.longitude.toStringAsFixed(5)}';

  String? _distanceBearingLine() {
    if (_selectedPlace == null) return null;
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

  Future<void> _onModeToggled(MapMode tapped) async {
    final MapMode next = (_mode == tapped) ? MapMode.none : tapped;
    final MapMode prev = _mode;

    if (prev == MapMode.ruler && next != MapMode.ruler) {
      await _abandonRulerInProgress();
    }
    if (prev == MapMode.track && next != MapMode.track) {
      await _clearTrackOverlay();
    }

    setState(() => _mode = next);

    if (next == MapMode.track) {
      await _startTrackMode();
    }
  }

  Future<void> _onClear() async {
    final MapLibreMapController? c = _controller;
    if (c != null) {
      await c.clearCircles();
      await c.clearSymbols();
      if (_trackLine != null) {
        await c.removeLine(_trackLine!);
      }
      if (_rulerLayerAdded) {
        await c.removeLayer(_kRulerLayerId);
        await c.removeSource(_kRulerSourceId);
      }
    }

    setState(() {
      _mode = MapMode.none;
      _selectedPlace = null;
      _markSymbols.clear();
      _rulerA = null;
      _rulerCircleA = null;
      _rulerCircleB = null;
      _rulerLayerAdded = false;
      _trackLine = null;
      _trackFrom = null;
      _trackFromCircle = null;
      _trackToCircle = null;
      _gpsHalo = null;
      _gpsDot = null;
    });

    if (!mounted) return;
    _showTopToast('Cleared');
  }

  Future<void> _onResetBearing() async {
    final MapLibreMapController? c = _controller;
    if (c == null) return;
    final CameraPosition? pos = c.cameraPosition;
    if (pos == null) return;
    await c.animateCamera(
      CameraUpdate.newCameraPosition(CameraPosition(
        target: pos.target,
        zoom: pos.zoom,
        bearing: 0,
        tilt: 0,
      )),
      duration: const Duration(milliseconds: 450),
    );
  }

  Future<void> _onRecenter() async {
    try {
      final Position pos = await _locationService.currentPosition();
      if (!mounted) return;
      final LatLng here = LatLng(pos.latitude, pos.longitude);
      await _controller?.animateCamera(
        CameraUpdate.newLatLngZoom(here, 16),
      );
      await _updateGpsMarker(here);
    } on LocationDenied catch (e) {
      if (!mounted) return;
      _showTopToast(e.message, error: true);
    } catch (e) {
      if (!mounted) return;
      _showTopToast('Could not get location: $e', error: true);
    }
  }

  Future<void> _updateGpsMarker(LatLng at) async {
    final MapLibreMapController? c = _controller;
    if (c == null) return;
    if (_gpsHalo == null || _gpsDot == null) {
      _gpsHalo = await c.addCircle(CircleOptions(
        geometry: at,
        circleRadius: 16,
        circleColor: '#2563EB',
        circleOpacity: 0.18,
        circleStrokeWidth: 0,
      ));
      _gpsDot = await c.addCircle(CircleOptions(
        geometry: at,
        circleRadius: 6,
        circleColor: '#2563EB',
        circleStrokeColor: '#FFFFFF',
        circleStrokeWidth: 2,
        circleOpacity: 1.0,
      ));
    } else {
      await c.updateCircle(_gpsHalo!, CircleOptions(geometry: at));
      await c.updateCircle(_gpsDot!, CircleOptions(geometry: at));
    }
  }

  Future<void> _onMapClick(Point<double> screenPoint, LatLng coords) async {
    if (_isOverActionPanel(screenPoint)) return;
    switch (_mode) {
      case MapMode.mark:
        await _addMark(coords);
        break;
      case MapMode.ruler:
        await _handleRulerTap(coords);
        break;
      case MapMode.track:
        await _setTrackDestination(coords);
        break;
      case MapMode.none:
        break;
    }
  }

  bool _isOverActionPanel(Point<double> screenPoint) {
    final RenderObject? ro = _actionPanelKey.currentContext?.findRenderObject();
    if (ro is! RenderBox) return false;
    final Offset topLeft = ro.localToGlobal(Offset.zero);
    final Rect rect = topLeft & ro.size;
    return rect.contains(Offset(screenPoint.x, screenPoint.y));
  }

  Future<void> _addMark(LatLng at) async {
    final MapLibreMapController? c = _controller;
    if (c == null || !_markPinReady) return;
    final Symbol s = await c.addSymbol(SymbolOptions(
      geometry: at,
      iconImage: _kMarkPinImageId,
      iconAnchor: 'bottom',
      iconSize: 0.55,
    ));
    _markSymbols.add(s);
  }

  Future<void> _registerMarkPin() async {
    final MapLibreMapController? c = _controller;
    if (c == null || _markPinReady) return;
    final Uint8List bytes = await _renderIconToPng(
      Icons.location_on,
      const Color(0xFFE53935),
      96,
    );
    await c.addImage(_kMarkPinImageId, bytes);
    if (!mounted) return;
    setState(() => _markPinReady = true);
  }

  Future<Uint8List> _renderIconToPng(IconData icon, Color color, double size) async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    final TextPainter tp = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontSize: size,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          color: color,
          shadows: const <Shadow>[
            Shadow(color: Color(0x66000000), blurRadius: 2, offset: Offset(0, 1)),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    tp.layout();
    tp.paint(canvas, Offset.zero);
    final ui.Image img = await recorder
        .endRecording()
        .toImage(tp.width.ceil(), tp.height.ceil());
    final ByteData? bd = await img.toByteData(format: ui.ImageByteFormat.png);
    return bd!.buffer.asUint8List();
  }

  Future<void> _handleRulerTap(LatLng at) async {
    final MapLibreMapController? c = _controller;
    if (c == null) return;

    if (_rulerCircleA != null && _rulerCircleB != null) {
      await _resetRuler();
    }

    if (_rulerA == null) {
      _rulerA = at;
      _rulerCircleA = await c.addCircle(_rulerEndpointOptions(at));
      return;
    }

    final LatLng a = _rulerA!;
    _rulerCircleB = await c.addCircle(_rulerEndpointOptions(at));
    await _drawRulerLine(a, at);

    final double meters = haversineMeters(a, at);
    if (!mounted) return;
    _showTopToast('Distance: ${formatDistance(meters)}');
  }

  CircleOptions _rulerEndpointOptions(LatLng at) => CircleOptions(
        geometry: at,
        circleRadius: 6,
        circleColor: '#FF1744',
        circleStrokeColor: '#FFFFFF',
        circleStrokeWidth: 2,
      );

  Map<String, dynamic> _lineFeature(List<LatLng> points) => <String, dynamic>{
        'type': 'Feature',
        'geometry': <String, dynamic>{
          'type': 'LineString',
          'coordinates': points
              .map((p) => <double>[p.longitude, p.latitude])
              .toList(),
        },
      };

  Future<void> _drawRulerLine(LatLng a, LatLng b) async {
    final MapLibreMapController? c = _controller;
    if (c == null) return;
    final Map<String, dynamic> data = _lineFeature(<LatLng>[a, b]);

    if (!_rulerLayerAdded) {
      await c.addGeoJsonSource(_kRulerSourceId, data);
      await c.addLineLayer(
        _kRulerSourceId,
        _kRulerLayerId,
        const LineLayerProperties(
          lineColor: '#FF1744',
          lineWidth: 3.0,
          lineDasharray: <double>[2, 2],
          lineCap: 'round',
          lineJoin: 'round',
        ),
      );
      _rulerLayerAdded = true;
    } else {
      await c.setGeoJsonSource(_kRulerSourceId, data);
    }
  }

  Future<void> _resetRuler() async {
    final MapLibreMapController? c = _controller;
    if (c == null) return;
    if (_rulerCircleA != null) await c.removeCircle(_rulerCircleA!);
    if (_rulerCircleB != null) await c.removeCircle(_rulerCircleB!);
    if (_rulerLayerAdded) {
      await c.removeLayer(_kRulerLayerId);
      await c.removeSource(_kRulerSourceId);
      _rulerLayerAdded = false;
    }
    _rulerA = null;
    _rulerCircleA = null;
    _rulerCircleB = null;
  }

  Future<void> _abandonRulerInProgress() async {
    if (_rulerCircleA != null && _rulerCircleB == null) {
      await _resetRuler();
    }
  }

  Future<void> _startTrackMode() async {
    try {
      final Position pos = await _locationService.currentPosition();
      if (!mounted) return;
      final LatLng here = LatLng(pos.latitude, pos.longitude);
      final MapLibreMapController? c = _controller;
      if (c == null) return;
      _trackFrom = here;
      _trackFromCircle = await c.addCircle(CircleOptions(
        geometry: here,
        circleRadius: 7,
        circleColor: '#2563EB',
        circleStrokeColor: '#FFFFFF',
        circleStrokeWidth: 2,
      ));
      if (!mounted) return;
      _showTopToast('Tap destination on the map');
    } on LocationDenied catch (e) {
      if (!mounted) return;
      _showTopToast(e.message, error: true);
      setState(() => _mode = MapMode.none);
    } catch (e) {
      if (!mounted) return;
      _showTopToast('Could not get location: $e', error: true);
      setState(() => _mode = MapMode.none);
    }
  }

  Future<void> _setTrackDestination(LatLng dest) async {
    final MapLibreMapController? c = _controller;
    if (c == null || _trackFrom == null) return;

    if (_trackToCircle == null) {
      _trackToCircle = await c.addCircle(CircleOptions(
        geometry: dest,
        circleRadius: 7,
        circleColor: '#00C853',
        circleStrokeColor: '#FFFFFF',
        circleStrokeWidth: 2,
      ));
    } else {
      await c.updateCircle(_trackToCircle!, CircleOptions(geometry: dest));
    }

    _showTopToast('Routing…');
    final int seq = ++_routingSeq;
    try {
      final RouteResult route = await _routing.route(_trackFrom!, dest);
      if (!mounted || seq != _routingSeq || _mode != MapMode.track) return;
      if (_trackLine == null) {
        _trackLine = await c.addLine(LineOptions(
          geometry: route.geometry,
          lineColor: '#00C853',
          lineWidth: 4.0,
          lineOpacity: 0.9,
        ));
      } else {
        await c.updateLine(_trackLine!, LineOptions(geometry: route.geometry));
      }
      if (!mounted) return;
      _showTopToast('Path: ${formatDistance(route.distanceMeters)}');
    } on RoutingException catch (e) {
      if (!mounted || seq != _routingSeq) return;
      _showTopToast(e.message, error: true);
    } catch (e) {
      if (!mounted || seq != _routingSeq) return;
      _showTopToast('Routing failed: $e', error: true);
    }
  }

  Future<void> _clearTrackOverlay() async {
    final MapLibreMapController? c = _controller;
    if (c != null) {
      if (_trackLine != null) await c.removeLine(_trackLine!);
      if (_trackFromCircle != null) await c.removeCircle(_trackFromCircle!);
      if (_trackToCircle != null) await c.removeCircle(_trackToCircle!);
    }
    _trackLine = null;
    _trackFrom = null;
    _trackFromCircle = null;
    _trackToCircle = null;
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
            onStyleLoadedCallback: _registerMarkPin,
            onMapClick: _onMapClick,
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
              child: KeyedSubtree(
                key: _actionPanelKey,
                child: ActionPanel(
                  mode: _mode,
                  onModeToggled: _onModeToggled,
                  onClear: _onClear,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
