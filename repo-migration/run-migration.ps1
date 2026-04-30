<#
.SYNOPSIS
    Orchestrates the full repo migration flow: Discover â†’ Prep â†’ Migrate â†’ Validate.
.DESCRIPTION
    Runs each step in order with gate checks between phases.
    Can resume from any step by specifying -StartFrom.
.PARAMETER ConfigPath
    Path to repo-migration-config.json
.PARAMETER StartFrom
    Step to start from: discover, prep, migrate, validate (default: discover)
.PARAMETER BatchName
    Specific batch (default: all batches)
.PARAMETER DryRun
    Pass through to migration step
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "$PSScriptRoot\config\repo-migration-config.json",

    [ValidateSet("discover", "prep", "migrate", "validate")]
    [string]$StartFrom = "discover",

    [string]$BatchName,

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$baseDir = $PSScriptRoot

$steps = @(
    @{ Name = "discover"; Order = 1 }
    @{ Name = "prep";     Order = 2 }
    @{ Name = "migrate";  Order = 3 }
    @{ Name = "validate"; Order = 4 }
)

$startOrder = ($steps | Where-Object { $_.Name -eq $StartFrom }).Order

Write-Host @"
â•”â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•—
â•‘      ADO â†’ GitHub Repo Migration Orchestrator    â•‘
â• â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•£
â•‘  Starting from : $StartFrom
â•‘  Config        : $ConfigPath
â•‘  Batch         : $(if ($BatchName) { $BatchName } else { 'ALL' })
â•‘  Dry Run       : $DryRun
â•šâ•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
"@ -ForegroundColor Cyan

function Invoke-Step {
    param([string]$Label, [scriptblock]$Action)
    Write-Host "`nâ–¶ $Label" -ForegroundColor Magenta
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        & $Action
        $sw.Stop()
        Write-Host "âœ” $Label completed ($([math]::Round($sw.Elapsed.TotalSeconds))s)" -ForegroundColor Green
        return $true
    }
    catch {
        $sw.Stop()
        Write-Host "âœ— $Label FAILED: $_" -ForegroundColor Red
        return $false
    }
}

