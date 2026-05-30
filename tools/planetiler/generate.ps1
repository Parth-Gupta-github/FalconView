<#
.SYNOPSIS
  Generates assets/basemap/world.mbtiles from OpenStreetMap data via Planetiler.

.DESCRIPTION
  Downloads the Planetiler JAR (cached) and runs it against the requested OSM
  area, producing a small low-zoom vector MBTiles bundled with the Flutter app.

  Working files (downloaded OSM PBF, Planetiler scratch) live under -WorkDir,
  which defaults to F:\planetiler-work because the typical C: drive on this
  machine is tight on space. Override with -WorkDir <path> if needed.

.PARAMETER Area
  OSM area to build. Default: "planet". Accepts any name Planetiler's
  --download mode recognises (planet, monaco, india, california, etc.) or a
  path to a .osm.pbf file.

.PARAMETER MinZoom
  Minimum zoom in the output. Default 0.

.PARAMETER MaxZoom
  Maximum zoom in the output. Default 6 — enough for country outlines and
  major roads; the app downloads z10+ data for the regions users actually use.

.PARAMETER Memory
  JVM heap, passed as -Xmx. Default 6g.

.PARAMETER WorkDir
  Where Planetiler stores its downloaded OSM PBF and scratch files. Default
  F:\planetiler-work. Pick a drive with the most free space — see the table
  in this script's banner for sizing.

.PARAMETER SkipFreeSpaceCheck
  Skip the precheck that fails fast when WorkDir's drive doesn't have enough
  room for the chosen area.

.PARAMETER Bounds
  Optional output bounding box, "west,south,east,north" in decimal degrees.
  Clips the MBTiles to this rectangle so the output is small even when the
  source PBF is country-sized. Use with -Area to target a city inside a
  country, e.g. -Area india -Bounds "75.37,22.27,76.35,23.17" for Indore.

.EXAMPLE
  ./generate.ps1
  Full planet, z0-6, working space on F:\planetiler-work, ~15 min.

.EXAMPLE
  ./generate.ps1 -Area monaco
  Tiny smoke test, ~30 seconds, ~500 MB working space.

.EXAMPLE
  ./generate.ps1 -Area indore -MaxZoom 14
  Indore + ~50 km at street level. Downloads India PBF (~1.5 GB one-time)
  and clips to the city bbox. Output ~30-80 MB.

.EXAMPLE
  ./generate.ps1 -Area india -WorkDir D:\pl-work
  Country-scale build with working files on D:.
#>
param(
    [string]$Area = "planet",
    [int]$MinZoom = 0,
    [int]$MaxZoom = 6,
    [string]$Memory = "6g",
    [string]$WorkDir = "F:\planetiler-work",
    [switch]$SkipFreeSpaceCheck,
    [string]$Bounds = "",
    [string]$OsmUrl = ""
)

# City-level presets. Each preset resolves a friendly name to a Geofabrik
# STATE-level extract URL + a city bbox. State-level PBFs are 10-15× smaller
# than country PBFs (Madhya Pradesh ~100 MB vs India ~1.6 GB) so the dev
# download and build time drop dramatically — but the final MBTiles size
# (what the phone bundles) is the same because we still clip with --bounds.
$presets = @{
    "indore" = @{
        osmUrl = "https://download.geofabrik.de/asia/india/madhya-pradesh-latest.osm.pbf";
        bounds = "75.37,22.27,76.35,23.17"
    }
    "bhopal" = @{
        osmUrl = "https://download.geofabrik.de/asia/india/madhya-pradesh-latest.osm.pbf";
        bounds = "77.15,23.05,77.65,23.42"
    }
    "delhi" = @{
        osmUrl = "https://download.geofabrik.de/asia/india/delhi-latest.osm.pbf";
        bounds = "76.84,28.40,77.35,28.88"
    }
    "mumbai" = @{
        osmUrl = "https://download.geofabrik.de/asia/india/maharashtra-latest.osm.pbf";
        bounds = "72.77,18.89,73.00,19.27"
    }
}
$presetKey = $Area.ToLower()
if ($presets.ContainsKey($presetKey)) {
    $preset = $presets[$presetKey]
    if ([string]::IsNullOrEmpty($OsmUrl)) { $OsmUrl = $preset.osmUrl }
    if ([string]::IsNullOrEmpty($Bounds)) { $Bounds = $preset.bounds }
    Write-Host "Preset '$presetKey' resolved:"
    Write-Host "  osm-url: $OsmUrl"
    Write-Host "  bounds:  $Bounds"
}

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot  = Resolve-Path (Join-Path $scriptDir "..\..")
$cacheDir  = Join-Path $scriptDir ".cache"
$outDir    = Join-Path $repoRoot "assets\basemap"
$outFile   = Join-Path $outDir "world.mbtiles"

# Planetiler release pinned for reproducibility. Bump deliberately.
$plVersion = "0.9.3"
$plUrl     = "https://github.com/onthegomap/planetiler/releases/download/v${plVersion}/planetiler.jar"
$plJar     = Join-Path $cacheDir "planetiler-${plVersion}.jar"

# Rough disk requirements (GB) by area — peak working space + downloaded PBF.
# Numbers from Planetiler upstream sizing notes; round up for safety.
$requirementsByArea = @{
    "planet"   = 180
    "us"       = 60
    "usa"      = 60
    "europe"   = 80
    "india"    = 15
    "germany"  = 15
    "france"   = 15
    "uk"       = 10
    "monaco"   = 1
    "default"  = 20  # unknown country → assume modest
}

