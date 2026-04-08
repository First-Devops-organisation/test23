<#
.SYNOPSIS
    Scans all repos for exposed secrets using gitleaks.
.DESCRIPTION
    For each repo in repo-inventory.json:
      - Clone to temp dir (shallow for large repos, full for small)
      - Run gitleaks detect --source <path> --report-format json
      - Collect findings into consolidated report
    Use -SizeFilter to run Small/Large repos in parallel jobs.
    Repos with findings MUST go through scrub-secrets.ps1 before migration.
.PARAMETER ConfigPath
    Path to repo-migration-config.json
.PARAMETER SizeFilter
    Filter repos by size: All (default), Small (< threshold), Large (>= threshold)
.PARAMETER SizeThresholdMB
    Size threshold in MB for Small/Large split (default: 1024 = 1 GB)
.PARAMETER ThrottleLimit
    Max parallel repo scans (default: 5)
.PARAMETER ShallowDepth
    Git clone depth for shallow clones (default: 50). Set to 0 to always do full clones.
.PARAMETER ShallowAboveMB
    Repos larger than this (MB) use shallow clone (default: 500). Ignored if ShallowDepth is 0.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "$PSScriptRoot\..\config\repo-migration-config.json",

    [Parameter(Mandatory = $false)]
    [ValidateSet('All', 'Small', 'Large')]
    [string]$SizeFilter = 'All',

    [Parameter(Mandatory = $false)]
    [int]$SizeThresholdMB = 1024,

    [Parameter(Mandatory = $false)]
    [int]$ThrottleLimit = 5,

    [Parameter(Mandatory = $false)]
    [int]$ShallowDepth = 50,

    [Parameter(Mandatory = $false)]
    [int]$ShallowAboveMB = 500
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

# ── Verify gitleaks ──────────────────────────────────────────────────────────
$gl = Get-Command gitleaks -ErrorAction SilentlyContinue
if (-not $gl) {
    Write-Error "gitleaks not found. Install: https://github.com/gitleaks/gitleaks/releases or run 02-prep\install-tools.ps1"
}

# ── Load inventory ───────────────────────────────────────────────────────────
$inventoryPath = Join-Path $reportDir "repo-inventory.json"
if (-not (Test-Path $inventoryPath)) {
    Write-Error "repo-inventory.json not found. Run 01-discover\discover-repos.ps1 first."
}
$repos = Get-Content $inventoryPath -Raw | ConvertFrom-Json

$adoPat = if ($config.source.pat -eq '$(ADO_PAT)') { $env:ADO_PAT } else { $config.source.pat }
if ([string]::IsNullOrWhiteSpace($adoPat)) { Write-Error "Set ADO_PAT environment variable" }

# Filter repos by size if requested (for parallel jobs)
$totalCount = ($repos | Measure-Object).Count
if ($SizeFilter -eq 'Small') {
    $repos = @($repos | Where-Object { $_.SizeMB -lt $SizeThresholdMB })
    Write-Host "Filter: Small repos only (< ${SizeThresholdMB} MB) — $($repos.Count) of $totalCount repos" -ForegroundColor Gray
} elseif ($SizeFilter -eq 'Large') {
    $repos = @($repos | Where-Object { $_.SizeMB -ge $SizeThresholdMB })
    Write-Host "Filter: Large repos only (>= ${SizeThresholdMB} MB) — $($repos.Count) of $totalCount repos" -ForegroundColor Gray
}

# Skip empty repos
$repos = @($repos | Where-Object { $_.SizeMB -gt 0 })

# Sort repos smallest-first so most repos complete quickly
$repos = @($repos | Sort-Object { $_.SizeMB })

# File suffix for parallel job output (avoids overwriting)
$fileSuffix = if ($SizeFilter -ne 'All') { "-$($SizeFilter.ToLower())" } else { '' }

Write-Host "=== Scanning $($repos.Count) repos for secrets [$SizeFilter] (ThrottleLimit=$ThrottleLimit) ===" -ForegroundColor Cyan
if ($ShallowDepth -gt 0) {
    Write-Host "  Shallow clone (depth=$ShallowDepth) for repos > ${ShallowAboveMB} MB" -ForegroundColor Cyan
}

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# ── Thread-safe collections for parallel execution ───────────────────────────
$allFindings = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()
$repoSummary = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()

