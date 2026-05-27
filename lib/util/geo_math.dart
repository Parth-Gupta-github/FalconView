import 'dart:math' as math;

class GeoMath {
  const GeoMath._();

  static const double _earthRadiusMeters = 6371000.0;

  static double haversineMeters(double lat1, double lon1, double lat2, double lon2) {
    final double phi1 = _deg2rad(lat1);
    final double phi2 = _deg2rad(lat2);
    final double dPhi = _deg2rad(lat2 - lat1);
    final double dLambda = _deg2rad(lon2 - lon1);

    final double a = math.sin(dPhi / 2) * math.sin(dPhi / 2) +
        math.cos(phi1) * math.cos(phi2) *
            math.sin(dLambda / 2) * math.sin(dLambda / 2);
    final double c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return _earthRadiusMeters * c;
  }

  static double initialBearingDegrees(double lat1, double lon1, double lat2, double lon2) {
    final double phi1 = _deg2rad(lat1);
    final double phi2 = _deg2rad(lat2);
    final double dLambda = _deg2rad(lon2 - lon1);

    final double y = math.sin(dLambda) * math.cos(phi2);
    final double x = math.cos(phi1) * math.sin(phi2) -
        math.sin(phi1) * math.cos(phi2) * math.cos(dLambda);
    final double theta = math.atan2(y, x);
    final double deg = theta * 180.0 / math.pi;
    return (deg + 360.0) % 360.0;
  }

  static String formatDistance(double meters) {
    if (meters < 1000) {
      return '${meters.round()} m';
    }
    return '${(meters / 1000.0).toStringAsFixed(2)} km';
  }

  static String formatBearing(double degrees) {
    final double normalized = (degrees % 360 + 360) % 360;
    return '${normalized.round().toString().padLeft(3, '0')}° ${_compass8(normalized)}';
  }

  static String _compass8(double deg) {
    const List<String> labels = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
    final int idx = ((deg + 22.5) / 45).floor() % 8;
    return labels[idx];
  }

  static double _deg2rad(double d) => d * math.pi / 180.0;
}
