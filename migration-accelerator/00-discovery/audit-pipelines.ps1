<#
.SYNOPSIS
    Runs GitHub Actions Importer audit against Azure DevOps pipelines.
.DESCRIPTION
    Wraps 'gh actions-importer audit azure-devops' to produce a conversion readiness report
    showing which pipeline tasks are supported, partially supported, or unsupported.
.PARAMETER AdoOrg
    Azure DevOps organization name (not URL)
.PARAMETER AdoProject
    Optional: specific project to audit. If omitted, audits all projects.
.PARAMETER AdoPat
    ADO PAT
.PARAMETER GitHubPat
    GitHub PAT (needed by actions-importer)
.PARAMETER OutputDir
    Directory for audit output
#>
[CmdletBinding()]
param(
    [string]$AdoOrg,

    [string]$AdoProject,

    [string]$AdoPat,

    [string]$GitHubPat,


    [string]$OutputDir = "./output/pipeline-audit"
)

$AdoOrg = if ($AdoOrg) { $AdoOrg } elseif ($env:ADO_Org) { $env:ADO_Org } elseif ($env:ADO_ORG) { $env:ADO_ORG } elseif ($env:ADOORG) { $env:ADOORG } else { $null }
$AdoPat = if ($AdoPat) { $AdoPat } elseif ($env:ADO_PAT) { $env:ADO_PAT } elseif ($env:AZDO_PAT) { $env:AZDO_PAT } else { $null }
$GitHubPat = if ($GitHubPat) { $GitHubPat } elseif ($env:GH_PAT) { $env:GH_PAT } elseif ($env:GITHUB_PAT) { $env:GITHUB_PAT } else { $null }
$OutputDir = if ($OutputDir -and -not [string]::IsNullOrWhiteSpace($OutputDir)) { $OutputDir } else { "./output/pipeline-audit" }

if (-not $AdoOrg) {
    Write-Host "ERROR: Azure DevOps organization is required. Provide -AdoOrg or set ADO_Org / ADO_ORG." -ForegroundColor Red
    exit 1
}
if (-not $AdoPat) {
    Write-Host "ERROR: Azure DevOps PAT is required. Provide -AdoPat or set ADO_PAT." -ForegroundColor Red
    exit 1
}
if (-not $GitHubPat) {
    Write-Host "ERROR: GitHub PAT is required. Provide -GitHubPat or set GH_PAT / GITHUB_PAT." -ForegroundColor Red
    exit 1
}

$ErrorActionPreference = "Stop"

# --- Verify Prerequisites ---
$gh = Get-Command gh -ErrorAction SilentlyContinue
if (-not $gh) {
    Write-Host "GitHub CLI (gh) not found. Install from: https://cli.github.com" -ForegroundColor Red
    exit 1
}

# Check actions-importer extension
$extensions = gh extension list 2>&1
if ($extensions -notmatch "actions-importer") {
    Write-Host "Installing gh actions-importer extension..." -ForegroundColor Yellow
    gh extension install github/gh-actions-importer
}

if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

Write-Host "=== Pipeline Audit: $AdoOrg ===" -ForegroundColor Cyan

# --- Set environment variables for actions-importer ---
$env:GITHUB_ACCESS_TOKEN = $GitHubPat
$env:GITHUB_TOKEN = $GitHubPat
$env:GH_TOKEN = $GitHubPat
$env:AZURE_DEVOPS_ACCESS_TOKEN = $AdoPat
$env:ADO_PAT = $AdoPat

# --- Update actions-importer ---
Write-Host "Updating actions-importer..." -ForegroundColor Yellow
gh actions-importer update 2>&1

# --- Run Audit ---
$auditArgs = @(
    "actions-importer", "audit", "azure-devops",
    "--output-dir", $OutputDir,
    "--azure-devops-organization", "https://dev.azure.com/$AdoOrg"
)

if ($AdoProject) {
    $auditArgs += "--azure-devops-project"
    $auditArgs += $AdoProject
}

Write-Host "Running audit (this may take several minutes)..." -ForegroundColor Yellow
gh @auditArgs 2>&1

# --- Parse Results ---
$auditSummaryFile = Join-Path $OutputDir "audit_summary.md"
if (Test-Path $auditSummaryFile) {
    Write-Host "`n=== Audit Summary ===" -ForegroundColor Cyan
    $content = Get-Content $auditSummaryFile -Raw

    # Extract key metrics
    $successMatch = [regex]::Match($content, "Successful:\s*(\d+)")
    $partialMatch = [regex]::Match($content, "Partially successful:\s*(\d+)")
    $unsupportedMatch = [regex]::Match($content, "Unsupported:\s*(\d+)")
    $failedMatch = [regex]::Match($content, "Failed:\s*(\d+)")

    if ($successMatch.Success) { Write-Host "  Fully Convertible:    $($successMatch.Groups[1].Value)" -ForegroundColor Green }
    if ($partialMatch.Success) { Write-Host "  Partially Convertible: $($partialMatch.Groups[1].Value)" -ForegroundColor Yellow }
    if ($unsupportedMatch.Success) { Write-Host "  Unsupported:          $($unsupportedMatch.Groups[1].Value)" -ForegroundColor Red }
    if ($failedMatch.Success) { Write-Host "  Failed:               $($failedMatch.Groups[1].Value)" -ForegroundColor Red }

    Write-Host "`nFull audit report: $auditSummaryFile" -ForegroundColor Green
}

# --- Manual Tasks Summary ---
$manualTasksFile = Join-Path $OutputDir "manual-tasks-summary.md"
$manualTasks = @"
# Manual Tasks Required Post-Pipeline Migration

## Per Pipeline
- [ ] Create GitHub Actions secrets (from ADO variable groups / key vault references)
- [ ] Configure self-hosted runners (if using ADO self-hosted agents)
- [ ] Set up GitHub Environments with protection rules (replaces ADO stages/gates)
- [ ] Update any hard-coded ADO URLs in scripts
- [ ] Configure OIDC for cloud deployments (replaces ADO service connections)

## Classic Release Pipelines
- [ ] Deployment gates → GitHub Environment protection rules + required reviewers
- [ ] Pre/post-deployment approvals → GitHub Environment required reviewers
- [ ] Variable scoping per stage → GitHub Environment secrets
- [ ] Artifact triggers → workflow_run triggers or composite actions

## Common Unsupported Tasks (require custom actions or scripts)
- AzureRmWebAppDeployment → azure/webapps-deploy
- AzureKeyVault → azure/login + az keyvault commands
- SonarQubePrepare/Analyze → SonarSource/sonarqube-scan-action
- VSBuild → microsoft/setup-msbuild + msbuild command
- NuGetCommand → nuget/setup-nuget + nuget commands

## NOT Migrated (stays in ADO)
- Pipeline run history and logs
- Build artifacts
- Test results
- Deployment history
"@
$manualTasks | Out-File -FilePath $manualTasksFile -Encoding utf8
Write-Host "Manual tasks guide saved to: $manualTasksFile" -ForegroundColor Green

# --- Cleanup env vars ---
Remove-Item Env:\GITHUB_ACCESS_TOKEN -ErrorAction SilentlyContinue
Remove-Item Env:\AZURE_DEVOPS_ACCESS_TOKEN -ErrorAction SilentlyContinue

Write-Host "`nPipeline audit complete." -ForegroundColor Cyan
