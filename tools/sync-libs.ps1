# Copy ../LibGranaryDB/LibGranaryDB-1.0 into HardCounters\Libs\LibGranaryDB-1.0 (a mirror: files removed upstream
# are removed here). Library changes are made in ../LibGranaryDB with tests, a CHANGELOG entry and a MINOR bump,
# never in the embedded copy. tests/toolchain_spec.lua fails while the two differ.
# Usage: tools\sync-libs.ps1
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$src = Join-Path $repo '..\LibGranaryDB\LibGranaryDB-1.0'
if (-not (Test-Path -LiteralPath $src)) { Write-Error "Not found: $src"; exit 1 }
$src = (Resolve-Path -LiteralPath $src).Path
$dst = Join-Path $repo 'HardCounters\Libs\LibGranaryDB-1.0'
& robocopy.exe "$src" "$dst" /MIR /NJH /NJS /NP /NFL /NDL | Out-Host
# robocopy: 0-7 are success codes (8+ are failures)
if ($LASTEXITCODE -ge 8) { Write-Error "robocopy failed with code $LASTEXITCODE"; exit 1 }
$main = Get-Content -Raw (Join-Path $dst 'LibGranaryDB-1.0.lua')
if ($main -match 'local MAJOR, MINOR = "LibGranaryDB-1.0", (\d+)') { Write-Host "Embedded LibGranaryDB-1.0 r$($Matches[1])" }
exit 0
