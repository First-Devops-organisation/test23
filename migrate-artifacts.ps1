<#
.SYNOPSIS
    Migrates build artifacts from Azure DevOps to GitHub Releases.
.PARAMETER LastBuilds
    Number of builds to migrate.
.PARAMETER OrgName
    ADO Organization name.
.PARAMETER ProjectName
    ADO Project name.
.PARAMETER PipelineName
    Source ADO Pipeline name.
.PARAMETER GitHubOrg
    Target GitHub Organization.
.PARAMETER GitHubRepo
    Target GitHub Repository.
.PARAMETER Version
    Version suffix for the release tag.
.PARAMETER Pat
    ADO Personal Access Token.
#>
param(
    [Parameter(Mandatory = $true)] [int]$LastBuilds,
    [Parameter(Mandatory = $true)] [string]$OrgName,
    [Parameter(Mandatory = $true)] [string]$ProjectName,
    [Parameter(Mandatory = $true)] [string]$PipelineName,
    [Parameter(Mandatory = $true)] [string]$GitHubOrg,
    [Parameter(Mandatory = $true)] [string]$GitHubRepo,
    [Parameter(Mandatory = $false)] [string]$Version = "1.0.0",
    [Parameter(Mandatory = $false)] [string]$Pat = $env:ADO_PAT
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Pat)) {
    Write-Error "ADO_PAT is required. Please provide it via the -Pat parameter or set the ADO_PAT environment variable."
    exit 1
}

# Ensure GitHub Token is available for 'gh' CLI
if (-not $env:GH_TOKEN -and $env:GH_PAT) {
    $env:GH_TOKEN = $env:GH_PAT
}

$base64Pat = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))
$headers = @{ Authorization = "Basic $base64Pat" }

Write-Host "`n" + ("=" * 60) -ForegroundColor Cyan
Write-Host " EXECUTING ARTIFACT MIGRATION" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host "  Source Pipeline : $OrgName/$ProjectName/$PipelineName"
Write-Host "  Target GitHub   : $GitHubOrg/$GitHubRepo"
Write-Host "  Build Limit     : $LastBuilds"

# 1. Find Pipeline Definition
Write-Host "`n[Step 1] Locating pipeline ID..." -ForegroundColor Gray
$defsUrl = "https://dev.azure.com/$OrgName/$ProjectName/_apis/build/definitions?api-version=7.1"
try {
    $defs = Invoke-RestMethod -Uri $defsUrl -Headers $headers
    $pipelineDef = $defs.value | Where-Object { $_.name -eq $PipelineName }
} catch {
    Write-Error "Failed to connect to Azure DevOps API: $_"
    exit 1
}

if (-not $pipelineDef) {
    Write-Error "Pipeline '$PipelineName' not found in project '$ProjectName'."
    exit 1
}

$pipelineDefId = $pipelineDef.id
Write-Host "  --> Found ID: $pipelineDefId" -ForegroundColor Green

# 2. Fetch Latest Builds
Write-Host "`n[Step 2] Fetching recent builds..." -ForegroundColor Gray
$buildsUrl = "https://dev.azure.com/$OrgName/$ProjectName/_apis/build/builds?definitions=$pipelineDefId&`$top=$LastBuilds&api-version=7.1"
$builds = Invoke-RestMethod -Uri $buildsUrl -Headers $headers

if ($builds.value.Count -eq 0) {
    Write-Host "  [SKIP] No builds found for this pipeline." -ForegroundColor Yellow
    exit 0
}

# 3. Create temporary directory
$downloadRoot = Join-Path $PSScriptRoot "temp_artifacts_$($PipelineName.Replace(' ','_'))"
if (-not (Test-Path $downloadRoot)) {
    New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null
}

# 4. Process each build
Write-Host "`n[Step 3] Migrating $($builds.value.Count) builds to GitHub..." -ForegroundColor Gray
foreach ($build in $builds.value) {
    $buildId = $build.id
    $buildFolder = Join-Path $downloadRoot "build_$buildId"
    New-Item -ItemType Directory -Path $buildFolder -Force | Out-Null

    Write-Host "`n  --> Processing Build #$buildId" -ForegroundColor Yellow
    
    # Download Artifacts
    $artifactsUrl = "https://dev.azure.com/$OrgName/$ProjectName/_apis/build/builds/$buildId/artifacts?api-version=7.1"
    $artifacts = Invoke-RestMethod -Uri $artifactsUrl -Headers $headers

    if ($artifacts.value.Count -eq 0) {
        Write-Host "      (No artifacts found for this build)" -ForegroundColor Gray
        continue
    }

    foreach ($artifact in $artifacts.value) {
        $artifactName = $artifact.name
        $outFile = Join-Path $buildFolder "$artifactName.zip"
        Write-Host "      Downloading: $artifactName" -ForegroundColor Gray
        Invoke-WebRequest -Uri $artifact.resource.downloadUrl -OutFile $outFile -Headers $headers
    }

    # 5. Create GitHub Release
    $releaseTag = "$PipelineName-build-$buildId-v$Version"
    $artifactFiles = Get-ChildItem -Path $buildFolder -Filter "*.zip" | Select-Object -ExpandProperty FullName

    if ($artifactFiles.Count -eq 0) {
        continue
    }

    Write-Host "      Creating GitHub Release: $releaseTag" -ForegroundColor Cyan
    
    # Check if release already exists
    $checkRelease = gh release view $releaseTag --repo "$GitHubOrg/$GitHubRepo" 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "      Release exists. Updating assets..." -ForegroundColor Yellow
        gh release upload $releaseTag --repo "$GitHubOrg/$GitHubRepo" --clobber $artifactFiles
    } else {
        gh release create $releaseTag `
            --repo "$GitHubOrg/$GitHubRepo" `
            --title "$PipelineName Build #$buildId" `
            --notes "Migrated from Azure DevOps build $buildId." `
            -- $artifactFiles
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "      Failed to complete GitHub Release for Build $buildId"
    }
}

# Cleanup
if (Test-Path $downloadRoot) {
    Remove-Item $downloadRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`n" + ("=" * 60) -ForegroundColor Green
Write-Host " MIGRATION COMPLETE" -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Green
