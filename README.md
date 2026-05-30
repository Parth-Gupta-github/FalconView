# FalconView

FalconView is a tactical-style mapping app for field navigation. It puts an edge-to-edge map under your fingertips with a live coordinate readout (Decimal, DMS, MGRS, UTM), fast place search that works in downloaded regions even without internet, one-tap GPS recentering with a persistent location marker, and a four-tool action panel for dropping marks, measuring distance, and routing to a destination. FalconView is designed for situations where the map is the primary surface — clean, high-contrast, and built to stay useful when the network isn't.

## What's new

- **Offline routing** — TRACK now works without internet inside downloaded regions. The road graph is built locally from MVT tiles at download time and Dijkstra runs on-device.
- **MVT-based offline POIs** — place search no longer depends on Overpass for downloaded regions; POIs are extracted directly from the same MVT tiles used for the map.
- **Unified tile walk** — POIs and the road graph are now built in a single pass over each region's tiles, cutting download time and bandwidth.
- **Chunked DB writes + cached search handles** — large region indexes write in batches and reuse open SQLite handles, so search stays snappy even on big bounding boxes.
- **Region download UX** — the Downloaded tab now shows region size and data source per region.
- **Fly-to on marker tap** — tapping a marker animates the camera onto it.
- **Toast layout fix** — top-right toasts now sit below the pinned status badge so they no longer overlap the tier pill.
- **App-name consistency** — the FalconView name is now used uniformly across Dart, the web `<title>`, and the PWA manifest.
- **Pro-tier gating** — offline download and offline POI fallback are restricted to the Pro tier (see the Plans screen).

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

## Acknowledgements

FalconView's offline map stack stands on the shoulders of several open data and open source projects. We're grateful to the maintainers and contributors of each.

- **[OpenStreetMap](https://www.openstreetmap.org/copyright)** — the world map data underneath every tile. © OpenStreetMap contributors, licensed under the [Open Database License (ODbL)](https://opendatacommons.org/licenses/odbl/). Any derived rendering or routing FalconView produces is, in turn, an OSM-derived work.
- **[Planetiler](https://github.com/onthegomap/planetiler)** — the OSM-PBF → vector-tile compiler used by `tools/planetiler/generate` to produce the bundled offline basemap MBTiles. Apache 2.0. Authored by [Onthegomap](https://github.com/onthegomap) and contributors. Same tool used by OpenFreeMap upstream.
- **[OpenMapTiles schema](https://openmaptiles.org/schema/)** — the vector tile schema (the `transportation`, `poi`, `place`, `landcover`, `water`, etc. layers) that every part of FalconView reads from. Used under the project's permissive licensing terms; check [openmaptiles.org](https://openmaptiles.org) for current status if redistributing tiles.
- **[OpenFreeMap](https://openfreemap.org)** — the live tile host used for online rendering and as the source for online region downloads. Community-hosted by Zsolt Ero. Style: Liberty (derived).
- **[MBTiles 1.3 spec](https://github.com/mapbox/mbtiles-spec)** — the SQLite container format used for the bundled basemap and tile storage. Originally by Mapbox, now widely supported and de facto standard.
- **[MapLibre Native](https://github.com/maplibre/maplibre-native)** + **[`maplibre_gl`](https://pub.dev/packages/maplibre_gl)** — the renderer.
- **[OSRM](https://project-osrm.org/)**, **[Nominatim](https://nominatim.org/)** — online routing and geocoding fallbacks.

If you redistribute the app with bundled tiles generated by `tools/planetiler/generate`, you are redistributing an OSM-derived dataset and must comply with the **ODbL attribution + share-alike** requirements. Add a visible "© OpenStreetMap contributors" credit in the app's about/help screen.