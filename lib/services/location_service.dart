import 'package:geolocator/geolocator.dart';

class LocationDenied implements Exception {
  final String message;
  LocationDenied(this.message);
  @override
  String toString() => message;
}

class LocationService {
  Future<void> _ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw LocationDenied('Location services are disabled. Enable them in settings.');
    }

    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.deniedForever) {
      throw LocationDenied('Location permission permanently denied. Grant it in app settings.');
    }
    if (perm == LocationPermission.denied) {
      throw LocationDenied('Location permission denied.');
    }
  }

  Future<Position> currentPosition() async {
    await _ensurePermission();
    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    );
  }

  Future<Stream<Position>> positionStream({int distanceFilterMeters = 5}) async {
    await _ensurePermission();
    return Geolocator.getPositionStream(
      locationSettings: LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: distanceFilterMeters,
      ),
    );
  }
}
