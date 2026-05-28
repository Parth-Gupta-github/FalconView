import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:maplibre_gl/maplibre_gl.dart';

import '../models/place.dart';
import 'offline_search_index.dart';

class OfflineNotAvailable implements Exception {
  final String message;
  OfflineNotAvailable(this.message);
  @override
  String toString() => message;
}

class OfflineRepository {
  OfflineRepository({OfflineSearchIndex? index})
      : _index = index ?? OfflineSearchIndex();

  static const String _styleUrl = 'https://tiles.openfreemap.org/styles/liberty';
  static const double _minZoom = 10;
  static const double _maxZoom = 16;
  static const String _metaKey = 'place';

  final OfflineSearchIndex _index;

  OfflineSearchIndex get index => _index;

  Future<OfflineRegion> download(
    Place place, {
    void Function(double percent)? onProgress,
  }) async {
    if (kIsWeb) {
      throw OfflineNotAvailable('Offline downloads are not supported on web.');
    }
    final OfflineRegionDefinition definition = OfflineRegionDefinition(
      bounds: place.bbox,
      mapStyleUrl: _styleUrl,
      minZoom: _minZoom,
      maxZoom: _maxZoom,
    );
    final OfflineRegion region = await downloadOfflineRegion(
      definition,
      metadata: {_metaKey: jsonEncode(place.toJson())},
      onEvent: onProgress == null
          ? null
          : (DownloadRegionStatus event) {
              if (event is InProgress) {
                onProgress(event.progress * 0.7);
              } else if (event is Success) {
                onProgress(70);
              }
            },
    );
    try {
      await _index.build(
        region.id,
        place.bbox,
        onProgress: (double pct) {
          if (onProgress != null) onProgress(70 + pct * 0.3);
        },
      );
    } catch (e, stack) {
      // Tiles already downloaded successfully; the index failure shouldn't
      // fail the whole download. Surface the cause to logs so it's diagnosable.
      // ignore: avoid_print
      print('[OfflineSearchIndex.build] FAILED: $e\n$stack');
      if (onProgress != null) onProgress(100);
      _lastIndexError = '$e';
    }
    return region;
  }

  /// Set when the most recent download's index build threw. Null if the last
  /// build succeeded or no build has happened.
  String? _lastIndexError;
  String? get lastIndexError => _lastIndexError;

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
