import 'dart:async';
import 'dart:math' as math;
import 'dart:math' show Point;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, LogicalKeyboardKey;
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_tier.dart';
import '../models/place.dart';
import '../services/location_service.dart';
import '../services/offline_repository.dart';
import '../services/offline_search_index.dart';
import '../services/routing_service.dart';
import '../services/subscription_service.dart';
import '../services/tile_config.dart';
import '../util/coordinate_formatter.dart';
import '../util/geo_math.dart';
import '../util/polygon_geo.dart';
import '../util/tile_math.dart';
import '../widgets/action_panel.dart';
import '../widgets/compass_fab.dart';
import '../widgets/coord_card.dart';
import '../theme/tactical_theme.dart';
import '../widgets/search_card.dart';
import 'plans_screen.dart';
import 'search_screen.dart';

const LatLng _kInitialCenter = LatLng(22.7196, 75.8577);
const double _kInitialZoom = 11;
const String _kCoordFormatPrefKey = 'coord_format';

const String _kRulerSourceId = 'ruler-src';
const String _kRulerLayerId = 'ruler-layer';
const String _kMarkPinImageId = 'mark-pin-red';

const String _kAreaSourceId = 'area-src';
const String _kAreaFillLayerId = 'area-fill';
const String _kAreaLineLayerId = 'area-line';

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

  // Inline JSON of the bundled Google-Maps-like style, loaded from assets in
  // initState. Null while loading — MapScreen falls back to the upstream URL
  // for the very first frame so the map isn't blank.
  String? _renderStyleJson;

  @override
  void initState() {
    super.initState();
    _loadCoordFormat();
    _loadRenderStyle();
    subscriptionService.addListener(_onTierChanged);
  }

  Future<void> _loadRenderStyle() async {
    try {
      final String s =
          await TileConfig.forTier(subscriptionService.tier).loadRenderStyle();
      if (!mounted) return;
      setState(() => _renderStyleJson = s);
    } catch (e) {
      // Asset missing → fall through to the upstream URL.
      debugPrint('Failed to load bundled style: $e');
    }
  }

  void _onTierChanged() {
    if (mounted) setState(() {});
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
  final OfflineRepository _offline = OfflineRepository();
  int _routingSeq = 0;

  Circle? _gpsHalo;
  Circle? _gpsDot;

  Circle? _selectedPlaceHalo;
  Circle? _selectedPlaceDot;

  OverlayEntry? _toastEntry;
  Timer? _toastTimer;

  String? _statusMessage;

  final GlobalKey _actionPanelKey = GlobalKey();
  final GlobalKey _areaBarKey = GlobalKey();

  // AREA mode: user-drawn download polygon. Vertices in tap order; the closing
  // edge is implicit. Circles mark each vertex; a fill+line layer shows the
  // polygon. `_areaDownloading` gates re-entry while a download runs.
  final List<LatLng> _areaPoints = <LatLng>[];
  final List<Circle> _areaVertexCircles = <Circle>[];
  bool _areaLayerAdded = false;
  bool _areaDownloading = false;

  void _onMapCreated(MapLibreMapController controller) {
    _controller = controller;
    controller.addListener(_onControllerChanged);
    controller.onSymbolTapped.add(_onSymbolTapped);
  }
  
  bool _symbolTapConsumed = false;

  Future<void> _onSymbolTapped(Symbol s) async {
    _symbolTapConsumed = true;
    
    final LatLng? at = s.options.geometry;
    final MapLibreMapController? c = _controller;
    if (at == null || c == null) return;
    final CameraPosition? pos = c.cameraPosition;
    // Stay zoomed-in if already close; otherwise jump to a useful level.
    final double targetZoom =
        math.max(pos?.zoom ?? 16, 16.0).toDouble();
    await c.animateCamera(
      CameraUpdate.newLatLngZoom(at, targetZoom),
      duration: const Duration(milliseconds: 400),
    );
  }

  int? _lastToastedZoomLevel;

  void _onControllerChanged() {
    final CameraPosition? pos = _controller?.cameraPosition;
    if (pos == null) return;
    setState(() {
      _mapCenter = pos.target;
      _bearing = pos.bearing;
    });
    final int level = pos.zoom.round();
    if (_lastToastedZoomLevel != level) {
      _lastToastedZoomLevel = level;
      _showTopToast('Zoom: $level');
    }
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    _toastEntry?.remove();
    _toastEntry = null;
    _gpsSub?.cancel();
    _gpsSub = null;
    _controller?.removeListener(_onControllerChanged);
    _controller?.onSymbolTapped.remove(_onSymbolTapped);
    subscriptionService.removeListener(_onTierChanged);
    super.dispose();
  }

  void _setStatusMessage(String? message) {
    if (!mounted) return;
    setState(() => _statusMessage = message);
  }

  void _showTopToast(String message, {bool error = false}) {
    _toastTimer?.cancel();
    _toastEntry?.remove();
    _toastEntry = null;

    final OverlayState? overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    final MediaQueryData mq = MediaQuery.of(context);
    // Stack from the status bar down: search bar, coord/tier row, optional
    // pinned status badge. The toast sits below all of it so it never
    // overlaps the tier pill or the status badge.
    const double searchBar = 52 + 12;
    const double coordRow = 72 + 10;
    final double statusBadge = _statusMessage != null ? 36 + 8 : 0;
    final double topInset =
        mq.padding.top + 12 + searchBar + coordRow + statusBadge + 8;

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
    final MapLibreMapController? c = _controller;
    if (c != null) {
      try {
        await c.animateCamera(
          CameraUpdate.newLatLngBounds(
            result.bbox,
            left: 60,
            right: 60,
            top: 120,
            bottom: 120,
          ),
        );
      } catch (_) {
        await c.animateCamera(CameraUpdate.newLatLngZoom(result.center, 15));
      }
      await _updateSelectedPlaceMarker(result.center);
    }
    setState(() => _selectedPlace = result);
    unawaited(_refreshGpsForBearing());
    if (!mounted) return;
    _showTopToast('Located: ${result.name}');
  }

  Future<void> _updateSelectedPlaceMarker(LatLng at) async {
    final MapLibreMapController? c = _controller;
    if (c == null) return;
    if (_selectedPlaceHalo == null || _selectedPlaceDot == null) {
      _selectedPlaceHalo = await c.addCircle(CircleOptions(
        geometry: at,
        circleRadius: 18,
        circleColor: '#FF7043',
        circleOpacity: 0.22,
        circleStrokeWidth: 0,
      ));
      _selectedPlaceDot = await c.addCircle(CircleOptions(
        geometry: at,
        circleRadius: 7,
        circleColor: '#E53935',
        circleStrokeColor: '#FFFFFF',
        circleStrokeWidth: 2,
        circleOpacity: 1.0,
      ));
    } else {
      await c.updateCircle(_selectedPlaceHalo!, CircleOptions(geometry: at));
      await c.updateCircle(_selectedPlaceDot!, CircleOptions(geometry: at));
    }
  }

  Future<void> _removeSelectedPlaceMarker() async {
    final MapLibreMapController? c = _controller;
    if (c != null) {
      if (_selectedPlaceHalo != null) await c.removeCircle(_selectedPlaceHalo!);
      if (_selectedPlaceDot != null) await c.removeCircle(_selectedPlaceDot!);
    }
    _selectedPlaceHalo = null;
    _selectedPlaceDot = null;
  }

  void _onCoordCardTap() {
    if (_selectedPlace != null) {
      setState(() => _selectedPlace = null);
      unawaited(_removeSelectedPlaceMarker());
    } else {
      _showTopToast('Long-press to change format');
    }
  }

  void _onCoordCardLongPress() {
    final CoordinateFormat next = _coordFormat.next();
    setState(() => _coordFormat = next);
    _saveCoordFormat(next);
    _showTopToast('Format: ${next.label}');
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
    // Leaving AREA mode mid-draw discards the in-progress polygon (unless a
    // download is running — that path clears it on completion).
    if (prev == MapMode.area && next != MapMode.area && !_areaDownloading) {
      await _clearAreaOverlay();
    }

    setState(() => _mode = next);

    if (next == MapMode.track) {
      await _startTrackMode();
    }
    if (next != MapMode.none) {
      // Fire-and-forget — no need to block mode activation on prefs I/O.
      unawaited(_maybeShowFirstTimeHint(next));
    }
  }

  /// One-shot hint per mode. Once the user has activated MARK / RULER / TRACK
  /// / AREA at least once, the hint stops appearing. CLR has no hint — its
  /// effect is immediate and self-explanatory.
  Future<void> _maybeShowFirstTimeHint(MapMode mode) async {
    const Map<MapMode, String> hints = <MapMode, String>{
      MapMode.mark: 'Tap anywhere on the map to drop a pin. Tap a pin to fly to it.',
      MapMode.ruler: 'Tap two points to measure the straight-line distance.',
      MapMode.track: 'Tap a destination on the map to draw the route from your location.',
      MapMode.area: 'Tap on the map to add polygon vertices. Tap near the first vertex to close.',
    };
    final String? hint = hints[mode];
    if (hint == null) return;
    final String prefKey = 'mode_hint_seen_${mode.name}';
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(prefKey) ?? false) return;
    await prefs.setBool(prefKey, true);
    if (!mounted) return;
    _showTopToast(hint);
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
      if (_areaLayerAdded) {
        await c.removeLayer(_kAreaLineLayerId);
        await c.removeLayer(_kAreaFillLayerId);
        await c.removeSource(_kAreaSourceId);
      }
    }

    setState(() {
      _mode = MapMode.none;
      _selectedPlace = null;
      _selectedPlaceHalo = null;
      _selectedPlaceDot = null;
      _markSymbols.clear();
      _rulerA = null;
      _rulerCircleA = null;
      _rulerCircleB = null;
      _rulerLayerAdded = false;
      _areaPoints.clear();
      _areaVertexCircles.clear();
      _areaLayerAdded = false;
      _areaDownloading = false;
      _trackLine = null;
      _trackFrom = null;
      _trackFromCircle = null;
      _trackToCircle = null;
      _gpsHalo = null;
      _gpsDot = null;
      _statusMessage = null;
    });

    // Always-on GPS marker: clearCircles wiped it too, so re-add if we
    // still have a fix. New circle ids will be tracked by _updateGpsMarker.
    if (_currentGps != null) {
      unawaited(_updateGpsMarker(_currentGps!));
    }

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
      setState(() => _currentGps = here);
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
    if (_symbolTapConsumed) {
      _symbolTapConsumed = false;
      return;
    }
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
      case MapMode.area:
        if (_isOverKey(_areaBarKey, screenPoint)) return;
        await _addAreaPoint(coords);
        break;
      case MapMode.none:
        await _maybeShowPoiSheet(coords);
        break;
    }
  }

  /// Map idle-tap interaction: look up the nearest indexed POI within ~50 m
  /// of the tap and present a small sheet with name + actions. No-op if no
  /// downloaded region covers the tap or no POI is close.
  Future<void> _maybeShowPoiSheet(LatLng coords) async {
    final Place? poi = await _offline.nearestPoiNear(
      coords.latitude,
      coords.longitude,
    );
    if (!mounted || poi == null) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: false,
      backgroundColor: TacticalPalette.panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (BuildContext ctx) => _PoiSheet(
        poi: poi,
        coordsText: _formatCoords(poi.center),
        onDirections: () {
          Navigator.pop(ctx);
          _useAsTrackDestination(poi.center);
        },
        onMark: () {
          Navigator.pop(ctx);
          _addMark(poi.center);
        },
        onCopy: () async {
          await Clipboard.setData(ClipboardData(
            text: '${poi.name}\n${_formatCoords(poi.center)}',
          ));
          if (!ctx.mounted) return;
          Navigator.pop(ctx);
          _showTopToast('Copied');
        },
      ),
    );
  }

  Future<void> _useAsTrackDestination(LatLng dest) async {
    // Enter TRACK mode if not already in it, then drop the destination.
    if (_mode != MapMode.track) {
      await _onModeToggled(MapMode.track);
    }
    if (!mounted || _trackFrom == null) return;
    await _setTrackDestination(dest);
  }

  bool _isOverActionPanel(Point<double> screenPoint) =>
      _isOverKey(_actionPanelKey, screenPoint);

  bool _isOverKey(GlobalKey key, Point<double> screenPoint) {
    final RenderObject? ro = key.currentContext?.findRenderObject();
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
    _setStatusMessage('Markers: ${_markSymbols.length}');
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
    // Kick the always-on GPS marker once the style is ready (otherwise
    // addCircle has nothing to attach to).
    unawaited(_startGpsTracking());
  }

  StreamSubscription<Position>? _gpsSub;

  /// Subscribes to a low-frequency position stream and keeps `_currentGps`
  /// plus the on-map halo + dot in sync. Permission is checked once; if
  /// denied, we silently give up and the user can still tap the GPS FAB
  /// to trigger an explicit request later.
  Future<void> _startGpsTracking() async {
    if (_gpsSub != null) return;
    try {
      final Stream<Position> stream =
          await _locationService.positionStream(distanceFilterMeters: 10);
      _gpsSub = stream.listen((Position pos) {
        if (!mounted) return;
        final LatLng here = LatLng(pos.latitude, pos.longitude);
        setState(() => _currentGps = here);
        unawaited(_updateGpsMarker(here));
      });
    } on LocationDenied {
      // Stay silent — user can still tap the GPS FAB to retry.
    } catch (_) {}
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

    final double meters =
        GeoMath.haversineMeters(a.latitude, a.longitude, at.latitude, at.longitude);
    if (!mounted) return;
    _setStatusMessage('Distance: ${GeoMath.formatDistance(meters)}');
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
      _setStatusMessage('Tap destination on the map');
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
    RouteResult? route;
    bool offline = false;
    OfflineRouteFailure? offlineFailure;
    try {
      route = await _routing.route(_trackFrom!, dest);
    } catch (_) {
      // Online routing failed — try the offline graph for any downloaded
      // region whose bbox contains the start point.
      try {
        final OfflineRouteOutcome outcome =
            await _offline.routeOffline(_trackFrom!, dest);
        if (outcome.isSuccess) {
          route = outcome.route;
          offline = true;
        } else {
          offlineFailure = outcome.failure;
        }
      } catch (_) {
        route = null;
      }
    }

    if (!mounted || seq != _routingSeq || _mode != MapMode.track) return;
    if (route == null) {
      _showTopToast(_offlineFailureMessage(offlineFailure), error: true);
      return;
    }

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
    final String prefix = offline ? 'Offline path' : 'Path';
    _setStatusMessage('$prefix: ${GeoMath.formatDistance(route.distanceMeters)}');
  }

  String _offlineFailureMessage(OfflineRouteFailure? f) {
    switch (f) {
      case OfflineRouteFailure.noRegion:
        return 'No downloaded region covers your location. Download the area first.';
      case OfflineRouteFailure.noGraph:
        return 'Offline road graph not built yet — re-download the region.';
      case OfflineRouteFailure.noPath:
        return 'No road path found between those two points.';
      case null:
        return 'Routing unavailable. Check your connection.';
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

  // ---------------- AREA (custom download polygon) ----------------

  Future<void> _addAreaPoint(LatLng at) async {
    final MapLibreMapController? c = _controller;
    if (c == null || _areaDownloading) return;
    _areaPoints.add(at);
    final Circle circle = await c.addCircle(CircleOptions(
      geometry: at,
      circleRadius: 5,
      circleColor: '#1565C0',
      circleStrokeColor: '#FFFFFF',
      circleStrokeWidth: 2,
    ));
    _areaVertexCircles.add(circle);
    await _redrawAreaPolygon();
    if (mounted) setState(() {});
  }

  Future<void> _undoAreaPoint() async {
    if (_areaPoints.isEmpty || _areaDownloading) return;
    final MapLibreMapController? c = _controller;
    _areaPoints.removeLast();
    if (_areaVertexCircles.isNotEmpty) {
      final Circle last = _areaVertexCircles.removeLast();
      if (c != null) await c.removeCircle(last);
    }
    await _redrawAreaPolygon();
    if (mounted) setState(() {});
  }

  Future<void> _redrawAreaPolygon() async {
    final MapLibreMapController? c = _controller;
    if (c == null) return;
    final Map<String, dynamic> data;
    if (_areaPoints.length >= 3) {
      final List<List<double>> ring = _areaPoints
          .map((LatLng p) => <double>[p.longitude, p.latitude])
          .toList();
      ring.add(<double>[_areaPoints.first.longitude, _areaPoints.first.latitude]);
      data = <String, dynamic>{
        'type': 'Feature',
        'geometry': <String, dynamic>{
          'type': 'Polygon',
          'coordinates': <List<List<double>>>[ring],
        },
      };
    } else if (_areaPoints.length == 2) {
      data = _lineFeature(_areaPoints);
    } else {
      data = <String, dynamic>{
        'type': 'FeatureCollection',
        'features': <dynamic>[],
      };
    }

    if (!_areaLayerAdded) {
      await c.addGeoJsonSource(_kAreaSourceId, data);
      await c.addFillLayer(
        _kAreaSourceId,
        _kAreaFillLayerId,
        const FillLayerProperties(fillColor: '#1565C0', fillOpacity: 0.14),
      );
      await c.addLineLayer(
        _kAreaSourceId,
        _kAreaLineLayerId,
        const LineLayerProperties(
          lineColor: '#1565C0',
          lineWidth: 2.5,
          lineJoin: 'round',
          lineCap: 'round',
        ),
      );
      _areaLayerAdded = true;
    } else {
      await c.setGeoJsonSource(_kAreaSourceId, data);
    }
  }

  Future<void> _clearAreaOverlay() async {
    final MapLibreMapController? c = _controller;
    if (c != null) {
      for (final Circle circle in _areaVertexCircles) {
        await c.removeCircle(circle);
      }
      if (_areaLayerAdded) {
        await c.removeLayer(_kAreaLineLayerId);
        await c.removeLayer(_kAreaFillLayerId);
        await c.removeSource(_kAreaSourceId);
      }
    }
    _areaVertexCircles.clear();
    _areaPoints.clear();
    _areaLayerAdded = false;
    if (mounted) setState(() {});
  }

  Future<void> _downloadArea() async {
    if (_areaPoints.length < 3 || _areaDownloading) return;
    if (subscriptionService.tier != AppTier.pro) {
      _showTopToast(
        'Offline download is a Pro feature. Enable Pro in Plans.',
        error: true,
      );
      return;
    }
    final List<LatLng> pts = List<LatLng>.from(_areaPoints);
    final LatLngBounds bbox = PolygonGeo.boundsOf(pts);
    final LatLng center = PolygonGeo.centroidOf(pts);
    final String sizeText = TileMath.estimatedDownloadSize(
      bbox.southwest.latitude,
      bbox.southwest.longitude,
      bbox.northeast.latitude,
      bbox.northeast.longitude,
    );
    final Place place = Place(
      name: 'Custom area',
      subtitle: '${pts.length}-point area · $sizeText',
      center: center,
      bbox: bbox,
      polygon: pts,
    );

    setState(() => _areaDownloading = true);
    _setStatusMessage('Downloading area… 0%');
    try {
      await _offline.download(
        place,
        onProgress: (double pct) {
          if (!mounted) return;
          _setStatusMessage('Downloading area… ${pct.round()}%');
        },
      );
      if (!mounted) return;
      final String? indexErr = _offline.lastIndexError;
      final IndexBuildStats? stats = _offline.lastIndexStats;
      await _clearAreaOverlay();
      if (!mounted) return;
      setState(() {
        _mode = MapMode.none;
        _areaDownloading = false;
        _statusMessage = null;
      });
      if (indexErr != null) {
        _showTopToast('Area saved, but index failed: $indexErr', error: true);
      } else {
        final String tail =
            stats == null ? '' : ' · ${stats.poisInserted} POIs';
        _showTopToast('Area downloaded$tail');
      }
    } on OfflineNotAvailable catch (e) {
      if (!mounted) return;
      setState(() {
        _areaDownloading = false;
        _statusMessage = null;
      });
      _showTopToast(e.message, error: true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _areaDownloading = false;
        _statusMessage = null;
      });
      _showTopToast('Download failed: $e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final TileConfig cfg = TileConfig.forTier(subscriptionService.tier);
    final Widget scaffold = Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          MapLibreMap(
            styleString: _renderStyleJson ?? cfg.styleUrl,
            initialCameraPosition: const CameraPosition(
              target: _kInitialCenter,
              zoom: _kInitialZoom,
            ),
            minMaxZoomPreference: MinMaxZoomPreference(0, cfg.interactiveMaxZoom),
            onMapCreated: _onMapCreated,
            onStyleLoadedCallback: _registerMarkPin,
            onMapClick: _onMapClick,
            trackCameraPosition: true,
            compassEnabled: false,
            // We draw our own GPS halo + dot via _updateGpsMarker so we can
            // keep it in sync with _currentGps and survive CLR. Letting
            // MapLibre also render its native location indicator just gave
            // us two stacked blue dots.
            myLocationEnabled: false,
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
                  // Cap the search bar on web so it doesn't stretch across a
                  // 1920 px monitor. On mobile this is a no-op.
                  kIsWeb
                      ? Align(
                          alignment: Alignment.centerLeft,
                          child: ConstrainedBox(
                            constraints:
                                const BoxConstraints(maxWidth: 480),
                            child: SearchCard(onTap: _openSearch),
                          ),
                        )
                      : SearchCard(onTap: _openSearch),
                  const SizedBox(height: 10),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 260),
                        child: CoordCard(
                          coordsText: _formatCoords(_mapCenter),
                          distanceBearingText: _distanceBearingLine(),
                          onTap: _onCoordCardTap,
                          onLongPress: _onCoordCardLongPress,
                        ),
                      ),
                      const Spacer(),
                      _TierPill(),
                    ],
                  ),
                  if (_statusMessage != null) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.topRight,
                      child: _StatusBadge(message: _statusMessage!),
                    ),
                  ],
                  if (_mode == MapMode.area) ...[
                    const SizedBox(height: 8),
                    _AreaControlBar(
                      key: _areaBarKey,
                      pointCount: _areaPoints.length,
                      downloading: _areaDownloading,
                      onUndo: (_areaPoints.isEmpty || _areaDownloading)
                          ? null
                          : _undoAreaPoint,
                      onDownload: (_areaPoints.length >= 3 && !_areaDownloading)
                          ? _downloadArea
                          : null,
                    ),
                  ],
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

    // Web-only keyboard shortcut: `/` focuses search (matches Google,
    // GitHub, Slack conventions). Esc/Enter live on SearchScreen itself.
    if (!kIsWeb) return scaffold;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.slash): _openSearch,
      },
      child: Focus(autofocus: true, child: scaffold),
    );
  }
}

