<#
.SYNOPSIS
    Migrates Azure DevOps repos to GitHub using GitHub Enterprise Importer (GEI).
.DESCRIPTION
    Reads batch config, generates GEI migration scripts, and executes batch migrations
    with monitoring, logging, and retry logic. Supports --all flag for teams/PRs.
.PARAMETER ConfigFile
    Path to migration-config.json
.PARAMETER BatchName
    Specific batch to migrate (from config batches). If omitted, processes all batches.
.PARAMETER DryRun
    Generate scripts without executing
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigFile,

    [string]$BatchName,

    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# --- Load Config ---
$config = Get-Content $ConfigFile -Raw | ConvertFrom-Json

$adoOrg = ($config.source.organization -replace "https://dev.azure.com/", "").TrimEnd("/")
$ghOrg = $config.target.organization
$adoPat = if ($config.source.pat) { $config.source.pat } else { $env:ADO_PAT }
$ghPat = if ($config.target.pat) { $config.target.pat } else { $env:GH_PAT }

if (-not $adoPat) { Write-Error "ADO PAT not found. Set in config or `$env:ADO_PAT"; exit 1 }
if (-not $ghPat) { Write-Error "GitHub PAT not found. Set in config or `$env:GH_PAT"; exit 1 }

$logDir = $config.options.logDirectory
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

$maxRetries = $config.options.retryCount
$retryDelay = $config.options.retryDelaySeconds

Write-Host "=== GEI Repo Migration ===" -ForegroundColor Cyan
Write-Host "Source: $adoOrg → Target: $ghOrg" -ForegroundColor Gray
if ($DryRun) { Write-Host "[DRY RUN MODE]" -ForegroundColor Yellow }

# --- Select Batches ---
$batches = $config.batches
if ($BatchName) {
    $batches = $batches | Where-Object { $_.name -eq $BatchName }
    if (-not $batches) { Write-Error "Batch '$BatchName' not found in config."; exit 1 }
}

# --- Set environment for GEI ---
$env:ADO_PAT = $adoPat
$env:GH_PAT = $ghPat

foreach ($batch in $batches) {
    Write-Host "`n--- Batch: $($batch.name) ---" -ForegroundColor Cyan
    Write-Host "Project: $($batch.adoProject) | Repos: $($batch.repos.Count)" -ForegroundColor Gray

    $batchLog = Join-Path $logDir "$($batch.name)-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    $migrationIds = @()

    foreach ($repoName in $batch.repos) {
        Write-Host "`n  Migrating: $($batch.adoProject)/$repoName" -ForegroundColor Yellow

        $targetRepo = $repoName.ToLower() -replace " ", "-"

        $geiArgs = @(
            "ado2gh", "migrate-repo",
            "--ado-org", $adoOrg,
            "--ado-team-project", $batch.adoProject,
            "--ado-repo", $repoName,
            "--github-org", $ghOrg,
            "--github-repo", $targetRepo,
            "--target-repo-visibility", $config.options.repoVisibility
        )

        if ($DryRun) {
            Write-Host "  [DRY RUN] gh $($geiArgs -join ' ')" -ForegroundColor Gray
            continue
        }

        $attempt = 0
        $success = $false

        while ($attempt -lt $maxRetries -and -not $success) {
            $attempt++
            Write-Host "  Attempt $attempt of $maxRetries..." -ForegroundColor Gray

            try {
                $output = gh @geiArgs 2>&1
                $outputStr = $output | Out-String

                # Extract migration ID
                $migIdMatch = [regex]::Match($outputStr, "Migration ID:\s*(\S+)")
                if ($migIdMatch.Success) {
                    $migId = $migIdMatch.Groups[1].Value
                    $migrationIds += @{ Repo = $repoName; MigrationId = $migId }
                    Write-Host "  Migration queued: $migId" -ForegroundColor Green
                    $success = $true
                }
                else {
                    Write-Host "  Output: $outputStr" -ForegroundColor Gray
                    if ($outputStr -notmatch "error|fail") { $success = $true }
                }

                "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $repoName | Attempt $attempt | $outputStr" | Out-File -Append $batchLog
            }
            catch {
                Write-Warning "  Attempt $attempt failed: $_"
                "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $repoName | Attempt $attempt | ERROR: $_" | Out-File -Append $batchLog
                if ($attempt -lt $maxRetries) {
                    Write-Host "  Retrying in $retryDelay seconds..." -ForegroundColor Yellow
                    Start-Sleep -Seconds $retryDelay
                }
            }
        }

        if (-not $success) {
            Write-Host "  FAILED after $maxRetries attempts: $repoName" -ForegroundColor Red
        }
    }

    if ($DryRun) { continue }

    # --- Wait for migrations to complete ---
    if ($migrationIds.Count -gt 0) {
        Write-Host "`n  Waiting for migrations to complete..." -ForegroundColor Yellow

        foreach ($mig in $migrationIds) {
            Write-Host "  Checking: $($mig.Repo) (ID: $($mig.MigrationId))" -ForegroundColor Gray

            $waitArgs = @("ado2gh", "wait-for-migration", "--migration-id", $mig.MigrationId)

            try {
                $waitOutput = gh @waitArgs 2>&1
                $waitStr = $waitOutput | Out-String

                if ($waitStr -match "succeeded|completed") {
                    Write-Host "  [DONE] $($mig.Repo)" -ForegroundColor Green
                }
                elseif ($waitStr -match "failed") {
                    Write-Host "  [FAILED] $($mig.Repo) — Check migration log" -ForegroundColor Red
                }
                else {
                    Write-Host "  [STATUS] $waitStr" -ForegroundColor Gray
                }

                "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $($mig.Repo) | WAIT | $waitStr" | Out-File -Append $batchLog
            }
            catch {
                Write-Warning "  Error waiting for $($mig.Repo): $_"
            }
        }
    }

    Write-Host "`n  Batch log: $batchLog" -ForegroundColor Green
}

# --- Summary ---
Write-Host "`n=== Migration Summary ===" -ForegroundColor Cyan
Write-Host "Batches processed: $($batches.Count)" -ForegroundColor Gray
Write-Host "Log directory: $logDir" -ForegroundColor Gray
Write-Host "`nNext steps:" -ForegroundColor Yellow
Write-Host "  1. Run 03-post-migrate/reclaim-mannequins.ps1" -ForegroundColor White
Write-Host "  2. Run 03-post-migrate/set-visibility.ps1" -ForegroundColor White
Write-Host "  3. Run 02-migrate/migrate-pipelines.ps1" -ForegroundColor White
Write-Host "  4. Run 02-migrate/migrate-boards.ps1" -ForegroundColor White

# Cleanup env
Remove-Item Env:\ADO_PAT -ErrorAction SilentlyContinue
Remove-Item Env:\GH_PAT -ErrorAction SilentlyContinue
