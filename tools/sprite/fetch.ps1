<#
.SYNOPSIS
  Downloads OpenFreeMap's Liberty sprite atlas into assets/sprite/ so
  MapLibre can render POI icons (hospital cross, train symbol, etc.).

.DESCRIPTION
  A "sprite" in MapLibre = one big PNG containing every icon the style
  references, plus a JSON manifest mapping icon name → (x, y, width, height).
  This script fetches both for the standard Liberty style.

  By default downloads both 1× and 2× (Hi-DPI) variants. ~80–200 KB total,
  one-time, bundled into the APK.
#>
param()

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot  = Resolve-Path (Join-Path $scriptDir "..\..")
$outDir    = Join-Path $repoRoot "assets\sprite"

if (-not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

$baseUrl = "https://tiles.openfreemap.org/sprites/v1/liberty"
$files = @(
    "liberty.png",
    "liberty.json",
    "liberty@2x.png",
    "liberty@2x.json"
)

Write-Host "Downloading Liberty sprite into: $outDir"
Write-Host ""

$totalBytes = 0
foreach ($name in $files) {
    # OpenFreeMap publishes them at /sprites/v1/liberty (no suffix), /liberty.png,
    # /liberty.json, /liberty@2x.png, /liberty@2x.json. The base URL is the
    # liberty prefix; we splice the rest in.
    $suffix = $name -replace '^liberty', ''
    $url    = "$baseUrl$suffix"
    $dest   = Join-Path $outDir $name
    if ((Test-Path $dest) -and ((Get-Item $dest).Length -gt 0)) {
        Write-Host "✓ cached  $name"
        $totalBytes += (Get-Item $dest).Length
        continue
    }
    Write-Host -NoNewline "↓ $name ... "
    try {
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
        $sizeKb = [math]::Round((Get-Item $dest).Length / 1KB, 1)
        $totalBytes += (Get-Item $dest).Length
        Write-Host "$sizeKb KB"
    } catch {
        Write-Host "FAILED: $_" -ForegroundColor Red
        if (Test-Path $dest) { Remove-Item $dest -ErrorAction SilentlyContinue }
    }
}

$totalKb = [math]::Round($totalBytes / 1KB, 1)
Write-Host ""
Write-Host "Done. ~$totalKb KB total."
Write-Host "Run 'flutter clean ; flutter pub get ; flutter run' to bundle them into the next APK build."
