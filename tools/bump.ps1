# Write one version everywhere it lives: the four shipped TOCs ("## Version:"), HC.VERSION in Core\Init.lua and
# the packs' ns.VERSION. tests/toolchain_spec.lua fails when they disagree, so never edit them by hand.
# Usage: tools\bump.ps1 0.1.0-alpha1
#   Allowed: X.Y.Z, X.Y.Z-dev, X.Y.Z-alphaN, X.Y.Z-betaN, X.Y.Z-rcN (the suffix is the release channel).
param([Parameter(Mandatory = $true)][string]$Version)
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^\d+\.\d+\.\d+(-(dev|alpha\d+|beta\d+|rc\d+))?$') {
    Write-Error "Not a version this repo uses: '$Version' (X.Y.Z with optional -dev, -alphaN, -betaN, -rcN)"
    exit 1
}
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

# File -> pattern whose first group is replaced. Files are read and written as UTF-8 without BOM, line endings kept.
$sites = [ordered]@{
    'HardCounters\HardCounters.toc'                                              = '(?m)^(## Version:[ \t]*)\S+'
    'HardCounters_Diagnostics\HardCounters_Diagnostics.toc'                      = '(?m)^(## Version:[ \t]*)\S+'
    'packs\Farmer\HardCounters_Farmer\HardCounters_Farmer.toc'                   = '(?m)^(## Version:[ \t]*)\S+'
    'packs\CharacterStats\HardCounters_CharacterStats\HardCounters_CharacterStats.toc' = '(?m)^(## Version:[ \t]*)\S+'
    'packs\Traveler\HardCounters_Traveler\HardCounters_Traveler.toc'             = '(?m)^(## Version:[ \t]*)\S+'
    'HardCounters\Core\Init.lua'                                                 = '(HC\.VERSION = ")[^"]+'
    'packs\Farmer\HardCounters_Farmer\Farmer.lua'                                = '(ns\.VERSION = ")[^"]+'
    'packs\CharacterStats\HardCounters_CharacterStats\Stats.lua'                 = '(ns\.VERSION = ")[^"]+'
    'packs\Traveler\HardCounters_Traveler\Traveler.lua'                          = '(ns\.VERSION = ")[^"]+'
}

$utf8 = New-Object System.Text.UTF8Encoding($false)
foreach ($rel in $sites.Keys) {
    $path = Join-Path $repo $rel
    $text = [IO.File]::ReadAllText($path, $utf8)
    $rx = [regex]$sites[$rel]
    if ($rx.Matches($text).Count -ne 1) { Write-Error "Expected exactly one version in $rel"; exit 1 }
    $new = $rx.Replace($text, { param($m) $m.Groups[1].Value + $Version }, 1)
    if ($new -ne $text) { [IO.File]::WriteAllText($path, $new, $utf8) }
    Write-Host "$rel -> $Version"
}
Write-Host "Now run tools\test.ps1 tests/toolchain_spec.lua and write the CHANGELOG entry."
