<#
.SYNOPSIS
    Migrates Azure DevOps pipeline definitions to GitHub Actions workflows.
.DESCRIPTION
    Uses GitHub Actions Importer to convert ADO YAML and Classic pipelines
    to GitHub Actions workflows. Handles dry-run, migration, and custom transformer support.
.PARAMETER ConfigFile
    Path to migration-config.json
.PARAMETER AdoProject
    ADO project to migrate pipelines from
.PARAMETER PipelineId
    Optional: specific pipeline ID to migrate. If omitted, migrates all.
.PARAMETER Mode
    dry-run (preview), migrate (create PRs), or audit (scan all)
.PARAMETER CustomTransformersDir
    Optional: directory containing custom transformer files
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigFile,

    [Parameter(Mandatory = $true)]
    [string]$AdoProject,

    [int]$PipelineId,

    [ValidateSet("list", "dry-run", "migrate", "audit")]
    [string]$Mode = "dry-run",

    [string]$CustomTransformersDir,

    [string]$OutputDir = "./output/pipelines"
)

$ErrorActionPreference = "Stop"

$config = Get-Content $ConfigFile -Raw | ConvertFrom-Json

# $adoOrg = ($config.source.organization -replace "https://dev.azure.com/", "").TrimEnd("/")
$adoOrgUrl = $config.source.organization.TrimEnd("/")
$ghOrg = $config.target.organization
$adoPat = if ($config.source.pat) { $config.source.pat } else { $env:ADO_PAT }
$ghPat = if ($config.target.pat) { $config.target.pat } else { $env:GH_PAT }

if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

$env:GITHUB_ACCESS_TOKEN = $ghPat
$env:AZURE_DEVOPS_ACCESS_TOKEN = $adoPat

Write-Host "=== Pipeline Migration ($Mode) ===" -ForegroundColor Cyan
Write-Host "Project: $AdoProject" -ForegroundColor Gray

# --- List mode: show all pipeline IDs and exit ---
if ($Mode -eq "list") {
    Write-Host "`nFetching pipelines from ADO..." -ForegroundColor Yellow
    $base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$adoPat"))
    $adoHeaders = @{ Authorization = "Basic $base64Auth" }
    # $pipelinesUrl = "https://dev.azure.com/$adoOrg/$AdoProject/_apis/build/definitions?api-version=7.1"
    $pipelinesUrl = "$adoOrgUrl/$AdoProject/_apis/build/definitions?api-version=7.1"
    $allPipelines = (Invoke-RestMethod -Uri $pipelinesUrl -Headers $adoHeaders).value

    Write-Host "`n=== Available Pipelines ($($allPipelines.Count) found) ===" -ForegroundColor Cyan
    Write-Host ("{0,-8} {1,-45} {2,-12} {3}" -f "ID", "Name", "Type", "Path") -ForegroundColor White
    Write-Host ("-" * 90)
    foreach ($p in $allPipelines | Sort-Object id) {
        $pType = if ($p.process.yamlFilename) { "YAML" } else { "Classic" }
        Write-Host ("{0,-8} {1,-45} {2,-12} {3}" -f $p.id, $p.name, $pType, $p.path)
    }
    Write-Host "`nUsage: migrate-pipelines.ps1 -PipelineId <ID> -Mode dry-run" -ForegroundColor Green
    return
}

if ($Mode -eq "audit") {
    Write-Host "`nRunning audit..." -ForegroundColor Yellow
    $auditArgs = @(
        "actions-importer", "audit", "azure-devops",
        "--output-dir", $OutputDir,
        "--azure-devops-organization", "https://dev.azure.com/$adoOrg",
        
        "--azure-devops-project", $AdoProject
    )
    gh @auditArgs 2>&1
    Write-Host "Audit complete. Check: $OutputDir/audit_summary.md" -ForegroundColor Green
    return
}

# --- Get pipelines ---
$base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$adoPat"))
$adoHeaders = @{ Authorization = "Basic $base64Auth" }

$pipelinesUrl = "https://dev.azure.com/$adoOrg/$AdoProject/_apis/build/definitions?api-version=7.1"
$pipelines = (Invoke-RestMethod -Uri $pipelinesUrl -Headers $adoHeaders).value

if ($PipelineId) {
    $pipelines = $pipelines | Where-Object { $_.id -eq $PipelineId }
}

Write-Host "Found $($pipelines.Count) pipeline(s) to process" -ForegroundColor Gray

$results = @()

