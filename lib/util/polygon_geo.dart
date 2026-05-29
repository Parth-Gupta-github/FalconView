import 'package:maplibre_gl/maplibre_gl.dart';

/// Geometry helpers for the user-drawn download area.
///
/// The polygon is a simple (non-self-intersecting is assumed) ring of
/// `LatLng` vertices in tap order; the closing edge back to the first vertex
/// is implicit — callers do not need to repeat it.
class PolygonGeo {
  const PolygonGeo._();

  /// Ray-casting point-in-polygon test. `lat`/`lon` are treated as y/x.
  /// Returns false for degenerate polygons (< 3 vertices).
  static bool contains(List<LatLng> polygon, double lat, double lon) {
    final int n = polygon.length;
    if (n < 3) return false;
    bool inside = false;
    for (int i = 0, j = n - 1; i < n; j = i++) {
      final double yi = polygon[i].latitude;
      final double xi = polygon[i].longitude;
      final double yj = polygon[j].latitude;
      final double xj = polygon[j].longitude;
      final bool crosses = (yi > lat) != (yj > lat) &&
          lon < (xj - xi) * (lat - yi) / (yj - yi) + xi;
      if (crosses) inside = !inside;
    }
    return inside;
  }

  /// Axis-aligned bounding box enclosing every vertex. Throws on an empty
  /// list — callers should guard for that case.
  static LatLngBounds boundsOf(List<LatLng> polygon) {
    double minLat = polygon.first.latitude;
    double maxLat = polygon.first.latitude;
    double minLon = polygon.first.longitude;
    double maxLon = polygon.first.longitude;
    for (final LatLng p in polygon) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLon) minLon = p.longitude;
      if (p.longitude > maxLon) maxLon = p.longitude;
    }
    return LatLngBounds(
      southwest: LatLng(minLat, minLon),
      northeast: LatLng(maxLat, maxLon),
    );
  }

  /// Simple vertex-average centroid — good enough for placing a label/marker.
  static LatLng centroidOf(List<LatLng> polygon) {
    double sumLat = 0;
    double sumLon = 0;
    for (final LatLng p in polygon) {
      sumLat += p.latitude;
      sumLon += p.longitude;
    }
    final int n = polygon.length;
    return LatLng(sumLat / n, sumLon / n);
  }
}
