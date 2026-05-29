import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_tier.dart';
import '../models/place.dart';
import '../util/polygon_geo.dart';
import 'offline_router.dart';
import 'offline_search_index.dart';
import 'routing_service.dart' show RouteResult;
import 'subscription_service.dart';
import 'tile_config.dart';

class OfflineNotAvailable implements Exception {
  final String message;
  OfflineNotAvailable(this.message);
  @override
  String toString() => message;
}

/// Why an offline route lookup failed. `noRegion` = origin is outside every
/// downloaded bbox. `noGraph` = a region covers the origin but its road
/// graph was never built (or is empty). `noPath` = graph exists but Dijkstra
/// found no connected route.
enum OfflineRouteFailure { noRegion, noGraph, noPath }

/// Result of an offline route lookup — either a `RouteResult` or a typed
/// reason for failure.
class OfflineRouteOutcome {
  final RouteResult? route;
  final OfflineRouteFailure? failure;

  const OfflineRouteOutcome.success(RouteResult this.route) : failure = null;
  const OfflineRouteOutcome.failure(OfflineRouteFailure this.failure)
      : route = null;

  bool get isSuccess => route != null;
}

class OfflineRepository {
  OfflineRepository({OfflineSearchIndex? index, OfflineRouter? router})
      : _index = index ?? OfflineSearchIndex(),
        _router = router ?? OfflineRouter();

  static const String _metaKey = 'place';
  static const String _poiSourcePrefix = 'poi_source_';

  final OfflineSearchIndex _index;
  final OfflineRouter _router;

  OfflineSearchIndex get index => _index;
  OfflineRouter get router => _router;

  Future<OfflineRegion> download(
    Place place, {
    void Function(double percent)? onProgress,
  }) async {
    if (kIsWeb) {
      throw OfflineNotAvailable('Offline downloads are not supported on web.');
    }
    if (subscriptionService.tier != AppTier.pro) {
      throw OfflineNotAvailable(
        'Offline download is a Pro feature. Upgrade in Plans to enable it.',
      );
    }
    final TileConfig cfg = TileConfig.forTier(subscriptionService.tier);
    // Map tiles are square, so we always download the polygon's bounding box.
    // The POI + road-graph extracts below are what get clipped to the drawn
    // area via this predicate (null for plain rectangular regions).
    final List<LatLng>? poly = place.polygon;
    final bool Function(double lat, double lon)? contains =
        (poly != null && poly.length >= 3)
            ? (double lat, double lon) => PolygonGeo.contains(poly, lat, lon)
            : null;
    final OfflineRegionDefinition definition = OfflineRegionDefinition(
      bounds: place.bbox,
      mapStyleUrl: cfg.styleUrl,
      minZoom: cfg.offlineMinZoom,
      maxZoom: cfg.offlineMaxZoom,
    );
    final OfflineRegion region = await downloadOfflineRegion(
      definition,
      metadata: {_metaKey: jsonEncode(place.toJson())},
      onEvent: onProgress == null
          ? null
          : (DownloadRegionStatus event) {
              if (event is InProgress) {
                onProgress(event.progress * 0.5);
              } else if (event is Success) {
                onProgress(50);
              }
            },
    );
    _lastIndexError = null;
    _lastPoiSource = PoiSource.none;
    _lastIndexStats = null;
    _lastRouterError = null;
    try {
      // OfflineSearchIndex.build() now walks the tiles once and produces both
      // the POI features table and the road graph. No separate router fetch.
      final IndexBuildStats stats = await _index.build(
        region.id,
        place.bbox,
        contains: contains,
        onProgress: (double pct) {
          if (onProgress != null) onProgress(50 + pct * 0.5);
        },
      );
      _lastPoiSource = stats.source;
      _lastIndexStats = stats;
      await _persistPoiSource(region.id, stats.source);
    } catch (e, stack) {
      // ignore: avoid_print
      print('[OfflineSearchIndex.build] FAILED: $e\n$stack');
      _lastIndexError = '$e';
    }
    if (onProgress != null) onProgress(100);
    return region;
  }

  /// Set when the most recent download's index build threw. Null if the last
  /// build succeeded or no build has happened.
  String? _lastIndexError;
  String? get lastIndexError => _lastIndexError;

