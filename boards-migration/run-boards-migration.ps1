# ============================================================
#  Boards Migration Orchestrator
#  Runs all phases end-to-end or a specific phase
#  Usage:
#    .\run-boards-migration.ps1                    # Full run
#    .\run-boards-migration.ps1 -Phase discover    # Single phase
#    .\run-boards-migration.ps1 -Phase migrate -DryRun  # Dry run
# ============================================================

[CmdletBinding()]
param(
    [ValidateSet("all", "discover", "prep", "migrate", "validate")]
    [string]$Phase = "all",
    [switch]$DryRun,
    [switch]$Resume,
    [string]$ConfigPath = "$PSScriptRoot\config\boards-migration-config.json"
)

$ErrorActionPreference = "Stop"
$scriptRoot = $PSScriptRoot

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Azure DevOps Boards → GitHub Projects Migration" -ForegroundColor Cyan
Write-Host "  Phase: $Phase $(if ($DryRun) {'(DRY RUN)'} else {''})" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# Validate config exists
if (-not (Test-Path $ConfigPath)) {
    Write-Host "ERROR: Config not found: $ConfigPath" -ForegroundColor Red
    exit 1
}

$startTime = Get-Date

# --- Phase 1: Discover ---
if ($Phase -in @("all", "discover")) {
    Write-Host "`n>>> PHASE 1: DISCOVERY <<<" -ForegroundColor Yellow
    Write-Host "─────────────────────────" -ForegroundColor DarkGray

    Write-Host "`n[1/2] Discovering work items..." -ForegroundColor White
    & "$scriptRoot\01-discover\discover-workitems.ps1" -ConfigPath $ConfigPath
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
        Write-Host "Discovery failed!" -ForegroundColor Red; exit 1
    }

    Write-Host "`n[2/2] Analyzing board structure..." -ForegroundColor White
    & "$scriptRoot\01-discover\analyze-board-structure.ps1" -ConfigPath $ConfigPath
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
        Write-Host "Analysis failed!" -ForegroundColor Red; exit 1
    }

    if ($Phase -eq "discover") {
        Write-Host "`nDiscovery complete. Review reports/ before proceeding." -ForegroundColor Green
        exit 0
    }
}

# --- Phase 2: Prepare ---
if ($Phase -in @("all", "prep")) {
    Write-Host "`n>>> PHASE 2: PREPARATION <<<" -ForegroundColor Yellow
    Write-Host "───────────────────────────" -ForegroundColor DarkGray

    Write-Host "`n[1/2] Validating mappings..." -ForegroundColor White
    & "$scriptRoot\02-prep\validate-mappings.ps1" -ConfigPath $ConfigPath
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
        Write-Host "Validation failed! Fix mapping errors before continuing." -ForegroundColor Red; exit 1
    }

    Write-Host "`n[2/2] Setting up GitHub labels..." -ForegroundColor White
    & "$scriptRoot\02-prep\setup-github-labels.ps1" -ConfigPath $ConfigPath
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
        Write-Host "Label setup failed!" -ForegroundColor Red; exit 1
    }

    if ($Phase -eq "prep") {
        Write-Host "`nPreparation complete." -ForegroundColor Green
        exit 0
    }
}

# --- Phase 3: Migrate ---
if ($Phase -in @("all", "migrate")) {
    Write-Host "`n>>> PHASE 3: MIGRATION <<<" -ForegroundColor Yellow
    Write-Host "─────────────────────────" -ForegroundColor DarkGray

    $migrateArgs = @("-ConfigPath", $ConfigPath)
    if ($DryRun) { $migrateArgs += "-DryRun" }
    if ($Resume) { $migrateArgs += "-Resume" }

    Write-Host "`nMigrating work items..." -ForegroundColor White
    & "$scriptRoot\03-migrate\migrate-workitems.ps1" @migrateArgs
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
        Write-Host "Migration had failures. Check logs." -ForegroundColor Red; exit 1
    }

    if ($Phase -eq "migrate") {
        Write-Host "`nMigration complete." -ForegroundColor Green
        exit 0
    }
}

# --- Phase 4: Validate ---
if ($Phase -in @("all", "validate")) {
    Write-Host "`n>>> PHASE 4: VALIDATION <<<" -ForegroundColor Yellow
    Write-Host "──────────────────────────" -ForegroundColor DarkGray

    Write-Host "`n[1/2] Validating migration..." -ForegroundColor White
    & "$scriptRoot\04-validate\validate-migration.ps1" -ConfigPath $ConfigPath

    Write-Host "`n[2/2] Generating report..." -ForegroundColor White
    & "$scriptRoot\04-validate\generate-report.ps1" -ConfigPath $ConfigPath
}

# --- Done ---
$duration = (Get-Date) - $startTime
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Migration Complete!" -ForegroundColor Green
Write-Host "  Duration: $($duration.ToString('hh\:mm\:ss'))" -ForegroundColor White
Write-Host "  Reports:  boards-migration/reports/" -ForegroundColor White
Write-Host "  Logs:     boards-migration/logs/" -ForegroundColor White
Write-Host "============================================================" -ForegroundColor Cyan
