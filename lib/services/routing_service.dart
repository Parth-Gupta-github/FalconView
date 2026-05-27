import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:maplibre_gl/maplibre_gl.dart';

class RouteResult {
  RouteResult({required this.geometry, required this.distanceMeters, required this.durationSeconds});

  final List<LatLng> geometry;
  final double distanceMeters;
  final double durationSeconds;
}

class RoutingException implements Exception {
  RoutingException(this.message);
  final String message;
  @override
  String toString() => message;
}

class RoutingService {
  RoutingService({http.Client? client, this.profile = 'driving'})
      : _client = client ?? http.Client();

  static const String _userAgent = 'FalconView/1.0 (contact: tarun@igismap.com)';
  static const String _host = 'router.project-osrm.org';

  final http.Client _client;
  final String profile;

  Future<RouteResult> route(LatLng from, LatLng to) async {
    final String coords =
        '${from.longitude},${from.latitude};${to.longitude},${to.latitude}';
    final Uri uri = Uri.https(_host, '/route/v1/$profile/$coords', <String, String>{
      'overview': 'full',
      'geometries': 'geojson',
      'alternatives': 'false',
      'steps': 'false',
    });

    final http.Response res = await _client.get(uri, headers: <String, String>{
      'User-Agent': _userAgent,
      'Accept': 'application/json',
    });
    if (res.statusCode != 200) {
      throw RoutingException('Routing failed (${res.statusCode})');
    }

    final Map<String, dynamic> body = jsonDecode(res.body) as Map<String, dynamic>;
    final String? code = body['code'] as String?;
    if (code != 'Ok') {
      throw RoutingException('No route found');
    }
    final List<dynamic> routes = (body['routes'] as List<dynamic>?) ?? const <dynamic>[];
    if (routes.isEmpty) {
      throw RoutingException('No route found');
    }
    final Map<String, dynamic> r = (routes.first as Map).cast<String, dynamic>();
    final Map<String, dynamic> geom = (r['geometry'] as Map).cast<String, dynamic>();
    final List<dynamic> coordsList = (geom['coordinates'] as List<dynamic>);
    final List<LatLng> points = coordsList.map<LatLng>((dynamic e) {
      final List<dynamic> pair = e as List<dynamic>;
      return LatLng((pair[1] as num).toDouble(), (pair[0] as num).toDouble());
    }).toList();

    return RouteResult(
      geometry: points,
      distanceMeters: (r['distance'] as num?)?.toDouble() ?? 0,
      durationSeconds: (r['duration'] as num?)?.toDouble() ?? 0,
    );
  }

  void dispose() => _client.close();
}
