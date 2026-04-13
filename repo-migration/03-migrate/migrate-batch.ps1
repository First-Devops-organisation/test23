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
.PARAMETER SliceIndex
    This agent's slice index (0-based). Used with SliceTotal to distribute
    repos across multiple self-hosted agents via ADO matrix strategy.
    Default 0 = run all repos on this agent.
.PARAMETER SliceTotal
    Total number of agent slices. Default 1 = single agent runs everything.
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
    [Parameter(Mandatory = $false)] [int]   $SliceIndex   = 0,
    [Parameter(Mandatory = $false)] [int]   $SliceTotal   = 1,
    [switch]$SkipAudit,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Normalize URLs — strip full URLs if passed instead of bare names ──────────
if ($ADOOrg -match '^https?://dev\.azure\.com/([^/]+)/?$') {
    Write-Host "  Normalising ADOOrg: stripping URL prefix → '$($Matches[1])'"
    $ADOOrg = $Matches[1]
}
if ($GHOrg -match '^https?://github\.com/([^/]+)/?$') {
    Write-Host "  Normalising GHOrg: stripping URL prefix → '$($Matches[1])'"
    $GHOrg = $Matches[1]
}

# ── Guard: detect unresolved ADO pipeline tokens ─────────────────────────────
foreach ($paramCheck in @(
    @{ Name = 'ADOOrg';    Value = $ADOOrg    }
    @{ Name = 'ADOProject';Value = $ADOProject }
    @{ Name = 'GHOrg';     Value = $GHOrg     }
)) {
    if ($paramCheck.Value -match '^\$\(') {
        Write-Error ("Parameter -$($paramCheck.Name) contains an unresolved ADO variable token: '$($paramCheck.Value)'. " +
            "Ensure the variable is defined in the pipeline variable group and saved before running.")
    }
}

# ── Validate PATs ────────────────────────────────────────────────────────────
if ([string]::IsNullOrWhiteSpace($env:GH_PAT))  { Write-Error "Set GH_PAT environment variable" }
if ([string]::IsNullOrWhiteSpace($env:ADO_PAT)) { Write-Error "Set ADO_PAT environment variable" }

