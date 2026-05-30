# Planetiler — Bundled Base Map Generator

This directory holds the scripts that produce **`assets/basemap/world.mbtiles`** — a tiny low-zoom (z0–6) vector basemap that ships inside the app. MapLibre falls back to it when no region has been downloaded and the device is offline, so the map is never blank.

The `.mbtiles` file itself is **not committed** (too large for git). Every developer must run the generator once before `flutter build`, and refresh it whenever OSM data drifts (every few months is fine).

## What gets produced

| File | Path | Size | Contents |
|---|---|---|---|
| Vector tiles | `assets/basemap/world.mbtiles` | ~80–250 MB | OpenMapTiles schema, z0–6, whole planet |

z6 is enough to show country outlines and major roads. The app's downloaded regions already cover z10+ where users actually pan and zoom — this bundle exists only as a "never blank" safety net.

## Prerequisites

| Tool | Why | Install |
|---|---|---|
| Java 21+ | Planetiler runs on the JVM | [Adoptium](https://adoptium.net/) |
| ~6 GB free RAM | Planet build peaks around this | — |
| ~30 GB free disk | Intermediate files + output | — |
| ~15 min wall time | Planet at z0–6 on a modern laptop | — |

You do **not** need to install Planetiler — the script downloads the official JAR on first run and caches it under `tools/planetiler/.cache/`.

## Generate

### Windows (PowerShell)

```powershell
cd tools/planetiler
./generate.ps1
```

### macOS / Linux (bash)

```bash
cd tools/planetiler
./generate.sh
```

Both scripts are equivalent. Output lands at `<repo>/assets/basemap/world.mbtiles`.

## Customizing the area

Default is the whole planet at z0–6. For faster iteration during development you can build a single country (much smaller, ~30 seconds):

```powershell
./generate.ps1 -Area monaco          # Tiny — for quick smoke tests
./generate.ps1 -Area india           # Country-scale
./generate.ps1 -MinZoom 0 -MaxZoom 5 # Even smaller bundle
```

Same flags work on the bash script (`--area`, `--min-zoom`, `--max-zoom`).

## Refreshing

OpenStreetMap data updates daily, but the bundled basemap is just a backdrop — refreshing once per release cycle is plenty. Re-run the script; it overwrites `world.mbtiles` in place.

## Why Planetiler (and not Tilemaker / Tippecanoe / OpenMapTiles)?

- **Planetiler** converts OSM PBF → MVT MBTiles. Java. ~15 min for the planet at z0–6 on a laptop. What we use.
- **Tilemaker** does the same job in C++. Slightly slower, lower memory. Credible alternative.
- **Tippecanoe** takes GeoJSON, not OSM. Different use case.
- **OpenMapTiles** (the original Docker pipeline) takes days for the planet. We use its *schema* via Planetiler.

OpenFreeMap (the live tile server this app talks to over the network) is itself Planetiler-generated, so the bundled tiles match the live tiles' schema exactly.

## What the app does with the file

1. On first launch, `BundledBasemapServer.ensureStarted()` copies `world.mbtiles` from `rootBundle` to writable storage (sqflite can't open assets directly).
2. It boots a `dart:io HttpServer` on `127.0.0.1` on an OS-picked port.
3. Each `/​{z}/{x}/{y}.pbf` request reads a row from the MBTiles SQLite and returns the bytes.
4. When the device has no internet and no downloaded region, `MapScreen` loads `assets/styles/falconview_offline.json` — a stripped-down style with `tiles: ["http://127.0.0.1:<port>/{z}/{x}/{y}.pbf"]` patched in at runtime.

If the `.mbtiles` file is missing (e.g. dev forgot to run the generator), the server silently no-ops and the app behaves exactly as it does today.

## Credits & licensing

This tool wraps and depends on the following projects — please respect their licenses if you redistribute the output.

- **[Planetiler](https://github.com/onthegomap/planetiler)** by Onthegomap — Apache 2.0. The JAR is downloaded on demand and cached under `.cache/`; nothing is bundled in the repo.
- **[OpenMapTiles schema](https://openmaptiles.org/schema/)** — Planetiler's `openmaptiles` profile (default) emits tiles in this schema. The output MBTiles inherit the schema's licensing terms; review [openmaptiles.org](https://openmaptiles.org) before redistribution.
- **[OpenStreetMap](https://www.openstreetmap.org/copyright)** — the data source. © OpenStreetMap contributors, [ODbL](https://opendatacommons.org/licenses/odbl/). Any `.mbtiles` produced here is an OSM-derived work and inherits ODbL obligations (attribution + share-alike).
- **[MBTiles 1.3](https://github.com/mapbox/mbtiles-spec)** — the SQLite container format the output uses. Spec originally by Mapbox.
- **[Natural Earth](https://www.naturalearthdata.com/)** + **[OSM water polygons](https://osmdata.openstreetmap.de/data/water-polygons.html)** — auxiliary data Planetiler downloads alongside the OSM PBF. Public-domain / ODbL respectively.

When the app ships with a bundled `world.mbtiles`, the **app** must surface attribution to OpenStreetMap contributors in a user-visible place (about screen, map credits overlay, etc.) to satisfy ODbL.
