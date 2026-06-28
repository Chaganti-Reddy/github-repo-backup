<#
.SYNOPSIS
    Mirror-backup ALL your GitHub repos (public + private) to a local folder / external HDD.

.DESCRIPTION
    - Lists every repo you can access via the GitHub REST API (handles pagination).
    - For each repo: bare "mirror" clone on first run, fast "remote update --prune" after.
      A mirror clone holds EVERYTHING: all branches, tags, notes, full history.
    - Token is supplied per-git-command via an auth header. It is NOT written into any
      repo config on disk, so your backup drive carries no secret.
    - Per-repo error isolation: one bad repo never stops the rest.
    - Full timestamped log file + a pass/fail summary at the end.

.PREREQUISITES
    1. git installed (you have it).
    2. A GitHub Personal Access Token (PAT):
         - Classic token: https://github.com/settings/tokens  -> scope: "repo" (full).
           Add "read:org" too if you want repos from orgs you belong to.
         - Store it so the script can read it. EASIEST + safest for occasional use:
             setx GITHUB_BACKUP_TOKEN "ghp_xxxxYOURTOKENxxxx"
           (open a NEW terminal after setx so it takes effect)
         - Or just run the script and it will prompt you securely.

.EXAMPLE
    .\Backup-GitHubRepos.ps1 -Destination "E:\GitHubBackup"

.EXAMPLE
    # include repos from orgs + repos you only collaborate on:
    .\Backup-GitHubRepos.ps1 -Destination "E:\GitHubBackup" -Affiliation "owner,organization_member,collaborator"
#>

[CmdletBinding()]
param(
    # Where mirrors get stored. If omitted, the script lists your drives and
    # asks you to pick one + a folder name (auto HDD detect).
    [string]$Destination,

    # Which repos to include. Default = everything you own + org repos + collaborator repos.
    # Options (comma-joined): owner, collaborator, organization_member
    [string]$Affiliation = "owner,collaborator,organization_member",

    # PAT. If omitted, read from env var GITHUB_BACKUP_TOKEN, else prompt securely.
    [string]$Token,

    # Also produce a single-file <repo>.bundle snapshot per repo (portable archive).
    [switch]$Bundle,

    # Also download all Git LFS objects (large files) into each mirror. Needs git-lfs installed.
    [switch]$Lfs
)

$ErrorActionPreference = "Stop"

# ----------------------------------------------------------------------------
# 0. Resolve token (priority: param > env var > secure prompt)
# ----------------------------------------------------------------------------
if (-not $Token) { $Token = $env:GITHUB_BACKUP_TOKEN }
if (-not $Token) {
    $sec = Read-Host -AsSecureString "Enter GitHub Personal Access Token (input hidden)"
    $Token = [System.Net.NetworkCredential]::new("", $sec).Password
}
if (-not $Token) { throw "No token provided. Set GITHUB_BACKUP_TOKEN or pass -Token." }

