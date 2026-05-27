import 'package:maplibre_gl/maplibre_gl.dart';

export 'package:maplibre_gl/maplibre_gl.dart' show LatLng, LatLngBounds;

enum PlaceDownloadState { none, downloading, downloaded }

class Place {
  final String name;
  final String subtitle;
  final LatLng center;
  final LatLngBounds bbox;
  PlaceDownloadState state;

  Place({
    required this.name,
    required this.subtitle,
    required this.center,
    required this.bbox,
    this.state = PlaceDownloadState.none,
  });
}
