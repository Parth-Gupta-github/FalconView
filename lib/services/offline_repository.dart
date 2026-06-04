import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_tier.dart';
import '../models/place.dart';
import '../util/polygon_geo.dart';
import 'mbtiles_tile_source.dart';
import 'mbtiles_writer.dart';
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

  // Imported-MBTiles regions live outside MapLibre's offline-region store, so
  // we keep our own registry in prefs. Their ids start high to avoid colliding
  // with MapLibre's small sequential ids. The .mbtiles file is kept on disk
  // (the local tile server renders from it), unlike network downloads.
  static const String _mbtilesRegionsKey = 'mbtiles_regions';
  static const String _mbtilesNextIdKey = 'mbtiles_next_id';
  static const int _mbtilesIdBase = 900000000;

  final OfflineSearchIndex _index;
  final OfflineRouter _router;

  OfflineSearchIndex get index => _index;
  OfflineRouter get router => _router;

  Future<void> download(
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
    // Desktop (macOS/Windows/Linux) has no native maplibre offline downloader,
    // so we fetch the region's tiles into a portable .mbtiles that the
    // LocalTileServer serves to the webview map. End result is the same as
    // Android's downloadOfflineRegion: tap download → region works offline.
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      await _downloadToMbtiles(place, cfg, onProgress);
      return;
    }
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
  }

  /// Desktop offline download: fetch the region's tiles into a portable
  /// `.mbtiles`, build the POI index + road graph from it, and register it so
  /// the LocalTileServer renders it and search/routing work — all offline
  /// afterwards. The map zoom range is capped at 14 (the offline style's source
  /// maxzoom; higher levels overzoom z14 and would just waste the download).
  Future<void> _downloadToMbtiles(
    Place place,
    TileConfig cfg,
    void Function(double percent)? onProgress,
  ) async {
    _lastIndexError = null;
    _lastPoiSource = PoiSource.none;
    _lastIndexStats = null;
    _lastRouterError = null;

    final int regionId = await _nextMbtilesRegionId();
    final String destPath = await _mbtilesPathFor(regionId);
    final LatLngBounds b = place.bbox;
    final String bounds = '${b.southwest.longitude},${b.southwest.latitude},'
        '${b.northeast.longitude},${b.northeast.latitude}';
    final int zMin = cfg.offlineMinZoom.toInt();
    final int zMax = cfg.offlineMaxZoom.toInt() < 14 ? cfg.offlineMaxZoom.toInt() : 14;

    final List<LatLng>? poly = place.polygon;
    final bool Function(double lat, double lon)? contains =
        (poly != null && poly.length >= 3)
            ? (double lat, double lon) => PolygonGeo.contains(poly, lat, lon)
            : null;

    try {
      // 1. Fetch tiles → .mbtiles (0–70%).
      final MbtilesWriter writer = await MbtilesWriter.create(
        destPath,
        name: place.name,
        bounds: bounds,
        minZoom: zMin,
        maxZoom: zMax,
      );
      int tilesWritten = 0;
      try {
        tilesWritten = await _index.downloadRegionToMbtiles(
          writer,
          b,
          zMin: zMin,
          zMax: zMax,
          onProgress: (double p) => onProgress?.call(p * 0.7),
        );
      } finally {
        await writer.close();
      }
      if (tilesWritten == 0) {
        throw OfflineNotAvailable(
          'No tiles could be downloaded — check your connection and try again.',
        );
      }

      // 2. Build POI index + road graph from the downloaded .mbtiles (70–100%).
      final MbtilesTileSource source = await MbtilesTileSource.open(destPath);
      try {
        final IndexBuildStats stats = await _index.buildFromMbtiles(
          regionId,
          source,
          contains: contains,
          onProgress: (double p) => onProgress?.call(70 + p * 0.3),
        );
        _lastPoiSource = stats.source;
        _lastIndexStats = stats;
        await _persistPoiSource(regionId, stats.source);
      } finally {
        await source.close();
      }

      // 3. Register so LocalTileServer + the offline style pick it up.
      final Place saved = Place(
        name: place.name,
        subtitle: 'Offline region · ${_lastIndexStats?.poisInserted ?? 0} POIs',
        center: place.center,
        bbox: place.bbox,
        polygon: place.polygon,
        state: PlaceDownloadState.downloaded,
        regionId: regionId,
      );
      await _saveMbtilesRegion(saved, destPath);
      onProgress?.call(100);
    } catch (e) {
      _lastIndexError = '$e';
      try {
        final File f = File(destPath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
      rethrow;
    }
  }

  /// Imports a local `.mbtiles` file: copies it into app storage (the local
  /// tile server renders from it), builds the POI index + road graph from it
  /// with no network, and registers it so it shows up in [listDownloaded] and
  /// [registeredMbtilesPaths]. This is the fully-offline path.
  Future<Place> importMbtiles(
    String pickedPath, {
    void Function(double percent)? onProgress,
  }) async {
    if (kIsWeb) {
      throw OfflineNotAvailable('MBTiles import is not supported on web.');
    }
    if (subscriptionService.tier != AppTier.pro) {
      throw OfflineNotAvailable(
        'Offline data is a Pro feature. Upgrade in Plans to enable it.',
      );
    }
    _lastIndexError = null;
    _lastPoiSource = PoiSource.none;
    _lastIndexStats = null;

    final int regionId = await _nextMbtilesRegionId();
    final String destPath = await _mbtilesPathFor(regionId);
    // Copy the picked file into our storage so it persists for rendering.
    await File(pickedPath).copy(destPath);

    final MbtilesTileSource source = await MbtilesTileSource.open(destPath);
    try {
      final Map<String, String> meta = await source.metadata();
      final String metaName = (meta['name'] ?? '').trim();
      final String name = metaName.isNotEmpty
          ? metaName
          : p.basenameWithoutExtension(pickedPath);
      final LatLngBounds? bbox = await source.bounds();
      if (bbox == null) {
        throw OfflineNotAvailable('MBTiles file has no readable tiles.');
      }
      final LatLng center = LatLng(
        (bbox.southwest.latitude + bbox.northeast.latitude) / 2,
        (bbox.southwest.longitude + bbox.northeast.longitude) / 2,
      );

      final IndexBuildStats stats = await _index.buildFromMbtiles(
        regionId,
        source,
        onProgress: onProgress,
      );
      _lastPoiSource = stats.source;
      _lastIndexStats = stats;
      await _persistPoiSource(regionId, stats.source);

      final Place place = Place(
        name: name,
        subtitle: 'Imported MBTiles · ${stats.poisInserted} POIs',
        center: center,
        bbox: bbox,
        state: PlaceDownloadState.downloaded,
        regionId: regionId,
      );
      await _saveMbtilesRegion(place, destPath);
      return place;
    } catch (e) {
      _lastIndexError = '$e';
      // Best-effort cleanup of the copied file on failure.
      try {
        final File f = File(destPath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
      rethrow;
    } finally {
      await source.close();
    }
  }

  // ---------------- Imported-MBTiles region registry ----------------

  Future<String> _mbtilesPathFor(int regionId) async {
    final Directory docs = await getApplicationDocumentsDirectory();
    final Directory dir = Directory(p.join(docs.path, 'region_mbtiles'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return p.join(dir.path, '$regionId.mbtiles');
  }

  Future<int> _nextMbtilesRegionId() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final int id = prefs.getInt(_mbtilesNextIdKey) ?? _mbtilesIdBase;
    await prefs.setInt(_mbtilesNextIdKey, id + 1);
    return id;
  }

  Future<void> _saveMbtilesRegion(Place place, String mbtilesPath) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final List<String> list =
        prefs.getStringList(_mbtilesRegionsKey) ?? <String>[];
    final Map<String, dynamic> json = place.toJson();
    json['regionId'] = place.regionId;
    json['mbtilesPath'] = mbtilesPath;
    list.add(jsonEncode(json));
    await prefs.setStringList(_mbtilesRegionsKey, list);
  }

  Future<List<Map<String, dynamic>>> _loadMbtilesRegistry() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final List<String> list =
          prefs.getStringList(_mbtilesRegionsKey) ?? <String>[];
      return list
          .map((String raw) => jsonDecode(raw) as Map<String, dynamic>)
          .toList();
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
  }

  Future<List<Place>> _loadMbtilesRegions() async {
    final List<Map<String, dynamic>> rows = await _loadMbtilesRegistry();
    return rows
        .map((Map<String, dynamic> j) =>
            Place.fromJson(j, regionId: (j['regionId'] as num?)?.toInt()))
        .toList();
  }

  /// Absolute paths of every imported `.mbtiles`, for the local tile server.
  Future<List<String>> registeredMbtilesPaths() async {
    final List<Map<String, dynamic>> rows = await _loadMbtilesRegistry();
    return rows
        .map((Map<String, dynamic> j) => j['mbtilesPath'] as String?)
        .whereType<String>()
        .toList();
  }

  Future<bool> _isMbtilesRegion(int regionId) async {
    final List<Map<String, dynamic>> rows = await _loadMbtilesRegistry();
    return rows.any((Map<String, dynamic> j) =>
        (j['regionId'] as num?)?.toInt() == regionId);
  }

  Future<void> _removeMbtilesRegion(int regionId) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final List<String> list =
        prefs.getStringList(_mbtilesRegionsKey) ?? <String>[];
    final List<String> kept = <String>[];
    for (final String raw in list) {
      try {
        final Map<String, dynamic> j = jsonDecode(raw) as Map<String, dynamic>;
        if ((j['regionId'] as num?)?.toInt() == regionId) {
          final String? path = j['mbtilesPath'] as String?;
          if (path != null) {
            try {
              final File f = File(path);
              if (await f.exists()) await f.delete();
            } catch (_) {}
          }
          continue;
        }
      } catch (_) {}
      kept.add(raw);
    }
    await prefs.setStringList(_mbtilesRegionsKey, kept);
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
    final List<Place> out = [];
    // Native maplibre offline regions (Android/iOS). On desktop the plugin has
    // no implementation, so getListOfRegions throws MissingPluginException —
    // guard it so the downloaded/imported MBTiles regions below still show.
    try {
      final List<OfflineRegion> regions = await getListOfRegions();
      for (final OfflineRegion r in regions) {
        final Place? p = _placeFromRegion(r);
        if (p != null) out.add(p);
      }
    } catch (e) {
      debugPrint('getListOfRegions unavailable (desktop?): $e');
    }
    // Imported/downloaded MBTiles regions live in our own registry.
    out.addAll(await _loadMbtilesRegions());
    return out;
  }

  Future<void> delete(int regionId) async {
    if (kIsWeb) return;
    // Imported MBTiles regions have no MapLibre offline region — drop the
    // registry entry (which deletes the .mbtiles file) and the index DB.
    if (await _isMbtilesRegion(regionId)) {
      await _removeMbtilesRegion(regionId);
      await _index.deleteIndex(regionId);
    } else {
      await deleteOfflineRegion(regionId);
      await _index.deleteIndex(regionId);
    }
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

  /// Tap-on-map handler: returns the closest indexed POI to (lat, lon)
  /// across all downloaded regions whose bbox contains the tap, or null
  /// when nothing is near (or no region covers the point).
  Future<Place?> nearestPoiNear(
    double lat,
    double lon, {
    double maxMeters = 50,
  }) async {
    if (kIsWeb) return null;
    final List<Place> regions = await listDownloaded();
    Place? best;
    double bestDist = double.infinity;
    for (final Place r in regions) {
      final int? id = r.regionId;
      if (id == null) continue;
      if (!_bboxContains(r.bbox, LatLng(lat, lon))) continue;
      final Place? hit =
          await _index.nearest(id, lat, lon, maxMeters: maxMeters);
      if (hit == null) continue;
      // Squared lat/lon delta is good enough for ranking — we already
      // capped by maxMeters inside _index.nearest.
      final double dl = hit.center.latitude - lat;
      final double dln = hit.center.longitude - lon;
      final double d2 = dl * dl + dln * dln;
      if (d2 < bestDist) {
        bestDist = d2;
        best = hit;
      }
    }
    return best;
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

/// App-wide singleton so the map and search screens share ONE repository.
/// Downloads run on this instance, so navigating between screens no longer
/// orphans an in-flight download, and the registry/index state stays
/// consistent across the app.
final OfflineRepository offlineRepository = OfflineRepository();
