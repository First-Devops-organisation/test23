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
    [string]$ConfigFile,

    [string]$AdoProject,

    [int[]]$PipelineId,

    [ValidateSet("list", "dry-run", "migrate", "audit")]
    [string]$Mode = "dry-run",

    [string]$CustomTransformersDir,

    [string]$OutputDir = "./output/pipelines"
)

$ErrorActionPreference = "Stop"

# Load config file if provided, otherwise use env vars from variable group
$config = $null
if ($ConfigFile -and (Test-Path $ConfigFile)) {
    $config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    Write-Host "Loaded config from: $ConfigFile" -ForegroundColor Gray
} else {
    Write-Host "No config file — using environment variables from variable group" -ForegroundColor Gray
}

# Read from config, fallback to env vars (variable group)
$adoOrg = if ($config) { $config.source.organization } else { $null }
if (-not $adoOrg -or $adoOrg -match '^\$\(') {
    $adoOrg = if ($env:ADO_ORG) { $env:ADO_ORG } elseif ($env:ADO_Org) { $env:ADO_Org } else { $null }
}
# Normalize: build full URL if just org name, keep as-is if already a URL
$adoOrg = $adoOrg.TrimEnd('/')
$adoOrgUrl = if ($adoOrg -match '^https?://') { $adoOrg } else { "https://dev.azure.com/$adoOrg" }
$adoOrgName = ($adoOrg -replace 'https?://dev\.azure\.com/', '')

$ghOrg = if ($config) { $config.target.organization } else { $null }
if (-not $ghOrg -or $ghOrg -match '^\$\(') {
    $ghOrg = if ($env:GH_ORG) { $env:GH_ORG } else { $null }
}

$adoPat = if ($config) { $config.source.pat } else { $null }
if (-not $adoPat -or $adoPat -match '^\$\(') { $adoPat = $env:ADO_PAT }

$ghPat = if ($config) { $config.target.pat } else { $null }
if (-not $ghPat -or $ghPat -match '^\$\(') { $ghPat = $env:GH_PAT }

# Use project from config if not passed as parameter
if (-not $AdoProject -or $AdoProject -match '^\$\(') {
    if ($config) { $AdoProject = $config.source.project }
    if (-not $AdoProject -or $AdoProject -match '^\$\(') {
        $AdoProject = $env:ADO_PROJECT
    }
}

if (-not $adoOrgName) { Write-Host "ERROR: ADO org not set. Set ADO_ORG env var." -ForegroundColor Red; exit 1 }
if (-not $adoPat) { Write-Host "ERROR: ADO PAT not set. Set ADO_PAT env var." -ForegroundColor Red; exit 1 }
if (-not $AdoProject) { Write-Host "ERROR: ADO project not set. Pass -AdoProject or set ADO_PROJECT env var." -ForegroundColor Red; exit 1 }

if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

$env:GITHUB_ACCESS_TOKEN = $ghPat
$env:AZURE_DEVOPS_ACCESS_TOKEN = $adoPat

Write-Host "=== Pipeline Migration ($Mode) ===" -ForegroundColor Cyan
Write-Host "  Organization: $adoOrgUrl" -ForegroundColor Gray
Write-Host "  Project:      $AdoProject" -ForegroundColor Gray

