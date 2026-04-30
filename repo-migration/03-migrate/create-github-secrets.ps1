<#
.SYNOPSIS
    Creates GitHub repository secrets from secret-values.json after migration.
.DESCRIPTION
    Reads the secret-values.json produced by scrub-secrets.ps1 and provisions
    each secret as a GitHub repository-level secret using the GitHub CLI (gh).

    DEDUPLICATION LOGIC:
      - Same SecretName + same SecretValue → set once (skip duplicates)
      - Same SecretName + different SecretValue → auto-rename to NAME_2, NAME_3, etc.
      - Groups secrets by target GitHub repo so each repo gets only its own secrets

    RETRY LOGIC:
      - Each secret creation is retried up to 3 times with exponential backoff
      - Partial failures do not stop the rest of the secrets from being created

    REQUIREMENTS:
      - GitHub CLI (gh) must be installed and authenticated
      - GH_PAT environment variable must be set
.PARAMETER SecretValuesPath
    Path to secret-values.json (from scrub-secrets.ps1)
.PARAMETER GitHubOrg
    GitHub organization name
.PARAMETER GitHubRepo
    Target GitHub repository name
.PARAMETER DryRun
    If set, prints what would be created without actually creating secrets
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SecretValuesPath = "",

    [Parameter(Mandatory = $true)]
    [string]$GitHubOrg,

    [Parameter(Mandatory = $true)]
    [string]$GitHubRepo,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "$PSScriptRoot\..\config\repo-migration-config.json",

    [Parameter(Mandatory = $false)]
    [int]$MaxRetries = 3,

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Resolve secret-values.json path ──────────────────────────────────────────
if ([string]::IsNullOrWhiteSpace($SecretValuesPath)) {
    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $reportDir = $config.output.reportDir
    $SecretValuesPath = Join-Path $reportDir "secret-values.json"
}

if (-not (Test-Path $SecretValuesPath)) {
    Write-Host "No secret-values.json found at $SecretValuesPath — no secrets to create." -ForegroundColor Yellow
    exit 0
}

# ── Verify gh CLI ────────────────────────────────────────────────────────────
$ghCli = Get-Command gh -ErrorAction SilentlyContinue
if (-not $ghCli) {
    Write-Error "GitHub CLI (gh) not found. Install: https://cli.github.com/"
}

# Ensure gh is authenticated
$ghPat = $env:GH_PAT
if ([string]::IsNullOrWhiteSpace($ghPat)) {
    $ghPat = $env:GH_TOKEN
}
if ([string]::IsNullOrWhiteSpace($ghPat)) {
    Write-Error "Set GH_PAT or GH_TOKEN environment variable for GitHub authentication"
}

# Authenticate gh CLI
Write-Host "Authenticating GitHub CLI..." -ForegroundColor Gray
$ghPat | gh auth login --with-token 2>&1 | Out-Null

# ── Load secret values ───────────────────────────────────────────────────────
$allSecrets = @(Get-Content $SecretValuesPath -Raw | ConvertFrom-Json)

if ($allSecrets.Count -eq 0) {
    Write-Host "No secrets found in $SecretValuesPath — nothing to provision." -ForegroundColor Green
    exit 0
}

# ── Filter secrets for this specific repo ────────────────────────────────────
# secret-values.json may contain secrets from multiple repos (batch mode)
$repoSecrets = @($allSecrets | Where-Object { $_.Repo -eq $GitHubRepo -or $_.Repo -eq (Split-Path $GitHubRepo -Leaf) })

# If no repo-specific filter matches, use all secrets (single repo migration)
if ($repoSecrets.Count -eq 0) {
    $repoSecrets = $allSecrets
    Write-Host "Using all $($allSecrets.Count) secrets (no repo filter match for '$GitHubRepo')" -ForegroundColor Gray
}

$targetRepo = "$GitHubOrg/$GitHubRepo"
Write-Host "`n=== Creating GitHub Secrets for $targetRepo ===" -ForegroundColor Cyan
Write-Host "  Total secrets in file: $($allSecrets.Count)" -ForegroundColor Gray
Write-Host "  Secrets for this repo: $($repoSecrets.Count)" -ForegroundColor Gray
Write-Host "  DryRun: $DryRun" -ForegroundColor Gray

# ── Deduplicate: same name + same value = keep one; same name + diff value = rename ──
$finalSecrets  = @{}   # secretName → secretValue (what we will actually create)
$nameTracker   = @{}   # secretName → secretValue (to detect collisions)

