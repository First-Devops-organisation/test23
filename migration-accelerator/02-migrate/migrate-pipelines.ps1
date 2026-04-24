```powershell
<#
.SYNOPSIS
    End-to-End ADO → GitHub Actions Pipeline Migration Script
    Supports:
    - config.json + env fallback
    - list / audit / dry-run / migrate
    - repo mapping
    - audit summary parsing
    - dashboard generation
#>


param(
    [string]$ConfigFile,
    [string]$AdoProject,
    [int[]]$PipelineId,

    [ValidateSet("list","audit","dry-run","migrate")]
    [string]$Mode = "dry-run",

    [ValidateSet("build","release")]
    [string]$PipelineType = "build",

    [string]$CustomTransformersDir,
    [string]$ConfigFilePath,
    [string]$OutputDir = "./output/pipelines"
)

$ErrorActionPreference = "Stop"

# ============================================================
# CONFIG RESOLVER
# ============================================================
function Get-ConfigValue {
    param($ConfigValue, $EnvVars)

    if ($ConfigValue -and $ConfigValue -notmatch '^\$\(') {
        return $ConfigValue
    }

    foreach ($envVar in $EnvVars) {
        $val = [Environment]::GetEnvironmentVariable($envVar)
        if ($val) { return $val }
    }

    return $null
}

# ============================================================
# LOAD CONFIG
# ============================================================
$config = $null
if ($ConfigFile -and (Test-Path $ConfigFile)) {
    $config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    Write-Host "Loaded config: $ConfigFile" -ForegroundColor Green
} else {
    Write-Host "Using environment variables fallback" -ForegroundColor Yellow
}

# Resolve values
$adoOrg     = Get-ConfigValue ($config?.source?.organization) @("ADO_ORG","ADO_Org")
$ghOrg      = Get-ConfigValue ($config?.target?.organization) @("GH_ORG")
$adoPat     = Get-ConfigValue ($config?.source?.pat)          @("ADO_PAT")
$ghPat      = Get-ConfigValue ($config?.target?.pat)          @("GH_PAT")
$AdoProject = if ($AdoProject) { $AdoProject } else { Get-ConfigValue ($config?.source?.project) @("ADO_PROJECT") }

if (-not $adoOrg -or -not $adoPat -or -not $ghOrg -or -not $ghPat -or -not $AdoProject) {
    throw "Missing required configuration"
}

# Normalize org
$adoOrg = $adoOrg.TrimEnd('/')
$adoOrgUrl  = if ($adoOrg -match '^https?://') { $adoOrg } else { "https://dev.azure.com/$adoOrg" }
$adoOrgName = ($adoOrgUrl -replace 'https?://dev\.azure\.com/', '')

# Tokens
$env:GITHUB_ACCESS_TOKEN = $ghPat
$env:AZURE_DEVOPS_ACCESS_TOKEN = $adoPat

# Output
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir | Out-Null
}

# ============================================================
# LIST MODE (FIXED + ENHANCED)
# ============================================================
if ($Mode -eq "list") {

    Write-Host "`nFetching pipelines..." -ForegroundColor Yellow

    $auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$adoPat"))
    $headers = @{ Authorization = "Basic $auth" }

    # Build pipelines
    $buildUrl = "$adoOrgUrl/$AdoProject/_apis/build/definitions?api-version=7.1&includeAllProperties=true"
    $buildPipelines = (Invoke-RestMethod -Uri $buildUrl -Headers $headers).value

    # Remove duplicates
    $buildPipelines = $buildPipelines | Sort-Object id -Unique

    Write-Host "`n=== Build Pipelines ===" -ForegroundColor Cyan
    Write-Host ("{0,-8} {1,-45} {2,-15} {3}" -f "ID","Name","Type","Migrate With")
    Write-Host ("-"*90)

    foreach ($p in $buildPipelines) {
        $type = if ($p.process.type -eq 2) { "YAML" } else { "Classic Build" }

        Write-Host ("{0,-8} {1,-45} {2,-15} {3}" -f `
            $p.id,
            $p.name,
            $type,
            "-PipelineType build"
        )
    }

    # Release pipelines
    try {
        $releaseUrl = "https://vsrm.dev.azure.com/$adoOrgName/$AdoProject/_apis/release/definitions?api-version=7.1"
        $releasePipelines = (Invoke-RestMethod -Uri $releaseUrl -Headers $headers).value

        if ($releasePipelines.Count -gt 0) {
            Write-Host "`n=== Release Pipelines ===" -ForegroundColor Cyan
            foreach ($r in $releasePipelines | Sort-Object id -Unique) {
                Write-Host ("{0,-8} {1,-45} {2,-15} {3}" -f `
                    $r.id,
                    $r.name,
                    "Release",
                    "-PipelineType release"
                )
            }
        }
    } catch {
        Write-Host "Release pipelines not accessible" -ForegroundColor Yellow
    }

    return
}

# ============================================================
# AUDIT MODE
# ============================================================
if ($Mode -eq "audit") {
    gh actions-importer audit azure-devops `
        --azure-devops-organization $adoOrgName `
        --azure-devops-project $AdoProject `
        --output-dir $OutputDir

    Write-Host "Audit completed" -ForegroundColor Green
    return
}

# ============================================================
# FETCH PIPELINES
# ============================================================
$auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$adoPat"))
$headers = @{ Authorization = "Basic $auth" }

if ($PipelineType -eq "release") {
    $url = "https://vsrm.dev.azure.com/$adoOrgName/$AdoProject/_apis/release/definitions?api-version=7.1"
} else {
    $url = "$adoOrgUrl/$AdoProject/_apis/build/definitions?api-version=7.1&includeAllProperties=true"
}

$pipelines = (Invoke-RestMethod -Uri $url -Headers $headers).value

if ($PipelineId) {
    $pipelines = $pipelines | Where-Object { $_.id -in $PipelineId }
}

# ============================================================
# REPO MAPPING
# ============================================================
$repoMap = @{}
if ($env:PIPELINE_REPO_MAP) {
    foreach ($entry in $env:PIPELINE_REPO_MAP.Split(',')) {
        $parts = $entry.Split('=')
        $repoMap[$parts[0]] = $parts[1]
    }
}

# ============================================================
# PROCESS PIPELINES
# ============================================================
$results = @()

foreach ($p in $pipelines) {

    $id = $p.id
    $name = $p.name

    Write-Host "`nProcessing: $name ($id)" -ForegroundColor Cyan

    # repo resolution
    $repo = if ($repoMap.ContainsKey("$id")) {
        $repoMap["$id"]
    } elseif ($p.repository) {
        ($p.repository.name -replace " ","-").ToLower()
    } else {
        $AdoProject.ToLower()
    }

    $outDir = Join-Path $OutputDir "$Mode/$name"
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null

    $cmd = @(
        "actions-importer",$Mode,"azure-devops","pipeline",
        "--azure-devops-organization",$adoOrgName,
        "--azure-devops-project",$AdoProject,
        "--pipeline-id",$id,
        "--output-dir",$outDir
    )

    if ($Mode -eq "migrate") {
        $cmd += "--target-url"
        $cmd += "https://github.com/$ghOrg/$repo"
    }

    if ($ConfigFilePath) {
        $cmd += "--config-file-path"
        $cmd += $ConfigFilePath
    }

    $output = gh @cmd 2>&1
    $exit = $LASTEXITCODE

    $status = if ($exit -ne 0) { "FAILED" }
    elseif ($output -match "partially") { "PARTIAL" }
    else { "SUCCESS" }

    Write-Host "Status: $status"

    $results += [PSCustomObject]@{
        Pipeline = $name
        Id       = $id
        Repo     = $repo
        Status   = $status
    }
}

# ============================================================
# SUMMARY
# ============================================================
Write-Host "`n=== SUMMARY ===" -ForegroundColor Cyan
$results | Format-Table

$csv = Join-Path $OutputDir "summary.csv"
$results | Export-Csv $csv -NoTypeInformation

Write-Host "Saved: $csv" -ForegroundColor Green

# Cleanup
Remove-Item Env:\GITHUB_ACCESS_TOKEN -ErrorAction SilentlyContinue
Remove-Item Env:\AZURE_DEVOPS_ACCESS_TOKEN -ErrorAction SilentlyContinue
```
