class LatLng {
  final double latitude;
  final double longitude;
  const LatLng(this.latitude, this.longitude);
}

class LatLngBounds {
  final double south;
  final double north;
  final double west;
  final double east;
  const LatLngBounds({
    required this.south,
    required this.north,
    required this.west,
    required this.east,
  });
}

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
