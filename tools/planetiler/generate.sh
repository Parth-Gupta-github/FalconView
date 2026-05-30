#!/usr/bin/env bash
#
# Generates assets/basemap/world.mbtiles from OpenStreetMap data via Planetiler.
#
# Usage:
#   ./generate.sh                       # planet, z0-6, ~15 min
#   ./generate.sh --area monaco         # tiny smoke test
#   ./generate.sh --area india --max-zoom 7
#
# Flags:
#   --area       OSM area name Planetiler can download, or path to .osm.pbf
#   --min-zoom   Minimum zoom in output (default 0)
#   --max-zoom   Maximum zoom in output (default 6)
#   --memory     JVM -Xmx (default 6g)

set -euo pipefail

AREA="planet"
MIN_ZOOM=0
MAX_ZOOM=6
MEMORY="6g"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --area)     AREA="$2";     shift 2 ;;
    --min-zoom) MIN_ZOOM="$2"; shift 2 ;;
    --max-zoom) MAX_ZOOM="$2"; shift 2 ;;
    --memory)   MEMORY="$2";   shift 2 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

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

java "-Xmx${MEMORY}" -jar "$PL_JAR" \
  --minzoom="$MIN_ZOOM" \
  --maxzoom="$MAX_ZOOM" \
  --output="$OUT_FILE" \
  --force \
  "${AREA_ARGS[@]}"

SIZE_MB=$(du -m "$OUT_FILE" | cut -f1)
echo ""
echo "Done. $OUT_FILE (${SIZE_MB} MB)"
echo "Run 'flutter pub get' (no-op for assets) and rebuild the app."
