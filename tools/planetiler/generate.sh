#!/usr/bin/env bash
#
# Generates assets/basemap/world.mbtiles from OpenStreetMap data via Planetiler.
#
# Usage:
#   ./generate.sh                                    # planet, z0-6, ~15 min
#   ./generate.sh --area monaco                      # tiny smoke test
#   ./generate.sh --area indore --max-zoom 14        # Indore city, street-level
#   ./generate.sh --area india --bounds 75.37,22.27,76.35,23.17 --max-zoom 14
#
# Flags:
#   --area       OSM area name Planetiler can download, a city preset
#                (indore/bhopal/delhi/mumbai), or a path to a local .osm.pbf
#   --bounds     Optional "west,south,east,north" decimal bbox to clip output
#   --min-zoom   Minimum zoom in output (default 0)
#   --max-zoom   Maximum zoom in output (default 6)
#   --memory     JVM -Xmx (default 6g)

set -euo pipefail

AREA="planet"
BOUNDS=""
MIN_ZOOM=0
MAX_ZOOM=6
MEMORY="6g"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --area)     AREA="$2";     shift 2 ;;
    --bounds)   BOUNDS="$2";   shift 2 ;;
    --min-zoom) MIN_ZOOM="$2"; shift 2 ;;
    --max-zoom) MAX_ZOOM="$2"; shift 2 ;;
    --memory)   MEMORY="$2";   shift 2 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

# City-level presets — resolve a friendly name to (source extract, bbox).
case "$(echo "$AREA" | tr '[:upper:]' '[:lower:]')" in
  indore) AREA="india";  [[ -z "$BOUNDS" ]] && BOUNDS="75.37,22.27,76.35,23.17" ;;
  bhopal) AREA="india";  [[ -z "$BOUNDS" ]] && BOUNDS="77.15,23.05,77.65,23.42" ;;
  delhi)  AREA="india";  [[ -z "$BOUNDS" ]] && BOUNDS="76.84,28.40,77.35,28.88" ;;
  mumbai) AREA="india";  [[ -z "$BOUNDS" ]] && BOUNDS="72.77,18.89,73.00,19.27" ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CACHE_DIR="$SCRIPT_DIR/.cache"
OUT_DIR="$REPO_ROOT/assets/basemap"
OUT_FILE="$OUT_DIR/world.mbtiles"

# Pinned Planetiler release for reproducibility. Bump deliberately.
PL_VERSION="0.9.3"
PL_URL="https://github.com/onthegomap/planetiler/releases/download/v${PL_VERSION}/planetiler.jar"
PL_JAR="$CACHE_DIR/planetiler-${PL_VERSION}.jar"

command -v java >/dev/null 2>&1 || {
  echo "Java not found on PATH. Install JDK 21+ from https://adoptium.net/" >&2
  exit 1
}

mkdir -p "$CACHE_DIR" "$OUT_DIR"

if [[ ! -f "$PL_JAR" ]]; then
  echo "Downloading Planetiler ${PL_VERSION}..."
  if command -v curl >/dev/null 2>&1; then
    curl -fL -o "$PL_JAR" "$PL_URL"
  else
    wget -O "$PL_JAR" "$PL_URL"
  fi
fi

echo ""
echo "Building bundled basemap:"
echo "  area:    $AREA"
[[ -n "$BOUNDS" ]] && echo "  bounds:  $BOUNDS"
echo "  zooms:   $MIN_ZOOM..$MAX_ZOOM"
echo "  output:  $OUT_FILE"
echo "  heap:    $MEMORY"
echo ""

# Treat $AREA as a file path if it exists; otherwise download it.
if [[ -f "$AREA" ]]; then
  AREA_ARGS=(--osm-path="$AREA")
else
  AREA_ARGS=(--download --area="$AREA")
fi

PL_ARGS=(
  --minzoom="$MIN_ZOOM"
  --maxzoom="$MAX_ZOOM"
  --output="$OUT_FILE"
  --force
)
[[ -n "$BOUNDS" ]] && PL_ARGS+=(--bounds="$BOUNDS")

java "-Xmx${MEMORY}" -jar "$PL_JAR" "${PL_ARGS[@]}" "${AREA_ARGS[@]}"

SIZE_MB=$(du -m "$OUT_FILE" | cut -f1)
echo ""
echo "Done. $OUT_FILE (${SIZE_MB} MB)"
echo "Run 'flutter pub get' (no-op for assets) and rebuild the app."
