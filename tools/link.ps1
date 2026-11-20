# Create directory junctions from WoW's AddOns folder to this repo's addon folders (HardCounters and
# HardCounters_Diagnostics). No admin rights needed. Idempotent; refuses to touch a real folder or a junction
# that points somewhere else. A NEW addon folder needs a full client restart; changed Lua only needs /reload.
# Usage: tools\link.ps1 [-AddOns "<path to Interface\AddOns>"] [-Names HardCounters,HardCounters_Diagnostics]
param(
    [string]$AddOns = "C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns",
    [string[]]$Names = @("HardCounters", "HardCounters_Diagnostics")
)
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path.TrimEnd('\')
if (-not (Test-Path -LiteralPath $AddOns)) {
    Write-Error "AddOns folder not found: $AddOns"
    exit 1
}
$failed = $false
foreach ($name in $Names) {
    $target = Join-Path $repo $name
    if (-not (Test-Path -LiteralPath $target)) { Write-Error "Addon folder not found: $target"; $failed = $true; continue }
    $link = Join-Path $AddOns $name
    if (Test-Path -LiteralPath $link) {
        $item = Get-Item -LiteralPath $link -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $current = @($item.Target)[0]
            if ($current) { $current = $current.TrimEnd('\') }
            if ($current -eq $target) { Write-Host "Already linked: $link -> $target"; continue }
            Write-Error "$link already links to '$current', not this repo. Remove that junction yourself first (rmdir `"$link`")."
            $failed = $true
            continue
        }
        Write-Error "$link is a real folder. Refusing to overwrite it; move it away yourself if you want the dev link."
        $failed = $true
        continue
    }
    cmd /c mklink /J "$link" "$target" | Out-Host
    if ($LASTEXITCODE -ne 0) { $failed = $true; continue }
    Write-Host "Linked $link -> $target"
}
if ($failed) { exit 1 }
Write-Host "New addon folders need a full client restart (not just /reload)."