$singleScript = "$PSScriptRoot\migrate-single.ps1"
if (-not (Test-Path $singleScript)) { Write-Error "migrate-single.ps1 not found at: $singleScript" }

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
    $batches = @($config.batches)
    if (-not [string]::IsNullOrWhiteSpace($BatchName)) {
        $batches = @($batches | Where-Object { $_.name -eq $BatchName.Trim() })
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

# ── Slice repo list for multi-agent distribution ──────────────────────────────
if ($SliceTotal -gt 1) {
    $allRepos = [System.Collections.Generic.List[hashtable]]::new($repoList)
    $repoList = [System.Collections.Generic.List[hashtable]]::new()
    for ($i = 0; $i -lt $allRepos.Count; $i++) {
        if ($i % $SliceTotal -eq $SliceIndex) { $repoList.Add($allRepos[$i]) }
    }
    Write-Host "Agent slice $SliceIndex/$SliceTotal — assigned $($repoList.Count) of $($allRepos.Count) repos"
    if ($repoList.Count -eq 0) {
        Write-Host "No repos assigned to this agent slice. Exiting cleanly."
        exit 0
    }
}

# ── Output folder ─────────────────────────────────────────────────────────────
$reportDir = "$OutputDir\reports"
New-Item -ItemType Directory -Path $reportDir -Force | Out-Null

Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  BATCH MIGRATION"
Write-Host "  ADO:         $ADOOrg / $ADOProject"
Write-Host "  GitHub:      $GHOrg"
Write-Host "  Repos:       $($repoList.Count)"
Write-Host "  Slice:       $SliceIndex of $SliceTotal"
Write-Host "  DryRun:      $DryRun"
Write-Host "======================================================" -ForegroundColor Cyan

# ── Free disk space pre-check (fail fast before any migration starts) ────────
$minFreeGB  = 10 * $repoList.Count   # rough estimate: 10 GB headroom per repo
$drive      = Split-Path -Qualifier $OutputDir
if (-not $drive) { $drive = (Get-Location).Drive.Root }
try {
    $freeGB = [math]::Round((Get-PSDrive ($drive.TrimEnd(':\')) -ErrorAction SilentlyContinue).Free / 1GB, 1)
    Write-Host "  Free disk on ${drive}: ${freeGB} GB  (recommended >= ${minFreeGB} GB for $($repoList.Count) repos)" -ForegroundColor Gray
    if ($freeGB -lt $minFreeGB) {
        Write-Warning "Low disk space: ${freeGB} GB free. Recommend >= ${minFreeGB} GB. Migration continues but may fail mid-run."
    }
} catch {
    Write-Warning "Could not check free disk space: $_"
}

# ── Run migrations sequentially (no child processes — avoids .NET errors) ─────
$completedRepos = @()
$failedRepos    = @()
$repoIndex      = 0

foreach ($entry in $repoList) {
    $repoIndex++
    $adoRepo = $entry.ADORepo
    $ghRepo  = $entry.GHRepo

    Write-Host "`n[$repoIndex/$($repoList.Count)] Migrating: $adoRepo → $ghRepo" -ForegroundColor Yellow

    $migrateParams = @{
        ADOOrg     = $ADOOrg
        ADOProject = $ADOProject
        ADORepo    = $adoRepo
        GHOrg      = $GHOrg
        GHRepo     = $ghRepo
        OutputDir  = $OutputDir
    }
    if ($SkipAudit) { $migrateParams['SkipAudit'] = $true }
    if ($DryRun)    { $migrateParams['DryRun']    = $true }

    try {
        & $singleScript @migrateParams
        $completedRepos += $adoRepo
        Write-Host "  [$adoRepo] Finished successfully." -ForegroundColor Green
    }
    catch {
        $failedRepos += $adoRepo
        Write-Warning "  [$adoRepo] FAILED: $_"
    }
}

# ── Collect per-repo results into a batch summary ─────────────────────────────
Write-Host "`nGenerating batch summary report..." -ForegroundColor Cyan

$batchResults = @()
foreach ($entry in $repoList) {
    $ghRepo    = $entry.GHRepo
    $adoRepo   = $entry.ADORepo
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
        RepoSize     = Get-Val2 $auditDir "gh-repo-size-actual.txt"
        DashboardPath = "$OutputDir\dashboard\$ghRepo\migration-report-$ghRepo.html"
    }
}

$sliceSuffix = if ($SliceTotal -gt 1) { "-agent$SliceIndex" } else { "" }
$summaryJson = "$reportDir\batch-migration-summary$sliceSuffix.json"
$summaryCsv  = "$reportDir\batch-migration-summary$sliceSuffix.csv"
$batchResults | ConvertTo-Json -Depth 3 | Out-File $summaryJson -Encoding utf8
$batchResults | Export-Csv $summaryCsv -NoTypeInformation -Encoding utf8

# ── Print final summary table ─────────────────────────────────────────────────
Write-Host ""
Write-Host "======================================================" -ForegroundColor Green
Write-Host "  BATCH MIGRATION SUMMARY"
Write-Host "======================================================"
$batchResults | Format-Table ADORepo, GHRepo, State, Branches, Commits, RepoSize -AutoSize

$successCount = @($batchResults | Where-Object { $_.State -in @("COMPLETE","SKIPPED","DRY_RUN") }).Count
$failCount    = @($batchResults | Where-Object { $_.State -in @("FAILED","UNKNOWN") }).Count

Write-Host "  Total   : $($batchResults.Count)"
Write-Host "  Success : $successCount" -ForegroundColor Green
Write-Host "  Failed  : $failCount" -ForegroundColor $(if ($failCount -gt 0) { "Red" } else { "Green" })
Write-Host ""
Write-Host "  Summary JSON: $summaryJson"
Write-Host "  Summary CSV : $summaryCsv"
Write-Host ""
Write-Host "Next step: Run validate-migration.ps1 to verify migrated repos." -ForegroundColor Cyan
