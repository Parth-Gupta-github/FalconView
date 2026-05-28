import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:maplibre_gl/maplibre_gl.dart';

import '../models/offline_poi.dart';

class OverpassException implements Exception {
  OverpassException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Fetches named POIs in a bbox from the public Overpass API.
///
/// Categories covered: hospital, school, clinic, college, university, police,
/// fuel, pharmacy, bank, tourism=hotel, shop=supermarket. Returns nodes, ways
/// and relations — for ways/relations the `center` coordinate (requested via
/// `out center`) is used as the POI location.
class OverpassService {
  OverpassService({http.Client? client}) : _client = client ?? http.Client();

  static const String _endpoint = 'https://overpass-api.de/api/interpreter';
  static const String _userAgent = 'FalconView/1.0 (contact: tarun@igismap.com)';
  static const Duration _timeout = Duration(seconds: 45);

  static const List<String> _amenities = <String>[
    'hospital', 'school', 'clinic', 'college', 'university',
    'police', 'fuel', 'pharmacy', 'bank',
  ];

  final http.Client _client;

  Future<List<OfflinePoi>> fetchPois({
    required LatLngBounds bbox,
    required String regionName,
    required int regionId,
  }) async {
    final double south = bbox.southwest.latitude;
    final double west = bbox.southwest.longitude;
    final double north = bbox.northeast.latitude;
    final double east = bbox.northeast.longitude;

    final String amenityRegex = _amenities.join('|');
    final String b = '$south,$west,$north,$east';
    final String query =
        '[out:json][timeout:30];'
        '('
        'node["amenity"~"^($amenityRegex)\$"]($b);'
        'way["amenity"~"^($amenityRegex)\$"]($b);'
        'relation["amenity"~"^($amenityRegex)\$"]($b);'
        'node["tourism"="hotel"]($b);'
        'way["tourism"="hotel"]($b);'
        'relation["tourism"="hotel"]($b);'
        'node["shop"="supermarket"]($b);'
        'way["shop"="supermarket"]($b);'
        'relation["shop"="supermarket"]($b);'
        ');'
        'out center tags;';

    final http.Response res = await _client
        .post(
          Uri.parse(_endpoint),
          headers: <String, String>{
            'User-Agent': _userAgent,
            'Content-Type': 'application/x-www-form-urlencoded',
          },
          body: <String, String>{'data': query},
        )
        .timeout(_timeout);

    if (res.statusCode != 200) {
      throw OverpassException('Overpass returned ${res.statusCode}');
    }

    final dynamic decoded = jsonDecode(res.body);
    if (decoded is! Map) {
      throw OverpassException('Overpass returned unexpected body');
    }
    final List<dynamic> elements =
        (decoded['elements'] as List<dynamic>?) ?? <dynamic>[];

    final List<OfflinePoi> out = <OfflinePoi>[];
    for (final dynamic raw in elements) {
      if (raw is! Map) continue;
      final OfflinePoi? p =
          _parseElement(raw.cast<String, dynamic>(), regionName, regionId);
      if (p != null) out.add(p);
    }
    return out;
  }

  OfflinePoi? _parseElement(
    Map<String, dynamic> el,
    String regionName,
    int regionId,
  ) {
    final String? type = el['type'] as String?;
    final int? id = (el['id'] as num?)?.toInt();
    if (type == null || id == null) return null;

    double? lat;
    double? lon;
    if (type == 'node') {
      lat = (el['lat'] as num?)?.toDouble();
      lon = (el['lon'] as num?)?.toDouble();
    } else {
      final Map<String, dynamic>? center =
          (el['center'] as Map?)?.cast<String, dynamic>();
      lat = (center?['lat'] as num?)?.toDouble();
      lon = (center?['lon'] as num?)?.toDouble();
    }
    if (lat == null || lon == null) return null;

    final Map<String, dynamic> tags =
        ((el['tags'] as Map?) ?? const <String, dynamic>{})
            .cast<String, dynamic>();
    final String? name = tags['name'] as String?;
    if (name == null || name.isEmpty) return null;

    final String? category = _extractCategory(tags);
    if (category == null) return null;

    return OfflinePoi(
      osmType: type,
      osmId: id,
      name: name,
      category: category,
      latitude: lat,
      longitude: lon,
      regionName: regionName,
      regionId: regionId,
    );
  }

  String? _extractCategory(Map<String, dynamic> tags) {
    final String? amenity = tags['amenity'] as String?;
    if (amenity != null && _amenities.contains(amenity)) return amenity;
    if (tags['tourism'] == 'hotel') return 'tourism:hotel';
    if (tags['shop'] == 'supermarket') return 'shop:supermarket';
    return null;
  }

  void dispose() => _client.close();
}
