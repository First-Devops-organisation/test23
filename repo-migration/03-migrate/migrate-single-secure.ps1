<#
.SYNOPSIS
    Secure wrapper for single repository migration.
.DESCRIPTION
    1. Runs scrub-secrets.ps1 to generate a clean local clone and secret-values.json.
    2. Runs the original intact migrate-single.ps1 (GEI migration).
    3. Overwrites GitHub history with the scrubbed clone (if secrets were found).
    4. Provisions GitHub Secrets.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]  [string]$ADO_Org,
    [Parameter(Mandatory = $true)]  [string]$ADO_Project,
    [Parameter(Mandatory = $true)]  [string]$ADO_Repo,
    [Parameter(Mandatory = $true)]  [string]$GitHub_Org,
    [Parameter(Mandatory = $false)] [string]$GitHub_Repo,
    [Parameter(Mandatory = $false)] [string]$OutputDir = "$PSScriptRoot\..\output",
    [Parameter(Mandatory = $false)] [string]$TargetRepoVisibility = "private",
    [switch]$SkipAudit,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($GitHub_Repo)) { $GitHub_Repo = $ADO_Repo }

Write-Host "`n======================================================" -ForegroundColor Cyan
Write-Host "  SECURE MIGRATION: $ADO_Repo → $GitHub_Repo"
Write-Host "======================================================" -ForegroundColor Cyan

# ── 1. Scrub Secrets ────────────────────────────────────────────────────────
Write-Host "`n[Step 1] Scrubbing Secrets..." -ForegroundColor Cyan
$scrubScript = "$PSScriptRoot\..\02-prep\scrub-secrets.ps1"
if (-not (Test-Path $scrubScript)) { throw "Missing $scrubScript" }

$scrubParams = @{
    RepoName = $ADO_Repo
    OutputDir = $OutputDir
}
if ($DryRun) { $scrubParams['DryRun'] = $true }
& $scrubScript @scrubParams

# ── 2. Run Intact GEI Migration ──────────────────────────────────────────────
Write-Host "`n[Step 2] Running GEI Migration (migrate-single.ps1)..." -ForegroundColor Cyan
$migrateScript = "$PSScriptRoot\migrate-single.ps1"
$migrateParams = @{
    ADO_Org     = $ADO_Org
    ADO_Project = $ADO_Project
    ADO_Repo    = $ADO_Repo
    GitHub_Org      = $GitHub_Org
    GitHub_Repo     = $GitHub_Repo
    OutputDir  = $OutputDir
    TargetRepoVisibility = $TargetRepoVisibility
}
if ($SkipAudit) { $migrateParams['SkipAudit'] = $true }
if ($DryRun) { $migrateParams['DryRun'] = $true }

& $migrateScript @migrateParams

$stateFile = "$OutputDir\logs\migration-state-$GitHub_Repo.txt"
$migState = if (Test-Path $stateFile) { (Get-Content $stateFile -Raw).Trim() } else { "UNKNOWN" }

if ($migState -ne "COMPLETE") {
    Write-Warning "Migration did not complete (State: $migState). Skipping secure post-processing."
    return
}

# ── 3. Overwrite History with Scrubbed Clone ──────────────────────────────────
$scrubbedClone = "$OutputDir\tmp\clones\$ADO_Repo"
$secretValuesFile = "$OutputDir\scrubbed\secret-values.json"

if (Test-Path $scrubbedClone) {
    Write-Host "`n[Step 3] Pushing scrubbed history to GitHub..." -ForegroundColor Cyan
    $ghFullRepo = "$GitHub_Org/$GitHub_Repo"
    try {
        Push-Location $scrubbedClone
        $ghUrl = "https://x-access-token:$($env:GH_TOKEN)@github.com/$ghFullRepo.git"
        Write-Host "    Setting remote..." -ForegroundColor Gray
        git remote add github $ghUrl
        Write-Host "    Pushing scrubbed history (--mirror --force)..." -ForegroundColor Yellow
        $pushOutput = & git push github --mirror --force 2>&1
        if ($LASTEXITCODE -ne 0) { throw ($pushOutput | Out-String) }
        Write-Host "    Successfully pushed scrubbed history." -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to push scrubbed history: $_"
    }
    finally {
        Pop-Location
    }
} else {
    Write-Host "`n[Step 3] No secrets found. Original GEI history retained." -ForegroundColor Green
}

# ── 4. Provision GitHub Secrets ───────────────────────────────────────────────
if (Test-Path $secretValuesFile) {
    # Check if this specific repo has secrets in the JSON
    $secretsData = Get-Content $secretValuesFile -Raw | ConvertFrom-Json
    $hasSecrets = $false
    if ($secretsData -is [array]) {
        $hasSecrets = ($secretsData | Where-Object { $_.GitHubRepo -eq "$GitHub_Org/$GitHub_Repo" }).Count -gt 0
    } elseif ($secretsData -is [object]) {
        $hasSecrets = ($secretsData.GitHubRepo -eq "$GitHub_Org/$GitHub_Repo")
    }

    if ($hasSecrets) {
        Write-Host "`n[Step 4] Provisioning GitHub Secrets..." -ForegroundColor Cyan
        $createSecretsScript = "$PSScriptRoot\create-github-secrets.ps1"
        & $createSecretsScript -SecretValuesFile $secretValuesFile -DeleteAfterCreate $false
    } else {
        Write-Host "`n[Step 4] No secrets to provision for $GitHub_Repo." -ForegroundColor Green
    }
} else {
    Write-Host "`n[Step 4] No secrets file generated. Skipping provisioning." -ForegroundColor Green
}

