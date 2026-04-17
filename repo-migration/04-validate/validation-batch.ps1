<#
.SYNOPSIS
    Batch validation wrapper — merges multi-agent summaries, skips SKIPPED repos,
    and calls validate-migration.ps1 for actual validation.
.DESCRIPTION
    Designed for use with azure-pipeline-batch.yaml (matrix strategy).
    Steps:
      1. Merges batch-migration-summary-agent*.json into a single summary
      2. Reads migration state per repo — skips repos with State = SKIPPED
      3. Writes a filtered summary (non-skipped repos only)
      4. Calls validate-migration.ps1 with the filtered summary
      5. Prints a combined summary (skipped + validated)

    Can also be called standalone outside of a pipeline.
.PARAMETER ADOOrg
    Azure DevOps organisation name
.PARAMETER ADOProject
    Azure DevOps project name
.PARAMETER GHOrg
    Target GitHub organisation name
.PARAMETER OutputDir
    Directory containing audit data and where reports are saved (default: ./output)
.PARAMETER ExpectedVisibility
    Expected GitHub repo visibility: internal | private | public  (default: private)
.PARAMETER BatchSummaryJson
    Explicit path to a pre-merged batch-migration-summary.json.
    If omitted, the script auto-merges agent-suffixed files from OutputDir/reports.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]  [string]$ADOOrg,
    [Parameter(Mandatory = $true)]  [string]$ADOProject,
    [Parameter(Mandatory = $true)]  [string]$GHOrg,
    [Parameter(Mandatory = $false)] [string]$OutputDir          = "$PSScriptRoot\..\output",
    [Parameter(Mandatory = $false)] [string]$ExpectedVisibility = "private",
    [Parameter(Mandatory = $false)] [string]$BatchSummaryJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Note: visibility is read from config.json inside validate-migration.ps1 directly

$reportDir      = "$OutputDir\reports"
$validateScript = "$PSScriptRoot\validate-migration.ps1"

if (-not (Test-Path $validateScript)) { Write-Error "validate-migration.ps1 not found at: $validateScript" }
New-Item -ItemType Directory -Path $reportDir -Force | Out-Null

# ── 1. Merge multi-agent summaries ───────────────────────────────────────────
Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  BATCH VALIDATION"
Write-Host "  ADO:    $ADOOrg / $ADOProject"
Write-Host "  GitHub: $GHOrg"
Write-Host "======================================================" -ForegroundColor Cyan

$merged = @()

if ($BatchSummaryJson) {
    # Caller supplied a specific file
    if (-not (Test-Path $BatchSummaryJson)) { Write-Error "Batch summary not found: $BatchSummaryJson" }
    Write-Host "`n[Step 1] Using supplied summary: $BatchSummaryJson" -ForegroundColor Cyan
    $data = Get-Content $BatchSummaryJson -Raw | ConvertFrom-Json
    if ($data -is [array]) { $merged = $data } else { $merged = @($data) }
}
else {
    Write-Host "`n[Step 1] Merging agent summaries..." -ForegroundColor Cyan

    # Collect from agent-suffixed files (multi-agent mode)
    $agentFiles = Get-ChildItem "$reportDir\batch-migration-summary-agent*.json" -ErrorAction SilentlyContinue
    if ($agentFiles) {
        foreach ($f in $agentFiles) {
            Write-Host "  Merging: $($f.Name)"
            $data = Get-Content $f.FullName -Raw | ConvertFrom-Json
            if ($data -is [array]) { $merged += $data } else { $merged += @($data) }
        }
    }

    # Fallback: single-agent mode (no suffix)
    if ($merged.Count -eq 0) {
        $singleFile = "$reportDir\batch-migration-summary.json"
        if (Test-Path $singleFile) {
            Write-Host "  Using single-agent summary: batch-migration-summary.json"
            $data = Get-Content $singleFile -Raw | ConvertFrom-Json
            if ($data -is [array]) { $merged = $data } else { $merged = @($data) }
        }
    }

    if ($merged.Count -eq 0) { Write-Error "No batch summaries found in $reportDir" }
    Write-Host "  Total repos found: $($merged.Count)"
}

