# Shared helper: run a bash command inside WSL at the repo root and exit with its code.
# Git stays on Windows; only tests, lint and benchmarks run in WSL (see docs/DEV_SETUP.md).
function Invoke-RepoWsl {
    param([Parameter(Mandatory = $true)][string]$Command)
    $repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    & wsl.exe --cd "$repo" -e bash -lc "$Command" | Out-Host
    exit $LASTEXITCODE
}