  String? _lastRouterError;
  String? get lastRouterError => _lastRouterError;

  /// Which strategy populated the most recently built index.
  PoiSource _lastPoiSource = PoiSource.none;
  PoiSource get lastPoiSource => _lastPoiSource;

  /// Tile-scan + POI-insert counts from the most recent index build. Null if
  /// the index step failed before completing.
  IndexBuildStats? _lastIndexStats;
  IndexBuildStats? get lastIndexStats => _lastIndexStats;

  Future<void> _persistPoiSource(int regionId, PoiSource source) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_poiSourcePrefix$regionId', source.name);
    } catch (_) {
      // Persistence failure shouldn't break the download flow.
    }
  }

  /// Returns the persisted POI source for a downloaded region, or
  /// `PoiSource.none` if nothing was recorded (older download or wiped state).
  Future<PoiSource> poiSourceFor(int regionId) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString('$_poiSourcePrefix$regionId');
      if (raw == null) return PoiSource.none;
      return PoiSource.values.firstWhere(
        (PoiSource s) => s.name == raw,
        orElse: () => PoiSource.none,
      );
    } catch (_) {
      return PoiSource.none;
    }
  }

  Future<List<Place>> listDownloaded() async {
    if (kIsWeb) return const <Place>[];
    final List<OfflineRegion> regions = await getListOfRegions();
    final List<Place> out = [];
    for (final OfflineRegion r in regions) {
      final Place? p = _placeFromRegion(r);
      if (p != null) out.add(p);
    }
    return out;
  }

  Future<void> delete(int regionId) async {
    if (kIsWeb) return;
    await deleteOfflineRegion(regionId);
    await _index.deleteIndex(regionId);
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_poiSourcePrefix$regionId');
    } catch (_) {}
  }

  /// Tries each downloaded region whose bbox contains [from] and returns the
  /// first successful offline route, or a typed failure reason if none works.
  Future<OfflineRouteOutcome> routeOffline(LatLng from, LatLng to) async {
    if (kIsWeb) {
      return const OfflineRouteOutcome.failure(OfflineRouteFailure.noRegion);
    }
    final List<Place> regions = await listDownloaded();
    if (regions.isEmpty) {
      return const OfflineRouteOutcome.failure(OfflineRouteFailure.noRegion);
    }
    bool anyCovers = false;
    bool anyHasGraph = false;
    for (final Place r in regions) {
      final int? id = r.regionId;
      if (id == null) continue;
      if (!_bboxContains(r.bbox, from)) continue;
      anyCovers = true;
      final bool ready = await _router.hasGraph(id);
      if (!ready) continue;
      anyHasGraph = true;
      final RouteResult? result = await _router.route(id, from, to);
      if (result != null) return OfflineRouteOutcome.success(result);
    }
    if (!anyCovers) {
      return const OfflineRouteOutcome.failure(OfflineRouteFailure.noRegion);
    }
    if (!anyHasGraph) {
      return const OfflineRouteOutcome.failure(OfflineRouteFailure.noGraph);
    }
    return const OfflineRouteOutcome.failure(OfflineRouteFailure.noPath);
  }

  bool _bboxContains(LatLngBounds b, LatLng p) {
    return p.latitude >= b.southwest.latitude &&
        p.latitude <= b.northeast.latitude &&
        p.longitude >= b.southwest.longitude &&
        p.longitude <= b.northeast.longitude;
  }

  Future<List<Place>> searchOffline(String query, {int limit = 20}) async {
    if (kIsWeb || query.trim().isEmpty) return const <Place>[];
    final List<Place> regions = await listDownloaded();
    final List<Place> hits = <Place>[];
    for (final Place r in regions) {
      final int? id = r.regionId;
      if (id == null) continue;
      hits.addAll(await _index.search(id, query, limit: limit));
      if (hits.length >= limit) break;
    }
    return hits.take(limit).toList();
  }

  Place? _placeFromRegion(OfflineRegion r) {
    final dynamic raw = r.metadata[_metaKey];
    if (raw is! String) return null;
    try {
      final Map<String, dynamic> json =
          jsonDecode(raw) as Map<String, dynamic>;
      return Place.fromJson(json, regionId: r.id);
    } catch (_) {
      return null;
    }
  }
}
