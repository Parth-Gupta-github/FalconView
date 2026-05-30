# `assets/basemap/`

This directory holds the bundled offline basemap MBTiles that the app falls back to when offline with no region downloaded.

The `.mbtiles` file is **not committed** (too large for git). Generate it before `flutter build`:

```powershell
cd tools/planetiler
./generate.ps1      # Windows
./generate.sh       # macOS / Linux
```

See [tools/planetiler/README.md](../../tools/planetiler/README.md) for full instructions.

If `world.mbtiles` is absent, the app still works — it just won't have the offline fallback layer. Map will show its normal upstream tiles when online and a blank canvas otherwise.
