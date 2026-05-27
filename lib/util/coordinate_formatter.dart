import 'dart:math' as math;

enum CoordinateFormat { decimal, dms, mgrs, utm }

extension CoordinateFormatX on CoordinateFormat {
  CoordinateFormat next() {
    final List<CoordinateFormat> all = CoordinateFormat.values;
    return all[(index + 1) % all.length];
  }

  String get label {
    switch (this) {
      case CoordinateFormat.decimal:
        return 'Decimal';
      case CoordinateFormat.dms:
        return 'DMS';
      case CoordinateFormat.mgrs:
        return 'MGRS';
      case CoordinateFormat.utm:
        return 'UTM';
    }
  }
}

class CoordinateFormatter {
  const CoordinateFormatter._();

  static String format(double lat, double lon, CoordinateFormat fmt) {
    // Outside the UTM/MGRS valid band, fall back to Decimal.
    if ((fmt == CoordinateFormat.utm || fmt == CoordinateFormat.mgrs) &&
        (lat < -80 || lat > 84)) {
      return _formatDecimal(lat, lon);
    }
    switch (fmt) {
      case CoordinateFormat.decimal:
        return _formatDecimal(lat, lon);
      case CoordinateFormat.dms:
        return _formatDms(lat, lon);
      case CoordinateFormat.utm:
        return _formatUtm(lat, lon);
      case CoordinateFormat.mgrs:
        return _formatMgrs(lat, lon);
    }
  }

  static String _formatDecimal(double lat, double lon) {
    return '${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}';
  }

  static String _formatDms(double lat, double lon) {
    return '${_dmsPart(lat, isLat: true)} ${_dmsPart(lon, isLat: false)}';
  }

  static String _dmsPart(double value, {required bool isLat}) {
    final String hemi = isLat ? (value >= 0 ? 'N' : 'S') : (value >= 0 ? 'E' : 'W');
    double v = value.abs();
    final int deg = v.floor();
    v = (v - deg) * 60;
    final int min = v.floor();
    final double sec = (v - min) * 60;
    return "$deg°${min.toString().padLeft(2, '0')}'${sec.toStringAsFixed(1).padLeft(4, '0')}\"$hemi";
  }

  // ---------- UTM / MGRS (WGS84, Snyder series) ----------

  static const double _a = 6378137.0;
  static const double _f = 1 / 298.257223563;
  static const double _k0 = 0.9996;

  static _UtmResult _toUtm(double lat, double lon) {
    final double e2 = 2 * _f - _f * _f;
    final double ep2 = e2 / (1 - e2);

    final int zone = ((lon + 180) / 6).floor() + 1;
    final double lambda0 = ((zone - 1) * 6 - 180 + 3) * math.pi / 180.0;

    final double phi = lat * math.pi / 180.0;
    final double lambda = lon * math.pi / 180.0;

    final double sinPhi = math.sin(phi);
    final double cosPhi = math.cos(phi);
    final double tanPhi = math.tan(phi);

    final double N = _a / math.sqrt(1 - e2 * sinPhi * sinPhi);
    final double T = tanPhi * tanPhi;
    final double C = ep2 * cosPhi * cosPhi;
    final double A = cosPhi * (lambda - lambda0);

    final double M = _a *
        ((1 - e2 / 4 - 3 * e2 * e2 / 64 - 5 * e2 * e2 * e2 / 256) * phi -
            (3 * e2 / 8 + 3 * e2 * e2 / 32 + 45 * e2 * e2 * e2 / 1024) *
                math.sin(2 * phi) +
            (15 * e2 * e2 / 256 + 45 * e2 * e2 * e2 / 1024) * math.sin(4 * phi) -
            (35 * e2 * e2 * e2 / 3072) * math.sin(6 * phi));

    final double easting = _k0 *
            N *
            (A +
                (1 - T + C) * math.pow(A, 3) / 6 +
                (5 - 18 * T + T * T + 72 * C - 58 * ep2) * math.pow(A, 5) / 120) +
        500000.0;

    double northing = _k0 *
        (M +
            N *
                tanPhi *
                (A * A / 2 +
                    (5 - T + 9 * C + 4 * C * C) * math.pow(A, 4) / 24 +
                    (61 - 58 * T + T * T + 600 * C - 330 * ep2) *
                        math.pow(A, 6) / 720));

    if (lat < 0) {
      northing += 10000000.0;
    }

    return _UtmResult(
      zone: zone,
      latBand: _latBand(lat),
      easting: easting,
      northing: northing,
    );
  }

  static String _formatUtm(double lat, double lon) {
    final _UtmResult r = _toUtm(lat, lon);
    return '${r.zone}${r.latBand} ${r.easting.round()} ${r.northing.round()}';
  }

  static String _formatMgrs(double lat, double lon) {
    final _UtmResult r = _toUtm(lat, lon);
    final int eastingInt = r.easting.round();
    final int northingInt = r.northing.round();

    final String colLetter = _mgrsColumnLetter(r.zone, eastingInt);
    final String rowLetter = _mgrsRowLetter(r.zone, northingInt);

    final int eastingRemainder = eastingInt % 100000;
    final int northingRemainder = northingInt % 100000;
    final String eastingStr = eastingRemainder.toString().padLeft(5, '0');
    final String northingStr = northingRemainder.toString().padLeft(5, '0');

    return '${r.zone}${r.latBand} $colLetter$rowLetter $eastingStr $northingStr';
  }

  static String _latBand(double lat) {
    // 'X' is the 12°-wide band 72°…84° (CDEFGHJKLMNPQRSTUVWX, 20 bands of 8° each, plus X at the top).
    if (lat >= 72 && lat <= 84) return 'X';
    const String bands = 'CDEFGHJKLMNPQRSTUVW';
    final int idx = ((lat + 80) / 8).floor();
    if (idx < 0 || idx >= bands.length) return 'Z';
    return bands[idx];
  }

  static String _mgrsColumnLetter(int zone, int easting) {
    const String set1 = 'ABCDEFGH'; // zones 1,4,7,...  (zone-1) mod 3 == 0
    const String set2 = 'JKLMNPQR'; // zones 2,5,8,...
    const String set3 = 'STUVWXYZ'; // zones 3,6,9,...
    final String letters = switch ((zone - 1) % 3) {
      0 => set1,
      1 => set2,
      _ => set3,
    };
    final int colIdx = (easting ~/ 100000) - 1;
    return letters[colIdx.clamp(0, 7)];
  }

  static String _mgrsRowLetter(int zone, int northing) {
    // 20 row letters that cycle every 2,000,000m of northing.
    // Odd zones start at 'A', even zones at 'F' (offset by 10).
    const String rowLetters = 'ABCDEFGHJKLMNPQRSTUV';
    final int baseOffset = zone.isOdd ? 0 : 5;
    final int rowIdx = ((northing ~/ 100000) + baseOffset) % 20;
    return rowLetters[rowIdx];
  }
}

class _UtmResult {
  final int zone;
  final String latBand;
  final double easting;
  final double northing;
  const _UtmResult({
    required this.zone,
    required this.latBand,
    required this.easting,
    required this.northing,
  });
}
