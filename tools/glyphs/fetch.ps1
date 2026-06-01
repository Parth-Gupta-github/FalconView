<#
.SYNOPSIS
  Downloads Noto Sans glyph PBFs from OpenFreeMap into assets/glyphs/ so
  MapLibre can render text labels offline.

.DESCRIPTION
  MapLibre needs glyph PBFs (font character outlines, sliced into 256-codepoint
  ranges) to draw any text on the map. The offline style currently strips all
  text layers because we don't bundle these. This script fixes that by
  fetching the ranges we need.

  By default downloads:
    - Three fontstacks: Noto Sans Regular / Italic / Bold
    - Two Unicode ranges per font:
        0-255       (Basic Latin + Latin-1 Supplement) for English names
        2304-2559   (Devanagari) for Hindi / Marathi / Sanskrit names

  Total download: ~600 KB, one-time. Bundled into the APK.

.PARAMETER Fonts
  Override the default font list. Comma-separated.

.PARAMETER Ranges
  Override the default Unicode range list. Comma-separated, each entry must
  match OpenFreeMap's naming scheme (e.g. "0-255", "2304-2559").

.EXAMPLE
  ./fetch.ps1
  Default Latin + Devanagari for Noto Sans Regular/Italic/Bold (~600 KB).

.EXAMPLE
  ./fetch.ps1 -Ranges "0-255,2304-2559,2944-3199,3328-3583"
  Add Tamil + Bengali support for multi-script Indian content.
#>
param(
    [string[]]$Fonts  = @('Noto Sans Regular', 'Noto Sans Italic', 'Noto Sans Bold'),
    [string[]]$Ranges = @('0-255', '2304-2559')
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot  = Resolve-Path (Join-Path $scriptDir "..\..")
$outRoot   = Join-Path $repoRoot "assets\glyphs"

$baseUrl = "https://tiles.openfreemap.org/fonts"

Write-Host "Downloading glyph PBFs into: $outRoot"
Write-Host "  fonts:  $($Fonts -join ', ')"
Write-Host "  ranges: $($Ranges -join ', ')"
Write-Host ""

$total      = $Fonts.Count * $Ranges.Count
$done       = 0
$totalBytes = 0

foreach ($font in $Fonts) {
    # OpenFreeMap expects the font directory name URL-encoded (space → %20).
    $fontEncoded = [uri]::EscapeDataString($font)
    # On disk we store under the unencoded name so it's readable in the repo,
    # and our server URL-decodes incoming requests before looking it up.
    $fontDir = Join-Path $outRoot $font
    if (-not (Test-Path $fontDir)) {
        New-Item -ItemType Directory -Path $fontDir -Force | Out-Null
    }
    foreach ($range in $Ranges) {
        $done++
        $url      = "$baseUrl/$fontEncoded/$range.pbf"
        $destFile = Join-Path $fontDir "$range.pbf"
        if ((Test-Path $destFile) -and ((Get-Item $destFile).Length -gt 0)) {
            Write-Host "[$done/$total] ✓ cached  $font $range.pbf"
            $totalBytes += (Get-Item $destFile).Length
            continue
        }
        Write-Host -NoNewline "[$done/$total] ↓ $font $range.pbf ... "
        try {
            Invoke-WebRequest -Uri $url -OutFile $destFile -UseBasicParsing
            $sizeKb = [math]::Round((Get-Item $destFile).Length / 1KB, 1)
            $totalBytes += (Get-Item $destFile).Length
            Write-Host "$sizeKb KB"
        } catch {
            Write-Host "FAILED: $_" -ForegroundColor Red
            if (Test-Path $destFile) { Remove-Item $destFile -ErrorAction SilentlyContinue }
        }
    }
}

$totalKb = [math]::Round($totalBytes / 1KB, 1)
Write-Host ""
Write-Host "Done. $total files, ~$totalKb KB total."
Write-Host "Run 'flutter clean ; flutter pub get ; flutter run' to bundle them into the next APK build."
