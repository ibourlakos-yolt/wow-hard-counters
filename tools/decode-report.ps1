# Decode the !HCReport:1! string (and the !GranaryDBReport:1! inside it) in a file offline, in WSL.
# Usage: tools\decode-report.ps1 "<path to file>"
# Prints the player's note first ("Note: ..."), then every key of the body, known to this script or not.
param([Parameter(Mandatory = $true)][string]$Path)
. (Join-Path $PSScriptRoot '_wsl.ps1')
$full = (Resolve-Path -LiteralPath $Path).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("granary-report-" + [guid]::NewGuid().ToString("N") + ".txt")
Copy-Item -LiteralPath $full -Destination $tmp # WSL paths with spaces and '#' are awkward; a temp copy is not
$drive = $tmp.Substring(0, 1).ToLower()
$wslTmp = "/mnt/$drive" + ($tmp.Substring(2) -replace '\\', '/')
try {
    $repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    & wsl.exe --cd "$repo" -e lua5.1 tools/decode_report.lua "$wslTmp" | Out-Host
    $code = $LASTEXITCODE
} finally {
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
}
exit $code
