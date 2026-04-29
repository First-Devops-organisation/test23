<#
.SYNOPSIS
    Forecasts GitHub Actions usage from Azure DevOps pipeline history.
.DESCRIPTION
    Runs 'gh actions-importer forecast azure-devops' to estimate runner minutes,
    job counts, and costs for GitHub Actions based on historical ADO pipeline usage.
.PARAMETER AdoOrg
    Azure DevOps organization name
.PARAMETER AdoProject
    Optional: specific project
.PARAMETER AdoPat
    ADO PAT
.PARAMETER GitHubPat
    GitHub PAT
.PARAMETER OutputDir
    Directory for forecast output
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AdoOrg,

    [string]$AdoProject,

    [Parameter(Mandatory = $true)]
    [string]$AdoPat,

    [Parameter(Mandatory = $true)]
    [string]$GitHubPat,

    [string]$OutputDir = "./output/forecast"
)

$ErrorActionPreference = "Stop"

$gh = Get-Command gh -ErrorAction SilentlyContinue
if (-not $gh) { Write-Error "GitHub CLI not found."; exit 1 }

if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

Write-Host "=== Pipeline Usage Forecast: $AdoOrg ===" -ForegroundColor Cyan

$env:GITHUB_ACCESS_TOKEN = $GitHubPat
$env:AZURE_DEVOPS_ACCESS_TOKEN = $AdoPat

$forecastArgs = @(
    "actions-importer", "forecast", "azure-devops",
    "--output-dir", $OutputDir,
    "--azure-devops-organization", "https://dev.azure.com/$AdoOrg"
)

if ($AdoProject) {
    $forecastArgs += "--azure-devops-project"
    $forecastArgs += $AdoProject
}

Write-Host "Running forecast (analyzing pipeline run history)..." -ForegroundColor Yellow
gh @forecastArgs 2>&1

$forecastFile = Join-Path $OutputDir "forecast_report.md"
if (Test-Path $forecastFile) {
    Write-Host "`n=== Forecast Report ===" -ForegroundColor Cyan
    Get-Content $forecastFile | Write-Host
    Write-Host "`nFull forecast: $forecastFile" -ForegroundColor Green
}

# --- Cost Estimation ---
$costEstimateFile = Join-Path $OutputDir "cost-estimate.md"
$costEstimate = @"
# GitHub Actions Cost Estimation Notes

## GitHub-Hosted Runner Rates (as of 2026)
| Runner OS | Per-minute rate |
|-----------|----------------|
| Linux     | `$0.008        |
| Windows   | `$0.016        |
| macOS     | `$0.080        |

## Included Minutes (GitHub Enterprise Cloud)
- 50,000 minutes/month included
- Additional minutes billed at above rates

## Self-Hosted Runners
- No per-minute charge from GitHub
- You manage infrastructure costs
- Recommended for bank environments (network isolation, compliance)

## Larger Runners (if needed)
- 4-core Linux: `$0.016/min
- 8-core Linux: `$0.032/min  
- 16-core Linux: `$0.064/min

## Recommendations for Bank Migration
1. Use self-hosted runners in private network for production deployments
2. Use GitHub-hosted runners for non-sensitive CI jobs
3. Monitor usage with billing API post-migration
"@
$costEstimate | Out-File -FilePath $costEstimateFile -Encoding utf8
Write-Host "Cost estimation guide saved to: $costEstimateFile" -ForegroundColor Green

Remove-Item Env:\GITHUB_ACCESS_TOKEN -ErrorAction SilentlyContinue
Remove-Item Env:\AZURE_DEVOPS_ACCESS_TOKEN -ErrorAction SilentlyContinue
