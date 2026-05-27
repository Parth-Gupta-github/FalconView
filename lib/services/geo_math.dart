import 'dart:math' as math;

import 'package:maplibre_gl/maplibre_gl.dart';

double haversineMeters(LatLng a, LatLng b) {
  const double earthRadius = 6371000.0;
  final double lat1 = a.latitude * math.pi / 180;
  final double lat2 = b.latitude * math.pi / 180;
  final double dLat = (b.latitude - a.latitude) * math.pi / 180;
  final double dLon = (b.longitude - a.longitude) * math.pi / 180;
  final double h = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1) * math.cos(lat2) * math.sin(dLon / 2) * math.sin(dLon / 2);
  return 2 * earthRadius * math.asin(math.sqrt(h));
}

String formatDistance(double meters) {
  if (meters < 1000) return '${meters.toStringAsFixed(0)} m';
  return '${(meters / 1000).toStringAsFixed(2)} km';
}
