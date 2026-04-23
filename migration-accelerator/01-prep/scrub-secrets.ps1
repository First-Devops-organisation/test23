<#
.SYNOPSIS
    Scrubs secrets from Git history and saves values for post-migration GitHub Secret creation.
.DESCRIPTION
    Reads gitleaks scan reports, redacts secrets from Git history using git-filter-repo,
    and saves the original secret values to a protected JSON file.
    After migration, a separate step creates GitHub repository secrets from this file.

    SAFETY: Works on a FRESH CLONE. The original ADO repo is NEVER modified.

    Flow:
      1. Read gitleaks findings
      2. Redact secrets from Git history with a placeholder
      3. Save secret values to secret-values.json (pipeline artifact, used post-migration)
      4. Generate secret-migration-report.csv (mapping for teams)
      5. Save the scrubbed clone as a pipeline artifact

.PARAMETER SecretScanDir
    Directory containing gitleaks JSON reports from scan-secrets.ps1
.PARAMETER Pat
    ADO PAT for cloning (read-only, original repo NOT modified)
.PARAMETER GitHubOrg
    GitHub organization name (used for mapping in the report)
.PARAMETER OutputDir
    Directory for scrubbed repo clones and reports
.PARAMETER DryRun
    If set, shows what would happen without modifying repos
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SecretScanDir,

    [Parameter(Mandatory = $true)]
    [string]$Pat,

    [Parameter(Mandatory = $true)]
    [string]$GitHubOrg,

    [string]$OutputDir = "./output/scrubbed",
    [string]$TempDir = "./tmp/scrub",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# --- Verify tools ---
$filterRepo = Get-Command git-filter-repo -ErrorAction SilentlyContinue
if (-not $filterRepo) {
    Write-Error "git-filter-repo not found. Install: pip install git-filter-repo"
    exit 1
}

# --- Setup ---
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
if (-not (Test-Path $TempDir)) { New-Item -ItemType Directory -Path $TempDir -Force | Out-Null }

Write-Host "=== Secret Scrubbing $(if ($DryRun) {'(DRY RUN)'} else {'(LIVE)'}) ===" -ForegroundColor Cyan
Write-Host "GitHub Org: $GitHubOrg" -ForegroundColor Gray
Write-Host "NOTE: Original ADO repos are NOT modified." -ForegroundColor Green

# --- Find all secret report files ---
$reportFiles = Get-ChildItem -Path $SecretScanDir -Filter "*_secrets.json" | Where-Object { $_.Length -gt 2 }

if ($reportFiles.Count -eq 0) {
    Write-Host "`nNo secret reports with findings found. All repos are clean." -ForegroundColor Green
    # Create empty report so publish step doesn't fail
    @() | ConvertTo-Json | Out-File -FilePath (Join-Path $OutputDir "secret-values.json") -Encoding utf8
    exit 0
}

Write-Host "Found $($reportFiles.Count) repos with secrets to process.`n" -ForegroundColor Yellow

# --- Collections ---
$migrationReport = @()
$secretValues = @()
$totalSecrets = 0

foreach ($reportFile in $reportFiles) {
    $repoIdentifier = $reportFile.BaseName -replace "_secrets$", ""
    Write-Host "  ==========================================" -ForegroundColor Cyan
    Write-Host "  Processing: $repoIdentifier" -ForegroundColor Yellow

    $findings = Get-Content $reportFile.FullName -Raw | ConvertFrom-Json
    if ($findings.Count -eq 0) { continue }

    Write-Host "    $($findings.Count) secrets found" -ForegroundColor Red

    # Determine names
    $parts = $repoIdentifier -split "_", 2
    $project = $parts[0]
    $repoName = $parts[1]
    $ghRepoName = $repoName.ToLower() -replace " ", "-"
    $ghFullRepo = "$GitHubOrg/$ghRepoName"

    Write-Host "    Target GitHub repo: $ghFullRepo" -ForegroundColor Gray

    # Build replacement expressions for git-filter-repo
    $expressionsFile = Join-Path (Resolve-Path $TempDir).Path "$repoIdentifier-expressions.txt"
    $expressions = @()
    $secretCounter = 0

    foreach ($finding in $findings) {
        $secret = $finding.Secret
        if ([string]::IsNullOrWhiteSpace($secret)) { continue }

        $secretCounter++
        $totalSecrets++

        # Generate a descriptive GitHub Secret name
        $ruleClean = ($finding.RuleID -replace "[^a-zA-Z0-9]", "_").ToUpper()
        $secretName = "MIGRATED_${ruleClean}_$secretCounter"

        # Truncate if too long (GitHub secret names max 100 chars)
        if ($secretName.Length -gt 100) {
            $secretName = $secretName.Substring(0, 100)
        }

        # --- Save secret value for post-migration GitHub Secret creation ---
        $secretValues += [PSCustomObject]@{
            GitHubRepo       = $ghFullRepo
            SecretName       = $secretName
            SecretValue      = $secret
            RuleID           = $finding.RuleID
            SourceFile       = $finding.File
            SourceLine       = $finding.StartLine
        }

        # --- Build redaction expression ---
        $escapedSecret = [regex]::Escape($secret)
        $placeholder = "***MIGRATED_TO_GITHUB_SECRET:${secretName}***"
        $expressions += "regex:$escapedSecret==>$placeholder"

        Write-Host "    → $($finding.RuleID) in $($finding.File):$($finding.StartLine) → $secretName" -ForegroundColor Gray

        # --- Add to migration report (NO secret values here — safe to share) ---
        $migrationReport += [PSCustomObject]@{
            Repo              = $repoIdentifier
            GitHubRepo        = $ghFullRepo
            File              = $finding.File
            Line              = $finding.StartLine
            SecretType        = $finding.RuleID
            Description       = $finding.Description
            Placeholder       = $placeholder
            GitHubSecretName  = $secretName
            SecretUsage       = "`${{ secrets.$secretName }}"
            Action            = "Update code to use env var / GitHub Secret"
        }
    }

    # Write expressions file
    $expressions | Out-File -FilePath $expressionsFile -Encoding utf8 -NoNewline:$false
    Write-Host "    Expressions file: $expressionsFile" -ForegroundColor Gray

    if ($DryRun) {
        Write-Host "    [DRY RUN] Would redact $($expressions.Count) secrets from history" -ForegroundColor Gray
        continue
    }

    # --- Clone repo (read-only, ADO untouched) ---
    $cloneDir = Join-Path (Resolve-Path $TempDir).Path $repoIdentifier
    if (Test-Path $cloneDir) { Remove-Item -Recurse -Force $cloneDir }

    Write-Host "    Cloning repo (read-only)..." -ForegroundColor Gray
    $adoOrg = $env:ADO_ORG
    $cloneUrl = "https://$Pat@dev.azure.com/$adoOrg/$project/_git/$repoName"
    git clone --mirror $cloneUrl $cloneDir 2>&1 | Out-Null

    if (-not (Test-Path $cloneDir)) {
        Write-Warning "    Failed to clone repo — skipping"
        continue
    }

    # --- Redact secrets from Git history ---
    Write-Host "    Running git-filter-repo (redacting $($expressions.Count) secrets)..." -ForegroundColor Gray
    $absExpressionsFile = (Resolve-Path $expressionsFile).Path
    Push-Location $cloneDir
    try {
        git filter-repo --replace-text "$absExpressionsFile" --force 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "    git-filter-repo returned exit code $LASTEXITCODE"
        } else {
            Write-Host "    ✓ Secrets redacted from history" -ForegroundColor Green
        }
    }
    catch {
        Write-Warning "    git-filter-repo error: $_"
    }
    finally {
        Pop-Location
    }

    Write-Host "    ✓ Original ADO repo was NOT modified" -ForegroundColor Green

    # Move to output
    $outputRepoDir = Join-Path $OutputDir $repoIdentifier
    if (Test-Path $outputRepoDir) { Remove-Item -Recurse -Force $outputRepoDir }
    Move-Item -Path $cloneDir -Destination $outputRepoDir
}

