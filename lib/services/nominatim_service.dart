import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/place.dart';

class NominatimException implements Exception {
  NominatimException(this.message);
  final String message;
  @override
  String toString() => message;
}

class NominatimService {
  NominatimService({http.Client? client}) : _client = client ?? http.Client();

  static const String _endpoint = 'https://nominatim.openstreetmap.org/search';
  static const String _userAgent = 'FalconView/1.0 (contact: tarun@igismap.com)';

  final http.Client _client;

  Future<List<Place>> search(String query, {int limit = 10}) async {
    final String q = query.trim();
    if (q.isEmpty) return const <Place>[];

    final Uri uri = Uri.parse(_endpoint).replace(queryParameters: <String, String>{
      'q': q,
      'format': 'jsonv2',
      'addressdetails': '1',
      'limit': '$limit',
    });

    final http.Response res = await _client.get(uri, headers: <String, String>{
      'User-Agent': _userAgent,
      'Accept': 'application/json',
      'Accept-Language': 'en',
    });

    if (res.statusCode != 200) {
      throw NominatimException('Search failed (${res.statusCode})');
    }

    final dynamic decoded = jsonDecode(res.body);
    if (decoded is! List) return const <Place>[];

    final List<Place> places = <Place>[];
    for (final dynamic item in decoded) {
      if (item is! Map) continue;
      final Place? p = _parse(item.cast<String, dynamic>());
      if (p != null) places.add(p);
    }
    return places;
  }

  Place? _parse(Map<String, dynamic> json) {
    final double? lat = _toDouble(json['lat']);
    final double? lon = _toDouble(json['lon']);
    if (lat == null || lon == null) return null;

    final List<dynamic>? bb = json['boundingbox'] as List<dynamic>?;
    LatLngBounds bounds;
    if (bb != null && bb.length == 4) {
      final double south = _toDouble(bb[0]) ?? lat;
      final double north = _toDouble(bb[1]) ?? lat;
      final double west = _toDouble(bb[2]) ?? lon;
      final double east = _toDouble(bb[3]) ?? lon;
      bounds = LatLngBounds(
        southwest: LatLng(south, west),
        northeast: LatLng(north, east),
      );
    } else {
      const double d = 0.05;
      bounds = LatLngBounds(
        southwest: LatLng(lat - d, lon - d),
        northeast: LatLng(lat + d, lon + d),
      );
    }

    final String display = (json['display_name'] as String?) ?? '';
    final String name = _shortName(json, display);
    final String subtitle = _subtitle(display, name);

    return Place(
      name: name,
      subtitle: subtitle,
      center: LatLng(lat, lon),
      bbox: bounds,
    );
  }

  String _shortName(Map<String, dynamic> json, String display) {
    final String? name = json['name'] as String?;
    if (name != null && name.isNotEmpty) return name;
    final int comma = display.indexOf(',');
    return comma == -1 ? display : display.substring(0, comma);
  }

  String _subtitle(String display, String name) {
    if (display.isEmpty) return '';
    if (display.startsWith('$name, ')) return display.substring(name.length + 2);
    return display;
  }

  double? _toDouble(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  void dispose() => _client.close();
}
