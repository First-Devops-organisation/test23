<#
.SYNOPSIS
    Enterprise ADO → GitHub Pipeline Migration Script
    Combines config.json + env fallback + full feature set
#>

[CmdletBinding()]
param(
    [string]$ConfigFile,
    [string]$AdoProject,
    [int[]]$PipelineId,
    [ValidateSet("list","dry-run","migrate","audit")]
    [string]$Mode = "dry-run",
    [ValidateSet("build","release")]
    [string]$PipelineType = "build",
    [string]$CustomTransformersDir,
    [string]$ConfigFilePath,
    [string]$OutputDir = "./output/pipelines"
)

$ErrorActionPreference = "Stop"

# ============================================================
# ✅ CONFIG RESOLVER (BEST VERSION)
# ============================================================
function Get-ConfigValue {
    param(
        [object]$ConfigValue,
        [string[]]$EnvVars
    )

    if ($ConfigValue -and $ConfigValue -notmatch '^\$\(') {
        return $ConfigValue
    }

    foreach ($envVar in $EnvVars) {
        $val = [System.Environment]::GetEnvironmentVariable($envVar)
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

# ============================================================
# RESOLVE VALUES
# ============================================================
$adoOrg     = Get-ConfigValue ($config?.source?.organization) @("ADO_ORG","ADO_Org")
$ghOrg      = Get-ConfigValue ($config?.target?.organization) @("GH_ORG")
$adoPat     = Get-ConfigValue ($config?.source?.pat)          @("ADO_PAT")
$ghPat      = Get-ConfigValue ($config?.target?.pat)          @("GH_PAT")
$AdoProject = if ($AdoProject) { $AdoProject } else { Get-ConfigValue ($config?.source?.project) @("ADO_PROJECT") }

if (-not $adoOrg -or -not $adoPat -or -not $ghOrg -or -not $ghPat -or -not $AdoProject) {
    throw "Missing required configuration values"
}

# Normalize org
$adoOrg = $adoOrg.TrimEnd('/')
$adoOrgUrl  = if ($adoOrg -match '^https?://') { $adoOrg } else { "https://dev.azure.com/$adoOrg" }
$adoOrgName = ($adoOrgUrl -replace 'https?://dev\.azure\.com/', '')

# Tokens
$env:GITHUB_ACCESS_TOKEN = $ghPat
$env:AZURE_DEVOPS_ACCESS_TOKEN = $adoPat

# Output dir
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

# ============================================================
# PIPELINE → REPO MAP SUPPORT
# ============================================================
$pipelineRepoMap = @{}
if ($env:PIPELINE_REPO_MAP) {
    foreach ($entry in $env:PIPELINE_REPO_MAP.Split(',')) {
        $parts = $entry.Split('=')
        if ($parts.Count -eq 2) {
            $pipelineRepoMap[$parts[0].Trim()] = $parts[1].Trim()
        }
    }
}

$defaultRepo = $env:GH_REPO

# ============================================================
# LIST MODE
# ============================================================
if ($Mode -eq "list") {
    $auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$adoPat"))
    $headers = @{ Authorization = "Basic $auth" }

    $buildUrl = "$adoOrgUrl/$AdoProject/_apis/build/definitions?api-version=7.1&includeAllProperties=true"
    $buildPipelines = (Invoke-RestMethod -Uri $buildUrl -Headers $headers).value

    $releasePipelines = @()
    try {
        $releaseUrl = "https://vsrm.dev.azure.com/$adoOrgName/$AdoProject/_apis/release/definitions?api-version=7.1"
        $releasePipelines = (Invoke-RestMethod -Uri $releaseUrl -Headers $headers).value
    } catch {}

    Write-Host "`n=== BUILD PIPELINES ===" -ForegroundColor Cyan
    foreach ($p in $buildPipelines) {
        $type = if ($p.process.type -eq 2) { "YAML" } else { "Classic" }
        Write-Host "$($p.id) - $($p.name) [$type]"
    }

    Write-Host "`n=== RELEASE PIPELINES ===" -ForegroundColor Cyan
    foreach ($r in $releasePipelines) {
        Write-Host "$($r.id) - $($r.name) [Release]"
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

Write-Host "Processing $($pipelines.Count) pipelines..."

# Ensure importer updated
gh actions-importer update | Out-Null

# ============================================================
# PROCESS
# ============================================================
$results = @()

foreach ($p in $pipelines) {

    $id = [int]$p.id
    $name = $p.name

    Write-Host "`nProcessing: $name ($id)" -ForegroundColor Cyan

    # Repo resolution
    if ($pipelineRepoMap.ContainsKey("$id")) {
        $repo = $pipelineRepoMap["$id"]
    } elseif ($defaultRepo) {
        $repo = $defaultRepo
    } elseif ($p.repository) {
        $repo = ($p.repository.name -replace " ", "-").ToLower()
    } else {
        $repo = $AdoProject.ToLower()
    }

    Write-Host "Target Repo: $ghOrg/$repo"

    $outDir = Join-Path $OutputDir "$Mode/$name"
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null

    $subCmd = if ($PipelineType -eq "release") { "release" } else { "pipeline" }

    $cmd = @(
        "actions-importer", $Mode, "azure-devops", $subCmd,
        "--azure-devops-organization", $adoOrgName,
        "--azure-devops-project", $AdoProject,
        "--pipeline-id", $id,
        "--output-dir", $outDir
    )

    if ($Mode -eq "migrate") {
        $cmd += "--target-url"
        $cmd += "https://github.com/$ghOrg/$repo"
    }

    if ($CustomTransformersDir -and (Test-Path $CustomTransformersDir)) {
        $cmd += "--custom-transformers"
        $cmd += $CustomTransformersDir
    }

    if ($ConfigFilePath -and (Test-Path $ConfigFilePath)) {
        $cmd += "--config-file-path"
        $cmd += $ConfigFilePath
    }

    Write-Host "Running: gh $($cmd -join ' ')" -ForegroundColor Gray

    $output = gh @cmd 2>&1
    $exit = $LASTEXITCODE
    $outputStr = $output | Out-String

    # Detect YAML output
    $yamlFiles = Get-ChildItem $outDir -Recurse -Include *.yml,*.yaml -ErrorAction SilentlyContinue

    $status = if ($exit -ne 0) { "FAILED" }
    elseif ($outputStr -match "error|failed") { "FAILED" }
    elseif ($outputStr -match "partially") { "PARTIAL" }
    elseif ($Mode -eq "dry-run" -and -not $yamlFiles) { "NO_OUTPUT" }
    else { "SUCCESS" }

    Write-Host "Status: $status" -ForegroundColor Green

    $results += [PSCustomObject]@{
        Pipeline   = $name
        Id         = $id
        Repo       = $repo
        Status     = $status
        OutputDir  = $outDir
    }

    # Debug logs if needed
    if ($status -eq "NO_OUTPUT") {
        Write-Host "⚠ No YAML generated. Checking logs..." -ForegroundColor Yellow
        Get-ChildItem $outDir -Filter *.log -Recurse | ForEach-Object {
            Write-Host "`n--- LOG: $($_.Name) ---"
            Get-Content $_.FullName
        }
    }
}

# ============================================================
# SUMMARY
# ============================================================
Write-Host "`n=== SUMMARY ===" -ForegroundColor Cyan

$results | Format-Table

$csv = Join-Path $OutputDir "summary.csv"
$results | Export-Csv $csv -NoTypeInformation

Write-Host "Saved CSV: $csv" -ForegroundColor Green

# ============================================================
# CLEANUP
# ============================================================
Remove-Item Env:\GITHUB_ACCESS_TOKEN -ErrorAction SilentlyContinue
Remove-Item Env:\AZURE_DEVOPS_ACCESS_TOKEN -ErrorAction SilentlyContinue