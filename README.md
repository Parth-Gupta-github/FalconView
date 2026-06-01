# FalconView

FalconView is a tactical-style mapping app for field navigation. It puts an edge-to-edge map under your fingertips with a live coordinate readout (Decimal, DMS, MGRS, UTM), fast place search that works in downloaded regions even without internet, one-tap GPS recentering with a persistent location marker, and a five-tool action panel for dropping marks, measuring distance, routing to a destination, and drawing custom download areas. FalconView is designed for situations where the map is the primary surface — clean, high-contrast, and built to stay useful when the network isn't.

## What's new

- **Bundled offline basemap** — a Planetiler-generated `world.mbtiles` ships inside the app and is served by a tiny localhost HTTP server, so the map never goes blank when offline with no region downloaded.
- **Bundled place index** — administrative place search (countries, states, cities, towns) works fully offline by reading the `place` layer out of the bundled MBTiles. Replaces Nominatim for the most common name → place lookups.
- **Custom area downloads** — AREA mode lets the user tap a polygon on the map; the offline download fetches the rectangular tile bbox but the POI index and road graph are clipped to points inside the polygon.
- **Whole-country aggregate pack** — typing "us" / "usa" pins a synthetic United States Place above Nominatim's results for a single-tap CONUS + Alaska + Hawaii pack.
- **Google-Maps-like style** — both tiers render a custom JSON style (`assets/styles/falconview_streets.json`) with a Google-leaning palette for land, water, parks, motorways, and buildings.
- **City-scale presets via Geofabrik state extracts** — dev iteration on POI indexing now downloads ~16× less than the previous country-wide PBF.
- **Dev-mode Pro checkout** — `PaymentScreen` mocks a UPI / card flow and flips the tier on success. Swap `_simulatePayment` for a real PSP SDK later.
- **Tier pill as an upgrade CTA** — the top-right pill now shows **UPGRADE** (lock icon) on Free and **PRO** (premium icon) on Pro, and reliably rebuilds when the tier changes.
- **Per-region size + POI source chip** — the Downloaded tab shows pack size and whether POIs came from MVT or are missing.

## Features

- **Edge-to-edge map** — MapLibre GL with a custom Google-leaning streets style, transparent system bars on Android and iOS so the map renders behind the status bar and gesture pill.
- **Offline-first rendering** — when the device is online MapLibre pulls from OpenFreeMap; when it isn't, the bundled `world.mbtiles` is served over localhost so the canvas is never blank.
- **Live coordinate card** — shows the map-centre coordinates in four formats (Decimal, DMS, MGRS, UTM). Long-press to cycle on mobile, double-click on desktop. Choice persists via `shared_preferences`.
- **Hybrid place search**
  - **Online**: Nominatim with 350 ms debounce, custom User-Agent, and stale-response guarding.
  - **Offline (bundled)**: countries, states, cities, towns, villages, suburbs out of the bundled MBTiles `place` layer.
  - **Offline (downloaded regions)**: POIs (restaurants, shops, services) out of the per-region MVT-derived SQLite index.
- **Offline regions** — Downloaded tab in the search screen for managing locally cached packs; each row shows size and POI source.
- **Compass FAB** — red-needle north indicator that animates the map back to north-up with tilt reset.
- **GPS FAB** — recenters the camera on the user and drops a persistent blue halo + dot at the precise location.
- **MARK** — toggle mode where each map tap drops a red location-pin symbol.
- **RULER** — tap two points to draw a dashed red line and read out the haversine distance.
- **TRACK** — tap a destination; the app routes from your current GPS to the target. Uses OSRM online; falls back to the per-region offline road graph (Dijkstra over MVT-extracted edges) when offline. Stale-request cancellation prevents older responses from overwriting newer ones.
- **AREA** — tap to drop polygon vertices for a custom download bbox; POI index + road graph are clipped to points-in-polygon.
- **CLR** — wipes all temporary overlays.
- **Tier pill** — top-right indicator; **UPGRADE** on Free taps into the Plans screen, **PRO** on Pro acts as a status badge.
- **Plans + Payment** — Plans screen lists Free and Pro feature deltas; Pro upgrade pushes the dev-mode `PaymentScreen` which mocks UPI / card processing and flips the tier on success.
- **Top-right toasts** — alerts surface as compact toasts below the search bar so they never overlap the action panel.
- **Gesture isolation** — Flutter overlays absorb double-tap and pinch over their bounds, so map zoom no longer fires when interacting with buttons. A rect filter on `onMapClick` blocks phantom map taps under the overlays.

## Tech stack

- **Flutter** (Dart SDK ^3.12)
- **maplibre_gl** — vector map rendering
- **geolocator** + **permission_handler** — location services
- **http** — Nominatim search, OSRM routing, MVT tile fetches for offline index builds
- **shared_preferences** — coord-format choice, tier, POI source per region
- **sqflite** + **sqflite_common_ffi** — bundled MBTiles, per-region POI index, road graph
- **vector_tile** — MVT decode for POI / road / place extraction
- **archive** — gzip decompression of MVT payloads
- **path** + **path_provider** — writable directory resolution for indexes and the materialized MBTiles
- **collection** — priority queue used by the offline Dijkstra router
- **Planetiler** (off-device, JVM) — generates the bundled `world.mbtiles` (see [tools/planetiler/README.md](tools/planetiler/README.md))
- **OpenFreeMap** Liberty tiles — online rendering and source for region downloads (no API key)
- **OSRM** public demo server — online routing (no API key; see *Production notes*)
- **Nominatim** — online geocoding fallback (custom User-Agent, no API key)

## Project layout

