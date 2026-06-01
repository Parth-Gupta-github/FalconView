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

# OpenFreeMap's current sprite path (as of June 2026) is
# /sprites/<hashed-version>/ofm, NOT /sprites/v1/liberty. The hash bumps
# whenever they regenerate the sprite, so we fetch the live style.json to
# learn the current URL instead of hard-coding it.
$styleUrl = "https://tiles.openfreemap.org/styles/liberty"
$baseUrl  = $null
try {
    $styleJson = Invoke-RestMethod -Uri $styleUrl -UseBasicParsing
    if ($styleJson.sprite) {
        $baseUrl = [string]$styleJson.sprite
        Write-Host "Resolved sprite base URL: $baseUrl"
    }
} catch {
    Write-Host "Could not fetch live style: $_" -ForegroundColor Yellow
}
if (-not $baseUrl) {
    # Fallback to a known-good URL from a recent style snapshot. If this 404s,
    # OpenFreeMap rotated the hash again — fetch the style URL manually.
    $baseUrl = "https://tiles.openfreemap.org/sprites/ofm_f384/ofm"
    Write-Host "Using fallback sprite URL: $baseUrl"
}

# We download with whatever the upstream file names are (e.g. "ofm.png") but
# save locally as "liberty.<ext>" so the in-app server + offline style can
# reference a stable name regardless of OpenFreeMap's renaming.
$variants = @(
    @{ remote = "";      local = "liberty.png" ; ext = "png"  },
    @{ remote = "";      local = "liberty.json"; ext = "json" },
    @{ remote = "@2x";   local = "liberty@2x.png" ; ext = "png"  },
    @{ remote = "@2x";   local = "liberty@2x.json"; ext = "json" }
)

Write-Host "Downloading Liberty sprite into: $outDir"
Write-Host ""

$totalBytes = 0
foreach ($v in $variants) {
    $name = $v.local
    $url  = "$baseUrl$($v.remote).$($v.ext)"
    $dest = Join-Path $outDir $name
    if ((Test-Path $dest) -and ((Get-Item $dest).Length -gt 0)) {
        Write-Host "cached  $name"
        $totalBytes += (Get-Item $dest).Length
        continue
    }
    Write-Host -NoNewline "fetching $name ... "
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
