# make_board_zip.ps1: pack the files the PYNQ board needs into one zip.
# Used by `build.bat board` (Windows PowerShell 5.1, nothing to install).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\make_board_zip.ps1 <repo root> <zip path>
#
# Layout inside the zip (unzip it in /home/xilinx/jupyter_notebooks on the board):
#   sobel/sobel_otsu.py
#   sobel/overlay/sobel_otsu.bit, sobel_otsu.hwh
#   sobel/golden/...            (without __pycache__ and tests)
#   sobel/notebooks/01_bringup.py, 02_benchmark.py, 03_live_video.py
#
# Uses .NET ZipArchive instead of Compress-Archive: the Compress-Archive that
# ships with PowerShell 5.1 writes '\' as path separator, which Linux unzip
# only accepts with a warning and Python's zipfile does not split at all.
# TODO(verify-on-windows): run once on the build laptop.

param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Zip
)
$ErrorActionPreference = 'Stop'

$bit = Join-Path $Root 'pynq\overlay\sobel_otsu.bit'
$hwh = Join-Path $Root 'pynq\overlay\sobel_otsu.hwh'
foreach ($f in @($bit, $hwh)) {
    if (-not (Test-Path -LiteralPath $f)) {
        Write-Host "ERROR: $f is missing. Build it first with:  build.bat bit"
        exit 1
    }
}

# zip entry name -> source file
$entries = [ordered]@{}
$entries['sobel/sobel_otsu.py'] = Join-Path $Root 'pynq\sobel_otsu.py'
$entries['sobel/overlay/sobel_otsu.bit'] = $bit
$entries['sobel/overlay/sobel_otsu.hwh'] = $hwh
foreach ($nb in @('01_bringup.py', '02_benchmark.py', '03_live_video.py')) {
    $entries["sobel/notebooks/$nb"] = Join-Path $Root "pynq\notebooks\$nb"
}
$goldenDir = Join-Path $Root 'golden'
Get-ChildItem -LiteralPath $goldenDir -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($goldenDir.Length).TrimStart('\', '/') -replace '\\', '/'
    $top = ($rel -split '/')[0]
    if ($rel -match '(^|/)__pycache__/' -or $top -eq 'tests' -or $_.Extension -eq '.pyc') { return }
    $entries["sobel/golden/$rel"] = $_.FullName
}
foreach ($src in $entries.Values) {
    if (-not (Test-Path -LiteralPath $src)) { Write-Host "ERROR: missing $src"; exit 1 }
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
if (Test-Path -LiteralPath $Zip) { Remove-Item -LiteralPath $Zip -Force }
$archive = [System.IO.Compression.ZipFile]::Open($Zip, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($name in $entries.Keys) {
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $archive, $entries[$name], $name, [System.IO.Compression.CompressionLevel]::Optimal)
        Write-Host "  + $name"
    }
} finally {
    $archive.Dispose()
}
$size = [math]::Round((Get-Item -LiteralPath $Zip).Length / 1MB, 2)
Write-Host "== wrote $Zip ($($entries.Count) files, $size MB)"
exit 0
