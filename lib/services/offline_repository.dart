import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:maplibre_gl/maplibre_gl.dart';
<<<<<<< Updated upstream

import '../models/app_tier.dart';
import '../models/place.dart';
=======
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_tier.dart';
import '../models/place.dart';
import '../util/polygon_geo.dart';
import 'mbtiles_tile_source.dart';
import 'mbtiles_writer.dart';
>>>>>>> Stashed changes
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

class OfflineRepository {
  OfflineRepository({OfflineSearchIndex? index, OfflineRouter? router})
      : _index = index ?? OfflineSearchIndex(),
        _router = router ?? OfflineRouter();

  static const String _metaKey = 'place';

  // Imported-MBTiles regions live outside MapLibre's offline-region store, so
  // we keep our own little registry of them in prefs. Their region ids start
  // high to avoid colliding with MapLibre's small sequential ids.
  static const String _mbtilesRegionsKey = 'mbtiles_regions';
  static const String _mbtilesNextIdKey = 'mbtiles_next_id';
  static const int _mbtilesIdBase = 900000000;

  // Zoom range packed into a downloaded region's .mbtiles. OpenMapTiles emits
  // POIs from z12 and its source maxzoom is 14, so z12-14 captures all POI +
  // road data with no overzoomed duplicates.
  static const int _dataZMin = 12;
  static const int _dataZMax = 14;

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
                onProgress(event.progress * 0.4);
              } else if (event is Success) {
                onProgress(40);
              }
            },
    );
    try {
<<<<<<< Updated upstream
      await _index.build(
        region.id,
        place.bbox,
        onProgress: (double pct) {
          if (onProgress != null) onProgress(50 + pct * 0.25);
        },
      );
=======
      // 1. Fetch the region's vector tiles into a portable .mbtiles file —
      //    this is the offline data pack, in standard MBTiles form rather than
      //    a transient pile of loose MVT tiles.
      final String mbtilesPath = await _mbtilesPathFor(region.id);
      final MbtilesWriter writer = await MbtilesWriter.create(
        mbtilesPath,
        name: place.name,
        bounds: place.bbox,
        minZoom: _dataZMin,
        maxZoom: _dataZMax,
      );
      try {
        await _index.downloadRegionToMbtiles(
          writer,
          place.bbox,
          zMin: _dataZMin,
          zMax: _dataZMax,
          onProgress: (double pct) => onProgress?.call(40 + pct * 0.35),
        );
      } finally {
        await writer.close();
      }

      // 2. Build the POI index + road graph from that .mbtiles, clipped to the
      //    drawn polygon if one was supplied. No network in this step.
      final MbtilesTileSource source = await MbtilesTileSource.open(mbtilesPath);
      try {
        final IndexBuildStats stats = await _index.buildFromMbtiles(
          region.id,
          source,
          contains: contains,
          onProgress: (double pct) => onProgress?.call(75 + pct * 0.25),
        );
        _lastPoiSource = stats.source;
        _lastIndexStats = stats;
        await _persistPoiSource(region.id, stats.source);
      } finally {
        await source.close();
      }
>>>>>>> Stashed changes
    } catch (e, stack) {
      // ignore: avoid_print
      print('[OfflineRepository.download] index build FAILED: $e\n$stack');
      _lastIndexError = '$e';
    }
    try {
      await _router.build(
        region.id,
        place.bbox,
        onProgress: (double pct) {
          if (onProgress != null) onProgress(75 + pct * 0.25);
        },
      );
    } catch (e, stack) {
      // ignore: avoid_print
      print('[OfflineRouter.build] FAILED: $e\n$stack');
      _lastRouterError = '$e';
    }
    if (onProgress != null) onProgress(100);
    return region;
  }

  Future<String> _mbtilesPathFor(int regionId) async {
    final Directory docs = await getApplicationDocumentsDirectory();
    final Directory dir = Directory(p.join(docs.path, 'region_mbtiles'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return p.join(dir.path, '$regionId.mbtiles');
  }

  Future<void> _deleteMbtilesFile(int regionId) async {
    try {
      final File f = File(await _mbtilesPathFor(regionId));
      if (await f.exists()) await f.delete();
    } catch (_) {
      // A leftover file is harmless; ignore cleanup failures.
    }
  }

  /// Builds an offline POI index + road graph from a local `.mbtiles` file —
  /// no network. The file only needs to be readable for the duration of this
  /// call; everything routing/search needs afterwards lives in the per-region
  /// DB we write. Registers the region in our prefs-backed registry so it
  /// shows up in [listDownloaded] alongside MapLibre downloads.
  Future<Place> importMbtiles(
    String filePath, {
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

    final MbtilesTileSource source = await MbtilesTileSource.open(filePath);
    try {
      final Map<String, String> meta = await source.metadata();
      final String metaName = (meta['name'] ?? '').trim();
      final String name = metaName.isNotEmpty
          ? metaName
          : p.basenameWithoutExtension(filePath);
      final LatLngBounds? bbox = await source.bounds();
      if (bbox == null) {
        throw OfflineNotAvailable('MBTiles file has no readable tiles.');
      }
      final LatLng center = LatLng(
        (bbox.southwest.latitude + bbox.northeast.latitude) / 2,
        (bbox.southwest.longitude + bbox.northeast.longitude) / 2,
      );
      final int regionId = await _nextMbtilesRegionId();

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
      await _saveMbtilesRegion(place);
      return place;
    } catch (e) {
      _lastIndexError = '$e';
      rethrow;
    } finally {
      await source.close();
    }
  }

  // ---------------- Imported-MBTiles region registry ----------------

  Future<int> _nextMbtilesRegionId() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final int id = prefs.getInt(_mbtilesNextIdKey) ?? _mbtilesIdBase;
    await prefs.setInt(_mbtilesNextIdKey, id + 1);
    return id;
  }

  Future<void> _saveMbtilesRegion(Place place) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final List<String> list =
        prefs.getStringList(_mbtilesRegionsKey) ?? <String>[];
    final Map<String, dynamic> json = place.toJson();
    json['regionId'] = place.regionId;
    list.add(jsonEncode(json));
    await prefs.setStringList(_mbtilesRegionsKey, list);
  }

  Future<List<Place>> _loadMbtilesRegions() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final List<String> list =
          prefs.getStringList(_mbtilesRegionsKey) ?? <String>[];
      final List<Place> out = <Place>[];
      for (final String raw in list) {
        final Map<String, dynamic> json =
            jsonDecode(raw) as Map<String, dynamic>;
        final int? id = (json['regionId'] as num?)?.toInt();
        out.add(Place.fromJson(json, regionId: id));
      }
      return out;
    } catch (_) {
      return const <Place>[];
    }
  }

  Future<bool> _isMbtilesRegion(int regionId) async {
    final List<Place> regions = await _loadMbtilesRegions();
    return regions.any((Place p) => p.regionId == regionId);
  }

  Future<void> _removeMbtilesRegion(int regionId) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final List<String> list =
        prefs.getStringList(_mbtilesRegionsKey) ?? <String>[];
    final List<String> kept = <String>[];
    for (final String raw in list) {
      try {
        final Map<String, dynamic> json =
            jsonDecode(raw) as Map<String, dynamic>;
        if ((json['regionId'] as num?)?.toInt() == regionId) continue;
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

  Future<List<Place>> listDownloaded() async {
    if (kIsWeb) return const <Place>[];
    final List<OfflineRegion> regions = await getListOfRegions();
    final List<Place> out = [];
    for (final OfflineRegion r in regions) {
      final Place? p = _placeFromRegion(r);
      if (p != null) out.add(p);
    }
    // Imported MBTiles regions live in our own registry, not MapLibre's store.
    out.addAll(await _loadMbtilesRegions());
    return out;
  }

  Future<void> delete(int regionId) async {
    if (kIsWeb) return;
<<<<<<< Updated upstream
    await deleteOfflineRegion(regionId);
    await _index.deleteIndex(regionId);
=======
    // MBTiles regions have no MapLibre offline region to remove — just drop
    // the registry entry and the per-region index/graph DB.
    if (await _isMbtilesRegion(regionId)) {
      await _removeMbtilesRegion(regionId);
      await _index.deleteIndex(regionId);
    } else {
      await deleteOfflineRegion(regionId);
      await _index.deleteIndex(regionId);
      await _deleteMbtilesFile(regionId);
    }
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_poiSourcePrefix$regionId');
    } catch (_) {}
>>>>>>> Stashed changes
  }

  /// Tries each downloaded region whose bbox contains [from] and returns the
  /// first successful offline route. Returns null when no region covers the
  /// origin, or no path is found within any covering region.
  Future<RouteResult?> routeOffline(LatLng from, LatLng to) async {
    if (kIsWeb) return null;
    final List<Place> regions = await listDownloaded();
    for (final Place r in regions) {
      final int? id = r.regionId;
      if (id == null) continue;
      if (!_bboxContains(r.bbox, from)) continue;
      final RouteResult? result = await _router.route(id, from, to);
      if (result != null) return result;
    }
    return null;
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
