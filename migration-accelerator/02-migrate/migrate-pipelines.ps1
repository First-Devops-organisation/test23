<#
.SYNOPSIS
    Migrates Azure DevOps pipelines to GitHub Actions
    Supports config.json + variable group fallback
#>

[CmdletBinding()]
param(
    [string]$ConfigFile,
    [string]$AdoProject,
    [int[]]$PipelineId,
    [ValidateSet("list", "dry-run", "migrate", "audit")]
    [string]$Mode = "dry-run",
    [ValidateSet("build", "release")]
    [string]$PipelineType = "build",
    [string]$CustomTransformersDir,
    [string]$ConfigFilePath,
    [string]$OutputDir = "./output/pipelines"
)

$ErrorActionPreference = "Stop"

# ============================================================
# ✅ CONFIG RESOLVER (CORE FIX)
# ============================================================
function Get-ConfigValue {
    param(
        [object]$ConfigValue,
        [string[]]$EnvVars
    )

    # Priority 1: config.json (ignore $(VAR))
    if ($ConfigValue -and $ConfigValue -notmatch '^\$\(') {
        return $ConfigValue
    }

    # Priority 2: environment variables
    foreach ($envVar in $EnvVars) {
        $val = [System.Environment]::GetEnvironmentVariable($envVar)
        if ($val) { return $val }
    }

    return $null
}

# ============================================================
# ✅ LOAD CONFIG FILE
# ============================================================
$config = $null
if ($ConfigFile -and (Test-Path $ConfigFile)) {
    $config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    Write-Host "Loaded config file: $ConfigFile" -ForegroundColor Green
} else {
    Write-Host "Using variable group (env vars fallback)" -ForegroundColor Yellow
}

# ============================================================
# ✅ RESOLVE ALL CONFIG VALUES
# ============================================================
$adoOrg     = Get-ConfigValue ($config?.source?.organization) @("ADO_ORG","ADO_Org")
$ghOrg      = Get-ConfigValue ($config?.target?.organization) @("GH_ORG")
$adoPat     = Get-ConfigValue ($config?.source?.pat)          @("ADO_PAT")
$ghPat      = Get-ConfigValue ($config?.target?.pat)          @("GH_PAT")
$AdoProject = if ($AdoProject) { $AdoProject } else { Get-ConfigValue ($config?.source?.project) @("ADO_PROJECT") }

# ============================================================
# ✅ VALIDATION
# ============================================================
if (-not $adoOrg)     { throw "ADO_ORG not set" }
if (-not $adoPat)     { throw "ADO_PAT not set" }
if (-not $AdoProject) { throw "ADO_PROJECT not set" }
if (-not $ghOrg)      { throw "GH_ORG not set" }
if (-not $ghPat)      { throw "GH_PAT not set" }

# Normalize org
$adoOrg = $adoOrg.TrimEnd('/')
$adoOrgUrl  = if ($adoOrg -match '^https?://') { $adoOrg } else { "https://dev.azure.com/$adoOrg" }
$adoOrgName = ($adoOrgUrl -replace 'https?://dev\.azure\.com/', '')

# Debug logs
Write-Host "`n=== CONFIGURATION ===" -ForegroundColor Cyan
Write-Host "ADO Org:      $adoOrgUrl"
Write-Host "ADO Project:  $AdoProject"
Write-Host "GitHub Org:   $ghOrg"

# Tokens
$env:GITHUB_ACCESS_TOKEN = $ghPat
$env:AZURE_DEVOPS_ACCESS_TOKEN = $adoPat

# Output dir
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir | Out-Null
}

# ============================================================
# ✅ FETCH PIPELINES
# ============================================================
$auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$adoPat"))
$headers = @{ Authorization = "Basic $auth" }

if ($PipelineType -eq "release") {
    $url = "https://vsrm.dev.azure.com/$adoOrgName/$AdoProject/_apis/release/definitions?api-version=7.1"
} else {
    $url = "$adoOrgUrl/$AdoProject/_apis/build/definitions?api-version=7.1"
}

Write-Host "`nFetching pipelines..." -ForegroundColor Yellow
$pipelines = (Invoke-RestMethod -Uri $url -Headers $headers).value

if ($PipelineId) {
    $pipelines = $pipelines | Where-Object { $_.id -in $PipelineId }
}

Write-Host "Found $($pipelines.Count) pipeline(s)"

# ============================================================
# ✅ IMPORTER SETUP
# ============================================================
gh actions-importer update | Out-Null

# ============================================================
# ✅ PROCESS PIPELINES
# ============================================================
$results = @()

foreach ($p in $pipelines) {

    $id = $p.id
    $name = $p.name
    Write-Host "`nProcessing: $name ($id)" -ForegroundColor Cyan

    $repo = ($p.repository.name -replace " ", "-").ToLower()

    $outDir = Join-Path $OutputDir "$Mode/$name"
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null

    $cmd = @(
        "actions-importer", $Mode, "azure-devops", "pipeline",
        "--azure-devops-organization", $adoOrgName,
        "--azure-devops-project", $AdoProject,
        "--pipeline-id", $id,
        "--output-dir", $outDir
    )

    if ($Mode -eq "migrate") {
        $cmd += "--target-url"
        $cmd += "https://github.com/$ghOrg/$repo"
    }

    if ($ConfigFilePath) {
        $cmd += "--config-file-path"
        $cmd += $ConfigFilePath
    }

    Write-Host "Running: gh $($cmd -join ' ')" -ForegroundColor Gray

    $output = gh @cmd 2>&1
    $exit = $LASTEXITCODE

    $status = if ($exit -ne 0) { "FAILED" }
    elseif ($output -match "partially") { "PARTIAL" }
    else { "SUCCESS" }

    Write-Host "Status: $status" -ForegroundColor Green

    $results += [PSCustomObject]@{
        Pipeline = $name
        Id       = $id
        Status   = $status
        Repo     = $repo
    }
}

# ============================================================
# ✅ SUMMARY
# ============================================================
Write-Host "`n=== SUMMARY ===" -ForegroundColor Cyan

$results | Format-Table

$csv = Join-Path $OutputDir "summary.csv"
$results | Export-Csv $csv -NoTypeInformation

Write-Host "Saved: $csv" -ForegroundColor Green

# Cleanup
Remove-Item Env:\GITHUB_ACCESS_TOKEN -ErrorAction SilentlyContinue
Remove-Item Env:\AZURE_DEVOPS_ACCESS_TOKEN -ErrorAction SilentlyContinue