function Confirm-Gate {
    param([string]$Message)
    Write-Host "`nâ•â•â•â• GATE CHECK â•â•â•â•" -ForegroundColor Yellow
    Write-Host $Message -ForegroundColor Yellow
    $response = Read-Host "Continue? [y/N]"
    if ($response -ne 'y') {
        Write-Host "Aborted by user." -ForegroundColor Red
        exit 1
    }
}

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# STEP 1: DISCOVER
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
if ($startOrder -le 1) {
    $ok = Invoke-Step "1.1 â€” Discover Repos" {
        & "$baseDir\01-discover\discover-repos.ps1" -ConfigPath $ConfigPath
    }
    if (-not $ok) { Write-Error "Discovery failed. Fix errors and retry." }

    $ok = Invoke-Step "1.2 â€” Audit Repo Sizes" {
        & "$baseDir\01-discover\audit-repo-sizes.ps1" -ConfigPath $ConfigPath
    }
    if (-not $ok) { Write-Warning "Size audit had errors. Review report before continuing." }

    $ok = Invoke-Step "1.3 â€” Scan for Secrets" {
        & "$baseDir\01-discover\scan-secrets.ps1" -ConfigPath $ConfigPath
    }
    if (-not $ok) { Write-Warning "Secret scan had errors. Review report before continuing." }

    # Gate: review discovery results
    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $reportDir = $config.output.reportDir

    $sizeReport = Join-Path $reportDir "repo-size-audit.json"
    $secretReport = Join-Path $reportDir "secret-scan-summary.json"

    if (Test-Path $sizeReport) {
        $sizeData = Get-Content $sizeReport -Raw | ConvertFrom-Json
        $blocked = $sizeData | Where-Object { $_.Status -eq 'BLOCKED' }
        if ($blocked) {
            Write-Host "`nBLOCKED repos detected (exceed GEI limits):" -ForegroundColor Red
            $blocked | ForEach-Object { Write-Host "  - $($_.Name) ($($_.TotalSizeGB) GB)" }
        }
    }

    if (Test-Path $secretReport) {
        $secretData = Get-Content $secretReport -Raw | ConvertFrom-Json
        $dirty = $secretData | Where-Object { $_.Status -eq 'SECRETS_FOUND' }
        if ($dirty) {
            Write-Host "`nRepos with secrets (MUST scrub before migration):" -ForegroundColor Red
            $dirty | ForEach-Object { Write-Host "  - $($_.Name) ($($_.FindingsCount) findings)" }
        }
    }

    Confirm-Gate "Review discovery results above. Proceed to preparation?"
}

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# STEP 2: PREP
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
if ($startOrder -le 2) {
    $ok = Invoke-Step "2.1 â€” Install/Verify Tools" {
        & "$baseDir\02-prep\install-tools.ps1"
    }
    if (-not $ok) { Write-Error "Tool installation failed." }

    # Check if secrets need scrubbing
    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $secretReport = Join-Path $config.output.reportDir "secret-scan-summary.json"
    $needsScrub = $false
    if (Test-Path $secretReport) {
        $secretData = Get-Content $secretReport -Raw | ConvertFrom-Json
        $needsScrub = ($secretData | Where-Object { $_.Status -eq 'SECRETS_FOUND' }).Count -gt 0
    }

    if ($needsScrub) {
        $ok = Invoke-Step "2.2 â€” Scrub Secrets" {
            & "$baseDir\02-prep\scrub-secrets.ps1" -ConfigPath $ConfigPath
        }
        if (-not $ok) { Write-Error "Secret scrubbing failed. Cannot proceed." }

        Write-Host "`nRe-running secret scan to verify clean..." -ForegroundColor Yellow
        & "$baseDir\01-discover\scan-secrets.ps1" -ConfigPath $ConfigPath
    }
    else {
        Write-Host "`n  No secrets to scrub â€” skipping step 2.2" -ForegroundColor Green
    }

    Confirm-Gate "Preparation complete. Ready to start migration?"
}

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# STEP 3: MIGRATE
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
if ($startOrder -le 3) {
    $migrateParams = @{ ConfigPath = $ConfigPath }
    if ($BatchName) { $migrateParams.BatchName = $BatchName }
    if ($DryRun)    { $migrateParams.DryRun = $true }

    $ok = Invoke-Step "3.1 â€” Migrate Repos (GEI)" {
        & "$baseDir\03-migrate\migrate-repos.ps1" @migrateParams
    }
    if (-not $ok) { Write-Error "Migration had failures. Review migration-results.json" }

    if (-not $DryRun) {
        Confirm-Gate "Migration complete. Proceed to validation?"
    }
}

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# STEP 4: VALIDATE
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
if ($startOrder -le 4 -and -not $DryRun) {
    $validateParams = @{ ConfigPath = $ConfigPath }
    if ($BatchName) { $validateParams.BatchName = $BatchName }

    $ok = Invoke-Step "4.1 â€” Validate Migrated Repos" {
        & "$baseDir\04-validate\validate-repos.ps1" @validateParams
    }

    $ok = Invoke-Step "4.2 â€” Reclaim Mannequins" {
        & "$baseDir\04-validate\reclaim-mannequins.ps1" -ConfigPath $ConfigPath
    }

    # Final summary
    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $validationReport = Join-Path $config.output.reportDir "validation-results.json"
    if (Test-Path $validationReport) {
        $results = Get-Content $validationReport -Raw | ConvertFrom-Json
        $passed = ($results | Where-Object Status -eq 'PASS').Count
        $failed = ($results | Where-Object Status -eq 'FAIL').Count

        Write-Host @"

â•”â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•—
â•‘           MIGRATION COMPLETE                      â•‘
â• â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•£
â•‘  Repos validated : $($results.Count)
â•‘  Passed          : $passed
â•‘  Failed          : $failed
â•šâ•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
"@ -ForegroundColor $(if ($failed -gt 0) { 'Yellow' } else { 'Green' })
    }
}

Write-Host "`nAll reports are in: $($config.output.reportDir)" -ForegroundColor Cyan


