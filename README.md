# FalconView

A Flutter map application built on MapLibre GL with OpenFreeMap Liberty tiles. Tactical-style UI with edge-to-edge map rendering, live coordinate readout, place search, GPS recenter, and a four-tool action panel for marking, measuring, and routing.

## Features

- **Edge-to-edge map** — MapLibre GL with the OpenFreeMap Liberty vector style, transparent system bars on Android and iOS so the map renders behind the status bar and gesture pill.
- **Live coordinate card** — shows the map-centre coordinates in four formats (Decimal, DMS, MGRS, UTM). Long-press to cycle on mobile, double-click on desktop. Choice persists via `shared_preferences`.
- **Place search** — Nominatim-backed live search with a 350 ms debounce, custom User-Agent, and stale-response guarding. Tapping a result flies the camera and shows distance + compass bearing from the user's GPS to the selected place.
- **Offline regions** — a Downloaded tab in the search screen for managing locally cached regions.
- **Compass FAB** — red-needle north indicator that animates the map back to north-up with tilt reset.
- **GPS FAB** — recenters the camera on the user and drops a persistent blue halo + dot at the precise location.
- **MARK** — toggle mode where each map tap drops a red location-pin symbol.
- **RULER** — tap two points to draw a dashed red line and read out the haversine distance.
- **TRACK** — tap a destination; the app fetches your current GPS and queries OSRM's public routing API to draw the actual road path between you and the target. Stale-request cancellation prevents older responses from overwriting newer ones.
- **CLR** — wipes all temporary overlays.
- **Top-right toasts** — alerts surface as compact toasts below the search bar so they never overlap the action panel.
- **Gesture isolation** — Flutter overlays absorb double-tap and pinch over their bounds, so map zoom no longer fires when interacting with buttons. A rect filter on `onMapClick` blocks phantom map taps under the overlays.

## Tech stack

- **Flutter** (Dart SDK ^3.12)
- **maplibre_gl** — vector map rendering
- **geolocator** + **permission_handler** — location services
- **http** — Nominatim search, OSRM routing
- **shared_preferences** — persisting the coordinate-format choice
- **OpenFreeMap** Liberty style tiles (no API key required)
- **OSRM** public demo server for routing (no API key required; see *Production notes*)
- **Nominatim** for geocoding (custom User-Agent, no API key required)

## Project layout

```
lib/
├── main.dart                       # App entry + edge-to-edge setup
├── theme/tactical_theme.dart       # Color palette and ThemeData
├── models/
│   └── place.dart                  # Place model (search results)
├── services/
│   ├── location_service.dart       # Permission + current-position
│   ├── nominatim_service.dart      # Geocoding client
│   ├── routing_service.dart        # OSRM client
│   └── offline_repository.dart     # Saved-region persistence
├── util/
│   ├── coordinate_formatter.dart   # Decimal / DMS / MGRS / UTM
│   └── geo_math.dart               # Haversine, bearing, formatters
├── widgets/
│   ├── action_panel.dart           # MARK / TRACK / RULER / CLR row
│   ├── compass_fab.dart            # North-needle button
│   ├── coord_card.dart             # Coord + distance/bearing card
│   └── search_card.dart            # Top search bar
└── screens/
    ├── map_screen.dart             # Main map + all overlays
    └── search_screen.dart          # Search + Downloaded tabs
```

## Getting started

### Prerequisites
- Flutter 3.x (Dart ^3.12)
- Android Studio / Xcode for mobile targets
- A device or emulator with GPS

### Install and run

```bash
git clone https://github.com/Parth-Gupta-github/FalconView.git
cd FalconView
flutter pub get
flutter run
```

### Permissions

The app requests fine + coarse location. On first run the OS will prompt; the permission strings live at:

- **Android**: [android/app/src/main/AndroidManifest.xml](android/app/src/main/AndroidManifest.xml)
- **iOS**: [ios/Runner/Info.plist](ios/Runner/Info.plist) (`NSLocationWhenInUseUsageDescription`)

## Building

### Android
```bash
flutter build appbundle           # for Play Store
flutter build apk --split-per-abi # for sideloading
```
Sign with your release keystore (`android/key.properties`) — see [Flutter Android deployment docs](https://docs.flutter.dev/deployment/android).

### iOS
```bash
flutter build ipa
```
Requires a Mac with Xcode and an Apple Developer account.

### Web
```bash
flutter build web --release
```
Output at `build/web/`. Note: `/build/` is gitignored. Deploy via a host that builds in CI (GitHub Pages via Actions, Cloudflare Pages, Netlify, Vercel) or `firebase deploy`.

### Desktop
```bash
flutter build windows
flutter build macos
flutter build linux
```

### App icon

The launcher icon lives at `assets/icon/icon.png` and is generated for every platform via [`flutter_launcher_icons`](https://pub.dev/packages/flutter_launcher_icons):

```bash
dart run flutter_launcher_icons
```

## Production notes

The current build uses free, anonymous third-party services that are fine for development but will throttle or block under real traffic:

- **OpenFreeMap** tiles — community-hosted; consider self-hosting or a paid tile provider for production.
- **OSRM** at `router.project-osrm.org` — public demo with a soft ~1 req/sec limit and no SLA. Swap in OpenRouteService, Mapbox Directions, GraphHopper, or self-hosted OSRM before going public.
- **Nominatim** at `nominatim.openstreetmap.org` — requires a descriptive User-Agent (already set) and is rate-limited to ~1 req/sec. Use a hosted geocoding provider for production.

A privacy policy URL is mandatory on both stores once the app requests location.