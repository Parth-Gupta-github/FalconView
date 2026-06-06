import 'dart:convert';

/// High-level driver for the MapLibre GL JS map hosted in [WebMapView] on
/// desktop platforms. It is deliberately **decoupled from the webview package**:
/// it only knows how to (a) serialise commands to JSON and hand them to an
/// injected JS evaluator, and (b) surface events the view feeds back in. That
/// keeps this file pure Dart — safe to import anywhere, including web — and
/// makes the command protocol easy to unit-test.
///
/// Command protocol mirrors `assets/web_map/index.html`'s `FV.handle`. Event
/// callbacks ([onReady], [onMapClick], [onCameraChanged]) are invoked by the
/// view when the JS side posts an `fvEvent`.
class WebMapController {
  WebMapController(this._eval);

  /// Evaluates a JS snippet in the host page. Supplied by [WebMapView] once the
  /// underlying webview controller exists. Returns a future that completes when
  /// the JS has been dispatched (not when any resulting animation finishes).
  final Future<void> Function(String js) _eval;

  /// Fired once the MapLibre style has loaded and the map is interactive.
  void Function()? onReady;

  /// Fired on every map tap. Coordinates are geographic; [x]/[y] are the tap's
  /// pixel position in the map canvas (used for hit-testing UI overlays).
  void Function(double lat, double lng, double x, double y)? onMapClick;

  /// Fired (throttled) as the camera moves and once when it settles.
  void Function(double lat, double lng, double zoom, double bearing)?
  onCameraChanged;

  bool _ready = false;
  bool get isReady => _ready;

  /// Called by [WebMapView] for each decoded `fvEvent` payload.
  void handleEvent(Map<String, dynamic> e) {
    switch (e['type'] as String?) {
      case 'ready':
        _ready = true;
        onReady?.call();
        break;
      case 'click':
        onMapClick?.call(_d(e['lat']), _d(e['lng']), _d(e['x']), _d(e['y']));
        break;
      case 'camera':
        onCameraChanged?.call(
          _d(e['lat']),
          _d(e['lng']),
          _d(e['zoom']),
          _d(e['bearing']),
        );
        break;
      // 'error' is intentionally swallowed here; the view logs it.
    }
  }

  static double _d(Object? v) => (v as num?)?.toDouble() ?? 0.0;

  Future<void> _send(Map<String, Object?> msg) =>
      _eval("window.FV && FV.handle(${jsonEncode(jsonEncode(msg))})");

  // --- style & camera --------------------------------------------------------

  /// Replaces the whole map style. [styleJson] is a MapLibre style document
  /// (the same string the native `MapLibreMap.styleString` consumes). Pass
  /// [diff] false to force a full reload when sources change wholesale.
  Future<void> setStyle(String styleJson, {bool diff = false}) => _send(
    <String, Object?>{'cmd': 'setStyle', 'style': styleJson, 'diff': diff},
  );

  Future<void> flyTo({
    double? lat,
    double? lng,
    double? zoom,
    double? bearing,
    double? pitch,
    int durationMs = 600,
  }) => _send(<String, Object?>{
    'cmd': 'flyTo',
    'lat': lat,
    'lng': lng,
    'zoom': zoom,
    'bearing': bearing,
    'pitch': pitch,
    'duration': durationMs,
  });

  Future<void> fitBounds({
    required double west,
    required double south,
    required double east,
    required double north,
    double padding = 60,
    int durationMs = 600,
  }) => _send(<String, Object?>{
    'cmd': 'fitBounds',
    'west': west,
    'south': south,
    'east': east,
    'north': north,
    'padding': padding,
    'duration': durationMs,
  });

  // --- markers ---------------------------------------------------------------

  /// Adds or moves a DOM marker. [kind] selects styling and maps to CSS classes
  /// in the host page: `gps`, `place`, `pin` (MARK), `track-a`, `track-b`,
  /// `ruler`, `area`.
  Future<void> setMarker(
    String id,
    double lat,
    double lng, {
    String kind = 'gps',
  }) => _send(<String, Object?>{
    'cmd': 'setMarker',
    'id': id,
    'lat': lat,
    'lng': lng,
    'kind': kind,
  });

  Future<void> removeMarker(String id) =>
      _send(<String, Object?>{'cmd': 'removeMarker', 'id': id});

  // --- lines & polygons ------------------------------------------------------

  /// Adds or updates a GeoJSON overlay. [style] is `track`, `ruler`, or `area`.
  Future<void> setGeoJson(
    String id,
    Map<String, dynamic> data, {
    String style = 'track',
  }) => _send(<String, Object?>{
    'cmd': 'setGeoJson',
    'id': id,
    'data': data,
    'style': style,
  });

  Future<void> removeGeoJson(String id) =>
      _send(<String, Object?>{'cmd': 'removeGeoJson', 'id': id});

  // --- raster (satellite) ----------------------------------------------------

  Future<void> addRaster(
    String id, {
    required List<String> tiles,
    int tileSize = 256,
    double maxzoom = 19,
    String attribution = '',
  }) => _send(<String, Object?>{
    'cmd': 'addRaster',
    'id': id,
    'tiles': tiles,
    'tileSize': tileSize,
    'maxzoom': maxzoom,
    'attribution': attribution,
  });

  Future<void> removeLayer(String id) =>
      _send(<String, Object?>{'cmd': 'removeLayer', 'id': id});

  // --- misc ------------------------------------------------------------------

  Future<void> clearOverlays() =>
      _send(<String, Object?>{'cmd': 'clearOverlays'});

  /// Toggles rotate/pitch gestures (north-up lock).
  Future<void> setInteraction({required bool rotate, required bool pitch}) =>
      _send(<String, Object?>{
        'cmd': 'setInteraction',
        'rotate': rotate,
        'pitch': pitch,
      });

  /// Step-zooms by [amount] zoom levels (positive = in, negative = out).
  /// Animated via easeTo so it feels the same as pinch / wheel input.
  Future<void> zoomBy(double amount, {int durationMs = 220}) =>
      _send(<String, Object?>{
        'cmd': 'zoomBy',
        'amount': amount,
        'duration': durationMs,
      });
}