# --- List mode: show all pipeline IDs and exit ---
if ($Mode -eq "list") {
    Write-Host "`nFetching pipelines from ADO..." -ForegroundColor Yellow
    $base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$adoPat"))
    $adoHeaders = @{ Authorization = "Basic $base64Auth" }

    # Fetch Build pipelines (YAML + Classic Build)
    $buildUrl = "$adoOrgUrl/$AdoProject/_apis/build/definitions?api-version=7.1"
    $buildPipelines = (Invoke-RestMethod -Uri $buildUrl -Headers $adoHeaders).value

    # Fetch Classic Release pipelines (separate API)
    $releasePipelines = @()
    try {
        $releaseUrl = "https://vsrm.dev.azure.com/$adoOrgName/$AdoProject/_apis/release/definitions?api-version=7.1"
        $releasePipelines = (Invoke-RestMethod -Uri $releaseUrl -Headers $adoHeaders).value
    } catch {
        Write-Host "  Note: Could not fetch release pipelines (may require additional permissions)" -ForegroundColor Yellow
    }

    $totalCount = $buildPipelines.Count + $releasePipelines.Count
    Write-Host "`n=== Available Pipelines ($totalCount found) ===" -ForegroundColor Cyan

    # Build pipelines
    Write-Host "`n--- Build Pipelines ($($buildPipelines.Count)) ---" -ForegroundColor White
    Write-Host ("{0,-8} {1,-45} {2,-12} {3}" -f "ID", "Name", "Type", "Path") -ForegroundColor White
    Write-Host ("-" * 90)
    foreach ($p in $buildPipelines | Sort-Object id) {
        $pType = if ($p.process.yamlFilename) { "YAML" } else { "Classic Build" }
        Write-Host ("{0,-8} {1,-45} {2,-12} {3}" -f $p.id, $p.name, $pType, $p.path)
    }

    # Release pipelines
    if ($releasePipelines.Count -gt 0) {
        Write-Host "`n--- Classic Release Pipelines ($($releasePipelines.Count)) ---" -ForegroundColor White
        Write-Host ("{0,-8} {1,-45} {2,-12} {3}" -f "ID", "Name", "Type", "Path") -ForegroundColor White
        Write-Host ("-" * 90)
        foreach ($r in $releasePipelines | Sort-Object id) {
            Write-Host ("{0,-8} {1,-45} {2,-12} {3}" -f $r.id, $r.name, "Release", $r.path)
        }
    }

    Write-Host "`nTo migrate a pipeline, re-run with: -PipelineId <ID> -Mode migrate" -ForegroundColor Green

    # --- Show audit status per pipeline if audit_summary.md exists ---
    $auditFile = Join-Path $OutputDir "audit_summary.md"
    if (-not (Test-Path $auditFile)) {
        # Also check default audit output location
        $auditFile = "./output/pipeline-audit/audit_summary.md"
    }
    if (Test-Path $auditFile) {
        $auditContent = Get-Content $auditFile -Raw
        Write-Host "`n=== Audit Results (from audit_summary.md) ===" -ForegroundColor Cyan

        $statusSections = @(
            @{ Header = 'Successful';            Color = 'Green';  Pattern = '(?ms)^### Successful\s*\n(.*?)(?=^### |\z)' },
            @{ Header = 'Partially Successful';   Color = 'Yellow'; Pattern = '(?ms)^### Partially successful\s*\n(.*?)(?=^### |\z)' },
            @{ Header = 'Unsupported';            Color = 'Red';    Pattern = '(?ms)^### Unsupported\s*\n(.*?)(?=^### |\z)' },
            @{ Header = 'Failed';                 Color = 'Red';    Pattern = '(?ms)^### Failed\s*\n(.*?)(?=^### |\z)' }
        )

        # Build name-to-ID lookup from already-fetched pipeline lists
        $nameToId = @{}
        foreach ($bp in $buildPipelines) { $nameToId[$bp.name] = $bp.id }
        foreach ($rp in $releasePipelines) { $nameToId[$rp.name] = $rp.id }

        foreach ($sec in $statusSections) {
            $sectionMatch = [regex]::Match($auditContent, $sec.Pattern)
            if ($sectionMatch.Success) {
                $sectionBody = $sectionMatch.Groups[1].Value
                $pipelineEntries = [regex]::Matches($sectionBody, '(?m)^####\s+(.+)$')
                if ($pipelineEntries.Count -gt 0) {
                    Write-Host "`n--- $($sec.Header) Pipelines ($($pipelineEntries.Count)) ---" -ForegroundColor $sec.Color
                    foreach ($pm in $pipelineEntries) {
                        $fullPath = $pm.Groups[1].Value.Trim()
                        $pipeName = ($fullPath -split '/')[-1]
                        $pipelineIdVal = $nameToId[$pipeName]
                        if ($pipelineIdVal) {
                            Write-Host ("  [{0}] {1}" -f $pipelineIdVal, $pipeName) -ForegroundColor $sec.Color
                        } else {
                            Write-Host "       $pipeName" -ForegroundColor $sec.Color
                        }
                    }
                }
            }
        }
    }

    return
}

if ($Mode -eq "audit") {
    Write-Host "`nRunning audit..." -ForegroundColor Yellow
    $auditArgs = @(
        "actions-importer", "audit", "azure-devops",
        "--output-dir", $OutputDir,
        "--azure-devops-organization", $adoOrgName,
        "--azure-devops-project", $AdoProject
    )
    gh @auditArgs 2>&1
    Write-Host "Audit complete. Check: $OutputDir/audit_summary.md" -ForegroundColor Green
    return
}

