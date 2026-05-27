import 'package:maplibre_gl/maplibre_gl.dart';

export 'package:maplibre_gl/maplibre_gl.dart' show LatLng, LatLngBounds;

enum PlaceDownloadState { none, downloading, downloaded }

class Place {
  final String name;
  final String subtitle;
  final LatLng center;
  final LatLngBounds bbox;
  PlaceDownloadState state;
  double downloadProgress;
  final int? regionId;

  Place({
    required this.name,
    required this.subtitle,
    required this.center,
    required this.bbox,
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
  };

  factory Place.fromJson(Map<String, dynamic> json, {int? regionId}) {
    final double south = (json['south'] as num).toDouble();
    final double west = (json['west'] as num).toDouble();
    final double north = (json['north'] as num).toDouble();
    final double east = (json['east'] as num).toDouble();
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
      state: PlaceDownloadState.downloaded,
      regionId: regionId,
    );
  }
}
