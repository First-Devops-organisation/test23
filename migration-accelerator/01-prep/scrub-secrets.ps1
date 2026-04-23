<#
.SYNOPSIS
    Scrubs secrets from Git history — encrypt for migration or redact permanently.
.DESCRIPTION
    Reads gitleaks scan reports, generates replacement expressions, and runs git-filter-repo
    to remove/encrypt secrets in Git history.

    Modes:
      - encrypt (default): Replaces secrets with AES-256 encrypted ENC{<base64>} tokens.
                           Generates secret-manifest.json in output for post-migration decryption.
                           Use this when migrating repos from ADO to GitHub.
      - redact:            Replaces secrets with ***REDACTED-<RuleID>*** (permanent, non-reversible).
                           Use this when secrets must be permanently purged from history.

    CRITICAL: Run this BEFORE migrating any repo with detected secrets.
.PARAMETER SecretScanDir
    Directory containing gitleaks JSON reports from scan-secrets.ps1
.PARAMETER Pat
    ADO PAT for cloning
.PARAMETER OutputDir
    Directory for scrubbed repos and logs
.PARAMETER Mode
    'encrypt' (default) — reversible encryption for migration
    'redact' — permanent redaction (legacy behavior)
.PARAMETER Passphrase
    Passphrase for AES-256 encryption. Required when Mode = encrypt.
    Use the same passphrase in decrypt-secrets.ps1 after migration.
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

    [ValidateSet("encrypt", "redact")]
    [string]$Mode = "encrypt",

    [string]$Passphrase,

    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# --- Validate parameters ---
if ($Mode -eq "encrypt" -and [string]::IsNullOrWhiteSpace($Passphrase)) {
    # Try environment variable fallback
    if ($env:SCRUB_PASSPHRASE) {
        $Passphrase = $env:SCRUB_PASSPHRASE
    }
    else {
        Write-Error "Passphrase is required when Mode = 'encrypt'. Pass -Passphrase or set `$env:SCRUB_PASSPHRASE."
        exit 1
    }
}

# --- Import crypto module (encrypt mode only) ---
if ($Mode -eq "encrypt") {
    $cryptoModulePath = Join-Path $PSScriptRoot "secrets-crypto.psm1"
    if (-not (Test-Path $cryptoModulePath)) {
        Write-Error "Cannot find secrets-crypto.psm1 at: $cryptoModulePath"
        exit 1
    }
    Import-Module $cryptoModulePath -Force
    Write-Host "Loaded secrets-crypto module" -ForegroundColor Gray
}

