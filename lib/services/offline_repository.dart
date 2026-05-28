import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:maplibre_gl/maplibre_gl.dart';

import '../models/offline_poi.dart';
import '../models/place.dart';
import 'overpass_service.dart';
import 'poi_repository.dart';
import 'subscription_service.dart';
import 'tile_config.dart';

class OfflineNotAvailable implements Exception {
  final String message;
  OfflineNotAvailable(this.message);
  @override
  String toString() => message;
}

class OfflineRepository {
  OfflineRepository({
    OverpassService? overpass,
    PoiRepository? poiRepo,
  })  : _overpass = overpass ?? OverpassService(),
        _poiRepo = poiRepo ?? PoiRepository();

  static const String _metaKey = 'place';

  final OverpassService _overpass;
  final PoiRepository _poiRepo;

  Future<OfflineRegion> download(
    Place place, {
    void Function(double percent)? onProgress,
  }) async {
    if (kIsWeb) {
      throw OfflineNotAvailable('Offline downloads are not supported on web.');
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
                onProgress(event.progress);
              } else if (event is Success) {
                onProgress(100);
              }
            },
    );

    // POI prefetch is best-effort. Tile download already succeeded; if
    // Overpass times out or rate-limits we just skip the POI index for this
    // region rather than rolling back the tiles.
    try {
      final List<OfflinePoi> pois = await _overpass.fetchPois(
        bbox: place.bbox,
        regionName: place.name,
        regionId: region.id,
      );
      await _poiRepo.savePoisForRegion(region.id, pois);
    } catch (e) {
      debugPrint('POI prefetch failed for region ${region.id}: $e');
    }

    return region;
  }

  Future<List<Place>> listDownloaded() async {
    if (kIsWeb) return const <Place>[];
    try {
      final List<OfflineRegion> regions = await getListOfRegions();
      final List<Place> out = [];
      for (final OfflineRegion r in regions) {
        final Place? p = _placeFromRegion(r);
        if (p != null) out.add(p);
      }
      return out;
    } catch (e, s) {
      debugPrint('listDownloaded failed: $e\n$s');
      return const <Place>[];
    }
  }

  Future<void> delete(int regionId) async {
    if (kIsWeb) return;
    try {
      await deleteOfflineRegion(regionId);
    } catch (e, s) {
      debugPrint('deleteOfflineRegion $regionId failed: $e\n$s');
    }
    // POI cleanup is independent — try it even if tile delete threw.
    await _poiRepo.deleteForRegion(regionId);
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
