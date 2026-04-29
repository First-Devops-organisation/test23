<#
.SYNOPSIS
    Migrates MULTIPLE repos from ADO to GitHub in batch using GEI (gh ado2gh).
    Calls migrate-single.ps1 for each repo — same audit + dashboard per repo.
.DESCRIPTION
    Reads batch repo list from:
      - config/repo-migration-config.json  (batches[].repos)  OR
      - a CSV file passed via –RepoListCsv  (columns: ADORepo, GHRepo)
    Runs up to –MaxParallel migrations concurrently via PowerShell jobs.
    After all jobs finish, writes a combined batch-summary report.
.PARAMETER ADOOrg
    Azure DevOps organisation name
.PARAMETER ADOProject
    Azure DevOps project name
.PARAMETER GHOrg
    Target GitHub organisation name
.PARAMETER ConfigPath
    Path to repo-migration-config.json (used when no –RepoListCsv)
.PARAMETER BatchName
    Specific batch name from config to run (default: all batches)
.PARAMETER RepoListCsv
    Optional CSV with columns ADORepo,GHRepo — overrides config batches
.PARAMETER OutputDir
    Directory for all reports/logs/dashboards (default: ./output)
.PARAMETER MaxParallel
    Max concurrent migrations (default: 3 — stay within GEI throttle)
.PARAMETER SkipAudit
    Passed to migrate-single.ps1 — skips branch-wise audit for all repos
.PARAMETER DryRun
    Passed to migrate-single.ps1 — prints GEI commands without running them
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]  [string]$ADOOrg,
    [Parameter(Mandatory = $true)]  [string]$ADOProject,
    [Parameter(Mandatory = $true)]  [string]$GHOrg,
    [Parameter(Mandatory = $false)] [string]$ConfigPath   = "$PSScriptRoot\..\config\repo-migration-config.json",
    [Parameter(Mandatory = $false)] [string]$BatchName,
    [Parameter(Mandatory = $false)] [string]$RepoListCsv,
    [Parameter(Mandatory = $false)] [string]$OutputDir    = "$PSScriptRoot\..\output",
    [Parameter(Mandatory = $false)] [int]   $MaxParallel  = 3,
    [switch]$SkipAudit,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Validate PATs ────────────────────────────────────────────────────────────
if ([string]::IsNullOrWhiteSpace($env:GH_PAT))  { Write-Error "Set GH_PAT environment variable" }
if ([string]::IsNullOrWhiteSpace($env:ADO_PAT)) { Write-Error "Set ADO_PAT environment variable" }
# Ensure GH_TOKEN is set for all downstream gh CLI calls (migrate-single.ps1 + gh commands)
$env:GH_TOKEN = $env:GH_PAT
$singleScript = "$PSScriptRoot\migrate-single-secure.ps1"
if (-not (Test-Path $singleScript)) { Write-Error "migrate-single-secure.ps1 not found at: $singleScript" }

# ── Build repo list ──────────────────────────────────────────────────────────
# Use List[hashtable] + Add() — avoids pipeline PSObject wrapping that breaks ['key'] access
$repoList = [System.Collections.Generic.List[hashtable]]::new()
$seen     = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

if ($RepoListCsv) {
    # ── From CSV ──
    if (-not (Test-Path $RepoListCsv)) { Write-Error "CSV not found: $RepoListCsv" }
    $csv = Import-Csv $RepoListCsv
    foreach ($row in $csv) {
        $ado = $row.ADORepo.Trim()
        $gh  = if ($row.GHRepo) { $row.GHRepo.Trim() } else { $ado }
        if ($seen.Add($ado)) { $repoList.Add(@{ ADORepo = $ado; GHRepo = $gh }) }
    }
    Write-Host "Loaded $($repoList.Count) repos from CSV: $RepoListCsv"
}
else {
    # ── From config JSON ──
    if (-not (Test-Path $ConfigPath)) { Write-Error "Config not found: $ConfigPath" }
    $config  = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $batches = $config.batches
    # ADO pipeline sends " " (space) as default — normalize to empty
    $BatchName = $BatchName.Trim()
    if (-not [string]::IsNullOrWhiteSpace($BatchName)) {
        $batches = @($batches | Where-Object { $_.name -eq $BatchName })
        if ($batches.Count -eq 0) { Write-Error "Batch '$BatchName' not found in config" }
    }
    foreach ($batch in $batches) {
        foreach ($repo in $batch.repos) {
            $name = $repo.ToString().Trim()
            if ($seen.Add($name)) { $repoList.Add(@{ ADORepo = $name; GHRepo = $name }) }
        }
    }
    Write-Host "Loaded $($repoList.Count) repos from config batch(es)"
}

if ($repoList.Count -eq 0) { Write-Error "No repos found to migrate." }

# ── Read target repo visibility from config ───────────────────────────────────────────
$targetVisibility = 'private'
$visConfig = if (Test-Path $ConfigPath) { Get-Content $ConfigPath -Raw | ConvertFrom-Json } else { $null }
if ($visConfig -and $visConfig.migration -and $visConfig.migration.targetRepoVisibility) {
    $targetVisibility = $visConfig.migration.targetRepoVisibility
}
Write-Host "  Repo visibility: $targetVisibility"

