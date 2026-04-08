<#
.SYNOPSIS
    Scans all repos for exposed secrets using gitleaks.
.DESCRIPTION
    For each repo in repo-inventory.json:
      - Full bare clone to temp dir
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
    [int]$ThrottleLimit = 5
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

# Sort repos smallest-first so most repos complete quickly
$repos = @($repos | Sort-Object { $_.SizeMB })

# File suffix for parallel job output (avoids overwriting)
$fileSuffix = if ($SizeFilter -ne 'All') { "-$($SizeFilter.ToLower())" } else { '' }

Write-Host "=== Scanning $($repos.Count) repos for secrets [$SizeFilter] ===" -ForegroundColor Cyan

$allFindings = @()
$repoSummary = @()

foreach ($repo in $repos) {
    Write-Host "`n── [$($repo.Project)] $($repo.Name) ──" -ForegroundColor Yellow

    $clonePath  = Join-Path $cloneDir "$($repo.Name).git"
    $reportFile = Join-Path $logDir "gitleaks-$($repo.Name).json"

    # Clone — use header auth to avoid URL-encoding issues with PAT
    $cloneUrl = $repo.RemoteUrl -replace '://[^@]+@', '://'
    $base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("pat:$adoPat"))
    if (Test-Path $clonePath) { Remove-Item $clonePath -Recurse -Force }

    try {
        Write-Host "  Cloning all branches with full history ($($repo.SizeMB) MB)" -ForegroundColor Gray
        $cloneArgs = @('-c', "http.extraHeader=Authorization: Basic $base64Auth", 'clone', '--bare', '--quiet', $cloneUrl, $clonePath)

        $cloneOutput = & git @cloneArgs 2>&1
        if ($LASTEXITCODE -ne 0) { throw ($cloneOutput | Out-String) }
    }
    catch {
        Write-Warning "  Clone failed: $_"
        $repoSummary += [PSCustomObject]@{ Project = $repo.Project; Name = $repo.Name; FindingsCount = -1; Status = "CLONE_FAILED" }
        continue
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
        Write-Host "  CLEAN — no secrets found" -ForegroundColor Green
        $repoSummary += [PSCustomObject]@{ Project = $repo.Project; Name = $repo.Name; FindingsCount = 0; Status = "CLEAN" }
    }
    elseif ($exitCode -eq 1 -and (Test-Path $reportFile)) {
        $findings = Get-Content $reportFile -Raw | ConvertFrom-Json
        $count = ($findings | Measure-Object).Count
        Write-Warning "  SECRETS FOUND: $count finding(s)"

        foreach ($f in $findings) {
            $allFindings += [PSCustomObject]@{
                Project    = $repo.Project
                Repo       = $repo.Name
                RuleID     = $f.RuleID
                Match      = ($f.Match -replace '.', '*')  # Mask the actual secret
                File       = $f.File
                StartLine  = $f.StartLine
                Commit     = $f.Commit
                Author     = $f.Author
                Date       = $f.Date
            }
        }
        $repoSummary += [PSCustomObject]@{ Project = $repo.Project; Name = $repo.Name; FindingsCount = $count; Status = "SECRETS_FOUND" }
    }
    else {
        Write-Warning "  gitleaks returned exit code $exitCode"
        $repoSummary += [PSCustomObject]@{ Project = $repo.Project; Name = $repo.Name; FindingsCount = -1; Status = "SCAN_ERROR" }
    }

    # Clean up this repo's clone immediately to free disk space
    if (Test-Path $clonePath) {
        Write-Host "  Cleaning up clone for $($repo.Name)..." -ForegroundColor Gray
        Remove-Item $clonePath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ── Final cleanup (safety net) ───────────────────────────────────────────────
if (Test-Path $cloneDir) { Remove-Item $cloneDir -Recurse -Force -ErrorAction SilentlyContinue }

# ── Reports ──────────────────────────────────────────────────────────────────
$summaryJson   = Join-Path $reportDir "secret-scan-summary${fileSuffix}.json"
$findingsJson  = Join-Path $reportDir "secret-scan-findings${fileSuffix}.json"

$repoSummary  | ConvertTo-Json -Depth 3 | Out-File $summaryJson  -Encoding utf8
$allFindings  | ConvertTo-Json -Depth 5 | Out-File $findingsJson -Encoding utf8

Write-Host "`n=== Secret Scan Summary [$SizeFilter] ===" -ForegroundColor Green
Write-Host "  Total repos scanned : $($repoSummary.Count)"
Write-Host "  Clean               : $(($repoSummary | Where-Object Status -eq 'CLEAN').Count)"
Write-Host "  Secrets found       : $(($repoSummary | Where-Object Status -eq 'SECRETS_FOUND').Count)"
Write-Host "  Scan errors         : $(($repoSummary | Where-Object Status -eq 'SCAN_ERROR').Count)"
Write-Host "  Clone failed        : $(($repoSummary | Where-Object Status -eq 'CLONE_FAILED').Count)"
Write-Host "  Total findings      : $($allFindings.Count)"

$dirty = $repoSummary | Where-Object { $_.Status -eq 'SECRETS_FOUND' }
if ($dirty) {
    Write-Host "`nRepos requiring secret scrubbing BEFORE migration:" -ForegroundColor Red
    $dirty | Format-Table Name, FindingsCount -AutoSize
    Write-Host "Run 02-prep\scrub-secrets.ps1 to clean these repos."
}

Write-Host "`nReports saved:"
Write-Host "  Summary  : $summaryJson"
Write-Host "  Findings : $findingsJson"
Write-Host "`nNext step: Run 02-prep\install-tools.ps1, then 02-prep\scrub-secrets.ps1"
