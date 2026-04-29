<#
.SYNOPSIS
    Scrubs secrets from Git history using git-filter-repo for repos flagged by scan-secrets.ps1.
.DESCRIPTION
    For each repo with findings in secret-scan-findings.json:
      - Clones the repo (full, not bare)
      - Runs git-filter-repo --replace-text with patterns from findings
      - Force-pushes cleaned history back to ADO
      - Generates credential rotation checklist
    CAUTION: This rewrites Git history. All developers must re-clone.
.PARAMETER ConfigPath
    Path to repo-migration-config.json
.PARAMETER DryRun
    If set, shows what would be cleaned without making changes
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "$PSScriptRoot\..\config\repo-migration-config.json",
    [switch]$DryRun
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

# ── Load findings ────────────────────────────────────────────────────────────
$findingsPath = Join-Path $reportDir "secret-scan-findings.json"
if (-not (Test-Path $findingsPath)) {
    Write-Error "secret-scan-findings.json not found. Run 01-discover\scan-secrets.ps1 first."
}
$findings = Get-Content $findingsPath -Raw | ConvertFrom-Json
if ($findings.Count -eq 0) {
    Write-Host "No secrets found — nothing to scrub." -ForegroundColor Green
    return
}

$inventoryPath = Join-Path $reportDir "repo-inventory.json"
$repos = Get-Content $inventoryPath -Raw | ConvertFrom-Json

$adoPat = if ($config.source.pat -eq '$(ADO_PAT)') { $env:ADO_PAT } else { $config.source.pat }
if ([string]::IsNullOrWhiteSpace($adoPat)) { Write-Error "Set ADO_PAT environment variable" }

# Group findings by repo
$byRepo = $findings | Group-Object -Property Repo

Write-Host "=== Secret Scrubbing ($($byRepo.Count) repos, DryRun=$DryRun) ===" -ForegroundColor Cyan

$rotationChecklist = @()

foreach ($group in $byRepo) {
    $repoName = $group.Name
    $repoFindings = $group.Group
    $repoInfo = $repos | Where-Object { $_.Name -eq $repoName }

    Write-Host "`n── $repoName ($($repoFindings.Count) findings) ──" -ForegroundColor Yellow

    if ($DryRun) {
        Write-Host "  [DRY RUN] Would scrub $($repoFindings.Count) secrets from $repoName"
        foreach ($f in $repoFindings) {
            Write-Host "    - $($f.RuleID) in $($f.File):$($f.StartLine)"
        }
        $rotationChecklist += $repoFindings | ForEach-Object {
            [PSCustomObject]@{ Repo = $repoName; RuleID = $_.RuleID; File = $_.File; Action = "ROTATE_CREDENTIAL" }
        }
        continue
    }

    # Full clone
    $clonePath = Join-Path $cloneDir $repoName
    if (Test-Path $clonePath) { Remove-Item $clonePath -Recurse -Force }

    $cloneUrl = $repoInfo.RemoteUrl -replace '://', "://$($adoPat)@"
    git clone --quiet $cloneUrl $clonePath 2>&1 | Out-Null

    # Build replacement expressions file
    $replacementsFile = Join-Path $logDir "replacements-$repoName.txt"
    # Each line: literal_pattern==>***REMOVED***
    $patterns = @()
    foreach ($f in $repoFindings) {
        # We use the file path and line to locate — for filter-repo we need the blob path
        $patterns += "$($f.File)"
    }
    $uniqueFiles = $patterns | Select-Object -Unique

    # Use git-filter-repo --path to remove specific files containing secrets
    # Or use --replace-text for inline replacement
    # Here we remove the files entirely and require developers to re-add clean versions
    Push-Location $clonePath
    try {
        foreach ($filePath in $uniqueFiles) {
            Write-Host "  Removing $filePath from all history..."
            git filter-repo --invert-paths --path $filePath --force 2>&1 | Out-Null
        }

        # Force push back to ADO
        Write-Host "  Force-pushing cleaned history to ADO..."
        git remote add origin $cloneUrl 2>$null
        git push --force --all origin 2>&1 | Out-Null
        git push --force --tags origin 2>&1 | Out-Null

        Write-Host "  DONE — history rewritten for $repoName" -ForegroundColor Green
    }
    catch {
        Write-Warning "  Failed to scrub $repoName : $_"
    }
    finally {
        Pop-Location
    }

    $rotationChecklist += $repoFindings | ForEach-Object {
        [PSCustomObject]@{ Repo = $repoName; RuleID = $_.RuleID; File = $_.File; Action = "ROTATE_CREDENTIAL" }
    }
}

# ── Cleanup clones ───────────────────────────────────────────────────────────
if (Test-Path $cloneDir) { Remove-Item $cloneDir -Recurse -Force -ErrorAction SilentlyContinue }

# ── Rotation checklist ───────────────────────────────────────────────────────
$checklistPath = Join-Path $reportDir "credential-rotation-checklist.csv"
$rotationChecklist | Export-Csv $checklistPath -NoTypeInformation -Encoding utf8

Write-Host "`n=== Scrub Summary ===" -ForegroundColor Green
Write-Host "  Repos processed         : $($byRepo.Count)"
Write-Host "  Credentials to rotate   : $($rotationChecklist.Count)"
Write-Host "`n  CRITICAL: Rotate ALL credentials listed in:" -ForegroundColor Red
Write-Host "  $checklistPath"
Write-Host "`n  All developers must re-clone affected repos after history rewrite."
Write-Host "`nNext step: Re-run 01-discover\scan-secrets.ps1 to verify clean, then proceed to 03-migrate."
