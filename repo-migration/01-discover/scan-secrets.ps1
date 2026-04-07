<#
.SYNOPSIS
    Scans all repos for exposed secrets using gitleaks.
.DESCRIPTION
    For each repo in repo-inventory.json:
      - Bare clone to temp dir
      - Run gitleaks detect --no-git -r <path> --report-format json
      - Collect findings into consolidated report
    Repos with findings MUST go through scrub-secrets.ps1 before migration.
.PARAMETER ConfigPath
    Path to repo-migration-config.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "$PSScriptRoot\..\config\repo-migration-config.json"
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

# Threshold: repos >= this size use shallow clone (latest commit only)
# These get flagged for manual full scan later
$deepScanLimitMB = 3072  # 3 GB

# Sort repos smallest-first so most repos complete quickly
$repos = @($repos | Sort-Object { $_.SizeMB })

Write-Host "=== Scanning $($repos.Count) repos for secrets ===" -ForegroundColor Cyan
$largeCount = @($repos | Where-Object { $_.SizeMB -ge $deepScanLimitMB }).Count
if ($largeCount -gt 0) {
    Write-Host "  $largeCount repo(s) >= ${deepScanLimitMB} MB will use shallow scan (latest commit only)" -ForegroundColor Yellow
}

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

    $isLargeRepo = $repo.SizeMB -ge $deepScanLimitMB

    try {
        $cloneArgs = @('-c', "http.extraHeader=Authorization: Basic $base64Auth", 'clone', '--bare', '--quiet')

        if ($isLargeRepo) {
            # Large repo: shallow clone to avoid long clone + scan time
            $defaultBranch = $repo.DefaultBranch
            $cloneArgs += @('--depth', '1')
            if ($defaultBranch) {
                $cloneArgs += @('--single-branch', '--branch', $defaultBranch)
            }
            Write-Host "  LARGE REPO ($($repo.SizeMB) MB) — shallow clone (latest commit only)" -ForegroundColor Yellow
        } else {
            Write-Host "  Cloning all branches with full history ($($repo.SizeMB) MB)" -ForegroundColor Gray
        }
        $cloneArgs += @($cloneUrl, $clonePath)

        $cloneOutput = & git @cloneArgs 2>&1
        if ($LASTEXITCODE -ne 0) { throw ($cloneOutput | Out-String) }
    }
    catch {
        Write-Warning "  Clone failed: $_"
        $repoSummary += [PSCustomObject]@{ Project = $repo.Project; Name = $repo.Name; FindingsCount = -1; Status = "CLONE_FAILED"; ScanType = "N/A" }
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

    $scanType = if ($isLargeRepo) { "SHALLOW" } else { "FULL" }

    if ($exitCode -eq 0) {
        Write-Host "  CLEAN — no secrets found" -ForegroundColor Green
        $repoSummary += [PSCustomObject]@{ Project = $repo.Project; Name = $repo.Name; FindingsCount = 0; Status = "CLEAN"; ScanType = $scanType }
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
        $repoSummary += [PSCustomObject]@{ Project = $repo.Project; Name = $repo.Name; FindingsCount = $count; Status = "SECRETS_FOUND"; ScanType = $scanType }
    }
    else {
        Write-Warning "  gitleaks returned exit code $exitCode"
        $repoSummary += [PSCustomObject]@{ Project = $repo.Project; Name = $repo.Name; FindingsCount = -1; Status = "SCAN_ERROR"; ScanType = "N/A" }
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
$summaryJson   = Join-Path $reportDir "secret-scan-summary.json"
$findingsJson  = Join-Path $reportDir "secret-scan-findings.json"

$repoSummary  | ConvertTo-Json -Depth 3 | Out-File $summaryJson  -Encoding utf8
$allFindings  | ConvertTo-Json -Depth 5 | Out-File $findingsJson -Encoding utf8

Write-Host "`n=== Secret Scan Summary ===" -ForegroundColor Green
Write-Host "  Total repos scanned : $($repoSummary.Count)"
Write-Host "  Full scan           : $(($repoSummary | Where-Object ScanType -eq 'FULL').Count)"
Write-Host "  Shallow scan (large): $(($repoSummary | Where-Object ScanType -eq 'SHALLOW').Count)"
Write-Host "  Clean               : $(($repoSummary | Where-Object Status -eq 'CLEAN').Count)"
Write-Host "  Secrets found       : $(($repoSummary | Where-Object Status -eq 'SECRETS_FOUND').Count)"
Write-Host "  Scan errors         : $(($repoSummary | Where-Object Status -eq 'SCAN_ERROR').Count)"
Write-Host "  Total findings      : $($allFindings.Count)"

$shallowRepos = @($repoSummary | Where-Object { $_.ScanType -eq 'SHALLOW' })
if ($shallowRepos) {
    Write-Host "`nRepos scanned with SHALLOW clone (may have secrets in old commits):" -ForegroundColor Yellow
    $shallowRepos | Format-Table Name, FindingsCount, Status -AutoSize
    Write-Host "Run a full manual scan on these repos before migration if needed."
}

$dirty = $repoSummary | Where-Object { $_.Status -eq 'SECRETS_FOUND' }
if ($dirty) {
    Write-Host "`nRepos requiring secret scrubbing BEFORE migration:" -ForegroundColor Red
    $dirty | Format-Table Name, FindingsCount, ScanType -AutoSize
    Write-Host "Run 02-prep\scrub-secrets.ps1 to clean these repos."
}

Write-Host "`nReports saved:"
Write-Host "  Summary  : $summaryJson"
Write-Host "  Findings : $findingsJson"
Write-Host "`nNext step: Run 02-prep\install-tools.ps1, then 02-prep\scrub-secrets.ps1"