# --- Save secret values JSON (used by post-migration step to create GitHub Secrets) ---
$secretValuesFile = Join-Path $OutputDir "secret-values.json"
$secretValues | ConvertTo-Json -Depth 10 | Out-File -FilePath $secretValuesFile -Encoding utf8
Write-Host "`n=== Secret values saved to: $secretValuesFile ===" -ForegroundColor Green
Write-Host "This file will be used after migration to create GitHub Secrets." -ForegroundColor Gray
Write-Host "WARNING: This file contains PLAINTEXT secret values. Handle with care." -ForegroundColor Red

# --- Save Migration Report CSV (safe to share — NO secret values) ---
if ($migrationReport.Count -gt 0) {
    $reportCsvFile = Join-Path $OutputDir "secret-migration-report.csv"
    $migrationReport | Export-Csv -Path $reportCsvFile -NoTypeInformation
    Write-Host "`n=== SECRET MIGRATION REPORT ===" -ForegroundColor Cyan
    Write-Host "Report saved to: $reportCsvFile" -ForegroundColor Green

    # Print summary table
    Write-Host ""
    Write-Host "  ┌──────────────────────┬──────────────────────────┬───────────────────────────────────┐" -ForegroundColor White
    Write-Host "  │ Repo                 │ File:Line                │ GitHub Secret Name                │" -ForegroundColor White
    Write-Host "  ├──────────────────────┼──────────────────────────┼───────────────────────────────────┤" -ForegroundColor White
    foreach ($entry in $migrationReport) {
        $repoCol = $entry.Repo.PadRight(20).Substring(0, 20)
        $fileCol = "$($entry.File):$($entry.Line)".PadRight(24).Substring(0, 24)
        $secretCol = $entry.GitHubSecretName.PadRight(33).Substring(0, 33)
        Write-Host "  │ $repoCol │ $fileCol │ $secretCol │" -ForegroundColor White
    }
    Write-Host "  └──────────────────────┴──────────────────────────┴───────────────────────────────────┘" -ForegroundColor White
}

# --- Summary ---
Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "Repos processed:        $($reportFiles.Count)" -ForegroundColor Gray
Write-Host "Total secrets found:    $totalSecrets" -ForegroundColor Yellow
Write-Host "Secret values file:     $secretValuesFile (for post-migration)" -ForegroundColor Gray
Write-Host "Migration report:       $OutputDir/secret-migration-report.csv" -ForegroundColor Gray
Write-Host "Scrubbed repos:         $OutputDir (published as pipeline artifact)" -ForegroundColor Green
Write-Host "Original ADO repos:     UNTOUCHED" -ForegroundColor Green

Write-Host "`n=== NEXT STEPS ===" -ForegroundColor Cyan
Write-Host "1. GEI will migrate the repos to GitHub" -ForegroundColor White
Write-Host "2. Pipeline will auto-create GitHub Secrets from secret-values.json" -ForegroundColor White
Write-Host "3. Teams download secret-migration-report.csv to update their code" -ForegroundColor White
Write-Host "4. Rotate ALL credentials" -ForegroundColor White

exit 0
