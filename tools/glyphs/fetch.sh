#!/usr/bin/env bash
#
# Downloads Noto Sans glyph PBFs from OpenFreeMap into assets/glyphs/ so
# MapLibre can render text labels offline.
#
# Default fontstacks: Noto Sans Regular / Italic / Bold
# Default ranges:     0-255 (Latin) + 2304-2559 (Devanagari)
#
# Usage:
#   ./fetch.sh
#   ./fetch.sh --fonts "Noto Sans Regular" --ranges "0-255,2304-2559,2944-3199"

set -euo pipefail

FONTS_DEFAULT=("Noto Sans Regular" "Noto Sans Italic" "Noto Sans Bold")
RANGES_DEFAULT=("0-255" "2304-2559")

FONTS=("${FONTS_DEFAULT[@]}")
RANGES=("${RANGES_DEFAULT[@]}")

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fonts)  IFS=',' read -r -a FONTS  <<< "$2"; shift 2 ;;
    --ranges) IFS=',' read -r -a RANGES <<< "$2"; shift 2 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT_ROOT="$REPO_ROOT/assets/glyphs"
BASE_URL="https://tiles.openfreemap.org/fonts"

mkdir -p "$OUT_ROOT"
echo "Downloading glyph PBFs into: $OUT_ROOT"
printf "  fonts:  %s\n" "${FONTS[*]}"
printf "  ranges: %s\n\n" "${RANGES[*]}"

total=$(( ${#FONTS[@]} * ${#RANGES[@]} ))
done_count=0
total_bytes=0

url_encode() {
  # URL-encode spaces in font names for the request path.
  printf '%s' "$1" | sed 's/ /%20/g'
}

for font in "${FONTS[@]}"; do
  font_enc=$(url_encode "$font")
  font_dir="$OUT_ROOT/$font"
  mkdir -p "$font_dir"
  for range in "${RANGES[@]}"; do
    done_count=$((done_count + 1))
    url="$BASE_URL/$font_enc/$range.pbf"
    dest="$font_dir/$range.pbf"
    if [[ -s "$dest" ]]; then
      sz=$(stat -c%s "$dest" 2>/dev/null || stat -f%z "$dest")
      total_bytes=$((total_bytes + sz))
      printf '[%d/%d] cached %s %s.pbf\n' "$done_count" "$total" "$font" "$range"
      continue
    fi
    printf '[%d/%d] %s %s.pbf ... ' "$done_count" "$total" "$font" "$range"
    if curl -fsSL -o "$dest" "$url"; then
      sz=$(stat -c%s "$dest" 2>/dev/null || stat -f%z "$dest")
      total_bytes=$((total_bytes + sz))
      printf '%dKB\n' $((sz / 1024))
    else
      echo "FAILED" >&2
      rm -f "$dest"
    fi
  done
done

echo
printf 'Done. %d files, ~%d KB total.\n' "$total" $((total_bytes / 1024))
echo "Run 'flutter clean ; flutter pub get ; flutter run' to bundle them into the next APK build."