# ── Parallel scan ────────────────────────────────────────────────────────────
$repos | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
    $repo         = $_
    $cloneDir     = $using:cloneDir
    $logDir       = $using:logDir
    $adoPat       = $using:adoPat
    $shallowDepth = $using:ShallowDepth
    $shallowAbove = $using:ShallowAboveMB
    $findings     = $using:allFindings
    $summary      = $using:repoSummary

    $repoLabel  = "[$($repo.Project)] $($repo.Name)"
    $clonePath  = Join-Path $cloneDir "$($repo.Name)-$([guid]::NewGuid().ToString('N').Substring(0,8)).git"
    $reportFile = Join-Path $logDir "gitleaks-$($repo.Name).json"

    # Decide clone strategy
    $useShallow = ($shallowDepth -gt 0) -and ($repo.SizeMB -ge $shallowAbove)

    # Clone — use header auth to avoid URL-encoding issues with PAT
    $cloneUrl   = $repo.RemoteUrl -replace '://[^@]+@', '://'
    $base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("pat:${adoPat}"))

    try {
        if ($useShallow) {
            Write-Host "  Cloning $repoLabel — SHALLOW (depth=$shallowDepth, $($repo.SizeMB) MB)" -ForegroundColor Gray
            $cloneArgs = @('-c', "http.extraHeader=Authorization: Basic $base64Auth",
                           'clone', '--bare', '--quiet', '--depth', $shallowDepth, $cloneUrl, $clonePath)
        } else {
            Write-Host "  Cloning $repoLabel — full ($($repo.SizeMB) MB)" -ForegroundColor Gray
            $cloneArgs = @('-c', "http.extraHeader=Authorization: Basic $base64Auth",
                           'clone', '--bare', '--quiet', $cloneUrl, $clonePath)
        }

        $cloneOutput = & git @cloneArgs 2>&1
        if ($LASTEXITCODE -ne 0) { throw ($cloneOutput | Out-String) }
    }
    catch {
        Write-Warning "  Clone failed for ${repoLabel}: $_"
        $summary.Add([PSCustomObject]@{ Project = $repo.Project; Name = $repo.Name; FindingsCount = -1; Status = "CLONE_FAILED" })
        return
    }

    # Run gitleaks
    $exitCode = 0
    try {
        $output = & gitleaks detect --source $clonePath --report-path $reportFile --report-format json --no-banner 2>&1
        $exitCode = $LASTEXITCODE
    }
    catch {
        $exitCode = $LASTEXITCODE
    }

    if ($exitCode -eq 0) {
        Write-Host "  CLEAN — $repoLabel" -ForegroundColor Green
        $summary.Add([PSCustomObject]@{ Project = $repo.Project; Name = $repo.Name; FindingsCount = 0; Status = "CLEAN" })
    }
    elseif ($exitCode -eq 1 -and (Test-Path $reportFile)) {
        $foundItems = Get-Content $reportFile -Raw | ConvertFrom-Json
        $count = ($foundItems | Measure-Object).Count
        Write-Warning "  SECRETS FOUND: $count finding(s) in $repoLabel"

        foreach ($f in $foundItems) {
            $findings.Add([PSCustomObject]@{
                Project   = $repo.Project
                Repo      = $repo.Name
                RuleID    = $f.RuleID
                Match     = ($f.Match -replace '.', '*')   # Mask the actual secret
                File      = $f.File
                StartLine = $f.StartLine
                Commit    = $f.Commit
                Author    = $f.Author
                Date      = $f.Date
            })
        }
        $summary.Add([PSCustomObject]@{ Project = $repo.Project; Name = $repo.Name; FindingsCount = $count; Status = "SECRETS_FOUND" })
    }
    else {
        Write-Warning "  gitleaks returned exit code $exitCode for $repoLabel"
        $summary.Add([PSCustomObject]@{ Project = $repo.Project; Name = $repo.Name; FindingsCount = -1; Status = "SCAN_ERROR" })
    }

    # Clean up this repo's clone immediately to free disk space
    if (Test-Path $clonePath) {
        Remove-Item $clonePath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$stopwatch.Stop()

# ── Final cleanup (safety net) ───────────────────────────────────────────────
if (Test-Path $cloneDir) { Remove-Item $cloneDir -Recurse -Force -ErrorAction SilentlyContinue }

# ── Convert ConcurrentBag to arrays for export ──────────────────────────────
$repoSummaryArr = @($repoSummary.ToArray())
$allFindingsArr = @($allFindings.ToArray())

# ── Reports ──────────────────────────────────────────────────────────────────
$summaryJson   = Join-Path $reportDir "secret-scan-summary${fileSuffix}.json"
$findingsJson  = Join-Path $reportDir "secret-scan-findings${fileSuffix}.json"

$repoSummaryArr | ConvertTo-Json -Depth 3 | Out-File $summaryJson  -Encoding utf8
$allFindingsArr | ConvertTo-Json -Depth 5 | Out-File $findingsJson -Encoding utf8

# ── HTML Report ──────────────────────────────────────────────────────────────
$htmlPath = Join-Path $reportDir "secret-scan-report${fileSuffix}.html"
$cleanCount   = ($repoSummaryArr | Where-Object Status -eq 'CLEAN').Count
$secretsCount = ($repoSummaryArr | Where-Object Status -eq 'SECRETS_FOUND').Count
$errorCount   = ($repoSummaryArr | Where-Object Status -eq 'SCAN_ERROR').Count
$failedCount  = ($repoSummaryArr | Where-Object Status -eq 'CLONE_FAILED').Count

$tableRows = ($repoSummaryArr | Sort-Object Status, Name | ForEach-Object {
    $statusColor = switch ($_.Status) {
        'CLEAN'         { '#27ae60' }
        'SECRETS_FOUND' { '#e74c3c' }
        'SCAN_ERROR'    { '#f39c12' }
        'CLONE_FAILED'  { '#95a5a6' }
        default         { '#333' }
    }
    "<tr><td>$([System.Net.WebUtility]::HtmlEncode($_.Project))</td><td>$([System.Net.WebUtility]::HtmlEncode($_.Name))</td><td>$($_.FindingsCount)</td><td style='color:$statusColor;font-weight:bold'>$($_.Status)</td></tr>"
}) -join "`n"

$html = @"
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Secret Scan Report [$SizeFilter]</title>
<style>
  body { font-family: 'Segoe UI', sans-serif; margin: 20px; background: #f5f5f5; }
  h1 { color: #2c3e50; } h2 { color: #34495e; }
  .summary { display: flex; gap: 15px; margin: 15px 0; }
  .card { padding: 15px 25px; border-radius: 8px; color: #fff; font-size: 1.1em; }
  .card .num { font-size: 2em; font-weight: bold; }
  table { border-collapse: collapse; width: 100%; background: #fff; margin-top: 10px; }
  th, td { border: 1px solid #ddd; padding: 8px 12px; text-align: left; }
  th { background: #2c3e50; color: #fff; }
  tr:nth-child(even) { background: #f9f9f9; }
  .elapsed { color: #7f8c8d; font-size: 0.9em; margin-top: 5px; }
</style></head><body>
<h1>Secret Scan Report [$SizeFilter]</h1>
<p class="elapsed">Scanned $($repoSummaryArr.Count) repos in $($stopwatch.Elapsed.ToString('hh\:mm\:ss')) | ThrottleLimit=$ThrottleLimit | ShallowDepth=$ShallowDepth (above ${ShallowAboveMB} MB)</p>
<div class="summary">
  <div class="card" style="background:#27ae60"><div class="num">$cleanCount</div>Clean</div>
  <div class="card" style="background:#e74c3c"><div class="num">$secretsCount</div>Secrets Found</div>
  <div class="card" style="background:#f39c12"><div class="num">$errorCount</div>Errors</div>
  <div class="card" style="background:#95a5a6"><div class="num">$failedCount</div>Clone Failed</div>
</div>
<h2>Repo Details</h2>
<table><tr><th>Project</th><th>Repo</th><th>Findings</th><th>Status</th></tr>
$tableRows
</table>
</body></html>
"@
$html | Out-File $htmlPath -Encoding utf8

Write-Host "`n=== Secret Scan Summary [$SizeFilter] ===" -ForegroundColor Green
Write-Host "  Elapsed time        : $($stopwatch.Elapsed.ToString('hh\:mm\:ss'))"
Write-Host "  Total repos scanned : $($repoSummaryArr.Count)"
Write-Host "  Clean               : $cleanCount"
Write-Host "  Secrets found       : $secretsCount"
Write-Host "  Scan errors         : $errorCount"
Write-Host "  Clone failed        : $failedCount"
Write-Host "  Total findings      : $($allFindingsArr.Count)"

$dirty = $repoSummaryArr | Where-Object { $_.Status -eq 'SECRETS_FOUND' }
if ($dirty) {
    Write-Host "`nRepos requiring secret scrubbing BEFORE migration:" -ForegroundColor Red
    $dirty | Format-Table Name, FindingsCount -AutoSize
    Write-Host "Run 02-prep\scrub-secrets.ps1 to clean these repos."
}

Write-Host "`nReports saved:"
Write-Host "  Summary  : $summaryJson"
Write-Host "  Findings : $findingsJson"
Write-Host "  HTML     : $htmlPath"
Write-Host "`nNext step: Run 02-prep\install-tools.ps1, then 02-prep\scrub-secrets.ps1"