# Build the Hard Counters bundle zip in dist\ (no store publishing): one zip, every addon folder that ships.
#   dist\HardCounters-<version>.zip   HardCounters\ (with Libs\), HardCounters_Diagnostics\, HardCounters_Farmer\,
#                                     HardCounters_CharacterStats\ (each at the zip root, as WoW's AddOns wants them)
# The version comes from "## Version:" in HardCounters\HardCounters.toc; the build fails if any shipped TOC says
# otherwise. Entries use forward slashes (Windows PowerShell's Compress-Archive writes backslashes, which break
# other unzippers).
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
# Zip folder name -> source folder in this repo.
$folders = [ordered]@{
    'HardCounters'                = 'HardCounters'
    'HardCounters_Diagnostics'    = 'HardCounters_Diagnostics'
    'HardCounters_Farmer'         = 'packs\Farmer\HardCounters_Farmer'
    'HardCounters_CharacterStats' = 'packs\CharacterStats\HardCounters_CharacterStats'
}

function Get-TocVersion([string]$name, [string]$src) {
    $toc = Get-Content -Raw (Join-Path $repo "$src\$name.toc")
    if ($toc -notmatch '(?m)^## Version:\s*(\S+)') { throw "## Version not found in $src\$name.toc" }
    return $Matches[1]
}

$version = Get-TocVersion 'HardCounters' $folders['HardCounters']
foreach ($name in $folders.Keys) {
    $v = Get-TocVersion $name $folders[$name]
    if ($v -ne $version) { Write-Error "$name.toc says $v, HardCounters.toc says $version"; exit 1 }
}

$dist = Join-Path $repo 'dist'
New-Item -ItemType Directory -Force $dist | Out-Null
$zipPath = Join-Path $dist "HardCounters-$version.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath }

$stream = [IO.File]::Open($zipPath, [IO.FileMode]::CreateNew)
$zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($name in $folders.Keys) {
        $src = Join-Path $repo $folders[$name]
        Get-ChildItem -LiteralPath $src -Recurse -File | ForEach-Object {
            $rel = $_.FullName.Substring($src.Length).TrimStart('\') -replace '\\', '/'
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $_.FullName, "$name/$rel", 'Optimal') | Out-Null
        }
        # The repo's LICENSE goes into every folder: players and hosts see folders, not the repo.
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $repo 'LICENSE'), "$name/LICENSE.txt", 'Optimal') | Out-Null
    }
} finally {
    $zip.Dispose()
    $stream.Dispose()
}
Write-Host "Built $zipPath"
