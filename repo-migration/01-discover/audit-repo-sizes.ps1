<#
.SYNOPSIS
    Clones each repo and runs git-sizer to detect files/trees exceeding GEI limits.
.DESCRIPTION
    For each repo in repo-inventory.json:
      - Shallow clone (bare) to temp directory
      - Run git-sizer --json to get blob/tree/commit stats
      - Flag repos with blobs > 400 MB (GEI file limit) or > 100 MB (GitHub push limit)
      - Flag repos > 40 GB total
    Outputs detailed size report.
.PARAMETER ConfigPath
    Path to repo-migration-config.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "$PSScriptRoot\..\config\repo-migration-config.json",

    [Parameter(Mandatory = $false)]
    [string]$RepoName = "",

    [Parameter(Mandatory = $false)]
    [string]$BatchName = "",

    [Parameter(Mandatory = $false)]
    [string]$MigrationMode = "Batch"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$config    = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$reportDir = $config.output.reportDir
$logDir    = $config.output.logDir
$cloneDir  = $config.migration.cloneTempDir

foreach ($d in @($reportDir, $logDir, $cloneDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ── Verify git-sizer is installed ────────────────────────────────────────────
$gitSizer = Get-Command git-sizer -ErrorAction SilentlyContinue
if (-not $gitSizer) {
    Write-Error "git-sizer not found. Install it: https://github.com/github/git-sizer/releases or run 02-prep\install-tools.ps1"
}

# ── Load inventory ───────────────────────────────────────────────────────────
$inventoryPath = Join-Path $reportDir "repo-inventory.json"
if (-not (Test-Path $inventoryPath)) {
    Write-Error "repo-inventory.json not found. Run 01-discover\discover-repos.ps1 first."
}
$repos = Get-Content $inventoryPath -Raw | ConvertFrom-Json

# ── Filtering logic ──────────────────────────────────────────────────────────
if ($MigrationMode -eq 'Single' -and -not [string]::IsNullOrWhiteSpace($RepoName)) {
    $rName = $RepoName.Trim()
    $repos = @($repos | Where-Object { $_.Name -eq $rName })
    Write-Host "Filtering for single repo: $rName (Found: $($repos.Count))" -ForegroundColor Cyan
} elseif ($MigrationMode -eq 'Batch' -and -not [string]::IsNullOrWhiteSpace($BatchName)) {
    $bName = $BatchName.Trim()
    $batch = $config.batches | Where-Object { $_.name -eq $bName }
    if ($batch) {
        $batchRepos = $batch.repos
        $repos = @($repos | Where-Object { $_.Name -in $batchRepos })
        Write-Host "Filtering for batch: $bName (Found: $($repos.Count) of $($batchRepos.Count) repos)" -ForegroundColor Cyan
    } else {
        Write-Warning "Batch '$bName' not found in config. Auditing all inventory repos."
    }
}

$adoPat = if ($config.source.pat -eq '$(ADO_PAT)') { $env:ADO_PAT } else { $config.source.pat }
if ([string]::IsNullOrWhiteSpace($adoPat)) { Write-Error "Set ADO_PAT environment variable" }

# ── ADO API base + auth header ───────────────────────────────────────────────
$ADO_Org  = if ($config.source.organization -match '^\$\(') { $env:ADO_Org } else { $config.source.organization }
$adoProj = if ($config.source.project      -match '^\$\(') { $env:ADO_Project } else { $config.source.project }
$adoPat  = if ($config.source.pat           -match '^\$\(') { $env:ADO_PAT } else { $config.source.pat }

$ADO_Org = ($ADO_Org ?? '').TrimEnd('/')
if ($ADO_Org -and $ADO_Org -notmatch '^https?://') {
    $ADO_Org = "https://dev.azure.com/$ADO_Org"
}

$base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$adoPat"))
$apiHeaders = @{ Authorization = "Basic $base64Auth" }

# Threshold: repos >= this size use API-only path (no clone)
$apiOnlyThresholdMB = 1024

Write-Host "=== Auditing repo sizes for $($repos.Count) repos ===" -ForegroundColor Cyan
Write-Host "  Repos >= ${apiOnlyThresholdMB} MB will use ADO REST API (no clone)" -ForegroundColor Gray

$results = @()

# ── Helper: Audit via ADO REST API (no clone needed) ─────────────────────────
function Get-RepoSizeViaApi {
    param($repo, $ADO_Org, $adoProj, $apiHeaders)

    $largestBlobs = @()
    $maxBlobSize  = 0

    # Use ADO Items API to recursively list all files in the default branch
    $defaultBranch = $repo.DefaultBranch
    if (-not $defaultBranch) {
        Write-Warning "  No default branch — using API size only"
        return @{ MaxBlobMB = 0; LargestBlobs = @() }
    }

    try {
        # Fetch file tree with sizes — ADO supports recursionLevel=Full
        $itemsUrl = "$ADO_Org/$adoProj/_apis/git/repositories/$($repo.Id)/items?recursionLevel=Full&versionDescriptor.version=$defaultBranch&api-version=7.1"
        $itemsResp = Invoke-RestMethod -Uri $itemsUrl -Headers $apiHeaders -Method Get

        if ($itemsResp.value) {
            # Filter to blobs (files) — ADO returns gitObjectType='blob' for files
            # Some items may lack isFolder; use gitObjectType or check for size property
            $files = @($itemsResp.value | Where-Object {
                $isFile = $false
                if ($_.PSObject.Properties['gitObjectType']) {
                    $isFile = $_.gitObjectType -eq 'blob'
                } elseif ($_.PSObject.Properties['isFolder']) {
                    $isFile = -not $_.isFolder
                } else {
                    $isFile = $_.PSObject.Properties['size'] -ne $null
                }
                $isFile -and $_.PSObject.Properties['size'] -and $_.size -gt 0
            } | Sort-Object { $_.size } -Descending |
                Select-Object -First 10)

            foreach ($f in $files) {
                $sizeMB = [math]::Round($f.size / 1MB, 2)
                $largestBlobs += [PSCustomObject]@{
                    SizeMB = $sizeMB
                    Hash   = $f.objectId
                    Path   = $f.path
                }
            }

            if ($files.Count -gt 0) {
                $maxBlobSize = [math]::Round($files[0].size / 1MB, 2)
            }
        }
    }
    catch {
        Write-Warning "  API items call failed: $_"
    }

    return @{ MaxBlobMB = $maxBlobSize; LargestBlobs = $largestBlobs }
}

foreach ($repo in $repos) {
    Write-Host "`n── [$($repo.Project)] $($repo.Name) ──" -ForegroundColor Yellow

    $maxBlobSize  = 0
    $largestBlobs = @()
    $totalSize    = $repo.SizeMB
    $auditMethod  = ""

    # ── LARGE REPOS: API-only path (no clone, no disk usage) ─────────────
    if ($repo.SizeMB -ge $apiOnlyThresholdMB) {
        $auditMethod = "API"
        Write-Host "  Using ADO REST API (repo is $($repo.SizeMB) MB — skipping clone)" -ForegroundColor Gray

        $apiResult    = Get-RepoSizeViaApi -repo $repo -ADO_Org $ADO_Org -adoProj $adoProj -apiHeaders $apiHeaders
        $maxBlobSize  = $apiResult.MaxBlobMB
        $largestBlobs = $apiResult.LargestBlobs
    }
    # ── SMALL REPOS: clone + git-sizer (precise analysis) ────────────────
    else {
        $auditMethod = "Clone"
        $clonePath = Join-Path $cloneDir "$($repo.Name).git"
        $cloneUrl  = $repo.RemoteUrl -replace '://[^@]+@', '://'
        $cloneAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("pat:$adoPat"))
        if (Test-Path $clonePath) { Remove-Item $clonePath -Recurse -Force }

        try {
            $defaultBranch = $repo.DefaultBranch
            $cloneArgs = @('-c', "http.extraHeader=Authorization: Basic $cloneAuth", 'clone', '--bare', '--quiet')
            if ($defaultBranch) {
                $cloneArgs += @('--single-branch', '--branch', $defaultBranch)
            }
            $cloneArgs += @($cloneUrl, $clonePath)
            $cloneOutput = & git @cloneArgs 2>&1
            if ($LASTEXITCODE -ne 0) { throw ($cloneOutput | Out-String) }
        }
        catch {
            Write-Warning "  Clone failed for $($repo.Name): $_ — falling back to API"
            $apiResult    = Get-RepoSizeViaApi -repo $repo -ADO_Org $ADO_Org -adoProj $adoProj -apiHeaders $apiHeaders
            $maxBlobSize  = $apiResult.MaxBlobMB
            $largestBlobs = $apiResult.LargestBlobs
            $auditMethod  = "API-fallback"

            $exceedsGEI  = $maxBlobSize -gt 400 -or $repo.SizeGB -gt 40
            $exceedsPush = $maxBlobSize -gt 100
            $results += [PSCustomObject]@{
                Project = $repo.Project; Name = $repo.Name
                Status  = if ($exceedsGEI) { "BLOCKED" } elseif ($exceedsPush) { "WARNING" } else { "OK" }
                MaxBlobMB = $maxBlobSize; TotalSizeMB = $totalSize; TotalSizeGB = $repo.SizeGB
                ExceedsGEI = $exceedsGEI; ExceedsPushLimit = $exceedsPush
                Top10Files = $largestBlobs; AuditMethod = $auditMethod
            }
            continue
        }

        try {
            Push-Location $clonePath
            $sizerJson = git-sizer --json 2>$null | ConvertFrom-Json -AsHashtable

            if ($sizerJson.ContainsKey('uniqueBlobSize') -and $sizerJson['uniqueBlobSize'].ContainsKey('maxSize')) {
                $maxBlobSize = [math]::Round($sizerJson['uniqueBlobSize']['maxSize'] / 1MB, 2)
            }

            # Enumerate blobs for small repos (fast enough under 1 GB)
            try {
                $blobLines = git rev-list --objects --all 2>$null |
                    git cat-file --batch-check='%(objecttype) %(objectsize) %(objectname) %(rest)' 2>$null |
                    Where-Object { $_ -match '^blob' } |
                    Sort-Object { [int64]($_ -split '\s+')[1] } -Descending |
                    Select-Object -First 10
                foreach ($line in $blobLines) {
                    $parts = $line -split '\s+', 4
                    $largestBlobs += [PSCustomObject]@{
                        SizeMB = [math]::Round([int64]$parts[1] / 1MB, 2)
                        Hash   = $parts[2]
                        Path   = $parts[3]
                    }
                }
            }
            catch {
                Write-Warning "  Could not enumerate blobs for $($repo.Name)"
            }
        }
        finally {
            Pop-Location
            if (Test-Path $clonePath) {
                Write-Host "  Cleaning up clone for $($repo.Name)..." -ForegroundColor Gray
                Remove-Item $clonePath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # ── Evaluate limits ──────────────────────────────────────────────────
    $exceedsGEI  = $maxBlobSize -gt 400 -or $repo.SizeGB -gt 40
    $exceedsPush = $maxBlobSize -gt 100

    if ($exceedsGEI) {
        Write-Warning "  BLOCKER: Exceeds GEI limits (max blob: ${maxBlobSize} MB, total: $($repo.SizeGB) GB)"
    }
    elseif ($exceedsPush) {
        Write-Warning "  WARNING: Has files > 100 MB — will need Git LFS after migration"
    }
    else {
        Write-Host "  OK (max blob: ${maxBlobSize} MB) [$auditMethod]" -ForegroundColor Green
    }

    $results += [PSCustomObject]@{
        Project          = $repo.Project
        Name             = $repo.Name
        Status           = if ($exceedsGEI) { "BLOCKED" } elseif ($exceedsPush) { "WARNING" } else { "OK" }
        MaxBlobMB        = $maxBlobSize
        TotalSizeMB      = $totalSize
        TotalSizeGB      = $repo.SizeGB
        ExceedsGEI       = $exceedsGEI
        ExceedsPushLimit = $exceedsPush
        Top10Files       = $largestBlobs
        AuditMethod      = $auditMethod
    }
}

# ── Final cleanup (safety net) ───────────────────────────────────────────────
if (Test-Path $cloneDir) { Remove-Item $cloneDir -Recurse -Force -ErrorAction SilentlyContinue }

# ── Report ───────────────────────────────────────────────────────────────────
$jsonOut = Join-Path $reportDir "repo-size-audit.json"
$results | ConvertTo-Json -Depth 5 | Out-File $jsonOut -Encoding utf8

Write-Host "`n=== Size Audit Summary ===" -ForegroundColor Green
Write-Host "  Total repos       : $($results.Count)"
Write-Host "  OK                : $(@($results | Where-Object Status -eq 'OK').Count)"
Write-Host "  WARNING (>100MB)  : $(@($results | Where-Object Status -eq 'WARNING').Count)"
Write-Host "  BLOCKED (GEI)     : $(@($results | Where-Object Status -eq 'BLOCKED').Count)"
Write-Host "  CLONE_FAILED      : $(@($results | Where-Object Status -eq 'CLONE_FAILED').Count)"

$blocked = @($results | Where-Object Status -eq 'BLOCKED')
if ($blocked) {
    Write-Host "`nBLOCKED repos (must resolve before migration):" -ForegroundColor Red
    $blocked | Format-Table Name, MaxBlobMB, TotalSizeGB -AutoSize
}

Write-Host "`nReport saved: $jsonOut"
Write-Host "Next step: Run 01-discover\scan-secrets.ps1 to check for exposed credentials."