class _TierPill extends StatelessWidget {
  const _TierPill();

  @override
  Widget build(BuildContext context) {
    final AppTier tier = subscriptionService.tier;
    final bool isPro = tier == AppTier.pro;
    final Color bg = isPro ? TacticalPalette.accent : TacticalPalette.panel;
    final Color fg = isPro ? Colors.white : TacticalPalette.accent;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const PlansScreen()),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: TacticalPalette.accent, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isPro ? Icons.workspace_premium : Icons.lock,
                size: 14,
                color: fg,
              ),
              const SizedBox(width: 4),
              Text(
                isPro ? 'PRO' : 'UPGRADE',
                style: TextStyle(
                  color: fg,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String message;
  const _StatusBadge({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: TacticalPalette.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: TacticalPalette.accent.withValues(alpha: 0.5)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.push_pin_outlined, size: 14, color: TacticalPalette.accent),
          const SizedBox(width: 6),
          Text(
            message,
            style: const TextStyle(
              color: TacticalPalette.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Top-of-screen controls shown while AREA mode is active: a hint + point
/// count, an undo button, and a download button enabled once the polygon has
/// at least three vertices.
class _AreaControlBar extends StatelessWidget {
  const _AreaControlBar({
    super.key,
    required this.pointCount,
    required this.downloading,
    required this.onUndo,
    required this.onDownload,
  });

  final int pointCount;
  final bool downloading;
  final VoidCallback? onUndo;
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context) {
    final String hint = downloading
        ? 'Downloading area…'
        : pointCount < 3
            ? 'Tap the map to add points ($pointCount/3)'
            : '$pointCount points · tap Download';
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(
        color: TacticalPalette.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: TacticalPalette.accent.withValues(alpha: 0.5)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Icon(Icons.crop_free, size: 16, color: TacticalPalette.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              hint,
              style: const TextStyle(
                color: TacticalPalette.textPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Undo last point',
            visualDensity: VisualDensity.compact,
            onPressed: onUndo,
            icon: const Icon(Icons.undo, size: 18),
          ),
          const SizedBox(width: 2),
          FilledButton.icon(
            onPressed: onDownload,
            icon: downloading
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download, size: 16),
            label: const Text('Download'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
    );
  }
}

class _PoiSheet extends StatelessWidget {
  final Place poi;
  final String coordsText;
  final VoidCallback onDirections;
  final VoidCallback onMark;
  final VoidCallback onCopy;

  const _PoiSheet({
    required this.poi,
    required this.coordsText,
    required this.onDirections,
    required this.onMark,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: TacticalPalette.divider,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.place, color: TacticalPalette.accent, size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        poi.name,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: TacticalPalette.textPrimary,
                        ),
                      ),
                      if (poi.subtitle.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 2),
                        Text(
                          poi.subtitle,
                          style: const TextStyle(
                            fontSize: 12,
                            color: TacticalPalette.textDim,
                          ),
                        ),
                      ],
                      const SizedBox(height: 4),
                      Text(
                        coordsText,
                        style: const TextStyle(
                          fontSize: 12,
                          color: TacticalPalette.textDim,
                          fontFeatures: <FontFeature>[
                            FontFeature.tabularFigures(),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton.icon(
                    onPressed: onDirections,
                    icon: const Icon(Icons.directions, size: 18),
                    label: const Text('Directions'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onMark,
                    icon: const Icon(Icons.place_outlined, size: 18),
                    label: const Text('Mark'),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.outlined(
                  onPressed: onCopy,
                  icon: const Icon(Icons.copy, size: 18),
                  tooltip: 'Copy coords',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