# Ensure actions-importer Docker image is available
Write-Host "`nEnsuring actions-importer image is up to date..." -ForegroundColor Yellow
gh actions-importer update 2>&1 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
if ($LASTEXITCODE -ne 0) {
    Write-Host "  WARNING: Could not update actions-importer image." -ForegroundColor Yellow
}

# --- Get pipelines ---
$base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$adoPat"))
$adoHeaders = @{ Authorization = "Basic $base64Auth" }

$pipelinesUrl = "$adoOrgUrl/$AdoProject/_apis/build/definitions?api-version=7.1"
$pipelines = (Invoke-RestMethod -Uri $pipelinesUrl -Headers $adoHeaders).value

if ($PipelineId -and $PipelineId.Count -gt 0) {
    $pipelines = $pipelines | Where-Object { $_.id -in $PipelineId }
    Write-Host "Filtering to pipeline IDs: $($PipelineId -join ', ')" -ForegroundColor Gray
}

Write-Host "Found $($pipelines.Count) pipeline(s) to process" -ForegroundColor Gray

$results = @()

foreach ($pipeline in $pipelines) {
    $pipelineName = $pipeline.name
    $currentId = [int]$pipeline.id
    Write-Host "`n  Processing: $pipelineName (ID: $currentId)" -ForegroundColor Yellow

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
        "--azure-devops-organization", $adoOrgName,
        "--azure-devops-project", $AdoProject,
        "--pipeline-id", $currentId
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
        Write-Host "    Command: gh $($importerArgs -join ' ')" -ForegroundColor DarkGray
        $output = gh @importerArgs 2>&1
        $exitCode = $LASTEXITCODE
        $outputStr = $output | Out-String

        Write-Host "    --- actions-importer output (exit code: $exitCode) ---" -ForegroundColor DarkGray
        Write-Host $outputStr
        Write-Host "    --- end output ---" -ForegroundColor DarkGray

        # Check generated files
        $generatedFiles = Get-ChildItem $outputSubDir -Recurse -ErrorAction SilentlyContinue
        $yamlFiles = $generatedFiles | Where-Object { $_.Extension -in '.yml','.yaml' }

        $status = if ($exitCode -ne 0) { "FAILED" }
        elseif ($outputStr -match "error|failed") { "FAILED" }
        elseif ($outputStr -match "partially") { "PARTIAL" }
        elseif ($Mode -eq "dry-run" -and -not $yamlFiles) { "NO_OUTPUT" }
        else { "SUCCESS" }

        $results += [PSCustomObject]@{
            Pipeline   = $pipelineName
            Id         = $currentId
            TargetRepo = $targetRepo
            Mode       = $Mode
            Status     = $status
            OutputDir  = $outputSubDir
        }

        $color = switch ($status) { "SUCCESS" { "Green" } "PARTIAL" { "Yellow" } "NO_OUTPUT" { "Yellow" } default { "Red" } }
        Write-Host "    $status" -ForegroundColor $color

        if ($Mode -eq "dry-run") {
            if ($yamlFiles) {
                Write-Host "    Generated files:" -ForegroundColor Gray
                $yamlFiles | ForEach-Object { Write-Host "      $($_.FullName)" -ForegroundColor Gray }
            } else {
                Write-Host "    WARNING: No .yml files generated in $outputSubDir" -ForegroundColor Yellow
                if ($generatedFiles) {
                    Write-Host "    Other files in output:" -ForegroundColor Yellow
                    $generatedFiles | ForEach-Object { Write-Host "      $($_.FullName)" -ForegroundColor Yellow }
                }
                # Print log file contents for debugging
                $logFiles = Get-ChildItem $outputSubDir -Filter "*.log" -Recurse -ErrorAction SilentlyContinue
                foreach ($logFile in $logFiles) {
                    Write-Host "    --- Log: $($logFile.Name) ---" -ForegroundColor Yellow
                    Get-Content $logFile.FullName -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "      $_" -ForegroundColor Yellow }
                    Write-Host "    --- end log ---" -ForegroundColor Yellow
                }
            }
        }
    }
    catch {
        Write-Warning "    Error: $_"
        $results += [PSCustomObject]@{
            Pipeline   = $pipelineName
            Id         = $currentId
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

exit 0