function Get-FreeSpaceGB([string]$path) {
    # Resolve the drive root for the requested path (creates the dir if needed
    # so Get-PSDrive can find it).
    if (-not (Test-Path $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    $drive = (Get-Item $path).PSDrive
    if ($null -eq $drive -or $drive.Provider.Name -ne 'FileSystem') {
        return $null
    }
    return [math]::Round($drive.Free / 1GB, 1)
}

# Sanity: Java present and recent enough? Planetiler 0.9.x requires JDK 21+.
$java = Get-Command java -ErrorAction SilentlyContinue
if (-not $java) {
    Write-Host "Java not found on PATH. Install JDK 21+ from https://adoptium.net/" -ForegroundColor Red
    exit 1
}
# Java -version writes to stderr. Let cmd do the redirect so PowerShell 5.1
# doesn't wrap each stderr line as an ErrorRecord (which would escalate to a
# terminating error under $ErrorActionPreference = "Stop").
$javaVersionLine = (& cmd /c "java -version 2>&1" | Select-Object -First 1)
if ($javaVersionLine -match '"(\d+)') {
    $major = [int]$Matches[1]
    if ($major -eq 1) {
        # "1.8.0" -> major=1, the Java 8 naming scheme.
        Write-Host "Java 8 detected ($javaVersionLine). Planetiler 0.9.x needs JDK 21+. Build will fail." -ForegroundColor Red
        exit 1
    } elseif ($major -lt 21) {
        Write-Host "Java major version $major detected. Planetiler 0.9.x needs JDK 21+. Build will likely fail." -ForegroundColor Yellow
    }
}

if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir | Out-Null }
if (-not (Test-Path $outDir))   { New-Item -ItemType Directory -Path $outDir   | Out-Null }
if (-not (Test-Path $WorkDir))  { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }

# Free-space precheck against the WorkDir drive.
$areaKey  = $Area.ToLower()
$required = if ($requirementsByArea.ContainsKey($areaKey)) { $requirementsByArea[$areaKey] } else { $requirementsByArea["default"] }
$freeGB   = Get-FreeSpaceGB $WorkDir
if (-not $SkipFreeSpaceCheck) {
    if ($null -eq $freeGB) {
        Write-Warning "Could not determine free space on $WorkDir - skipping precheck."
    } elseif ($freeGB -lt $required) {
        Write-Host ""
        Write-Host "Not enough free space on drive containing $WorkDir." -ForegroundColor Red
        Write-Host "  Area:       $Area"
        Write-Host "  Required:   ~$required GB"
        Write-Host "  Available:  $freeGB GB"
        Write-Host "Rerun with -WorkDir followed by a path on a bigger drive, or pick a smaller area"
        Write-Host "(e.g. -Area monaco for a smoke test, -Area india for a country)."
        Write-Host "Override the check with -SkipFreeSpaceCheck if you know what you are doing."
        exit 1
    }
}

# Download Planetiler if not cached.
if (-not (Test-Path $plJar)) {
    Write-Host "Downloading Planetiler ${plVersion}..."
    Invoke-WebRequest -Uri $plUrl -OutFile $plJar
}

Write-Host ""
Write-Host "Building bundled basemap:"
Write-Host "  area:       $Area"
if (-not [string]::IsNullOrEmpty($Bounds)) { Write-Host "  bounds:     $Bounds" }
Write-Host "  zooms:      $MinZoom..$MaxZoom"
Write-Host "  output:     $outFile"
Write-Host "  work dir:   $WorkDir"
Write-Host "  free space: $freeGB GB available, ~$required GB required"
Write-Host "  heap:       $Memory"
Write-Host ""

# Decide how Planetiler should locate the OSM PBF, in priority order:
#   1. -OsmUrl explicit → --download with that URL
#   2. -Area is a path that exists → --osm-path
#   3. otherwise → --download --area=<name>
if (-not [string]::IsNullOrEmpty($OsmUrl)) {
    $areaArg = "--download --osm-url=$OsmUrl"
} elseif (Test-Path $Area) {
    $areaArg = "--osm-path=$Area"
} else {
    $areaArg = "--download --area=$Area"
}

# Route ALL Planetiler scratch + downloaded sources onto WorkDir so we don't
# touch C: at all.
$tmpDir      = Join-Path $WorkDir "tmp"
$downloadDir = Join-Path $WorkDir "sources"
if (-not (Test-Path $tmpDir))      { New-Item -ItemType Directory -Path $tmpDir      -Force | Out-Null }
if (-not (Test-Path $downloadDir)) { New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null }

$javaArgs = @(
    "-Xmx$Memory"
    "-jar", $plJar
    "--minzoom=$MinZoom"
    "--maxzoom=$MaxZoom"
    "--output=$outFile"
    "--tmpdir=$tmpDir"
    "--download-dir=$downloadDir"
    "--force"
) + $areaArg.Split(" ")
if (-not [string]::IsNullOrEmpty($Bounds)) {
    $javaArgs += "--bounds=$Bounds"
}

& java @javaArgs
if ($LASTEXITCODE -ne 0) {
    Write-Error "Planetiler exited with code $LASTEXITCODE"
}

$sizeMb = [math]::Round((Get-Item $outFile).Length / 1MB, 1)
Write-Host ""
Write-Host "Done. $outFile ($sizeMb MB)"
Write-Host "Run 'flutter pub get' (no-op for assets) and rebuild the app."
