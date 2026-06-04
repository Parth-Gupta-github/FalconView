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
    try {
      // A live fix, time-boxed so it can't hang: on desktop (no GPS chip) the
      // OS resolves location from Wi-Fi/network, which never returns offline.
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 8),
        ),
      );
    } catch (_) {
      // Offline / no GPS hardware (e.g. macOS): fall back to the OS's
      // last-known position so offline TRACK/recenter still work.
      final Position? last = await Geolocator.getLastKnownPosition();
      if (last != null) return last;
      throw LocationDenied(
        'Could not determine your location. Offline location needs a recent '
        'fix — connect once to set it, then try again.',
      );
    }
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
