import '../models/offline_poi.dart';
import '../models/place.dart';
import 'offline_repository.dart';
import 'poi_repository.dart';

/// Offline place search across previously-downloaded regions.
///
/// Searches the per-region POI index built by `OverpassService` at download
/// time (name or category match), and also falls back to matching against
/// downloaded region names themselves so the user can still find "Indore"
/// offline even if the POI fetch failed for that region.
class OfflineGeocoder {
  OfflineGeocoder({
    PoiRepository? poiRepo,
    OfflineRepository? offline,
  })  : _poiRepo = poiRepo ?? PoiRepository(),
        _offline = offline ?? OfflineRepository();

  final PoiRepository _poiRepo;
  final OfflineRepository _offline;

  Future<List<Place>> search(String query, {int limit = 30}) async {
    final String q = query.trim().toLowerCase();
    if (q.isEmpty) return const <Place>[];

    final List<OfflinePoi> pois = await _poiRepo.search(q, limit: limit);
    final List<Place> results = pois.map(_poiToPlace).toList();

    if (results.length >= limit) return results;

    // Backfill with region name matches so the user can still find a downloaded
    // city by its own name even when its POI index is missing or empty.
    final List<Place> regions = await _offline.listDownloaded();
    for (final Place region in regions) {
      if (region.name.toLowerCase().contains(q) ||
          region.subtitle.toLowerCase().contains(q)) {
        results.add(region);
        if (results.length >= limit) break;
      }
    }
    return results;
  }

  Place _poiToPlace(OfflinePoi poi) {
    const double pad = 0.005; // ~500 m
    return Place(
      name: poi.name,
      subtitle: '${_humanCategory(poi.category)} · ${poi.regionName}',
      center: LatLng(poi.latitude, poi.longitude),
      bbox: LatLngBounds(
        southwest: LatLng(poi.latitude - pad, poi.longitude - pad),
        northeast: LatLng(poi.latitude + pad, poi.longitude + pad),
      ),
    );
  }

  String _humanCategory(String c) {
    if (c.startsWith('tourism:')) return c.substring(8);
    if (c.startsWith('shop:')) return c.substring(5);
    return c;
  }
}
