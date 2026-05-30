/// Result of a successful coordinate parse — the decimal-degree (lat, lon)
/// pair and a label describing which format the parser recognised it as.
class CoordinateMatch {
  const CoordinateMatch({
    required this.lat,
    required this.lon,
    required this.formatLabel,
  });

  final double lat;
  final double lon;

  /// User-visible label, e.g. "Decimal" or "DMS". Surfaced as the subtitle
  /// of the synthetic search result.
  final String formatLabel;
}

/// Detects pasted / typed coordinates in the search input.
///
/// Tries DMS first (it has stronger structural markers — `°`, `'`, `"`, and
/// a cardinal hemisphere letter), then falls back to Decimal. Returns null
/// when the input doesn't look like a coordinate at all so the caller can
/// fall through to a place-name search.
///
/// MGRS and UTM detection is intentionally out of scope here — they require
/// an inverse projection round-trip, which is a separate change.
class CoordinateParser {
  const CoordinateParser._();

  static CoordinateMatch? tryParse(String input) {
    final String s = input.trim();
    if (s.isEmpty) return null;
    return _tryDms(s) ?? _tryDecimal(s);
  }

  // ---------- Decimal ----------

  /// Accepts things people commonly paste from Google Maps, OSM, etc.:
  ///   "43.74, 7.42"          comma-separated
  ///   "43.74,7.42"           no space after comma
  ///   "43.74 7.42"           space-separated
  ///   "-23.5  175.0"         negatives
  ///   "43.74°N 7.42°E"       cardinals
  ///   "43.74°N, 7.42°E"      cardinals + comma
  ///
  /// Rejects bare integer pairs like "8 8" — those are too easy to confuse
  /// with regular search queries. We require at least one strong signal:
  /// a decimal point, a `°`, or a cardinal letter.
  static CoordinateMatch? _tryDecimal(String s) {
    final bool hasDegreeMark = s.contains('°');
    final bool hasCardinal =
        RegExp(r'[NSEW]', caseSensitive: false).hasMatch(s);

    // Capture which number carries which hemisphere BEFORE stripping the
    // cardinal letters. We look for a digit (or digit+space) immediately
    // followed by N/S → that's the lat hemi; same for E/W → lon hemi.
    final Match? latHemiMatch =
        RegExp(r'\d\s*([NS])', caseSensitive: false).firstMatch(s);
    final Match? lonHemiMatch =
        RegExp(r'\d\s*([EW])', caseSensitive: false).firstMatch(s);

    final String cleaned = s
        .replaceAll('°', ' ')
        .replaceAll(',', ' ')
        .replaceAll(RegExp(r'[NSEWnsew]'), ' ')
        .trim();

    final List<double> nums = RegExp(r'[-+]?\d+(?:\.\d+)?')
        .allMatches(cleaned)
        .map((Match m) => double.parse(m.group(0)!))
        .toList();
    if (nums.length != 2) return null;

    final bool hasDecimalPoint =
        nums.any((double n) => n != n.truncateToDouble());
    if (!hasDecimalPoint && !hasDegreeMark && !hasCardinal) return null;

    double lat = nums[0];
    double lon = nums[1];

    if (latHemiMatch != null) {
      final String hemi = latHemiMatch.group(1)!.toUpperCase();
      lat = hemi == 'S' ? -lat.abs() : lat.abs();
    }
    if (lonHemiMatch != null) {
      final String hemi = lonHemiMatch.group(1)!.toUpperCase();
      lon = hemi == 'W' ? -lon.abs() : lon.abs();
    }

    if (!_validRange(lat, lon)) return null;
    return CoordinateMatch(lat: lat, lon: lon, formatLabel: 'Decimal');
  }

  // ---------- DMS ----------

  /// Accepts widely-seen DMS variants:
  ///   43°44'24.0"N 7°25'12.0"E      what the formatter outputs
  ///   43° 44' 24" N 7° 25' 12" E    with spaces
  ///   43°44'N 7°25'E                no seconds
  ///   43d44m24sN 7d25m12sE          rare letter-based form
  ///
  /// Requires a cardinal letter on each component to avoid false positives.
  static CoordinateMatch? _tryDms(String s) {
    final RegExp dmsRe = RegExp(
      // deg [°d] (min [′’'m])? (sec [″”"s])? cardinal
      r"(\d+(?:\.\d+)?)\s*[°d]\s*"
      r"(?:(\d+(?:\.\d+)?)\s*[′’'m]\s*)?"
      r'(?:(\d+(?:\.\d+)?)\s*[″”"s]\s*)?'
      r'([NSEW])',
      caseSensitive: false,
    );
    final List<Match> matches = dmsRe.allMatches(s).toList();
    if (matches.length < 2) return null;

    final double a = _dmsMatchToDeg(matches[0]);
    final double b = _dmsMatchToDeg(matches[1]);
    final String hemiA = matches[0].group(4)!.toUpperCase();
    final String hemiB = matches[1].group(4)!.toUpperCase();

    // First match might be lon-then-lat ("7°25'E 43°44'N"); be permissive
    // and assign by hemisphere class rather than order.
    double? lat;
    double? lon;
    if (hemiA == 'N' || hemiA == 'S') lat = a;
    if (hemiA == 'E' || hemiA == 'W') lon = a;
    if (hemiB == 'N' || hemiB == 'S') lat = b;
    if (hemiB == 'E' || hemiB == 'W') lon = b;
    if (lat == null || lon == null) return null;

    if (!_validRange(lat, lon)) return null;
    return CoordinateMatch(lat: lat, lon: lon, formatLabel: 'DMS');
  }

  static double _dmsMatchToDeg(Match m) {
    final double deg = double.parse(m.group(1)!);
    final double min =
        m.group(2) != null ? double.parse(m.group(2)!) : 0;
    final double sec =
        m.group(3) != null ? double.parse(m.group(3)!) : 0;
    final String hemi = m.group(4)!.toUpperCase();
    final double abs = deg + min / 60 + sec / 3600;
    return (hemi == 'S' || hemi == 'W') ? -abs : abs;
  }

  static bool _validRange(double lat, double lon) =>
      lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180;
}
