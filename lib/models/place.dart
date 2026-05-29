import 'package:maplibre_gl/maplibre_gl.dart';

export 'package:maplibre_gl/maplibre_gl.dart' show LatLng, LatLngBounds;

enum PlaceDownloadState { none, downloading, downloaded }

class Place {
  final String name;
  final String subtitle;
  final LatLng center;
  final LatLngBounds bbox;

  /// Optional user-drawn download area. When set, the offline download still
  /// fetches the rectangular [bbox] of map tiles (tiles are square), but the
  /// POI index and road graph are clipped to points inside this polygon. Null
  /// for plain rectangular (search-result) regions.
  final List<LatLng>? polygon;

  PlaceDownloadState state;
  double downloadProgress;
  final int? regionId;

  Place({
    required this.name,
    required this.subtitle,
    required this.center,
    required this.bbox,
    this.polygon,
    this.state = PlaceDownloadState.none,
    this.downloadProgress = 0,
    this.regionId,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'subtitle': subtitle,
    'centerLat': center.latitude,
    'centerLng': center.longitude,
    'south': bbox.southwest.latitude,
    'west': bbox.southwest.longitude,
    'north': bbox.northeast.latitude,
    'east': bbox.northeast.longitude,
    if (polygon != null)
      'polygon': polygon!
          .map((LatLng p) => <double>[p.longitude, p.latitude])
          .toList(),
  };

  factory Place.fromJson(Map<String, dynamic> json, {int? regionId}) {
    final double south = (json['south'] as num).toDouble();
    final double west = (json['west'] as num).toDouble();
    final double north = (json['north'] as num).toDouble();
    final double east = (json['east'] as num).toDouble();
    List<LatLng>? polygon;
    final dynamic rawPolygon = json['polygon'];
    if (rawPolygon is List && rawPolygon.isNotEmpty) {
      polygon = rawPolygon
          .whereType<List>()
          .where((List<dynamic> p) => p.length >= 2)
          .map((List<dynamic> p) =>
              LatLng((p[1] as num).toDouble(), (p[0] as num).toDouble()))
          .toList();
    }
    return Place(
      name: json['name'] as String,
      subtitle: json['subtitle'] as String,
      center: LatLng(
        (json['centerLat'] as num).toDouble(),
        (json['centerLng'] as num).toDouble(),
      ),
      bbox: LatLngBounds(
        southwest: LatLng(south, west),
        northeast: LatLng(north, east),
      ),
      polygon: polygon,
      state: PlaceDownloadState.downloaded,
      regionId: regionId,
    );
  }
}
