<#
.SYNOPSIS
    Scrubs secrets from Git history and stores them as GitHub repository secrets.
.DESCRIPTION
    Reads gitleaks scan reports, redacts secrets from Git history using git-filter-repo,
    and stores the original secret values as GitHub repository secrets via the gh CLI.
    Generates a secret-migration-report.csv mapping every secret to its GitHub Secret name.

    SAFETY: Works on a FRESH CLONE. The original ADO repo is NEVER modified.

    Flow:
      1. Read gitleaks findings
      2. For each secret → create a GitHub repo secret via `gh secret set`
      3. Redact the secret from Git history with a placeholder
      4. Save the scrubbed clone as a pipeline artifact
      5. Generate secret-migration-report.csv

.PARAMETER SecretScanDir
    Directory containing gitleaks JSON reports from scan-secrets.ps1
.PARAMETER Pat
    ADO PAT for cloning (read-only, original repo NOT modified)
.PARAMETER GitHubOrg
    GitHub organization name where secrets will be created
.PARAMETER GitHubPat
    GitHub PAT with repo + admin:org scope for creating secrets
.PARAMETER OutputDir
    Directory for scrubbed repo clones and reports
.PARAMETER DryRun
    If set, shows what would happen without creating secrets or modifying repos
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SecretScanDir,

    [Parameter(Mandatory = $true)]
    [string]$Pat,

    [Parameter(Mandatory = $true)]
    [string]$GitHubOrg,

    [Parameter(Mandatory = $true)]
    [string]$GitHubPat,

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

$ghCli = Get-Command gh -ErrorAction SilentlyContinue
if (-not $ghCli) {
    Write-Error "GitHub CLI (gh) not found. Install: https://cli.github.com"
    exit 1
}

# --- Setup ---
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
if (-not (Test-Path $TempDir)) { New-Item -ItemType Directory -Path $TempDir -Force | Out-Null }

# Authenticate gh CLI
$env:GH_TOKEN = $GitHubPat

Write-Host "=== Secret Scrubbing & GitHub Secret Migration $(if ($DryRun) {'(DRY RUN)'} else {'(LIVE)'}) ===" -ForegroundColor Cyan
Write-Host "GitHub Org: $GitHubOrg" -ForegroundColor Gray
Write-Host "NOTE: Original ADO repos are NOT modified." -ForegroundColor Green

# --- Find all secret report files ---
$reportFiles = Get-ChildItem -Path $SecretScanDir -Filter "*_secrets.json" | Where-Object { $_.Length -gt 2 }

if ($reportFiles.Count -eq 0) {
    Write-Host "`nNo secret reports with findings found. All repos are clean." -ForegroundColor Green
    exit 0
}

Write-Host "Found $($reportFiles.Count) repos with secrets to process.`n" -ForegroundColor Yellow

# --- Migration report ---
$migrationReport = @()
$totalSecretsCreated = 0
$totalSecretsFailed = 0

