# FalconMap

A Flutter port of the FalconMap Android app — an offline-capable tactical map
for Android and iOS, built on MapLibre Native with OpenStreetMap data. No paid
services, no API keys, no Google Play Services dependency.

## Features

- **Vector map** rendered by MapLibre Native using the free
  [OpenFreeMap](https://openfreemap.org/) Liberty style (OSM-derived tiles).
- **Live coordinate HUD** that updates with the map centre and cycles through
  four formats on long-press — Decimal, DMS, MGRS, UTM (WGS84 / Snyder series).
  The chosen format persists across restarts.
- **Distance + bearing readout** from the current GPS fix to a selected place
  or tapped marker (haversine + 8-point compass).
- **Search** via [Nominatim](https://nominatim.openstreetmap.org/) with 350 ms
  debounce and a custom User-Agent. Tap a result to fly the camera there.
- **Map interaction modes:**
  - **MARK** — drop persistent multi-pin markers.
  - **RULER** — measure great-circle distance between two tapped points.
  - **TRACK** — live road-routed path via OSRM, fed by the GPS position stream.
  - **CLR** — wipe all overlays and reset.
- **Offline regions** — download a place's bounding box at zoom 10–16 via
  MapLibre's built-in `OfflineManager`; downloaded regions are listed in the
  Downloaded tab and survive restarts. Progress (0–100 %) shows on the
  download button. Tap a downloaded entry to navigate to it in airplane mode.
- **GPS recenter + compass** FABs; map's default compass is hidden in favour of
  the in-app one that rotates with the map bearing and resets on tap.

## Tech stack

| Layer | Choice |
|---|---|
| Framework | Flutter (Dart 3) |
| Map engine | [`maplibre_gl`](https://pub.dev/packages/maplibre_gl) `^0.26.0` |
| Tile style | OpenFreeMap Liberty (`tiles.openfreemap.org/styles/liberty`) |
| Geocoding | Nominatim via `http` |
| Routing | OSRM public demo server |
| GPS | `geolocator` |
| Permissions | `permission_handler` |
| Preferences | `shared_preferences` |
| App icons | `flutter_launcher_icons` |

## Project layout

```
lib/
├── main.dart                       MaterialApp + system UI overlay setup
├── screens/
│   ├── map_screen.dart             MapLibreMap + overlays + mode dispatcher
│   └── search_screen.dart          Search / Downloaded tabs
├── widgets/
│   ├── action_panel.dart           MARK / TRACK / RULER / CLR row
│   ├── coord_card.dart             Coord HUD with format cycling
│   ├── compass_fab.dart            Compass mini-FAB
│   └── search_card.dart            Pill search card
├── services/
│   ├── location_service.dart       Geolocator wrapper + permission flow
│   ├── nominatim_service.dart      Debounced Nominatim client
│   ├── routing_service.dart        OSRM road-routing client
│   └── offline_repository.dart     OfflineManager wrapper + Place metadata
├── models/
│   └── place.dart                  Place + JSON helpers for offline metadata
├── util/
│   ├── geo_math.dart               Haversine + bearing + 8-point compass
│   └── coordinate_formatter.dart   Decimal / DMS / MGRS / UTM
└── theme/
    └── tactical_theme.dart         Material 3 light theme + palette
```

## Running

### Prerequisites

- Flutter SDK (stable channel, Dart 3+)
- For Android: emulator (API 24+) or device
- For iOS: Xcode + a Mac

### Setup

```sh
flutter pub get
```

### Android

```sh
flutter emulators --launch <your-emulator-id>
flutter run
```

### iOS

```sh
cd ios && pod install && cd ..
flutter run -d <ios-device-or-simulator>
```

### Web (dev loop)

Web is supported for quick UI iteration but is not the deployment target.
Limitations on web:
- `OfflineManager` is not available — downloads short-circuit with a snackbar.
- The blue dot requires the MapLibre GL JS `GeolocateControl`.

```sh
flutter run -d chrome
```

## Permissions

### Android (`android/app/src/main/AndroidManifest.xml`)

- `INTERNET`
- `ACCESS_NETWORK_STATE`
- `ACCESS_FINE_LOCATION`
- `ACCESS_COARSE_LOCATION`

### iOS (`ios/Runner/Info.plist`)

- `NSLocationWhenInUseUsageDescription`
- `NSLocationAlwaysAndWhenInUseUsageDescription`

## Coordinate formats

`CoordinateFormatter` produces:

| Format | Example (22.7196°N, 75.8577°E) |
|---|---|
| Decimal | `22.71960, 75.85770` |
| DMS | `22°43'10.6"N 75°51'27.7"E` |
| UTM (WGS84) | `43Q <easting> <northing>` |
| MGRS | `43Q <col><row> <easting5> <northing5>` |

UTM/MGRS fall back to Decimal outside −80°…+84° latitude. The math follows
Snyder's WGS84 transverse Mercator series (`a = 6 378 137`,
`f = 1/298.257223563`, `k0 = 0.9996`).

## License

OpenStreetMap data © OpenStreetMap contributors, available under the Open
Database License. Tiles © OpenFreeMap / OpenMapTiles.