```
lib/
├── main.dart                          # App entry + edge-to-edge + service boot
├── theme/tactical_theme.dart          # Color palette and ThemeData
├── models/
│   ├── app_tier.dart                  # Free / Pro enum
│   └── place.dart                     # Place model (search results + polygon clip)
├── services/
│   ├── location_service.dart          # Permission + current-position
│   ├── nominatim_service.dart         # Online geocoding client
│   ├── routing_service.dart           # Online OSRM client
│   ├── subscription_service.dart      # Tier state (persisted)
│   ├── tile_config.dart               # Per-tier style URL + zoom limits
│   ├── tile_cache_locator.dart        # MethodChannel → native offline DB path
│   ├── bundled_basemap_server.dart    # 127.0.0.1 HTTP server vending bundled tiles
│   ├── bundled_place_index.dart       # FTS5 over the bundled MBTiles place layer
│   ├── offline_repository.dart        # Per-region download + route + search facade
│   ├── offline_search_index.dart      # MVT → POI SQLite per region
│   └── offline_router.dart            # MVT → road graph + Dijkstra
├── util/
│   ├── coordinate_formatter.dart      # Decimal / DMS / MGRS / UTM
│   ├── geo_math.dart                  # Haversine, bearing, formatters
│   ├── tile_math.dart                 # Tile enumeration + size estimates
│   └── polygon_geo.dart               # Point-in-polygon + bbox
├── widgets/
│   ├── action_panel.dart              # MARK / RULER / TRACK / AREA / CLR row
│   ├── compass_fab.dart               # North-needle button
│   ├── coord_card.dart                # Coord + distance/bearing card
│   └── search_card.dart               # Top search bar
└── screens/
    ├── map_screen.dart                # Main map + all overlays + AREA polygon UI
    ├── search_screen.dart             # Search + Downloaded tabs
    ├── plans_screen.dart              # Free vs Pro feature comparison
    └── payment_screen.dart            # Dev-mode UPI / card checkout

assets/
├── basemap/                           # Bundled world.mbtiles (not committed)
├── styles/
│   ├── falconview_streets.json        # Google-leaning vector style (online + downloaded regions)
│   └── falconview_offline.json        # Same schema, tile source patched to 127.0.0.1
└── icon/icon.png

tools/
└── planetiler/                        # World MBTiles generator (see its README)
    ├── generate.ps1                   # Windows entry point
    ├── generate.sh                    # macOS / Linux entry point
    ├── README.md
    └── .cache/                        # Cached Planetiler JAR + OSM PBFs (gitignored)
```

## Getting started

### Prerequisites
- Flutter 3.x (Dart ^3.12)
- Android Studio / Xcode for mobile targets
- A device or emulator with GPS
- **(Optional but recommended)** Java 21+ for the Planetiler basemap generator

### Install and run

```bash
git clone https://github.com/Parth-Gupta-github/FalconView.git
cd FalconView
flutter pub get

# Optional: build the bundled offline basemap (~5–15 min, ~80–250 MB).
# Skip this and the app still runs — it just won't have an offline canvas
# when no region is downloaded.
cd tools/planetiler
./generate.ps1   # Windows
./generate.sh    # macOS / Linux
cd ../..

flutter run
```

See [tools/planetiler/README.md](tools/planetiler/README.md) for details on customizing the bundled area / zoom range and refreshing the bundle when OSM drifts.

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
Output at `build/web/`. Note: the bundled-basemap server, per-region offline downloads, and offline router are all `dart:io`-dependent and are no-ops on web — web stays fully online.

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

## How offline works

FalconView's offline stack has three independent layers; each can be present or missing without breaking the others:

1. **Bundled basemap** (`assets/basemap/world.mbtiles`) — z0–6 vector tiles for the whole planet (or a smaller dev area). Vended by `BundledBasemapServer` on `http://127.0.0.1:<port>/{z}/{x}/{y}.pbf` so MapLibre can render even with no internet and no downloaded region. ~80–250 MB, generated off-device by Planetiler.
2. **Bundled place index** — an FTS5 SQLite built once on first launch from the bundled MBTiles' `place` layer. Powers "Mumbai", "California", etc. without network. Stored at `<appDocs>/bundled_places.db`.
3. **Per-region downloaded packs** (Pro) — the user picks a search result, optionally draws an AREA polygon to clip the bbox, and downloads:
   - MapLibre Native's offline tile cache (z10–14 free, z10–16 pro)
   - A per-region SQLite at `<appDocs>/region_indexes/<id>.db` containing POIs (decoded from the `poi` + `place` layers) and the road graph (decoded from the `transportation` layer)

The Plans screen gates downloads to Pro; the dev-mode Payment screen flips the tier on a faked checkout for testing.

## Production notes

The current build uses free, anonymous third-party services that are fine for development but will throttle or block under real traffic:

- **OpenFreeMap** tiles — community-hosted; consider self-hosting or a paid tile provider for production. Note the bundled basemap removes the *cold-start blank-canvas* failure mode but downloaded regions still pull initial tiles from OpenFreeMap.
- **OSRM** at `router.project-osrm.org` — public demo with a soft ~1 req/sec limit and no SLA. Swap in OpenRouteService, Mapbox Directions, GraphHopper, or self-hosted OSRM before going public. The offline Dijkstra router takes over inside downloaded regions when offline.
- **Nominatim** at `nominatim.openstreetmap.org` — requires a descriptive User-Agent (already set) and is rate-limited to ~1 req/sec. The bundled place index already handles the most common queries offline; Nominatim is now the *online fallback* rather than the primary path.
- **PaymentScreen** is dev-only — it does not contact any PSP. Wire a real Razorpay / Stripe / RevenueCat SDK before any public release.

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

Built by <b>Parth Gupta</b> and <b>Parv Tiwari</b>.