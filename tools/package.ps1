# Build the Hard Counters bundle zip in dist\ (no store publishing): one zip, every addon folder that ships.
#   dist\HardCounters-<version>.zip   HardCounters\ (with Libs\), HardCounters_Diagnostics\, HardCounters_Farmer\,
#                                     HardCounters_CharacterStats\, HardCounters_Traveler\ (each at the zip root, as
#                                     WoW's AddOns wants them)
# The version comes from "## Version:" in HardCounters\HardCounters.toc; the build fails if any shipped TOC says
# otherwise, or if the embedded LibGranaryDB is not an exact copy of ..\LibGranaryDB (when that folder exists).
# Entries use forward slashes (Windows PowerShell's Compress-Archive writes backslashes, which break other unzippers).
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
    'HardCounters_Traveler'       = 'packs\Traveler\HardCounters_Traveler'
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

# The embedded LibGranaryDB must be an exact copy of ..\LibGranaryDB (tools\sync-libs.ps1 makes it one): same files,
# same bytes. Without that sibling folder (a CI runner, a fresh clone) the check is skipped with a warning, as in
# tests\toolchain_spec.lua.
$libSrc = Join-Path $repo '..\LibGranaryDB\LibGranaryDB-1.0'
$libDst = Join-Path $repo 'HardCounters\Libs\LibGranaryDB-1.0'
if (Test-Path -LiteralPath $libSrc) {
    function Get-TreeHashes([string]$root) {
        $root = (Resolve-Path -LiteralPath $root).Path
        $h = @{}
        Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object {
            $h[$_.FullName.Substring($root.Length).TrimStart('\')] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        }
        return $h
    }
    $a = Get-TreeHashes $libSrc
    $b = Get-TreeHashes $libDst
    $diff = @()
    foreach ($k in $a.Keys) {
        if (-not $b.ContainsKey($k)) { $diff += "missing from the embedded copy: $k" }
        elseif ($a[$k] -ne $b[$k]) { $diff += "differs: $k" }
    }
    foreach ($k in $b.Keys) { if (-not $a.ContainsKey($k)) { $diff += "only in the embedded copy: $k" } }
    if ($diff.Count -gt 0) {
        Write-Error ("Embedded LibGranaryDB differs from ..\LibGranaryDB (run tools\sync-libs.ps1):`n  " + (($diff | Sort-Object) -join "`n  "))
        exit 1
    }
} else {
    Write-Warning "..\LibGranaryDB not found: not checking that the embedded LibGranaryDB is an exact copy."
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
