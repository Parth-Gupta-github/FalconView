import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:maplibre_gl/maplibre_gl.dart';

import '../models/place.dart';

class OfflineNotAvailable implements Exception {
  final String message;
  OfflineNotAvailable(this.message);
  @override
  String toString() => message;
}

class OfflineRepository {
  static const String _styleUrl = 'https://tiles.openfreemap.org/styles/liberty';
  static const double _minZoom = 10;
  static const double _maxZoom = 16;
  static const String _metaKey = 'place';

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
    return downloadOfflineRegion(
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
