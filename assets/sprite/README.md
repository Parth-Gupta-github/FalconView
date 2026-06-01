# `assets/sprite/`

Holds the bundled MapLibre sprite atlas — the PNG image + JSON manifest containing every POI icon the offline style references (hospital cross, train symbol, etc.).

**Not committed:** the PNG / JSON files are gitignored. Each dev fetches them once with the helper script:

```powershell
cd tools/sprite
./fetch.ps1
```

Bash:

```bash
cd tools/sprite
./fetch.sh
```

Total download is ~80–200 KB (1× + 2× variants of the Liberty sprite from OpenFreeMap).

Without these files the offline style falls back to the bare colored POI dots — the map still works, you just see dots instead of icons.
