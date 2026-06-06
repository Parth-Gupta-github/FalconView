import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../models/app_tier.dart';
import '../models/place.dart';
import '../util/polygon_geo.dart';
import 'mbtiles_tile_source.dart';
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
    // Map tiles are square, so we always download the polygon's bounding box.
    // The POI + road-graph extracts below are what get clipped to the drawn
    // area via this predicate (null for plain rectangular regions).
    final List<LatLng>? poly = place.polygon;
    final bool Function(double lat, double lon)? contains =
        (poly != null && poly.length >= 3)
            ? (double lat, double lon) => PolygonGeo.contains(poly, lat, lon)
            : null;

    // Desktop (macOS/Windows/Linux) has no maplibre_gl Flutter binding for
    // [downloadOfflineRegion]. Instead we walk the same tile pyramid the
    // mobile path's index builder already fetches and write each tile to an
    // .mbtiles bundle, which the local tile server then serves to the
    // WebView basemap. End result: full offline rendering + search + routing,
    // built from the same MVT extraction code mobile uses.
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      await _downloadAsMbtiles(place, contains, onProgress);
      return;
    }
    final TileConfig cfg = TileConfig.forTier(subscriptionService.tier);
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

  /// Desktop region download: fetches tiles for [place.bbox] over HTTP, writes
  /// them into a fresh `.mbtiles` file, extracts POIs + the road graph from
  /// the same tile bytes, and registers the file with the imported-MBTiles
  /// registry so [listDownloaded] and the local tile server pick it up.
  Future<void> _downloadAsMbtiles(
    Place place,
    bool Function(double lat, double lon)? contains,
    void Function(double percent)? onProgress,
  ) async {
    _lastIndexError = null;
    _lastPoiSource = PoiSource.none;
    _lastIndexStats = null;
    _lastRouterError = null;

    final int regionId = await _nextMbtilesRegionId();
    final String destPath = await _mbtilesPathFor(regionId);

    IndexBuildStats stats;
    try {
      stats = await _index.build(
        regionId,
        place.bbox,
        contains: contains,
        mbtilesOutPath: destPath,
        mbtilesName: place.name,
        onProgress: onProgress,
      );
      _lastPoiSource = stats.source;
      _lastIndexStats = stats;
      await _persistPoiSource(regionId, stats.source);
    } catch (e, stack) {
      // ignore: avoid_print
      print('[OfflineSearchIndex.build mbtiles] FAILED: $e\n$stack');
      _lastIndexError = '$e';
      try {
        final File f = File(destPath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
      rethrow;
    }

    // Verify the writer actually produced a usable file before we register it.
    // We open it as an MBTiles source and confirm at least one tile landed —
    // catches the "every fetch failed" / "network died" scenarios that would
    // otherwise leave us with an empty .mbtiles in the registry.
    final File outFile = File(destPath);
    bool ok = false;
    if (await outFile.exists()) {
      try {
        final MbtilesTileSource probe = await MbtilesTileSource.open(destPath);
        try {
          ok = (await probe.tileCount(0, 24)) > 0;
        } finally {
          await probe.close();
        }
      } catch (_) {
        ok = false;
      }
    }
    if (!ok) {
      _lastIndexError = _lastIndexError ?? 'MBTiles output is empty';
      try {
        if (await outFile.exists()) await outFile.delete();
      } catch (_) {}
      throw OfflineNotAvailable(
        'Region download failed — no tiles were saved. Check your network.',
      );
    }

    final Place stored = Place(
      name: place.name,
      subtitle: place.subtitle,
      center: place.center,
      bbox: place.bbox,
      polygon: place.polygon,
      state: PlaceDownloadState.downloaded,
      regionId: regionId,
    );
    await _saveMbtilesRegion(stored, destPath);
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
    // maplibre_gl's getListOfRegions has no desktop binding — calling it on
    // Windows/macOS/Linux throws MissingPluginException, which previously
    // caused the entire Downloaded tab to come back empty even when our own
    // .mbtiles registry had regions. Treat the throw as "no native regions"
    // (which is always true on desktop) and let the MBTiles registry below
    // contribute its rows.
    final List<Place> out = <Place>[];
    try {
      final List<OfflineRegion> regions = await getListOfRegions();
      for (final OfflineRegion r in regions) {
        final Place? p = _placeFromRegion(r);
        if (p != null) out.add(p);
      }
    } catch (e) {
      debugPrint('getListOfRegions unavailable (desktop?): $e');
    }
    // Imported / desktop-downloaded MBTiles regions live in our own registry,
    // not MapLibre's store.
    out.addAll(await _loadMbtilesRegions());
    return out;
  }

  /// Best-effort storage metrics for the delete-confirmation dialog. Returns
  /// total bytes the region occupies on disk (`.mbtiles` + index `.db`) and
  /// the POI count in its index. Either value is null when the file is
  /// missing or unreadable — the UI shows `—` for nulls. No exceptions
  /// propagate; this is cheap and safe to call from a dialog `FutureBuilder`.
  Future<({int? bytes, int? poiCount})> regionStorageInfo(int regionId) async {
    if (kIsWeb) return (bytes: null, poiCount: null);
    int? bytes;
    try {
      final Directory docs = await getApplicationDocumentsDirectory();
      final List<String> candidates = <String>[
        p.join(docs.path, 'region_mbtiles', '$regionId.mbtiles'),
        p.join(docs.path, 'region_indexes', '$regionId.db'),
      ];
      int total = 0;
      bool any = false;
      for (final String path in candidates) {
        final File f = File(path);
        if (await f.exists()) {
          total += await f.length();
          any = true;
        }
      }
      if (any) bytes = total;
    } catch (_) {
      // Leave bytes null.
    }

    int? poiCount;
    try {
      final Directory docs = await getApplicationDocumentsDirectory();
      final String indexPath =
          p.join(docs.path, 'region_indexes', '$regionId.db');
      if (await File(indexPath).exists()) {
        final Database db = await openDatabase(indexPath, readOnly: true);
        try {
          final List<Map<String, Object?>> rows =
              await db.rawQuery('SELECT COUNT(*) AS n FROM features');
          if (rows.isNotEmpty) {
            final Object? n = rows.first['n'];
            if (n is num) poiCount = n.toInt();
          }
        } catch (_) {
          // Stale schema or no `features` table — leave poiCount null.
        } finally {
          await db.close();
        }
      }
    } catch (_) {
      // Leave poiCount null.
    }

    return (bytes: bytes, poiCount: poiCount);
  }

  Future<void> delete(int regionId) async {
    if (kIsWeb) return;
    // Imported / desktop-downloaded MBTiles regions have no MapLibre offline
    // region — drop the registry entry (which deletes the .mbtiles file) and
    // the index DB.
    if (await _isMbtilesRegion(regionId)) {
      await _removeMbtilesRegion(regionId);
      await _index.deleteIndex(regionId);
    } else {
      // Native offline region — only exists on mobile. Wrap defensively so
      // an attempt on desktop (where deleteOfflineRegion throws
      // MissingPluginException) still cleans up the local index.
      try {
        await deleteOfflineRegion(regionId);
      } catch (e) {
        debugPrint('deleteOfflineRegion unavailable (desktop?): $e');
      }
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

final OfflineRepository offlineRepository = OfflineRepository();
