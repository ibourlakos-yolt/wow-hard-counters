# Run the busted test suite in WSL (PUC Lua 5.1).
# Usage: tools\test.ps1 [extra busted args], e.g. tools\test.ps1 --filter=calendar
. (Join-Path $PSScriptRoot '_wsl.ps1')
$extra = ($args | ForEach-Object { "'$_'" }) -join ' '
Invoke-RepoWsl "busted $extra"