foreach ($reportFile in $reportFiles) {
    $repoIdentifier = $reportFile.BaseName -replace "_secrets$", ""
    Write-Host "  ═══════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Processing: $repoIdentifier" -ForegroundColor Yellow

    $findings = Get-Content $reportFile.FullName -Raw | ConvertFrom-Json
    if ($findings.Count -eq 0) { continue }

    Write-Host "    $($findings.Count) secrets found" -ForegroundColor Red

    # Determine the GitHub repo name
    $parts = $repoIdentifier -split "_", 2
    $project = $parts[0]
    $repoName = $parts[1]
    $ghRepoName = $repoName.ToLower() -replace " ", "-"
    $ghFullRepo = "$GitHubOrg/$ghRepoName"

    Write-Host "    Target GitHub repo: $ghFullRepo" -ForegroundColor Gray

    # Build replacement expressions for git-filter-repo
    $expressionsFile = Join-Path $TempDir "$repoIdentifier-expressions.txt"
    $expressions = @()
    $secretCounter = 0

    foreach ($finding in $findings) {
        $secret = $finding.Secret
        if ([string]::IsNullOrWhiteSpace($secret)) { continue }

        $secretCounter++

        # Generate a descriptive GitHub Secret name
        # Format: MIGRATED_<RULEID>_<COUNTER>
        $ruleClean = ($finding.RuleID -replace "[^a-zA-Z0-9]", "_").ToUpper()
        $secretName = "MIGRATED_${ruleClean}_$secretCounter"

        # Truncate if too long (GitHub secret names max 100 chars)
        if ($secretName.Length -gt 100) {
            $secretName = $secretName.Substring(0, 100)
        }

        # --- Create GitHub Secret ---
        if ($DryRun) {
            Write-Host "    [DRY RUN] Would create secret: $secretName in $ghFullRepo" -ForegroundColor Gray
        }
        else {
            try {
                # Use gh CLI to set the secret (handles encryption automatically)
                $secret | gh secret set $secretName --repo $ghFullRepo 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "    ✓ Created GitHub Secret: $secretName" -ForegroundColor Green
                    $totalSecretsCreated++
                }
                else {
                    Write-Warning "    ✗ Failed to create secret: $secretName"
                    $totalSecretsFailed++
                }
            }
            catch {
                Write-Warning "    ✗ Error creating secret $secretName : $_"
                $totalSecretsFailed++
            }
        }

        # --- Build redaction expression ---
        $escapedSecret = [regex]::Escape($secret)
        $placeholder = "***MIGRATED_TO_GITHUB_SECRET:${secretName}***"
        $expressions += "regex:$escapedSecret==>$placeholder"

        # --- Add to migration report ---
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
    $expressions | Out-File -FilePath $expressionsFile -Encoding utf8

    if ($DryRun) {
        Write-Host "    [DRY RUN] Would redact $($expressions.Count) secrets from history" -ForegroundColor Gray
        continue
    }

    # --- Clone repo (read-only, ADO untouched) ---
    $cloneDir = Join-Path $TempDir $repoIdentifier
    if (Test-Path $cloneDir) { Remove-Item -Recurse -Force $cloneDir }

    Write-Host "    Cloning repo (read-only)..." -ForegroundColor Gray
    $cloneUrl = "https://$Pat@dev.azure.com/$($env:ADO_ORG)/$project/_git/$repoName"
    git clone $cloneUrl $cloneDir 2>&1 | Out-Null

    if (-not (Test-Path $cloneDir)) {
        Write-Warning "    Failed to clone repo — skipping"
        continue
    }

    # --- Redact secrets from Git history ---
    Write-Host "    Running git-filter-repo (redacting $($expressions.Count) secrets)..." -ForegroundColor Gray
    Push-Location $cloneDir
    git filter-repo --replace-text $expressionsFile --force 2>&1
    Pop-Location

    Write-Host "    ✓ Secrets redacted from history" -ForegroundColor Green
    Write-Host "    ✓ Original ADO repo was NOT modified" -ForegroundColor Green

    # Move to output
    $outputRepoDir = Join-Path $OutputDir $repoIdentifier
    if (Test-Path $outputRepoDir) { Remove-Item -Recurse -Force $outputRepoDir }
    Move-Item -Path $cloneDir -Destination $outputRepoDir
}

# --- Save Migration Report CSV ---
if ($migrationReport.Count -gt 0) {
    $reportFile = Join-Path $OutputDir "secret-migration-report.csv"
    $migrationReport | Export-Csv -Path $reportFile -NoTypeInformation
    Write-Host "`n=== SECRET MIGRATION REPORT ===" -ForegroundColor Cyan
    Write-Host "Report saved to: $reportFile" -ForegroundColor Green
    Write-Host ""

    # Print summary table
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

# --- Credential Rotation Checklist ---
Write-Host "`n=== CREDENTIAL ROTATION REMINDER ===" -ForegroundColor Red
Write-Host "Even though secrets are stored in GitHub Secrets, the original" -ForegroundColor Yellow
Write-Host "credentials may have been exposed in ADO history. Rotate them." -ForegroundColor Yellow

# --- Summary ---
Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "Repos processed:        $($reportFiles.Count)" -ForegroundColor Gray
Write-Host "GitHub Secrets created:  $totalSecretsCreated" -ForegroundColor $(if ($totalSecretsCreated -gt 0) { "Green" } else { "Yellow" })
Write-Host "GitHub Secrets failed:   $totalSecretsFailed" -ForegroundColor $(if ($totalSecretsFailed -gt 0) { "Red" } else { "Green" })
Write-Host "Migration report:        $OutputDir/secret-migration-report.csv" -ForegroundColor Gray
Write-Host ""
Write-Host "Scrubbed repos saved to: $OutputDir (published as pipeline artifact)" -ForegroundColor Green
Write-Host "Original ADO repos:      UNTOUCHED" -ForegroundColor Green

if (-not $DryRun) {
    Write-Host "`n=== NEXT STEPS FOR TEAMS ===" -ForegroundColor Cyan
    Write-Host "1. Download secret-migration-report.csv from pipeline artifacts" -ForegroundColor White
    Write-Host "2. For each entry, update your code to read from environment variable" -ForegroundColor White
    Write-Host '3. In GitHub Actions: use ${{ secrets.SECRET_NAME }} to inject the value' -ForegroundColor White
    Write-Host "4. Rotate the original credentials" -ForegroundColor White
}
