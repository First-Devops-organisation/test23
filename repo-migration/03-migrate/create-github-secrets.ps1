<#
.SYNOPSIS
    Creates GitHub repository secrets from secret-values.json after migration.
.DESCRIPTION
    Reads the secret-values.json produced by scrub-secrets.ps1 and provisions
    each secret as a GitHub repository-level secret using the GitHub CLI.
    Handles deduplication: same name+value = skip, same name+different value = auto-rename.
.PARAMETER GitHubOrg
    GitHub organization name
.PARAMETER GitHubRepo
    GitHub repository name
.PARAMETER SecretValuesPath
    Path to secret-values.json (default: ./output/reports/secret-values.json)
.PARAMETER DryRun
    If set, prints what would be created without making changes
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$GitHubOrg,

    [Parameter(Mandatory = $false)]
    [string]$GitHubRepo,

    [Parameter(Mandatory = $false)]
    [string]$SecretValuesPath = "$PSScriptRoot\..\output\reports\secret-values.json",

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "$PSScriptRoot\..\config\repo-migration-config.json",

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Resolve GitHub org/repo from config if not provided ──────────────────────
if ([string]::IsNullOrWhiteSpace($GitHubOrg) -or [string]::IsNullOrWhiteSpace($GitHubRepo)) {
    if (Test-Path $ConfigPath) {
        $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        if ([string]::IsNullOrWhiteSpace($GitHubOrg)) {
            $GitHubOrg = if ($config.target.organization -match '^\$\(') { $env:GitHub_Org } else { $config.target.organization }
        }
        if ([string]::IsNullOrWhiteSpace($GitHubRepo)) {
            $GitHubRepo = if ($config.migration.singleRepo) { $config.migration.singleRepo } else { "" }
        }
    }
}

if ([string]::IsNullOrWhiteSpace($GitHubOrg)) { Write-Error "GitHubOrg is required. Set via parameter or GitHub_Org env variable." }
# GitHubRepo can be empty for batch mode — will process all repos in the JSON

# Normalize org
if ($GitHubOrg -match '^https?://github\.com/([^/]+)/?$') {
    $GitHubOrg = $Matches[1]
}

# ── Validate GH_PAT / GH_TOKEN ──────────────────────────────────────────────
$ghPat = $env:GH_PAT
if ([string]::IsNullOrWhiteSpace($ghPat)) { $ghPat = $env:GH_TOKEN }
if ([string]::IsNullOrWhiteSpace($ghPat)) { Write-Error "Set GH_PAT or GH_TOKEN environment variable" }
$env:GH_TOKEN = $ghPat

# ── Load secret values ──────────────────────────────────────────────────────
if (-not (Test-Path $SecretValuesPath)) {
    Write-Host "secret-values.json not found at: $SecretValuesPath" -ForegroundColor Yellow
    Write-Host "No secrets to create — scan likely found no secrets. Skipping." -ForegroundColor Green
    return
}

$allSecrets = Get-Content $SecretValuesPath -Raw | ConvertFrom-Json
if ($allSecrets.Count -eq 0) {
    Write-Host "No secrets to create. secret-values.json is empty." -ForegroundColor Green
    return
}

# ── Filter for target repo (if specified) ────────────────────────────────────
if (-not [string]::IsNullOrWhiteSpace($GitHubRepo)) {
    $allSecrets = @($allSecrets | Where-Object { $_.Repo -eq $GitHubRepo })
    Write-Host "Filtered for repo: $GitHubRepo ($($allSecrets.Count) secrets)" -ForegroundColor Cyan
}

if ($allSecrets.Count -eq 0) {
    Write-Host "No secrets found for $GitHubRepo." -ForegroundColor Green
    return
}

# ── Group by repo ────────────────────────────────────────────────────────────
$byRepo = $allSecrets | Group-Object -Property Repo

Write-Host "=== Creating GitHub Secrets (DryRun=$DryRun) ===" -ForegroundColor Cyan
Write-Host "  Organization: $GitHubOrg"
Write-Host "  Repos: $($byRepo.Count)"

$results = @()
$totalCreated = 0
$totalSkipped = 0
$totalFailed  = 0

