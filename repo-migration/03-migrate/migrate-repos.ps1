<#
.SYNOPSIS
    Migrates Git repos from Azure DevOps to GitHub using GitHub Enterprise Importer (GEI).
.DESCRIPTION
    Reads batches from config. For each batch:
      1. Generates GEI migration script via gh gei generate-script
      2. Queues migrations for all repos in the batch
      3. Monitors migration status with polling
      4. Logs results per repo (success/failed/warning)
      5. Downloads migration logs for failed migrations
    Supports --lock-source-repo to freeze ADO repos during migration.
.PARAMETER ConfigPath
    Path to repo-migration-config.json
.PARAMETER BatchName
    Specific batch to run (from config.batches[].name). If omitted, runs ALL batches.
.PARAMETER DryRun
    If set, generates scripts but does not execute them.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "$PSScriptRoot\..\config\repo-migration-config.json",

    [Parameter(Mandatory = $false)]
    [string]$BatchName,

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$config    = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$adoOrg    = ($config.source.organization -replace 'https://dev.azure.com/', '').TrimEnd('/')
$adoProj   = $config.source.project
$ghOrg     = $config.target.organization
$reportDir = $config.output.reportDir
$logDir    = $config.output.logDir

foreach ($d in @($reportDir, $logDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ── Validate env vars ───────────────────────────────────────────────────────
$adoPat = if ($config.source.pat -eq '$(ADO_PAT)') { $env:ADO_PAT } else { $config.source.pat }
$ghPat  = if ($config.target.pat -eq '$(GH_PAT)') { $env:GH_PAT } else { $config.target.pat }

if ([string]::IsNullOrWhiteSpace($adoPat)) { Write-Error "Set ADO_PAT environment variable" }
if ([string]::IsNullOrWhiteSpace($ghPat))  { Write-Error "Set GH_PAT environment variable" }

# GEI uses these env vars directly
$env:ADO_PAT = $adoPat
$env:GH_PAT  = $ghPat

# ── Validate GEI extension ──────────────────────────────────────────────────
try { gh gei --help | Out-Null }
catch { Write-Error "gh gei extension not found. Run: gh extension install github/gh-gei" }

# ── Determine batches to run ────────────────────────────────────────────────
$batches = $config.batches
if ($BatchName) {
    $batches = $batches | Where-Object { $_.name -eq $BatchName }
    if (-not $batches) { Write-Error "Batch '$BatchName' not found in config" }
}

# ── Load inventory to get repo IDs ──────────────────────────────────────────
$inventoryPath = Join-Path $reportDir "repo-inventory.json"
$inventory = @()
if (Test-Path $inventoryPath) {
    $inventory = Get-Content $inventoryPath -Raw | ConvertFrom-Json
}

# ── Migration options ───────────────────────────────────────────────────────
$lockSource     = $config.migration.lockSourceRepo
$targetVis      = $config.migration.targetRepoVisibility
$retryCount     = $config.migration.retryCount
$retryDelay     = $config.migration.retryDelaySeconds
$pollIntervalSec = 30

Write-Host "=== GEI Repo Migration ===" -ForegroundColor Cyan
Write-Host "  Source : $adoOrg / $adoProj"
Write-Host "  Target : $ghOrg"
Write-Host "  Batches: $($batches.Count)"
Write-Host "  DryRun : $DryRun"
Write-Host ""

$migrationResults = @()

foreach ($batch in $batches) {
    Write-Host "━━━ Batch: $($batch.name) ($($batch.repos.Count) repos) ━━━" -ForegroundColor Magenta

    foreach ($repoName in $batch.repos) {
        Write-Host "`n── $repoName ──" -ForegroundColor Yellow

        $targetRepo = $repoName  # Same name by default

        # Build GEI command
        $geiArgs = @(
            "gei", "migrate-repo"
            "--ado-org", $adoOrg
            "--ado-team-project", $adoProj
            "--ado-repo", $repoName
            "--github-org", $ghOrg
            "--github-repo", $targetRepo
            "--target-repo-visibility", $targetVis
        )

        if ($lockSource) {
            $geiArgs += "--lock-ado-repo"
        }

        $cmdString = "gh " + ($geiArgs -join " ")
        Write-Host "  CMD: $cmdString" -ForegroundColor Gray

        if ($DryRun) {
            Write-Host "  [DRY RUN] Skipping execution" -ForegroundColor DarkYellow
            $migrationResults += [PSCustomObject]@{
                Batch = $batch.name; Repo = $repoName; Status = "DRY_RUN"; MigrationId = ""; Duration = ""
            }
            continue
        }

        # Execute with retry
        $success = $false
        $migrationId = ""
        $attempt = 0

        while (-not $success -and $attempt -lt $retryCount) {
            $attempt++
            Write-Host "  Attempt $attempt/$retryCount..." -ForegroundColor Cyan

            try {
                $output = & gh @geiArgs 2>&1
                $outputStr = $output -join "`n"

                # Extract migration ID from output
                if ($outputStr -match '(RM_\w+)') {
                    $migrationId = $Matches[1]
                    Write-Host "  Migration queued: $migrationId" -ForegroundColor Green
                }

                $success = $true
            }
            catch {
                Write-Warning "  Attempt $attempt failed: $_"
                if ($attempt -lt $retryCount) {
                    Write-Host "  Retrying in $retryDelay seconds..." -ForegroundColor Yellow
                    Start-Sleep -Seconds $retryDelay
                }
            }
        }

        if (-not $success) {
            Write-Host "  FAILED after $retryCount attempts" -ForegroundColor Red
            $migrationResults += [PSCustomObject]@{
                Batch = $batch.name; Repo = $repoName; Status = "FAILED"; MigrationId = ""; Duration = ""
            }
            continue
        }

        # Poll for completion
        if ($migrationId) {
            Write-Host "  Waiting for migration to complete..."
            $startTime = Get-Date
            $completed = $false

            while (-not $completed) {
                Start-Sleep -Seconds $pollIntervalSec
                $elapsed = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)

                try {
                    $statusOutput = & gh gei wait-for-migration --migration-id $migrationId 2>&1
                    $statusStr = $statusOutput -join "`n"

                    if ($statusStr -match 'succeeded|completed') {
                        $completed = $true
                        $duration = "$elapsed min"
                        Write-Host "  SUCCEEDED ($duration)" -ForegroundColor Green
                        $migrationResults += [PSCustomObject]@{
                            Batch = $batch.name; Repo = $repoName; Status = "SUCCEEDED"
                            MigrationId = $migrationId; Duration = $duration
                        }
                    }
                    elseif ($statusStr -match 'failed') {
                        $completed = $true
                        Write-Host "  MIGRATION FAILED" -ForegroundColor Red
                        $migrationResults += [PSCustomObject]@{
                            Batch = $batch.name; Repo = $repoName; Status = "MIGRATION_FAILED"
                            MigrationId = $migrationId; Duration = "$elapsed min"
                        }

                        # Download migration log
                        $migLogPath = Join-Path $logDir "migration-log-$repoName.log"
                        try {
                            & gh gei download-logs --github-org $ghOrg --migration-id $migrationId | Out-File $migLogPath -Encoding utf8
                            Write-Host "  Migration log: $migLogPath" -ForegroundColor Yellow
                        }
                        catch { Write-Warning "  Could not download migration log" }
                    }
                    else {
                        Write-Host "  Still in progress... ($elapsed min elapsed)" -ForegroundColor Gray
                    }
                }
                catch {
                    Write-Warning "  Status check error: $_"
                }

                # Safety timeout: 4 hours
                if ($elapsed -gt 240) {
                    Write-Warning "  Migration exceeded 4-hour timeout. Check manually: gh gei wait-for-migration --migration-id $migrationId"
                    $migrationResults += [PSCustomObject]@{
                        Batch = $batch.name; Repo = $repoName; Status = "TIMEOUT"
                        MigrationId = $migrationId; Duration = "$elapsed min"
                    }
                    $completed = $true
                }
            }
        }
    }
}

# ── Report ───────────────────────────────────────────────────────────────────
$resultPath = Join-Path $reportDir "migration-results.json"
$csvPath    = Join-Path $reportDir "migration-results.csv"
$migrationResults | ConvertTo-Json -Depth 3 | Out-File $resultPath -Encoding utf8
$migrationResults | Export-Csv $csvPath -NoTypeInformation -Encoding utf8

Write-Host "`n=== Migration Summary ===" -ForegroundColor Green
Write-Host "  Total repos      : $($migrationResults.Count)"
Write-Host "  Succeeded        : $(($migrationResults | Where-Object Status -eq 'SUCCEEDED').Count)"
Write-Host "  Failed           : $(($migrationResults | Where-Object Status -match 'FAILED').Count)"
Write-Host "  Timeout          : $(($migrationResults | Where-Object Status -eq 'TIMEOUT').Count)"
Write-Host "  Dry Run          : $(($migrationResults | Where-Object Status -eq 'DRY_RUN').Count)"

$failed = $migrationResults | Where-Object { $_.Status -match 'FAILED|TIMEOUT' }
if ($failed) {
    Write-Host "`nFailed migrations:" -ForegroundColor Red
    $failed | Format-Table Batch, Repo, Status, MigrationId -AutoSize
}

Write-Host "`nResults: $resultPath"
Write-Host "Next step: Run 04-validate\validate-repos.ps1 to verify migrated repos."
