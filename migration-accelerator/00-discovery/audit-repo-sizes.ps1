<#
.SYNOPSIS
    Clones repos and runs git-sizer to detect oversized repos, large blobs, and LFS usage.
.DESCRIPTION
    Iterates repos from inventory JSON, clones bare copies, runs git-sizer,
    and produces a consolidated sizing report with GEI compatibility flags.
.PARAMETER InventoryFile
    Path to the inventory JSON produced by inventory-assets.ps1
.PARAMETER Pat
    ADO PAT for cloning repos
.PARAMETER OutputDir
    Directory for reports
.PARAMETER TempDir
    Temp directory for bare clones (cleaned up after)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InventoryFile,

    [Parameter(Mandatory = $true)]
    [string]$Pat,

    [string]$OutputDir = "./output/sizing",
    [string]$TempDir = "./tmp/repos"
)

$ErrorActionPreference = "Stop"

# --- Verify git-sizer ---
$gitSizer = Get-Command git-sizer -ErrorAction SilentlyContinue
if (-not $gitSizer) {
    Write-Host "git-sizer not found. Install from: https://github.com/github/git-sizer/releases" -ForegroundColor Red
    Write-Host "Add git-sizer to PATH and re-run." -ForegroundColor Red
    exit 1
}

# --- Load Inventory ---
$inventory = Get-Content $InventoryFile -Raw | ConvertFrom-Json

if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
if (-not (Test-Path $TempDir)) { New-Item -ItemType Directory -Path $TempDir -Force | Out-Null }

$orgName = $inventory.organization
Write-Host "=== Repo Size Audit: $orgName ===" -ForegroundColor Cyan

$results = @()
$GEI_MAX_REPO_GB = 40
$GEI_MAX_FILE_MB = 400

foreach ($project in $inventory.projects) {
    foreach ($repo in $project.repos) {
        if ($repo.isDisabled) {
            Write-Host "  Skipping disabled repo: $($project.name)/$($repo.name)" -ForegroundColor Gray
            continue
        }

        Write-Host "  Analyzing: $($project.name)/$($repo.name) ($($repo.sizeMB) MB reported)" -ForegroundColor Yellow

        $cloneDir = Join-Path $TempDir "$($project.name)_$($repo.name)"

        try {
            # Clone bare
            $cloneUrl = $repo.url -replace "://", "://$Pat@"
            git clone --bare $cloneUrl $cloneDir 2>&1 | Out-Null

            # Run git-sizer
            $sizerOutput = & git-sizer --json $cloneDir 2>&1
            $sizerJson = $sizerOutput | ConvertFrom-Json

            # Check for LFS
            $lfsObjects = 0
            Push-Location $cloneDir
            try {
                $lfsFiles = git lfs ls-files 2>&1
                if ($lfsFiles -and $lfsFiles -notmatch "not a git lfs") {
                    $lfsObjects = ($lfsFiles | Measure-Object -Line).Lines
                }
            }
            catch { }
            Pop-Location

            $maxBlobSizeMB = 0
            if ($sizerJson.uniqueBlobSize.maxSize) {
                $maxBlobSizeMB = [math]::Round($sizerJson.uniqueBlobSize.maxSize / 1MB, 2)
            }

            $result = [PSCustomObject]@{
                Project            = $project.name
                Repo               = $repo.name
                ReportedSizeMB     = $repo.sizeMB
                ReportedSizeGB     = $repo.sizeGB
                MaxBlobSizeMB      = $maxBlobSizeMB
                TotalCommits       = if ($sizerJson.uniqueCommitCount) { $sizerJson.uniqueCommitCount.value } else { 0 }
                TotalBlobs         = if ($sizerJson.uniqueBlobCount) { $sizerJson.uniqueBlobCount.value } else { 0 }
                TotalTrees         = if ($sizerJson.uniqueTreeCount) { $sizerJson.uniqueTreeCount.value } else { 0 }
                LFSObjectCount     = $lfsObjects
                ExceedsGEIRepoLimit = ($repo.sizeGB -gt $GEI_MAX_REPO_GB)
                ExceedsGEIFileLimit = ($maxBlobSizeMB -gt $GEI_MAX_FILE_MB)
                HasLFS             = ($lfsObjects -gt 0)
                MigrationReady     = (($repo.sizeGB -le $GEI_MAX_REPO_GB) -and ($maxBlobSizeMB -le $GEI_MAX_FILE_MB))
            }
            $results += $result
        }
        catch {
            Write-Warning "  Failed to analyze $($project.name)/$($repo.name): $_"
            $results += [PSCustomObject]@{
                Project             = $project.name
                Repo                = $repo.name
                ReportedSizeMB      = $repo.sizeMB
                ReportedSizeGB      = $repo.sizeGB
                MaxBlobSizeMB       = "ERROR"
                TotalCommits        = "ERROR"
                TotalBlobs          = "ERROR"
                TotalTrees          = "ERROR"
                LFSObjectCount      = "ERROR"
                ExceedsGEIRepoLimit = ($repo.sizeGB -gt $GEI_MAX_REPO_GB)
                ExceedsGEIFileLimit = "UNKNOWN"
                HasLFS              = "UNKNOWN"
                MigrationReady      = $false
            }
        }
        finally {
            if (Test-Path $cloneDir) { Remove-Item -Recurse -Force $cloneDir }
        }
    }
}

# --- Summary ---
$readyCount = ($results | Where-Object { $_.MigrationReady -eq $true }).Count
$blockedCount = ($results | Where-Object { $_.MigrationReady -eq $false }).Count
$lfsCount = ($results | Where-Object { $_.HasLFS -eq $true }).Count

Write-Host "`n=== Sizing Summary ===" -ForegroundColor Cyan
Write-Host "Migration Ready: $readyCount" -ForegroundColor Green
Write-Host "Blocked:         $blockedCount" -ForegroundColor Red
Write-Host "Has LFS:         $lfsCount (requires separate LFS push)" -ForegroundColor Yellow

# --- Export ---
$csvFile = Join-Path $OutputDir "repo-sizing-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
$results | Export-Csv -Path $csvFile -NoTypeInformation
Write-Host "`nSizing report saved to: $csvFile" -ForegroundColor Green

$jsonFile = Join-Path $OutputDir "repo-sizing-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
$results | ConvertTo-Json -Depth 5 | Out-File -FilePath $jsonFile -Encoding utf8
Write-Host "Sizing JSON saved to: $jsonFile" -ForegroundColor Green

# Cleanup
if (Test-Path $TempDir) { Remove-Item -Recurse -Force $TempDir -ErrorAction SilentlyContinue }
