# Run luacheck in WSL with the repo's .luacheckrc.
. (Join-Path $PSScriptRoot '_wsl.ps1')
Invoke-RepoWsl "luacheck ."
