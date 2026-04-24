<#
.SYNOPSIS
    Scans all repos for secrets/credentials using gitleaks.
.DESCRIPTION
    Clones each repo, runs gitleaks detect, and aggregates findings into a report.
    CRITICAL for bank migrations — no repo should migrate with exposed secrets.
.PARAMETER InventoryFile
    Path to inventory JSON from inventory-assets.ps1
.PARAMETER Pat
    ADO PAT for cloning
.PARAMETER OutputDir
    Directory for scan reports
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InventoryFile,

    [Parameter(Mandatory = $true)]
    [string]$Pat,

    [string]$OutputDir = "./output/secrets",
    [string]$TempDir = "./tmp/secret-scan"
)

$ErrorActionPreference = "Stop"

# --- Verify gitleaks ---
$gitleaks = Get-Command gitleaks -ErrorAction SilentlyContinue
if (-not $gitleaks) {
    Write-Host "gitleaks not found. Install from: https://github.com/gitleaks/gitleaks/releases" -ForegroundColor Red
    Write-Host "Or run: winget install gitleaks" -ForegroundColor Yellow
    exit 1
}

# --- Load Inventory ---
$inventory = Get-Content $InventoryFile -Raw | ConvertFrom-Json

if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
if (-not (Test-Path $TempDir)) { New-Item -ItemType Directory -Path $TempDir -Force | Out-Null }

Write-Host "=== Secret Scan: $($inventory.organization) ===" -ForegroundColor Cyan

$summary = @()
$totalFindings = 0

foreach ($project in $inventory.projects) {
    foreach ($repo in $project.repos) {
        if ($repo.isDisabled) { continue }

        Write-Host "  Scanning: $($project.name)/$($repo.name)" -ForegroundColor Yellow

        $cloneDir = Join-Path $TempDir "$($project.name)_$($repo.name)"
        $reportFile = Join-Path $OutputDir "$($project.name)_$($repo.name)_secrets.json"

        try {
            $cloneUrl = $repo.url -replace "://", "://$Pat@"
            git clone $cloneUrl $cloneDir 2>&1 | Out-Null

            # Run gitleaks — scan ALL commits, ALL branches, full history
            $exitCode = 0
            & gitleaks detect --source $cloneDir --report-path $reportFile --report-format json --no-banner --log-opts="--all --full-history" 2>&1 | Out-Null
            $exitCode = $LASTEXITCODE

            $findingCount = 0
            if (Test-Path $reportFile) {
                $findings = Get-Content $reportFile -Raw | ConvertFrom-Json
                $findingCount = $findings.Count
            }

            $totalFindings += $findingCount

            $status = if ($findingCount -eq 0) { "CLEAN" } else { "SECRETS_FOUND" }

            $summary += [PSCustomObject]@{
                Project      = $project.name
                Repo         = $repo.name
                Status       = $status
                FindingCount = $findingCount
                ReportFile   = if ($findingCount -gt 0) { $reportFile } else { "" }
                Action       = if ($findingCount -gt 0) { "MUST scrub with git-filter-repo before migration" } else { "Ready" }
            }

            $color = if ($findingCount -eq 0) { "Green" } else { "Red" }
            Write-Host "    $status — $findingCount findings" -ForegroundColor $color
        }
        catch {
            Write-Warning "    Failed to scan $($project.name)/$($repo.name): $_"
            $summary += [PSCustomObject]@{
                Project      = $project.name
                Repo         = $repo.name
                Status       = "ERROR"
                FindingCount = -1
                ReportFile   = ""
                Action       = "Manual review required"
            }
        }
        finally {
            if (Test-Path $cloneDir) { Remove-Item -Recurse -Force $cloneDir }
        }
    }
}

# --- Summary ---
$cleanCount = ($summary | Where-Object { $_.Status -eq "CLEAN" }).Count
$dirtyCount = ($summary | Where-Object { $_.Status -eq "SECRETS_FOUND" }).Count
$errorCount = ($summary | Where-Object { $_.Status -eq "ERROR" }).Count

Write-Host "`n=== Secret Scan Summary ===" -ForegroundColor Cyan
Write-Host "Clean Repos:         $cleanCount" -ForegroundColor Green
Write-Host "Repos with Secrets:  $dirtyCount" -ForegroundColor Red
Write-Host "Errors:              $errorCount" -ForegroundColor Yellow
Write-Host "Total Findings:      $totalFindings" -ForegroundColor $(if ($totalFindings -gt 0) { "Red" } else { "Green" })

if ($dirtyCount -gt 0) {
    Write-Host "`n=== ACTION REQUIRED ===" -ForegroundColor Red
    Write-Host "The following repos contain secrets and MUST be scrubbed before migration:" -ForegroundColor Red
    $summary | Where-Object { $_.Status -eq "SECRETS_FOUND" } | ForEach-Object {
        Write-Host "  $($_.Project)/$($_.Repo) — $($_.FindingCount) secrets" -ForegroundColor Red
    }
    Write-Host "`nRun 01-prep/scrub-secrets.ps1 to remediate." -ForegroundColor Yellow
}

# --- Export ---
$csvFile = Join-Path $OutputDir "secret-scan-summary-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
$summary | Export-Csv -Path $csvFile -NoTypeInformation
Write-Host "`nScan summary saved to: $csvFile" -ForegroundColor Green

# Cleanup
if (Test-Path $TempDir) { Remove-Item -Recurse -Force $TempDir -ErrorAction SilentlyContinue }

# Exit 0 — finding secrets is expected (the scrub step handles them next)
exit 0
