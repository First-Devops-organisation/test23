<#
.SYNOPSIS
    Scrubs secrets from Git history using git-filter-repo based on gitleaks findings.
.DESCRIPTION
    Reads gitleaks scan reports, generates replacement expressions, and runs git-filter-repo
    to remove secrets from Git history. Also provides credential rotation checklist.
    CRITICAL: Run this BEFORE migrating any repo with detected secrets.
.PARAMETER SecretScanDir
    Directory containing gitleaks JSON reports from scan-secrets.ps1
.PARAMETER Pat
    ADO PAT for cloning
.PARAMETER OutputDir
    Directory for scrubbed repos and logs
.PARAMETER DryRun
    If true, only generates the filter expressions without applying them
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SecretScanDir,

    [Parameter(Mandatory = $true)]
    [string]$Pat,

    [string]$OutputDir = "./output/scrubbed",
    [string]$TempDir = "./tmp/scrub",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# --- Verify git-filter-repo ---
$filterRepo = Get-Command git-filter-repo -ErrorAction SilentlyContinue
if (-not $filterRepo) {
    Write-Host "git-filter-repo not found. Install: pip install git-filter-repo" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
if (-not (Test-Path $TempDir)) { New-Item -ItemType Directory -Path $TempDir -Force | Out-Null }

Write-Host "=== Secret Scrubbing $(if ($DryRun) {'(DRY RUN)'} else {'(LIVE)'}) ===" -ForegroundColor Cyan

# --- Find all secret report files ---
$reportFiles = Get-ChildItem -Path $SecretScanDir -Filter "*_secrets.json" | Where-Object { $_.Length -gt 2 }

if ($reportFiles.Count -eq 0) {
    Write-Host "No secret reports with findings found. All repos are clean." -ForegroundColor Green
    exit 0
}

Write-Host "Found $($reportFiles.Count) repos with secrets to scrub." -ForegroundColor Yellow

$rotationChecklist = @()

foreach ($reportFile in $reportFiles) {
    $repoIdentifier = $reportFile.BaseName -replace "_secrets$", ""
    Write-Host "`n  Processing: $repoIdentifier" -ForegroundColor Yellow

    $findings = Get-Content $reportFile.FullName -Raw | ConvertFrom-Json
    if ($findings.Count -eq 0) { continue }

    Write-Host "    $($findings.Count) secrets to scrub" -ForegroundColor Red

    # Build replacement expressions file for git-filter-repo
    $expressionsFile = Join-Path $TempDir "$repoIdentifier-expressions.txt"
    $expressions = @()

    foreach ($finding in $findings) {
        $secret = $finding.Secret
        if ([string]::IsNullOrWhiteSpace($secret)) { continue }

        # Escape regex special characters
        $escapedSecret = [regex]::Escape($secret)
        $replacement = "***REDACTED-$($finding.RuleID)***"
        $expressions += "regex:$escapedSecret==>$replacement"

        $rotationChecklist += [PSCustomObject]@{
            Repo         = $repoIdentifier
            RuleID       = $finding.RuleID
            File         = $finding.File
            Line         = $finding.StartLine
            Commit       = $finding.Commit
            Description  = $finding.Description
            SecretLength = $secret.Length
            Action       = "ROTATE credential immediately"
        }
    }

    $expressions | Out-File -FilePath $expressionsFile -Encoding utf8

    if ($DryRun) {
        Write-Host "    [DRY RUN] Would apply $($expressions.Count) replacements" -ForegroundColor Gray
        Write-Host "    Expressions file: $expressionsFile" -ForegroundColor Gray
        continue
    }

    # Clone the repo fresh
    $parts = $repoIdentifier -split "_", 2
    $project = $parts[0]
    $repoName = $parts[1]

    $cloneDir = Join-Path $TempDir $repoIdentifier
    if (Test-Path $cloneDir) { Remove-Item -Recurse -Force $cloneDir }

    Write-Host "    Cloning repo..." -ForegroundColor Gray
    # Using a generic clone URL pattern; actual URL from inventory would be better
    $cloneUrl = "https://$Pat@dev.azure.com/$($env:ADO_ORG)/$project/_git/$repoName"
    git clone $cloneUrl $cloneDir 2>&1 | Out-Null

    # Run git-filter-repo
    Write-Host "    Running git-filter-repo..." -ForegroundColor Gray
    Push-Location $cloneDir
    git filter-repo --replace-text $expressionsFile --force 2>&1
    Pop-Location

    Write-Host "    Scrubbing complete for $repoIdentifier" -ForegroundColor Green

    # Move to output directory
    $outputRepoDir = Join-Path $OutputDir $repoIdentifier
    if (Test-Path $outputRepoDir) { Remove-Item -Recurse -Force $outputRepoDir }
    Move-Item -Path $cloneDir -Destination $outputRepoDir
}

# --- Credential Rotation Checklist ---
if ($rotationChecklist.Count -gt 0) {
    $checklistFile = Join-Path $OutputDir "credential-rotation-checklist.csv"
    $rotationChecklist | Export-Csv -Path $checklistFile -NoTypeInformation
    Write-Host "`n=== CREDENTIAL ROTATION REQUIRED ===" -ForegroundColor Red
    Write-Host "Checklist saved to: $checklistFile" -ForegroundColor Yellow
    Write-Host "Total credentials to rotate: $($rotationChecklist.Count)" -ForegroundColor Red
    Write-Host "`nIMPORTANT: Rotate ALL identified credentials BEFORE migration." -ForegroundColor Red
    Write-Host "Even after scrubbing history, the old credentials may have been compromised." -ForegroundColor Red
}

# --- Post-Scrub Verification ---
Write-Host "`n=== Post-Scrub Verification ===" -ForegroundColor Cyan
Write-Host "After scrubbing, re-run scan-secrets.ps1 on the scrubbed repos to verify clean." -ForegroundColor Yellow
Write-Host "Then force-push scrubbed repos back to ADO before running GEI migration." -ForegroundColor Yellow

if (-not $DryRun) {
    Write-Host "`n=== NEXT STEPS ===" -ForegroundColor Cyan
    Write-Host "1. Verify scrubbed repos in: $OutputDir" -ForegroundColor White
    Write-Host "2. Re-run secret scan to verify clean" -ForegroundColor White
    Write-Host "3. Force-push scrubbed repos to ADO (coordinate with teams)" -ForegroundColor White
    Write-Host "4. Rotate ALL credentials in the checklist" -ForegroundColor White
    Write-Host "5. Proceed with GEI migration" -ForegroundColor White
}
