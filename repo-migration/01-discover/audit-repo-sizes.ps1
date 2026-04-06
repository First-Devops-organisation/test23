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
    [string]$ConfigPath = "$PSScriptRoot\..\config\repo-migration-config.json"
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

$adoPat = if ($config.source.pat -eq '$(ADO_PAT)') { $env:ADO_PAT } else { $config.source.pat }
if ([string]::IsNullOrWhiteSpace($adoPat)) { Write-Error "Set ADO_PAT environment variable" }

Write-Host "=== Auditing repo sizes for $($repos.Count) repos ===" -ForegroundColor Cyan

$results = @()

foreach ($repo in $repos) {
    Write-Host "`n── $($repo.Name) ──" -ForegroundColor Yellow

    $clonePath = Join-Path $cloneDir "$($repo.Name).git"

    # Clone bare — use header auth to avoid URL-encoding issues with PAT
    $cloneUrl = $repo.RemoteUrl -replace '://[^@]+@', '://'
    $base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("pat:$adoPat"))
    if (Test-Path $clonePath) { Remove-Item $clonePath -Recurse -Force }

    try {
        $cloneOutput = git -c http.extraHeader="Authorization: Basic $base64Auth" clone --bare --quiet $cloneUrl $clonePath 2>&1
        if ($LASTEXITCODE -ne 0) { throw ($cloneOutput | Out-String) }
    }
    catch {
        Write-Warning "  Clone failed for $($repo.Name): $_"
        $results += [PSCustomObject]@{
            Name = $repo.Name; Status = "CLONE_FAILED"; MaxBlobMB = 0; TotalSizeMB = $repo.SizeMB
            ExceedsGEI = $false; ExceedsPushLimit = $false; LargestFiles = @()
        }
        continue
    }

    # Run git-sizer
    try {
        Push-Location $clonePath
        $sizerJson = git-sizer --json 2>$null | ConvertFrom-Json -AsHashtable

        $maxBlobSize   = 0
        $totalSize     = $repo.SizeMB
        if ($sizerJson.ContainsKey('uniqueBlobSize') -and $sizerJson['uniqueBlobSize'].ContainsKey('maxSize')) {
            $maxBlobSize = [math]::Round($sizerJson['uniqueBlobSize']['maxSize'] / 1MB, 2)
        }

        # Find largest blobs via git rev-list
        $largestBlobs = @()
        try {
            $blobList = git rev-list --objects --all | git cat-file --batch-check='%(objecttype) %(objectsize) %(objectname) %(rest)' | Where-Object { $_ -match '^blob' } | Sort-Object { [int64]($_ -split '\s+')[1] } -Descending | Select-Object -First 10
            foreach ($line in $blobList) {
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

        $exceedsGEI  = $maxBlobSize -gt 400 -or $repo.SizeGB -gt 40
        $exceedsPush = $maxBlobSize -gt 100

        if ($exceedsGEI) {
            Write-Warning "  BLOCKER: Exceeds GEI limits (max blob: ${maxBlobSize} MB, total: $($repo.SizeGB) GB)"
        }
        elseif ($exceedsPush) {
            Write-Warning "  WARNING: Has files > 100 MB — will need Git LFS after migration"
        }
        else {
            Write-Host "  OK (max blob: ${maxBlobSize} MB)" -ForegroundColor Green
        }

        $results += [PSCustomObject]@{
            Name             = $repo.Name
            Status           = if ($exceedsGEI) { "BLOCKED" } elseif ($exceedsPush) { "WARNING" } else { "OK" }
            MaxBlobMB        = $maxBlobSize
            TotalSizeMB      = $totalSize
            TotalSizeGB      = $repo.SizeGB
            ExceedsGEI       = $exceedsGEI
            ExceedsPushLimit = $exceedsPush
            Top10Files       = $largestBlobs
        }
    }
    finally {
        Pop-Location
    }
}

# ── Cleanup clones ───────────────────────────────────────────────────────────
Write-Host "`nCleaning up temp clones..." -ForegroundColor Gray
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
