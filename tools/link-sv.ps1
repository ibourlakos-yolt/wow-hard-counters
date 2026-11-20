# Create a directory junction <repo>\SavedVariables -> WoW's SavedVariables folder for one account, so the
# addons' saved files are at SavedVariables\HardCounters*.lua inside the repo. Git-ignored and excluded from
# luacheck. A junction, not a file link: file symlinks need admin rights on this machine, and a hard link
# would go stale because WoW writes a fresh file at every save (the old one becomes .bak).
# Deleting the junction (Explorer, rmdir, git clean -fdx) removes only the link, never WoW's files.
# Usage: tools\link-sv.ps1 -Account <folder name under WTF\Account> [-Wtf "<path to _forever_\WTF>"]
#   Without -Account it lists the account folders (the one you play on has the newest SavedVariables).
param(
    [string]$Account,
    [string]$Wtf = "C:\Program Files (x86)\World of Warcraft\_forever_\WTF"
)
if (-not $Account) {
    Write-Host "Pass -Account <name>. Account folders, newest saved files first:"
    Get-ChildItem -LiteralPath (Join-Path $Wtf 'Account') -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SavedVariables') } |
        Sort-Object { (Get-Item -LiteralPath (Join-Path $_.FullName 'SavedVariables')).LastWriteTime } -Descending |
        ForEach-Object { Write-Host "  $($_.Name)" }
    exit 1
}
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path.TrimEnd('\')
$target = Join-Path $Wtf "Account\$Account\SavedVariables"
if (-not (Test-Path -LiteralPath $target)) {
    Write-Error "SavedVariables folder not found: $target"
    exit 1
}
$target = (Resolve-Path -LiteralPath $target).Path.TrimEnd('\')
$link = Join-Path $repo "SavedVariables"
if (Test-Path -LiteralPath $link) {
    $item = Get-Item -LiteralPath $link -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        $current = @($item.Target)[0]
        if ($current) { $current = $current.TrimEnd('\') }
        if ($current -eq $target) {
            Write-Host "Already linked: $link -> $target"
            exit 0
        }
        Write-Error "$link already links to '$current'. Remove that junction first (rmdir `"$link`"), then run this again."
        exit 1
    }
    Write-Error "$link is a real folder. Refusing to touch it."
    exit 1
}
cmd /c mklink /J "$link" "$target" | Out-Host
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host "Linked $link -> $target. Saved files: SavedVariables\HardCounters.lua and HardCounters_Diagnostics.lua (after /reload or logout). Read them; never edit them."
