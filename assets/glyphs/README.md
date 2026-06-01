# `assets/glyphs/`

Holds the bundled font glyph PBFs that MapLibre uses to render text labels offline (road names, place names, POI names).

**Not committed:** the `.pbf` files are gitignored. Each dev fetches them once with the helper script:

```powershell
cd tools/glyphs
./fetch.ps1
```

Bash:

```bash
cd tools/glyphs
./fetch.sh
```

Default download is ~600 KB covering:

- Fontstacks: Noto Sans Regular, Noto Sans Italic, Noto Sans Bold
- Unicode ranges: 0-255 (Latin) + 2304-2559 (Devanagari — Hindi / Marathi)

Pass `-Ranges` (PowerShell) or `--ranges` (bash) to add other Indian scripts (Tamil, Telugu, Bengali, etc.). See the script for details.

Without these files the offline style still renders the map — just without any text labels.