foreach ($group in $byRepo) {
    $repoName = $group.Name
    $secrets  = $group.Group

    $targetRepo = if (-not [string]::IsNullOrWhiteSpace($GitHubRepo)) { $GitHubRepo } else { $repoName }

    Write-Host "`n── $targetRepo ($($secrets.Count) secrets) ──" -ForegroundColor Yellow

    # Deduplicate: same name+value = skip, same name+different value = suffix
    $dedupMap = [ordered]@{} # name → value
    $nameCounter = @{}

    foreach ($s in $secrets) {
        $name = $s.SecretName
        $val  = $s.SecretValue

        # Check if exact same name+value already exists
        if ($dedupMap.Contains($name) -and $dedupMap[$name] -ceq $val) {
            Write-Host "    [SKIP] $name (duplicate — same value)" -ForegroundColor Gray
            $totalSkipped++
            $results += [PSCustomObject]@{ Repo = $targetRepo; SecretName = $name; Status = "SKIPPED_DUPLICATE" }
            continue
        }

        # Check if name exists with different value
        if ($dedupMap.Contains($name)) {
            if (-not $nameCounter.Contains($name)) { $nameCounter[$name] = 1 }
            $nameCounter[$name]++
            $name = "${name}_$($nameCounter[$name])"
            Write-Host "    [RENAME] Collision detected → renamed to $name" -ForegroundColor DarkYellow
        }

        $dedupMap[$name] = $val

        if ($DryRun) {
            $maskedVal = $val.Substring(0, [Math]::Min(4, $val.Length)) + "***"
            Write-Host "    [DRY RUN] Would create: $name = $maskedVal" -ForegroundColor DarkYellow
            $totalSkipped++
            $results += [PSCustomObject]@{ Repo = $targetRepo; SecretName = $name; Status = "DRY_RUN" }
            continue
        }

        # ── Create secret with retry ─────────────────────────────────────
        $success = $false
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                # Use echo + pipe to handle special characters in values
                $output = $val | gh secret set $name --repo "$GitHubOrg/$targetRepo" 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "    [OK] $name created" -ForegroundColor Green
                    $totalCreated++
                    $results += [PSCustomObject]@{ Repo = $targetRepo; SecretName = $name; Status = "CREATED" }
                    $success = $true
                    break
                }
                else {
                    $outStr = $output -join " "
                    if ($outStr -match "already exists") {
                        Write-Host "    [EXISTS] $name already exists — updating" -ForegroundColor Yellow
                        $totalCreated++
                        $results += [PSCustomObject]@{ Repo = $targetRepo; SecretName = $name; Status = "UPDATED" }
                        $success = $true
                        break
                    }
                    throw $outStr
                }
            }
            catch {
                if ($attempt -lt 3) {
                    $wait = $attempt * 5
                    Write-Host "    [RETRY] $name failed (attempt $attempt/3). Waiting ${wait}s..." -ForegroundColor Yellow
                    Start-Sleep -Seconds $wait
                }
            }
        }

        if (-not $success) {
            Write-Host "    [FAILED] $name — could not create after 3 attempts" -ForegroundColor Red
            $totalFailed++
            $results += [PSCustomObject]@{ Repo = $targetRepo; SecretName = $name; Status = "FAILED" }
        }
    }
}

# ── Save results ─────────────────────────────────────────────────────────────
$reportDir = Split-Path $SecretValuesPath -Parent
$resultsPath = Join-Path $reportDir "github-secrets-results.json"
$results | ConvertTo-Json -Depth 3 | Out-File $resultsPath -Encoding utf8

# ── Summary ──────────────────────────────────────────────────────────────────
Write-Host "`n=== GitHub Secrets Summary ===" -ForegroundColor Cyan
Write-Host "  Created  : $totalCreated" -ForegroundColor Green
Write-Host "  Skipped  : $totalSkipped" -ForegroundColor Gray
Write-Host "  Failed   : $totalFailed" -ForegroundColor $(if ($totalFailed -gt 0) { "Red" } else { "Green" })
Write-Host "  Results  : $resultsPath"