# ── 2. Separate SKIPPED vs to-validate ────────────────────────────────────────
Write-Host "`n[Step 2] Checking migration states..." -ForegroundColor Cyan

$toValidate  = @()
$skippedList = @()

foreach ($entry in $merged) {
    $state = $null
    foreach ($p in $entry.PSObject.Properties) { if ($p.Name -eq 'State') { $state = $p.Value } }

    if ($state -eq 'SKIPPED') {
        $skippedList += $entry
        Write-Host "  SKIP  : $($entry.ADORepo) → $($entry.GHRepo)  (migration was SKIPPED — repo already existed)" -ForegroundColor DarkGray
    }
    else {
        $toValidate += $entry
        Write-Host "  VALIDATE: $($entry.ADORepo) → $($entry.GHRepo)  (State=$state)" -ForegroundColor White
    }
}

Write-Host ""
Write-Host "  To validate : $($toValidate.Count)" -ForegroundColor Green
Write-Host "  Skipped     : $($skippedList.Count)" -ForegroundColor DarkGray

# ── 3. Write filtered summary and merged summary ─────────────────────────────
# Write full merged summary (so validate-migration.ps1 has all entries — it handles SKIPPED internally)
$mergedPath = "$reportDir\batch-migration-summary.json"
$merged | ConvertTo-Json -Depth 3 | Out-File $mergedPath -Encoding utf8 -Force
Write-Host "`n[Step 3] Wrote merged summary: $mergedPath ($($merged.Count) repos)"

if ($toValidate.Count -eq 0) {
    Write-Host ""
    Write-Host "======================================================" -ForegroundColor DarkGray
    Write-Host "  ALL REPOS SKIPPED — nothing to validate"
    Write-Host "  Skipped: $($skippedList.Count)"
    Write-Host "======================================================"

    # Still generate empty validation reports so pipeline artifacts don't fail
    @() | ConvertTo-Json -Depth 5 | Out-File "$reportDir\validation-results.json" -Encoding utf8
    "# Migration Validation Report`n`n> All repos were skipped (already existed). Nothing to validate." | Out-File "$reportDir\validation-summary.md" -Encoding utf8
    exit 0
}

# ── 4. Call validate-migration.ps1 with the merged summary ────────────────────
Write-Host "`n[Step 4] Running validation on $($toValidate.Count) repo(s)..." -ForegroundColor Cyan
Write-Host "         ($($skippedList.Count) repo(s) will be skipped by validate-migration.ps1)" -ForegroundColor DarkGray
Write-Host ""

& $validateScript `
    -ADOOrg             $ADOOrg `
    -ADOProject         $ADOProject `
    -GHOrg              $GHOrg `
    -OutputDir          $OutputDir `
    -ExpectedVisibility $ExpectedVisibility `
    -BatchSummaryJson   $mergedPath

$validationExitCode = $LASTEXITCODE

# ── 5. Print combined summary ─────────────────────────────────────────────────
Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  BATCH VALIDATION COMPLETE"
Write-Host "  Total repos in batch : $($merged.Count)"
Write-Host "  Skipped (not migrated): $($skippedList.Count)" -ForegroundColor DarkGray
Write-Host "  Validated             : $($toValidate.Count)" -ForegroundColor Green
Write-Host "======================================================"

if ($skippedList.Count -gt 0) {
    Write-Host "`n  Skipped repos:" -ForegroundColor DarkGray
    foreach ($s in $skippedList) {
        Write-Host "    - $($s.ADORepo)" -ForegroundColor DarkGray
    }
}

# Propagate exit code from validate-migration.ps1
exit $validationExitCode