# --- Verify git-filter-repo ---
$filterRepo = Get-Command git-filter-repo -ErrorAction SilentlyContinue
if (-not $filterRepo) {
    Write-Host "git-filter-repo not found. Install: pip install git-filter-repo" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
if (-not (Test-Path $TempDir)) { New-Item -ItemType Directory -Path $TempDir -Force | Out-Null }

$modeLabel = switch ($Mode) {
    "encrypt" { "ENCRYPT" }
    "redact"  { "REDACT" }
}
Write-Host "=== Secret Scrubbing [$modeLabel] $(if ($DryRun) {'(DRY RUN)'} else {'(LIVE)'}) ===" -ForegroundColor Cyan

# --- Find all secret report files ---
$reportFiles = Get-ChildItem -Path $SecretScanDir -Filter "*_secrets.json" | Where-Object { $_.Length -gt 2 }

if ($reportFiles.Count -eq 0) {
    Write-Host "No secret reports with findings found. All repos are clean." -ForegroundColor Green
    exit 0
}

Write-Host "Found $($reportFiles.Count) repos with secrets to scrub." -ForegroundColor Yellow

$rotationChecklist = @()
$secretManifest = @()

foreach ($reportFile in $reportFiles) {
    $repoIdentifier = $reportFile.BaseName -replace "_secrets$", ""
    Write-Host "`n  Processing: $repoIdentifier" -ForegroundColor Yellow

    $findings = Get-Content $reportFile.FullName -Raw | ConvertFrom-Json
    if ($findings.Count -eq 0) { continue }

    Write-Host "    $($findings.Count) secrets to scrub" -ForegroundColor Red

    # Build replacement expressions file for git-filter-repo
    $expressionsFile = Join-Path $TempDir "$repoIdentifier-expressions.txt"
    $expressions = @()
    $repoManifestEntries = @()

    foreach ($finding in $findings) {
        $secret = $finding.Secret
        if ([string]::IsNullOrWhiteSpace($secret)) { continue }

        # Escape regex special characters
        $escapedSecret = [regex]::Escape($secret)

        if ($Mode -eq "encrypt") {
            # Encrypt the secret value
            $replacement = Protect-Secret -Plaintext $secret -Passphrase $Passphrase
            Write-Host "    Encrypted secret ($($finding.RuleID)) — $($secret.Length) chars → ENC{...}" -ForegroundColor Gray

            $repoManifestEntries += [PSCustomObject]@{
                Repo        = $repoIdentifier
                RuleID      = $finding.RuleID
                File        = $finding.File
                StartLine   = $finding.StartLine
                EndLine     = $finding.EndLine
                Commit      = $finding.Commit
                Description = $finding.Description
                OrigLength  = $secret.Length
                EncLength   = $replacement.Length
            }
        }
        else {
            # Legacy redact mode
            $replacement = "***REDACTED-$($finding.RuleID)***"
        }

        $expressions += "regex:$escapedSecret==>$replacement"

        $rotationChecklist += [PSCustomObject]@{
            Repo         = $repoIdentifier
            RuleID       = $finding.RuleID
            File         = $finding.File
            Line         = $finding.StartLine
            Commit       = $finding.Commit
            Description  = $finding.Description
            SecretLength = $secret.Length
            Mode         = $modeLabel
            Action       = "ROTATE credential immediately"
        }
    }

    $expressions | Out-File -FilePath $expressionsFile -Encoding utf8

    # Add to global manifest (encrypt mode)
    if ($Mode -eq "encrypt") {
        $secretManifest += $repoManifestEntries
    }

    if ($DryRun) {
        Write-Host "    [DRY RUN] Would apply $($expressions.Count) replacements ($modeLabel mode)" -ForegroundColor Gray
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
    Write-Host "    Running git-filter-repo ($modeLabel mode)..." -ForegroundColor Gray
    Push-Location $cloneDir
    git filter-repo --replace-text $expressionsFile --force 2>&1
    Pop-Location

    # For encrypt mode: add secret-manifest.json to the repo
    if ($Mode -eq "encrypt" -and $repoManifestEntries.Count -gt 0) {
        $repoManifestFile = Join-Path $cloneDir "secret-manifest.json"
        $repoManifestData = @{
            generatedAt  = (Get-Date -Format "o")
            generatedBy  = "scrub-secrets.ps1"
            mode         = "encrypt"
            repoIdentifier = $repoIdentifier
            totalSecrets = $repoManifestEntries.Count
            secrets      = $repoManifestEntries
            instructions = "Run decrypt-secrets.ps1 with the same passphrase after migration to restore original secret values."
        }
        $repoManifestData | ConvertTo-Json -Depth 10 | Out-File -FilePath $repoManifestFile -Encoding utf8

        # Commit the manifest
        Push-Location $cloneDir
        git add secret-manifest.json 2>&1 | Out-Null
        git commit -m "chore: add secret-manifest.json for post-migration decryption" 2>&1 | Out-Null
        Pop-Location

        Write-Host "    Added secret-manifest.json ($($repoManifestEntries.Count) entries)" -ForegroundColor Gray
    }

    Write-Host "    Scrubbing complete for $repoIdentifier ($modeLabel mode)" -ForegroundColor Green

    # Move to output directory
    $outputRepoDir = Join-Path $OutputDir $repoIdentifier
    if (Test-Path $outputRepoDir) { Remove-Item -Recurse -Force $outputRepoDir }
    Move-Item -Path $cloneDir -Destination $outputRepoDir
}

# --- Save global manifest (encrypt mode) ---
if ($Mode -eq "encrypt" -and $secretManifest.Count -gt 0) {
    $globalManifestFile = Join-Path $OutputDir "secret-manifest-global.json"
    $globalManifestData = @{
        generatedAt  = (Get-Date -Format "o")
        generatedBy  = "scrub-secrets.ps1"
        mode         = "encrypt"
        totalRepos   = ($secretManifest | Select-Object -ExpandProperty Repo -Unique).Count
        totalSecrets = $secretManifest.Count
        secrets      = $secretManifest
    }
    $globalManifestData | ConvertTo-Json -Depth 10 | Out-File -FilePath $globalManifestFile -Encoding utf8
    Write-Host "`nGlobal secret manifest saved: $globalManifestFile" -ForegroundColor Green
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

    if ($Mode -eq "encrypt") {
        Write-Host "5. Proceed with GEI migration" -ForegroundColor White
        Write-Host "6. After migration, run decrypt-secrets.ps1 on each GitHub repo" -ForegroundColor White
        Write-Host "   using the SAME passphrase to restore original secret values" -ForegroundColor White
    }
    else {
        Write-Host "5. Proceed with GEI migration" -ForegroundColor White
    }
}