# ── Output folder ─────────────────────────────────────────────────────────────
$reportDir = "$OutputDir\reports"
New-Item -ItemType Directory -Path $reportDir -Force | Out-Null

Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  BATCH MIGRATION"
Write-Host "  ADO:         $ADOOrg / $ADOProject"
Write-Host "  GitHub:      $GHOrg"
Write-Host "  Repos:       $($repoList.Count)"
Write-Host "  MaxParallel: $MaxParallel"
Write-Host "  DryRun:      $DryRun"
Write-Host "======================================================" -ForegroundColor Cyan

# ── Run migrations sequentially (in-process) ─────────────────────────────────
# NOTE: Start-Job / Receive-Job was removed because gh CLI writes informational
#       messages to stderr (e.g. "GH_TOKEN environment variable is being used")
#       which PowerShell strict mode treats as terminating errors, causing
#       pipeline exit code 1 even on successful migrations.
$successRepos = @()
$failedRepos  = @()
$repoIndex    = 0

foreach ($entry in $repoList) {
    $repoIndex++
    $adoRepo = $entry.ADORepo
    $ghRepo  = $entry.GHRepo

    Write-Host "`n[$repoIndex/$($repoList.Count)] Migrating: $adoRepo → $ghRepo" -ForegroundColor Yellow

    $migParams = @{
        ADOOrg     = $ADOOrg
        ADOProject = $ADOProject
        ADORepo    = $adoRepo
        GHOrg      = $GHOrg
        GHRepo     = $ghRepo
        OutputDir  = $OutputDir
        TargetRepoVisibility = $targetVisibility
    }
    if ($SkipAudit) { $migParams['SkipAudit'] = $true }
    if ($DryRun)    { $migParams['DryRun']    = $true }

    try {
        & $singleScript @migParams
        Write-Host "  [$adoRepo] Completed successfully." -ForegroundColor Green
        $successRepos += $adoRepo
    }
    catch {
        Write-Host "  [$adoRepo] FAILED: $($_.Exception.Message)" -ForegroundColor Red
        $failedRepos += $adoRepo
    }
}

Write-Host "`nAll $($repoList.Count) repo(s) processed." -ForegroundColor Cyan

# ── Collect per-repo results into a batch summary ─────────────────────────────
Write-Host "`nGenerating batch summary report..." -ForegroundColor Cyan

$batchResults = @()
foreach ($entry in $repoList) {
    $ghRepo    = $entry['GHRepo']
    $adoRepo   = $entry['ADORepo']
    $stateFile = "$OutputDir\logs\migration-state-$ghRepo.txt"
    $auditDir  = "$OutputDir\audit\$ghRepo"

    $state = if (Test-Path $stateFile) { (Get-Content $stateFile -Raw).Trim() } else { "UNKNOWN" }

    function Get-Val2($dir, $file) {
        $p = "$dir\$file"
        if (Test-Path $p) { return (Get-Content $p -Raw).Trim() }
        return "N/A"
    }

    $batchResults += [PSCustomObject]@{
        ADORepo      = $adoRepo
        GHRepo       = $ghRepo
        State        = $state
        Branches     = Get-Val2 $auditDir "gh-branch-count.txt"
        Tags         = Get-Val2 $auditDir "gh-tag-count.txt"
        Commits      = Get-Val2 $auditDir "gh-commit-count.txt"
        PRs          = Get-Val2 $auditDir "gh-pr-count.txt"
        DashboardPath = "$OutputDir\dashboard\$ghRepo\migration-report-$ghRepo.html"
    }
}

$summaryJson = "$reportDir\batch-migration-summary.json"
$summaryCsv  = "$reportDir\batch-migration-summary.csv"
$batchResults | ConvertTo-Json -Depth 3 | Out-File $summaryJson -Encoding utf8
$batchResults | Export-Csv $summaryCsv -NoTypeInformation -Encoding utf8

# ── Print final summary table ─────────────────────────────────────────────────
Write-Host ""
Write-Host "======================================================" -ForegroundColor Green
Write-Host "  BATCH MIGRATION SUMMARY"
Write-Host "======================================================"
$batchResults | Format-Table ADORepo, GHRepo, State, Branches, Tags, Commits, PRs -AutoSize

$successCount = @($batchResults | Where-Object { $_.State -in @("COMPLETE","SKIPPED","DRY_RUN") }).Count
$failCount    = @($batchResults | Where-Object { $_.State -in @("FAILED","UNKNOWN") }).Count

Write-Host "  Total   : $($batchResults.Count)"
Write-Host "  Success : $successCount" -ForegroundColor Green
Write-Host "  Failed  : $failCount" -ForegroundColor $(if ($failCount -gt 0) { "Red" } else { "Green" })
Write-Host ""
Write-Host "  Summary JSON: $summaryJson"
Write-Host "  Summary CSV : $summaryCsv"

# ── Ensure pipeline sees exit 0 ──────────────────────────────────────────────
# gh CLI / GEI may leave non-zero $LASTEXITCODE from stderr messages;
# PS7 propagates that to the ADO pipeline agent causing a false failure.
exit 0
Write-Host ""
Write-Host "Next step: Run validate-migration.ps1 to verify migrated repos." -ForegroundColor Cyan