foreach ($pipeline in $pipelines) {
    $pipelineName = $pipeline.name
    $pId = $pipeline.id
    Write-Host "`n  Processing: $pipelineName (ID: $pId)" -ForegroundColor Yellow

    # Determine target repo
    $targetRepo = if ($pipeline.repository) {
        ($pipeline.repository.name).ToLower() -replace " ", "-"
    }
    else {
        $AdoProject.ToLower() -replace " ", "-"
    }

    $outputSubDir = Join-Path $OutputDir "$pipelineName"
    if (-not (Test-Path $outputSubDir)) { New-Item -ItemType Directory -Path $outputSubDir -Force | Out-Null }

    $importerArgs = @(
        "actions-importer", $Mode, "azure-devops", "pipeline",
        "--output-dir", $outputSubDir,
        # "--azure-devops-organization", "https://dev.azure.com/$adoOrg",
        "--azure-devops-organization", $adoOrgUrl,
        "--azure-devops-project", $AdoProject,
        "--pipeline-id", $pId
    )

    if ($Mode -eq "migrate") {
        $importerArgs += "--target-url"
        $importerArgs += "https://github.com/$ghOrg/$targetRepo"
    }

    if ($CustomTransformersDir -and (Test-Path $CustomTransformersDir)) {
        $importerArgs += "--custom-transformers"
        $importerArgs += $CustomTransformersDir
    }

    try {
        $output = gh @importerArgs 2>&1
        $outputStr = $output | Out-String

        $status = if ($outputStr -match "error|failed") { "FAILED" }
        elseif ($outputStr -match "partially") { "PARTIAL" }
        else { "SUCCESS" }

        $results += [PSCustomObject]@{
            Pipeline   = $pipelineName
            Id         = $pId
            TargetRepo = $targetRepo
            Mode       = $Mode
            Status     = $status
            OutputDir  = $outputSubDir
        }

        $color = switch ($status) { "SUCCESS" { "Green" } "PARTIAL" { "Yellow" } default { "Red" } }
        Write-Host "    $status" -ForegroundColor $color

        if ($Mode -eq "dry-run") {
            $yamlFiles = Get-ChildItem $outputSubDir -Filter "*.yml" -Recurse -ErrorAction SilentlyContinue
            if ($yamlFiles) {
                Write-Host "    Generated: $($yamlFiles.Name -join ', ')" -ForegroundColor Gray
            }
        }
    }
    catch {
        Write-Warning "    Error: $_"
        $results += [PSCustomObject]@{
            Pipeline   = $pipelineName
            Id         = $pId
            TargetRepo = $targetRepo
            Mode       = $Mode
            Status     = "ERROR"
            OutputDir  = $outputSubDir
        }
    }
}

# --- Summary ---
Write-Host "`n=== Pipeline Migration Summary ===" -ForegroundColor Cyan
$successCount = ($results | Where-Object { $_.Status -eq "SUCCESS" }).Count
$partialCount = ($results | Where-Object { $_.Status -eq "PARTIAL" }).Count
$failedCount = ($results | Where-Object { $_.Status -in @("FAILED", "ERROR") }).Count

Write-Host "Successful:  $successCount" -ForegroundColor Green
Write-Host "Partial:     $partialCount" -ForegroundColor Yellow
Write-Host "Failed:      $failedCount" -ForegroundColor Red

$csvFile = Join-Path $OutputDir "pipeline-migration-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
$results | Export-Csv -Path $csvFile -NoTypeInformation
Write-Host "`nResults saved to: $csvFile" -ForegroundColor Green

# --- Manual Post-Steps ---
Write-Host "`n=== MANUAL STEPS REQUIRED ===" -ForegroundColor Yellow
Write-Host @"
For each migrated pipeline:
1. Review generated GitHub Actions YAML for correctness
2. Create GitHub Actions secrets: Settings > Secrets > Actions
3. Configure environments with protection rules (replaces ADO gates)
4. Set up self-hosted runners if needed
5. Configure OIDC for Azure deployments (replaces service connections)
6. Test trigger the workflow

IMPORTANT: Pipeline run history/logs DO NOT migrate.
Historical logs remain in Azure DevOps.
"@ -ForegroundColor Gray

Remove-Item Env:\GITHUB_ACCESS_TOKEN -ErrorAction SilentlyContinue
Remove-Item Env:\AZURE_DEVOPS_ACCESS_TOKEN -ErrorAction SilentlyContinue