foreach ($s in $repoSecrets) {
    $name  = $s.SecretName
    $value = $s.SecretValue

    if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($value)) {
        continue
    }

    # Skip values with control characters that GitHub API rejects
    if ($value -match '[\x00-\x1f]' -and $value -notmatch '[\r\n]') {
        Write-Host "  SKIP (control chars): $name" -ForegroundColor DarkGray
        continue
    }

    # Case 1: We've already seen this exact name+value combo → skip (true duplicate)
    if ($finalSecrets.ContainsKey($name) -and $finalSecrets[$name] -eq $value) {
        Write-Host "  SKIP (duplicate): $name (same value already queued)" -ForegroundColor DarkGray
        continue
    }

    # Case 2: Name exists but with a DIFFERENT value → rename with suffix
    if ($finalSecrets.ContainsKey($name) -and $finalSecrets[$name] -ne $value) {
        $baseName = $name
        $suffix = 2
        while ($finalSecrets.ContainsKey("${baseName}_${suffix}")) {
            # Check if this suffixed name already has the same value
            if ($finalSecrets["${baseName}_${suffix}"] -eq $value) {
                # Same value already exists under a suffixed name → skip
                $name = $null
                break
            }
            $suffix++
        }
        if ($null -eq $name) {
            Write-Host "  SKIP (duplicate value under different suffix): $baseName" -ForegroundColor DarkGray
            continue
        }
        $name = "${baseName}_${suffix}"
        Write-Host "  RENAME: $baseName → $name (different value)" -ForegroundColor Yellow
    }

    # Case 3: Brand new name → add directly
    $finalSecrets[$name] = $value
}

Write-Host "`n  Unique secrets to create: $($finalSecrets.Count)" -ForegroundColor Cyan

# ── Create secrets ───────────────────────────────────────────────────────────
$successCount = 0
$failCount    = 0
$skipCount    = 0
$results      = @()

foreach ($entry in $finalSecrets.GetEnumerator()) {
    $secretName  = $entry.Key
    $secretValue = $entry.Value

    $secretPreview = if ($secretValue.Length -le 8) { "***" }
                     else { $secretValue.Substring(0, 3) + ("*" * ($secretValue.Length - 6)) + $secretValue.Substring($secretValue.Length - 3) }

    if ($DryRun) {
        Write-Host "  [DRY RUN] Would create: $secretName = $secretPreview" -ForegroundColor Gray
        $results += [PSCustomObject]@{ Name = $secretName; Status = "DRY_RUN"; Attempts = 0 }
        $skipCount++
        continue
    }

    # Retry loop with exponential backoff
    $created = $false
    $attempts = 0

    for ($retry = 1; $retry -le $MaxRetries; $retry++) {
        $attempts = $retry
        try {
            Write-Host "  Creating: $secretName ($secretPreview)..." -ForegroundColor Gray -NoNewline

            # Use gh secret set with stdin to handle special characters in values
            $secretValue | gh secret set $secretName --repo $targetRepo 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host " OK" -ForegroundColor Green
                $created = $true
                break
            } else {
                throw "gh secret set returned exit code $LASTEXITCODE"
            }
        }
        catch {
            if ($retry -lt $MaxRetries) {
                $waitSec = [math]::Pow(2, $retry)
                Write-Host " RETRY in ${waitSec}s..." -ForegroundColor Yellow
                Start-Sleep -Seconds $waitSec
            } else {
                Write-Host " FAILED after $MaxRetries attempts: $_" -ForegroundColor Red
            }
        }
    }

    if ($created) {
        $successCount++
        $results += [PSCustomObject]@{ Name = $secretName; Status = "CREATED"; Attempts = $attempts }
    } else {
        $failCount++
        $results += [PSCustomObject]@{ Name = $secretName; Status = "FAILED"; Attempts = $attempts }
    }
}

# ── Save results report ──────────────────────────────────────────────────────
$resultsPath = Join-Path (Split-Path $SecretValuesPath) "github-secrets-results.json"
$results | ConvertTo-Json -Depth 3 | Out-File $resultsPath -Encoding utf8

# ── Console Summary ──────────────────────────────────────────────────────────
Write-Host "`n=== GitHub Secrets Summary ===" -ForegroundColor Cyan
Write-Host "  Target repo     : $targetRepo"
Write-Host "  Secrets created : $successCount" -ForegroundColor Green
Write-Host "  Secrets failed  : $failCount" -ForegroundColor $(if ($failCount -gt 0) { 'Red' } else { 'Gray' })
Write-Host "  Skipped (dry)   : $skipCount" -ForegroundColor Gray
Write-Host "  Results saved   : $resultsPath" -ForegroundColor Gray

if ($failCount -gt 0) {
    Write-Host "`n  WARNING: $failCount secret(s) failed to create!" -ForegroundColor Red
    Write-Host "  Review $resultsPath for details." -ForegroundColor Red
    $failedNames = @($results | Where-Object Status -eq 'FAILED' | ForEach-Object { $_.Name })
    Write-Host "  Failed: $($failedNames -join ', ')" -ForegroundColor Red
}

Write-Host "`nDone. Verify secrets at: https://github.com/$targetRepo/settings/secrets/actions"