# ----------------------------------------------------------------------------
# 1. Resolve destination. If not passed, auto-list drives and ask.
# ----------------------------------------------------------------------------
function Select-Destination {
    # List every filesystem drive with a letter, newest/removable first, show free space.
    $vols = Get-Volume |
        Where-Object { $_.DriveLetter } |
        Sort-Object @{ E = { $_.DriveType -eq 'Removable' } ; Descending = $true }, DriveLetter

    if (-not $vols) { throw "No drives with a letter found." }

    Write-Host ""
    Write-Host "Available drives:" -ForegroundColor Cyan
    $i = 0
    foreach ($v in $vols) {
        $i++
        $freeGB = [math]::Round($v.SizeRemaining / 1GB, 1)
        $sizeGB = [math]::Round($v.Size / 1GB, 1)
        $label  = if ($v.FileSystemLabel) { $v.FileSystemLabel } else { "(no label)" }
        "{0}. {1}:  {2}  [{3}]  {4} GB free / {5} GB" -f `
            $i, $v.DriveLetter, $label, $v.DriveType, $freeGB, $sizeGB | Write-Host
    }
    Write-Host ""

    do {
        $pick = Read-Host "Pick drive number (1-$($vols.Count))"
        $valid = ($pick -as [int]) -ge 1 -and ($pick -as [int]) -le $vols.Count
        if (-not $valid) { Write-Host "Enter a number 1-$($vols.Count)." -ForegroundColor Yellow }
    } until ($valid)

    $drive  = $vols[[int]$pick - 1].DriveLetter
    $folder = Read-Host "Folder name on ${drive}: (Enter for 'GitHubBackup')"
    if ([string]::IsNullOrWhiteSpace($folder)) { $folder = "GitHubBackup" }

    return (Join-Path "${drive}:\" $folder)
}

if (-not $Destination) {
    $Destination = Select-Destination
    Write-Host "Using destination: $Destination" -ForegroundColor Green
}

# ----------------------------------------------------------------------------
#    Prep destination + logging
# ----------------------------------------------------------------------------
if (-not (Test-Path $Destination)) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
}
$Destination = (Resolve-Path $Destination).Path

$stamp   = (Get-Date).ToString("yyyy-MM-dd_HH-mm-ss")
$logDir  = Join-Path $Destination "_logs"
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logFile = Join-Path $logDir "backup_$stamp.log"

function Log {
    param([string]$Msg, [string]$Level = "INFO")
    $line = "{0} [{1}] {2}" -f (Get-Date).ToString("HH:mm:ss"), $Level, $Msg
    $line | Tee-Object -FilePath $logFile -Append
}

Log "GitHub backup started. Destination: $Destination"
Log "Affiliation filter: $Affiliation"

# Auth header passed to every git call (keeps token OUT of repo configs on disk).
$authHeader = "AUTHORIZATION: bearer $Token"

# Headers for REST API calls.
$apiHeaders = @{
    Authorization          = "Bearer $Token"
    Accept                 = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
    "User-Agent"           = "ps-github-backup"
}

# ----------------------------------------------------------------------------
# 2. Verify token + identify user
# ----------------------------------------------------------------------------
try {
    $me = Invoke-RestMethod -Uri "https://api.github.com/user" -Headers $apiHeaders
    Log "Authenticated as: $($me.login)"
}
catch {
    Log "Token check FAILED: $($_.Exception.Message)" "ERROR"
    throw "Could not authenticate to GitHub. Check the token + its scopes."
}

# If -Lfs requested, confirm git-lfs is actually installed; warn + disable if not.
if ($Lfs) {
    git lfs version *> $null
    if ($LASTEXITCODE -ne 0) {
        Log "git-lfs not found. Install from https://git-lfs.com then re-run. Skipping LFS." "WARN"
        $Lfs = $false
    } else {
        Log "git-lfs detected. Will fetch all LFS objects per repo."
    }
}

# ----------------------------------------------------------------------------
# 3. List ALL repos (paginated). 100 per page, follow until empty.
# ----------------------------------------------------------------------------
Log "Listing repositories..."
$repos = @()
$page  = 1
do {
    $uri = "https://api.github.com/user/repos?per_page=100&page=$page&affiliation=$Affiliation"
    $batch = Invoke-RestMethod -Uri $uri -Headers $apiHeaders
    if ($batch.Count -gt 0) {
        $repos += $batch
        Log ("  page {0}: {1} repos" -f $page, $batch.Count)
    }
    $page++
} while ($batch.Count -eq 100)

if ($repos.Count -eq 0) {
    Log "No repos returned. Check token scopes (needs 'repo')." "WARN"
    return
}
Log ("Total repos to back up: {0}" -f $repos.Count)

# ----------------------------------------------------------------------------
# 4. Mirror each repo. Clone on first run, update on later runs.
#    Layout on disk:  <Destination>\<owner>\<repo>.git  (bare mirror)
# ----------------------------------------------------------------------------
$ok = 0; $fail = 0; $failed = @()

foreach ($r in $repos) {
    $owner    = $r.owner.login
    $name     = $r.name
    $url      = $r.clone_url                       # https URL, NO token in it
    $ownerDir = Join-Path $Destination $owner
    $repoDir  = Join-Path $ownerDir "$name.git"

    New-Item -ItemType Directory -Path $ownerDir -Force | Out-Null

    try {
        if (Test-Path $repoDir) {
            Log "Updating $owner/$name ..."
            git -c "http.extraHeader=$authHeader" -C $repoDir remote update --prune 2>&1 |
                Tee-Object -FilePath $logFile -Append | Out-Null
        }
        else {
            Log "Cloning  $owner/$name ..."
            git -c "http.extraHeader=$authHeader" clone --mirror $url $repoDir 2>&1 |
                Tee-Object -FilePath $logFile -Append | Out-Null
        }

        if ($LASTEXITCODE -ne 0) { throw "git exited with code $LASTEXITCODE" }

        # Optional: pull every Git LFS object (large files) into the mirror.
        if ($Lfs) {
            git -c "http.extraHeader=$authHeader" -C $repoDir lfs fetch --all 2>&1 |
                Tee-Object -FilePath $logFile -Append | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "git lfs fetch failed (code $LASTEXITCODE)" }
        }

        # Optional: single-file portable snapshot of everything.
        if ($Bundle) {
            $bundleFile = Join-Path $ownerDir "$name.bundle"
            git -C $repoDir bundle create $bundleFile --all 2>&1 |
                Tee-Object -FilePath $logFile -Append | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "git bundle failed (code $LASTEXITCODE)" }
            Log "  bundle -> $bundleFile"
        }

        $ok++
    }
    catch {
        $fail++
        $failed += "$owner/$name"
        Log "FAILED $owner/$name : $($_.Exception.Message)" "ERROR"
    }
}

# ----------------------------------------------------------------------------
# 5. Summary
# ----------------------------------------------------------------------------
Log "-----------------------------------------------"
Log ("DONE. Success: {0}  Failed: {1}  Total: {2}" -f $ok, $fail, $repos.Count)
if ($fail -gt 0) {
    Log ("Failed repos: {0}" -f ($failed -join ", ")) "WARN"
    Log "Re-run the script to retry failed repos." "WARN"
}
Log "Log saved to: $logFile"
