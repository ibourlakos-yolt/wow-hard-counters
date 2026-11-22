# Upload the bundle zip to CurseForge (the CI release job runs this after the GitHub release), or check first.
#   tools\curseforge.ps1 -Version 0.2.0-beta1 -Zip dist\HardCounters-0.2.0-beta1.zip -Notes release-notes.md
#   tools\curseforge.ps1 -Check                          look up the game version on CurseForge, upload nothing
#   tools\curseforge.ps1 -Version 0.2.0-beta1 -DryRun    print what would be sent, no network, no token
# The token comes from $env:CF_API_TOKEN (a GitHub Actions secret the maintainer makes on CurseForge; never in a
# file or a log). The project ID is "## X-Curse-Project-ID" and the game version comes from "## Interface" in
# HardCounters.toc: 16001 -> "1.60.1", which must exist on CurseForge as a WoW Forever version, or nothing is sent.
# The release type follows the version: -alphaN Alpha, -betaN and -rcN Beta, none Release. Alpha and beta builds say
# "(experimental)" in the display name.
# Calls as in the BigWigs packager: GET /api/game/wow/versions, POST /api/projects/<id>/upload-file (multipart:
# "metadata" JSON and "file"), header x-api-token.
param(
    [string]$Version,
    [string]$Zip,
    [string]$Notes,
    [switch]$Check,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$site = 'https://wow.curseforge.com'
$FOREVER = 88568   # CurseForge's gameVersionTypeID for WoW Forever

$toc = Get-Content -Raw (Join-Path $repo 'HardCounters\HardCounters.toc')
if ($toc -notmatch '(?m)^## X-Curse-Project-ID:\s*(\d+)') { throw '## X-Curse-Project-ID not found in HardCounters.toc' }
$project = $Matches[1]
if ($toc -notmatch '(?m)^## Interface:\s*(\d+)') { throw '## Interface not found in HardCounters.toc' }
$interface = [int]$Matches[1]
# Interface MMmmpp -> M.mm.p (16001 -> 1.60.1).
$gameVersion = '{0}.{1}.{2}' -f [math]::Floor($interface / 10000), [math]::Floor(($interface % 10000) / 100), ($interface % 100)

if (-not $Check -and $Version -notmatch '^\d+\.\d+\.\d+(-(alpha|beta|rc)\d+)?$') { throw "Not a releasable version: '$Version'" }
$releaseType = switch -Regex ($Version) { '-alpha\d+$' { 'alpha' } '-(beta|rc)\d+$' { 'beta' } default { 'release' } }
$displayName = "Hard Counters $Version"
if ($Version -match '-(alpha|beta)\d+$') { $displayName += ' (experimental)' }

if ($Check) { "Project $project, game version $gameVersion (Interface $interface)" }
else { "Project $project, $releaseType, game version $gameVersion (Interface $interface), display name '$displayName'" }

$token = $env:CF_API_TOKEN
if (-not $DryRun) {
    if (-not $token) { throw 'CF_API_TOKEN is not set (the CurseForge API token, a GitHub Actions secret)' }
    $raw = & curl.exe -sS --retry 3 -H "x-api-token: $token" "$site/api/game/wow/versions"
    if ($LASTEXITCODE -ne 0) { throw "Fetching CurseForge game versions failed (curl $LASTEXITCODE)" }
    $all = ($raw -join "`n") | ConvertFrom-Json
    $forever = @($all | Where-Object { $_.gameVersionTypeID -eq $FOREVER })
    "WoW Forever versions on CurseForge: " + (($forever | ForEach-Object { "$($_.name) (id $($_.id))" }) -join ', ')
    $match = @($forever | Where-Object { $_.name -eq $gameVersion })
    if ($match.Count -ne 1) { throw "No single WoW Forever version named $gameVersion on CurseForge: nothing uploaded" }
    $gameVersionId = [int]$match[0].id
    "Game version $gameVersion = id $gameVersionId"
} else {
    $gameVersionId = 0
}
if ($Check) { return }

if (-not $Zip -or -not (Test-Path -LiteralPath $Zip)) { throw "Zip not found: $Zip" }
if (-not $Notes -or -not (Test-Path -LiteralPath $Notes)) { throw "Release notes not found: $Notes" }
$changelog = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Notes).Path, [Text.Encoding]::UTF8)
$metadata = [ordered]@{
    displayName   = $displayName
    gameVersions  = @($gameVersionId)
    releaseType   = $releaseType
    changelog     = $changelog
    changelogType = 'markdown'
} | ConvertTo-Json -Compress
$metaPath = Join-Path ([IO.Path]::GetTempPath()) 'curseforge-metadata.json'
[IO.File]::WriteAllText($metaPath, $metadata, (New-Object System.Text.UTF8Encoding($false)))

if ($DryRun) {
    "Dry run: would upload $Zip ($((Get-Item -LiteralPath $Zip).Length) bytes) to $site/api/projects/$project/upload-file"
    $metadata
    return
}

$result = Join-Path ([IO.Path]::GetTempPath()) 'curseforge-result.json'
$code = & curl.exe -sS --retry 3 --retry-delay 10 -w '%{http_code}' -o $result -H "x-api-token: $token" `
    -F "metadata=<$metaPath" -F "file=@$((Resolve-Path -LiteralPath $Zip).Path)" "$site/api/projects/$project/upload-file"
if ($LASTEXITCODE -ne 0) { throw "Upload failed (curl $LASTEXITCODE)" }
if ($code -ne '200') {
    $body = if (Test-Path $result) { Get-Content -Raw $result } else { '' }
    throw "CurseForge answered $code`: $body"
}
"Uploaded to CurseForge: " + (Get-Content -Raw $result)
