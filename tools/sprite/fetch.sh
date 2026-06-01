#!/usr/bin/env bash
#
# Downloads OpenFreeMap's Liberty sprite atlas (1× + 2×) into assets/sprite/
# so MapLibre can render POI icons.
#
# Usage: ./fetch.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT_DIR="$REPO_ROOT/assets/sprite"
BASE_URL="https://tiles.openfreemap.org/sprites/v1/liberty"

mkdir -p "$OUT_DIR"
echo "Downloading Liberty sprite into: $OUT_DIR"
echo

total_bytes=0
for name in liberty.png liberty.json liberty@2x.png liberty@2x.json; do
  suffix="${name#liberty}"
  url="$BASE_URL$suffix"
  dest="$OUT_DIR/$name"
  if [[ -s "$dest" ]]; then
    sz=$(stat -c%s "$dest" 2>/dev/null || stat -f%z "$dest")
    total_bytes=$((total_bytes + sz))
    echo "cached $name"
    continue
  fi
  printf '%s ... ' "$name"
  if curl -fsSL -o "$dest" "$url"; then
    sz=$(stat -c%s "$dest" 2>/dev/null || stat -f%z "$dest")
    total_bytes=$((total_bytes + sz))
    printf '%dKB\n' $((sz / 1024))
  else
    echo "FAILED" >&2
    rm -f "$dest"
  fi
done

echo
printf 'Done. ~%d KB total.\n' $((total_bytes / 1024))
echo "Run 'flutter clean ; flutter pub get ; flutter run' to bundle them into the next APK build."
