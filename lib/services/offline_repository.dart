import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:maplibre_gl/maplibre_gl.dart';

import '../models/app_tier.dart';
import '../models/place.dart';
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
                onProgress(event.progress * 0.5);
              } else if (event is Success) {
                onProgress(50);
              }
            },
    );
    try {
      await _index.build(
        region.id,
        place.bbox,
        onProgress: (double pct) {
          if (onProgress != null) onProgress(50 + pct * 0.25);
        },
      );
    } catch (e, stack) {
      // ignore: avoid_print
      print('[OfflineSearchIndex.build] FAILED: $e\n$stack');
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
    return out;
  }

  Future<void> delete(int regionId) async {
    if (kIsWeb) return;
    await deleteOfflineRegion(regionId);
    await _index.deleteIndex(regionId);
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
