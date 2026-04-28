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

    [ValidateSet("list", "dry-run", "migrate", "audit", "migrate-reusables")]
    [string]$Mode = "dry-run",

    [ValidateSet("build", "release")]
    [string]$PipelineType = "build",

    [string]$CustomTransformersDir,

    [string]$ImporterConfigFile,

    [string]$ConfigFilePath,  # New parameter for --config-file-path

    # Central GitHub repo (e.g. "my-org/reusable-workflows") that should host
    # every converted reusable workflow + composite action. When set, the script
    # rewrites every target_url in config.yml to this repo before calling GEI.
    [string]$ReusablesTargetRepo,

    # Branch/tag/SHA the consuming pipelines should pin to. Defaults to "main".
    [string]$ReusablesRef = "main",

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

# Override parameters from config if present (fallback is var grp/env vars)
if ($config) {
    if ($null -ne $config.PIPELINE_IDS -and (-not $PSBoundParameters.ContainsKey('PipelineId') -or $PipelineId.Count -eq 0)) { 
        $PipelineId = $config.PIPELINE_IDS 
    }
    if ($config.PIPELINE_TYPE -and (-not $PSBoundParameters.ContainsKey('PipelineType') -or $PipelineType -eq "")) { 
        $PipelineType = $config.PIPELINE_TYPE 
    }
    if (-not $PSBoundParameters.ContainsKey('Mode')) {
        if ($config.MIGRATE_MODE) { $Mode = $config.MIGRATE_MODE }
        elseif ($config.MODE) { $Mode = $config.MODE }
    }
}

# Parse PIPELINE_REPO_MAP (format: "1106=repo1,1135=repo2,717=repo3")
$pipelineRepoMap = @{}
$repoMapRaw = if ($config -and $null -ne $config.PIPELINE_REPO_MAP) { $config.PIPELINE_REPO_MAP } elseif ($env:PIPELINE_REPO_MAP) { $env:PIPELINE_REPO_MAP } else { $null }
if ($repoMapRaw) {
    if ($repoMapRaw -is [System.Management.Automation.PSCustomObject] -or $repoMapRaw -is [System.Collections.Hashtable]) {
        foreach ($prop in $repoMapRaw.psobject.properties) {
            $pipelineRepoMap[$prop.Name] = $prop.Value
        }
    } else {
        foreach ($entry in $repoMapRaw.ToString().Split(',')) {
            $parts = $entry.Trim().Split('=', 2)
            if ($parts.Count -eq 2) {
                $pipelineRepoMap[$parts[0].Trim()] = $parts[1].Trim()
            }
        }
    }
    Write-Host "  Pipeline-to-Repo map: $($pipelineRepoMap.Count) entries loaded" -ForegroundColor Gray
}

# Default target repo from GH_REPO env var
$defaultTargetRepo = if ($config -and $config.GH_REPO) { $config.GH_REPO } elseif ($env:GH_REPO) { $env:GH_REPO } elseif ($env:GHRepo) { $env:GHRepo } else { $null }

Write-Host "=== Pipeline Migration ($Mode) ===" -ForegroundColor Cyan
Write-Host "  Organization: $adoOrgUrl" -ForegroundColor Gray
Write-Host "  Project:      $AdoProject" -ForegroundColor Gray

# --- List mode: show all pipeline IDs and exit ---
if ($Mode -eq "list") {
    Write-Host "`nFetching pipelines from ADO..." -ForegroundColor Yellow
    $base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$adoPat"))
    $adoHeaders = @{ Authorization = "Basic $base64Auth" }

    # Fetch Build pipelines (YAML + Classic Build) — includeAllProperties ensures process.type is returned
    $buildUrl = "$adoOrgUrl/$AdoProject/_apis/build/definitions?api-version=7.1&includeAllProperties=true"
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
        $pType = if ($p.process.type -eq 2) { "YAML" } else { "Classic Build" }
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

    Write-Host "`nTo migrate a build pipeline:   -PipelineId <ID> -PipelineType build -Mode migrate" -ForegroundColor Green
    Write-Host "To migrate a release pipeline: -PipelineId <ID> -PipelineType release -Mode migrate" -ForegroundColor Green

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

        # Build lookups: exact name, lowercase name, slug name, ID-based
        $nameToId = @{}
        $idToName = @{}
        $nameToType = @{}
        $idToType = @{}
        $slugToId = @{}
        $slugToType = @{}
        foreach ($bp in $buildPipelines) {
            $nameToId[$bp.name] = $bp.id
            $idToName["$($bp.id)"] = $bp.name
            $bType = if ($bp.process.type -eq 2) { "YAML" } else { "Classic Build" }
            $nameToType[$bp.name] = $bType
            $idToType["$($bp.id)"] = $bType
            # Slug: lowercase, spaces/special chars to hyphens
            $slug = ($bp.name.ToLower() -replace '[^a-z0-9\-]', '-') -replace '-+', '-' -replace '^-|-$', ''
            $slugToId[$slug] = $bp.id
            $slugToType[$slug] = $bType
        }
        foreach ($rp in $releasePipelines) {
            $nameToId[$rp.name] = $rp.id
            $idToName["$($rp.id)"] = $rp.name
            $nameToType[$rp.name] = "Release"
            $idToType["$($rp.id)"] = "Release"
            $slug = ($rp.name.ToLower() -replace '[^a-z0-9\-]', '-') -replace '-+', '-' -replace '^-|-$', ''
            $slugToId[$slug] = $rp.id
            $slugToType[$slug] = "Release"
        }

        foreach ($sec in $statusSections) {
            $sectionMatch = [regex]::Match($auditContent, $sec.Pattern)
            if ($sectionMatch.Success) {
                $sectionBody = $sectionMatch.Groups[1].Value
                $pipelineEntries = [regex]::Matches($sectionBody, '(?m)^####\s+(.+)$')
                if ($pipelineEntries.Count -gt 0) {
                    Write-Host "`n--- $($sec.Header) Pipelines ($($pipelineEntries.Count)) ---" -ForegroundColor $sec.Color
                    Write-Host ("{0,-8} {1,-45} {2,-15} {3}" -f "ID", "Name", "Type", "Migrate With") -ForegroundColor White
                    Write-Host ("-" * 90)
                    foreach ($pm in $pipelineEntries) {
                        $fullPath = $pm.Groups[1].Value.Trim()
                        $pipeName = ($fullPath -split '/')[-1]

                        # Try direct name match first (case-sensitive)
                        $pipelineIdVal = $nameToId[$pipeName]
                        $pipeTypeVal = $nameToType[$pipeName]

                        # Fallback: case-insensitive match
                        if (-not $pipelineIdVal) {
                            $ciMatch = $nameToId.Keys | Where-Object { $_ -ieq $pipeName } | Select-Object -First 1
                            if ($ciMatch) {
                                $pipelineIdVal = $nameToId[$ciMatch]
                                $pipeTypeVal = $nameToType[$ciMatch]
                                $pipeName = $ciMatch
                            }
                        }

                        # Fallback: extract ID from _(ID) suffix
                        if (-not $pipelineIdVal -and $pipeName -match '_\((\d+)\)$') {
                            $extractedId = $matches[1]
                            $pipelineIdVal = [int]$extractedId
                            $pipeName = $idToName[$extractedId]
                            if (-not $pipeName) { $pipeName = ($fullPath -split '/')[-1] -replace '_\(\d+\)$', '' }
                            $pipeTypeVal = $idToType[$extractedId]
                        }

                        # Fallback: slug match (lowercase, special chars normalized)
                        if (-not $pipelineIdVal) {
                            $auditSlug = ($pipeName.ToLower() -replace '[^a-z0-9\-]', '-') -replace '-+', '-' -replace '^-|-$', ''
                            # Also try without _(ID) suffix
                            $auditSlugClean = ($auditSlug -replace '-+\d+$', '')
                            $matchSlug = $auditSlug
                            if ($slugToId.ContainsKey($auditSlug)) { $matchSlug = $auditSlug }
                            elseif ($slugToId.ContainsKey($auditSlugClean)) { $matchSlug = $auditSlugClean }
                            if ($slugToId.ContainsKey($matchSlug)) {
                                $pipelineIdVal = $slugToId[$matchSlug]
                                $pipeTypeVal = $slugToType[$matchSlug]
                                $pipeName = $idToName["$pipelineIdVal"]
                                if (-not $pipeName) { $pipeName = ($fullPath -split '/')[-1] }
                            }
                        }

                        if (-not $pipeTypeVal) { $pipeTypeVal = "Unknown" }
                        $migrateWith = if ($pipeTypeVal -eq "Release") { "-PipelineType release" } else { "-PipelineType build" }
                        if ($pipelineIdVal) {
                            Write-Host ("{0,-8} {1,-45} {2,-15} {3}" -f $pipelineIdVal, $pipeName, $pipeTypeVal, $migrateWith) -ForegroundColor $sec.Color
                        } else {
                            Write-Host ("{0,-8} {1,-45} {2,-15} {3}" -f "?", $pipeName, $pipeTypeVal, "") -ForegroundColor $sec.Color
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

    # Ensure actions-importer Docker image is available (audit needs it too)
    Write-Host "Ensuring actions-importer image is up to date..." -ForegroundColor Yellow
    gh actions-importer update 2>&1 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  WARNING: Could not update actions-importer image." -ForegroundColor Yellow
    }

    $auditArgs = @(
        "actions-importer", "audit", "azure-devops",
        "--output-dir", $OutputDir,
        "--azure-devops-organization", $adoOrgName,
        "--azure-devops-project", $AdoProject
    )
    gh @auditArgs 2>&1 | ForEach-Object { Write-Host "  $_" }
    $auditExit = $LASTEXITCODE
    Write-Host "Audit complete (exit $auditExit). Check: $OutputDir/audit_summary.md" -ForegroundColor Green

    # --- Surface generated config.yml (lists reusable workflows + composite actions) ---
    $generatedConfig = Join-Path $OutputDir "config.yml"
    if (Test-Path $generatedConfig) {
        Write-Host "`n=== Reusable Workflows / Composite Actions Discovered ===" -ForegroundColor Cyan
        Write-Host "GEI generated a config file describing every reusable workflow and composite" -ForegroundColor Gray
        Write-Host "action it converted from your ADO templates:" -ForegroundColor Gray
        Write-Host "  $generatedConfig" -ForegroundColor Yellow
        Write-Host "`n--- config.yml contents ---" -ForegroundColor DarkGray
        Get-Content $generatedConfig | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
        Write-Host "--- end ---" -ForegroundColor DarkGray

        Write-Host "`nNEXT STEPS to migrate the reusable templates:" -ForegroundColor Yellow
        Write-Host "  Option A (central repo - recommended for ADO 'templates repo' pattern):" -ForegroundColor Gray
        Write-Host "    .\migrate-pipelines.ps1 -Mode migrate-reusables ``" -ForegroundColor Green
        Write-Host "        -ConfigFilePath '$generatedConfig' ``" -ForegroundColor Green
        Write-Host "        -AdoProject '$AdoProject' ``" -ForegroundColor Green
        Write-Host "        -ReusablesTargetRepo '$ghOrg/reusable-workflows' -ReusablesRef main" -ForegroundColor Green
        Write-Host "  Option B (manual): edit '$generatedConfig' and set target_url per entry, then:" -ForegroundColor Gray
        Write-Host "    .\migrate-pipelines.ps1 -Mode migrate-reusables -ConfigFilePath '$generatedConfig' -AdoProject '$AdoProject'" -ForegroundColor Green
    } else {
        Write-Host "`nNote: no config.yml was produced (no reusable templates detected)." -ForegroundColor Yellow
    }
    # Audit is informational only — never fail the job from this branch.
    exit 0
}

# ---------------------------------------------------------------------------
# migrate-reusables: open PRs for every reusable workflow / composite action
# listed in the GEI-produced config.yml (--config-file-path flow).
# ---------------------------------------------------------------------------
if ($Mode -eq "migrate-reusables") {
    if (-not $ConfigFilePath -or -not (Test-Path $ConfigFilePath)) {
        Write-Host "ERROR: -ConfigFilePath is required and must point to the config.yml" -ForegroundColor Red
        Write-Host "       produced by 'audit' (e.g. ./output/pipelines/config.yml)." -ForegroundColor Red
        exit 1
    }

    Write-Host "`n=== Migrating Reusable Workflows / Composite Actions ===" -ForegroundColor Cyan
    Write-Host "  Config file: $ConfigFilePath" -ForegroundColor Gray

    # -----------------------------------------------------------------------
    # Optional: rewrite every target_url in config.yml to a single central
    # GitHub repo. This implements the ADO "central templates repo" pattern:
    # all reusable workflows + composite actions land in one shared repo.
    # -----------------------------------------------------------------------
    if ($ReusablesTargetRepo) {
        $centralUrl = if ($ReusablesTargetRepo -match '^https?://') {
            $ReusablesTargetRepo.TrimEnd('/')
        } elseif ($ReusablesTargetRepo -match '/') {
            "https://github.com/$ReusablesTargetRepo"
        } else {
            "https://github.com/$ghOrg/$ReusablesTargetRepo"
        }

        Write-Host "  Centralizing all reusables -> $centralUrl (ref: $ReusablesRef)" -ForegroundColor Yellow

        # Back up original then rewrite in place
        $backup = "$ConfigFilePath.bak"
        Copy-Item $ConfigFilePath $backup -Force
        Write-Host "  Backup saved: $backup" -ForegroundColor DarkGray

        # Walk every line: rewrite existing target_url/ref, and INJECT target_url
        # right after each "- name:" entry when it's missing (GEI sometimes emits
        # config.yml with only name + ref).
        $rewritten = New-Object System.Collections.Generic.List[string]
        $lines = Get-Content $ConfigFilePath
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]

            if ($line -match '^(\s*)target_url:\s*\S+') {
                $rewritten.Add("$($matches[1])target_url: $centralUrl")
                continue
            }
            if ($line -match '^(\s*)ref:\s*\S+') {
                $rewritten.Add("$($matches[1])ref: $ReusablesRef")
                continue
            }

            # Match "- name: foo.yml" (entry start). Add the line, then ensure
            # the next non-name lines for this entry contain target_url.
            if ($line -match '^(\s*)-\s*name:\s*\S+') {
                $entryIndent = $matches[1]
                $propIndent  = "$entryIndent  "   # YAML list-item property indent
                $rewritten.Add($line)

                # Look ahead within this entry block to see if target_url already exists.
                $hasTarget = $false
                for ($j = $i + 1; $j -lt $lines.Count; $j++) {
                    $look = $lines[$j]
                    if ($look -match '^\s*-\s*name:') { break }                 # next entry
                    if ($look -match '^\S' -or $look -match '^[A-Za-z_]+:') { break }  # new top-level key
                    if ($look -match '^\s*target_url:') { $hasTarget = $true; break }
                }
                if (-not $hasTarget) {
                    $rewritten.Add("${propIndent}target_url: $centralUrl")
                }
                continue
            }

            $rewritten.Add($line)
        }
        Set-Content -Path $ConfigFilePath -Value $rewritten -Encoding utf8

        $reusableCount = (Select-String -Path $ConfigFilePath -Pattern '^\s*-\s*name:').Count
        Write-Host "  Normalized $reusableCount reusable entries (target_url + ref) -> central repo." -ForegroundColor Green
        $reusableTargetUrl = $centralUrl
    } else {
        # Determine a default --target-url (required by GEI even when config drives routing).
        $reusableTargetUrl = $null
        if ($defaultTargetRepo) {
            $reusableTargetUrl = "https://github.com/$ghOrg/$defaultTargetRepo"
        } else {
            $firstTarget = (Select-String -Path $ConfigFilePath -Pattern 'target_url:\s*(\S+)' | Select-Object -First 1)
            if ($firstTarget) {
                $reusableTargetUrl = ($firstTarget.Matches[0].Groups[1].Value).Trim()
            }
        }
        if (-not $reusableTargetUrl) {
            Write-Host "ERROR: No target URL available. Pass -ReusablesTargetRepo, set GH_REPO env var, or add 'target_url' entries in config.yml." -ForegroundColor Red
            exit 1
        }
    }
    Write-Host "  Default target-url: $reusableTargetUrl" -ForegroundColor Gray

    $reusableArgs = @(
        "actions-importer", "migrate", "azure-devops", "pipeline",
        "--output-dir", (Join-Path $OutputDir "reusables"),
        "--azure-devops-organization", $adoOrgName,
        "--azure-devops-project", $AdoProject,
        "--config-file-path", $ConfigFilePath,
        "--target-url", $reusableTargetUrl
    )
    if ($CustomTransformersDir -and (Test-Path $CustomTransformersDir)) {
        $reusableArgs += "--custom-transformers"
        $reusableArgs += $CustomTransformersDir
    }

    Write-Host "  Command: gh $($reusableArgs -join ' ')" -ForegroundColor DarkGray
    gh @reusableArgs 2>&1 | ForEach-Object { Write-Host "    $_" }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Reusable migration FAILED (exit $LASTEXITCODE)" -ForegroundColor Red
        exit $LASTEXITCODE
    }

    Write-Host "`nReusable workflow / composite action PRs opened per target_url in config.yml." -ForegroundColor Green
    Write-Host "Next:" -ForegroundColor Yellow
    Write-Host "  1. Review and merge the PR(s) in the shared repo." -ForegroundColor Gray
    Write-Host "  2. (Private repo) Settings -> Actions -> General -> Access ->" -ForegroundColor Gray
    Write-Host "     'Accessible from repositories owned by <org>' so consumers can call them." -ForegroundColor Gray
    Write-Host "  3. Re-run consuming pipelines with the SAME --config-file-path so generated" -ForegroundColor Gray
    Write-Host "     workflows emit 'uses: <repo>/.github/workflows/<x>.yml@$ReusablesRef'." -ForegroundColor Gray
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

if ($PipelineType -eq "release") {
    $pipelinesUrl = "https://vsrm.dev.azure.com/$adoOrgName/$AdoProject/_apis/release/definitions?api-version=7.1"
    Write-Host "  Fetching release pipelines..." -ForegroundColor Yellow
} else {
    $pipelinesUrl = "$adoOrgUrl/$AdoProject/_apis/build/definitions?api-version=7.1&includeAllProperties=true"
    Write-Host "  Fetching build pipelines..." -ForegroundColor Yellow
}
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

    # Determine target repo: PIPELINE_REPO_MAP > GH_REPO > ADO repo name
    $targetRepo = $null
    if ($pipelineRepoMap.ContainsKey("$currentId")) {
        $targetRepo = $pipelineRepoMap["$currentId"]
    } elseif ($defaultTargetRepo) {
        $targetRepo = $defaultTargetRepo
    } elseif ($pipeline.repository) {
        $targetRepo = ($pipeline.repository.name).ToLower() -replace " ", "-"
    } else {
        $targetRepo = $AdoProject.ToLower() -replace " ", "-"
    }
    Write-Host "    Target repo: $ghOrg/$targetRepo" -ForegroundColor Gray


    # Use different output directories for dry-run and migrate
    if ($Mode -eq "dry-run") {
        $outputSubDir = Join-Path $OutputDir "dry-run/$pipelineName"
    } elseif ($Mode -eq "migrate") {
        $outputSubDir = Join-Path $OutputDir "migrate/$pipelineName"
    } else {
        $outputSubDir = Join-Path $OutputDir $pipelineName
    }
    if (-not (Test-Path $outputSubDir)) { New-Item -ItemType Directory -Path $outputSubDir -Force | Out-Null }

    $importerSubCommand = if ($PipelineType -eq "release") { "release" } else { "pipeline" }

    $importerArgs = @(
        "actions-importer", $Mode, "azure-devops", $importerSubCommand,
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

    # Add support for --config-file-path if provided
    if ($ConfigFilePath -and (Test-Path $ConfigFilePath)) {
        $importerArgs += "--config-file-path"
        $importerArgs += $ConfigFilePath
    } elseif ($ImporterConfigFile -and (Test-Path $ImporterConfigFile)) {
        # Backward compatibility for ImporterConfigFile
        $importerArgs += "--config-file-path"
        $importerArgs += $ImporterConfigFile
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

# ===========================================================================
# HTML Migration Dashboard
# ===========================================================================
Add-Type -AssemblyName System.Web

$dashboardDir = Join-Path $OutputDir "dashboard"
if (-not (Test-Path $dashboardDir)) { New-Item -ItemType Directory -Path $dashboardDir -Force | Out-Null }

$scanDate    = Get-Date -Format "yyyy-MM-dd HH:mm:ss UTC"
$encOrg      = [System.Web.HttpUtility]::HtmlEncode($adoOrgName)
$encProj     = [System.Web.HttpUtility]::HtmlEncode($AdoProject)
$encGhOrg    = [System.Web.HttpUtility]::HtmlEncode($ghOrg)
$totalCount  = $results.Count
$noOutputCount = ($results | Where-Object { $_.Status -eq "NO_OUTPUT" }).Count

# Percentages
$safeDivisor = [Math]::Max($totalCount, 1)
$pctSuccess  = [math]::Round(($successCount  / $safeDivisor) * 100)
$pctPartial  = [math]::Round(($partialCount  / $safeDivisor) * 100)
$pctFailed   = [math]::Round(($failedCount   / $safeDivisor) * 100)
$pctNoOutput = [math]::Round(($noOutputCount / $safeDivisor) * 100)
$pctMigrated = $pctSuccess + $pctPartial

# Donut segments
$seg1 = $pctSuccess
$seg2 = $seg1 + $pctPartial
$seg3 = $seg2 + $pctFailed

# Pipeline detail table rows
$pipelineTableRows = ""
foreach ($r in $results | Sort-Object Status, Pipeline) {
    $encName = [System.Web.HttpUtility]::HtmlEncode($r.Pipeline)
    $encRepo = [System.Web.HttpUtility]::HtmlEncode($r.TargetRepo)
    $statusBadge = switch ($r.Status) {
        "SUCCESS"   { "<span class='badge-ok'>&#9989; Success</span>" }
        "PARTIAL"   { "<span class='badge-warn'>&#9888;&#65039; Partial</span>" }
        "NO_OUTPUT" { "<span class='badge-warn'>&#128196; No Output</span>" }
        "FAILED"    { "<span class='badge-fail'>&#10060; Failed</span>" }
        "ERROR"     { "<span class='badge-fail'>&#128683; Error</span>" }
        default     { "<span class='badge-fail'>$($r.Status)</span>" }
    }
    $ghRepoUrl = "https://github.com/$ghOrg/$($r.TargetRepo)"
    $pipelineTableRows += "    <tr><td>$($r.Id)</td><td>$encName</td><td><a href='$ghRepoUrl' target='_blank'>$encRepo</a></td><td class='center'>$($r.Mode)</td><td class='center'>$statusBadge</td></tr>`n"
}

# Generated workflow files
$workflowRows = ""
$yamlFiles = Get-ChildItem -Path $OutputDir -Recurse -Include "*.yml","*.yaml" -ErrorAction SilentlyContinue
foreach ($yf in $yamlFiles) {
    $relPath = $yf.FullName.Replace($OutputDir,"").TrimStart("\").TrimStart("/")
    $name = [System.Web.HttpUtility]::HtmlEncode($yf.BaseName)
    $dir  = [System.Web.HttpUtility]::HtmlEncode((Split-Path $relPath -Parent))
    $size = "{0:N1} KB" -f ($yf.Length / 1KB)
    $workflowRows += "    <tr><td>$dir</td><td>$name</td><td class='num'>$size</td></tr>`n"
}

$workflowSection = if ($workflowRows) {
    @"
      <table>
        <thead><tr><th>Directory</th><th>Workflow</th><th>Size</th></tr></thead>
        <tbody>
$workflowRows
        </tbody>
      </table>
"@
} else { "      <p class='empty-state'><span class='empty-icon'>&#128194;</span>No workflow YAML files generated.</p>" }

# Breakdown rows
$breakdownRows = @"
        <tr><td><span class='dot' style='background:#10b981'></span> Successful</td>
            <td class='num'>$successCount</td>
            <td><div class='mini-bar'><div class='mini-fill' style='width:${pctSuccess}%;background:#10b981'></div></div></td>
            <td class='num'>${pctSuccess}%</td></tr>
        <tr><td><span class='dot' style='background:#f59e0b'></span> Partial</td>
            <td class='num'>$partialCount</td>
            <td><div class='mini-bar'><div class='mini-fill' style='width:${pctPartial}%;background:#f59e0b'></div></div></td>
            <td class='num'>${pctPartial}%</td></tr>
        <tr><td><span class='dot' style='background:#ef4444'></span> Failed / Error</td>
            <td class='num'>$failedCount</td>
            <td><div class='mini-bar'><div class='mini-fill' style='width:${pctFailed}%;background:#ef4444'></div></div></td>
            <td class='num'>${pctFailed}%</td></tr>
        <tr><td><span class='dot' style='background:#6b7280'></span> No Output</td>
            <td class='num'>$noOutputCount</td>
            <td><div class='mini-bar'><div class='mini-fill' style='width:${pctNoOutput}%;background:#6b7280'></div></div></td>
            <td class='num'>${pctNoOutput}%</td></tr>
"@

$migrationHtml = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Pipeline Migration Report &mdash; $encOrg</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap');
  :root {
    --green: #10b981; --yellow: #f59e0b; --red: #ef4444; --gray: #6b7280;
    --bg: #0f172a; --surface: #1e293b; --surface2: #334155;
    --text: #f1f5f9; --text2: #94a3b8; --accent: #38bdf8; --accent2: #818cf8;
    --border: rgba(148,163,184,.15); --radius: 16px;
  }
  * { margin:0; padding:0; box-sizing:border-box; }
  body { font-family:'Inter',system-ui,sans-serif; background:var(--bg); color:var(--text); min-height:100vh; }

  .header { background: linear-gradient(135deg, #10b981 0%, #0ea5e9 50%, #8b5cf6 100%);
    padding: 40px 48px 32px; position: relative; overflow: hidden; }
  .header::before { content:''; position:absolute; top:-50%; right:-20%; width:600px; height:600px;
    background: radial-gradient(circle, rgba(255,255,255,.08) 0%, transparent 70%); }
  .header h1 { font-size:2.2rem; font-weight:800; letter-spacing:-.02em; position:relative; z-index:1; }
  .header h1 .icon { font-size:1.6rem; margin-right:10px; }
  .header .meta { margin-top:8px; font-size:.9rem; opacity:.85; position:relative; z-index:1; }
  .header .meta span { margin-right:24px; }
  .header .badge { display:inline-block; background:rgba(255,255,255,.2); backdrop-filter:blur(8px);
    padding:4px 14px; border-radius:20px; font-size:.8rem; font-weight:600; margin-top:12px; position:relative; z-index:1; }

  .container { max-width:1440px; margin:0 auto; padding: 0 32px 40px; }

  .kpi-row { display:grid; grid-template-columns:repeat(5,1fr); gap:16px; margin: -40px 0 32px; position:relative; z-index:2; }
  .kpi { background:var(--surface); border:1px solid var(--border); border-radius:var(--radius); padding:24px 20px;
    text-align:center; transition: transform .2s, box-shadow .2s; }
  .kpi:hover { transform:translateY(-4px); box-shadow: 0 12px 40px rgba(0,0,0,.3); }
  .kpi .kpi-icon { font-size:1.6rem; margin-bottom:8px; }
  .kpi .kpi-val { font-size:2.4rem; font-weight:800; font-variant-numeric:tabular-nums; }
  .kpi .kpi-label { font-size:.78rem; color:var(--text2); margin-top:4px; text-transform:uppercase; letter-spacing:.06em; }
  .kpi.total .kpi-val { color:var(--accent); }
  .kpi.success .kpi-val { color:var(--green); }
  .kpi.partial .kpi-val { color:var(--yellow); }
  .kpi.failed .kpi-val { color:var(--red); }
  .kpi.nooutput .kpi-val { color:var(--gray); }

  .panel { background:var(--surface); border:1px solid var(--border); border-radius:var(--radius);
    padding:28px; margin-bottom:20px; }
  .panel h2 { font-size:1.15rem; font-weight:700; margin-bottom:20px; display:flex; align-items:center; gap:10px; }
  .panel h2 .sec-icon { font-size:1.2rem; }

  .chart-grid { display:grid; grid-template-columns: 280px 1fr; gap:32px; align-items:center; }
  @media (max-width:768px) { .chart-grid { grid-template-columns:1fr; } }
  .donut-wrap { position:relative; width:220px; height:220px; margin:0 auto; }
  .donut { width:220px; height:220px; border-radius:50%;
    background: conic-gradient(
      var(--green) 0% ${seg1}%,
      var(--yellow) ${seg1}% ${seg2}%,
      var(--red) ${seg2}% ${seg3}%,
      var(--gray) ${seg3}% 100%
    );
    -webkit-mask: radial-gradient(circle, transparent 60%, black 61%);
            mask: radial-gradient(circle, transparent 60%, black 61%);
  }
  .donut-center { position:absolute; top:50%; left:50%; transform:translate(-50%,-50%); text-align:center; }
  .donut-center .big { font-size:2.6rem; font-weight:800; color:var(--accent); }
  .donut-center .sub { font-size:.8rem; color:var(--text2); }

  .breakdown { width:100%; border-collapse:collapse; }
  .breakdown td { padding:12px 10px; border-bottom:1px solid var(--border); font-size:.9rem; }
  .breakdown tr:last-child td { border-bottom:none; }
  .dot { display:inline-block; width:10px; height:10px; border-radius:50%; margin-right:8px; vertical-align:middle; }
  .num { text-align:right; font-variant-numeric:tabular-nums; font-weight:600; }
  .mini-bar { width:100%; height:8px; background:var(--surface2); border-radius:4px; overflow:hidden; }
  .mini-fill { height:100%; border-radius:4px; transition: width .8s ease; }

  .stacked-bar { display:flex; height:14px; border-radius:7px; overflow:hidden; margin-top:16px; }
  .stacked-bar .seg { transition: width .8s ease; }

  table:not(.breakdown) { width:100%; border-collapse:collapse; }
  table:not(.breakdown) th { background: linear-gradient(135deg,#10b981,#0ea5e9); color:#fff;
    padding:14px 12px; text-align:left; font-size:.8rem; text-transform:uppercase; letter-spacing:.06em; font-weight:600; }
  table:not(.breakdown) td { padding:12px; border-bottom:1px solid var(--border); font-size:.85rem; }
  table:not(.breakdown) tr:hover { background:rgba(56,189,248,.06); }
  .center { text-align:center; }
  a { color:var(--accent); text-decoration:none; }
  a:hover { text-decoration:underline; }

  .badge-ok { background:rgba(16,185,129,.15); color:var(--green); padding:3px 12px; border-radius:12px; font-size:.78rem; font-weight:600; }
  .badge-warn { background:rgba(245,158,11,.15); color:var(--yellow); padding:3px 12px; border-radius:12px; font-size:.78rem; font-weight:600; }
  .badge-fail { background:rgba(239,68,68,.15); color:var(--red); padding:3px 12px; border-radius:12px; font-size:.78rem; font-weight:600; }

  .checklist-item { display:flex; align-items:flex-start; gap:10px; padding:8px 0; font-size:.88rem; cursor:pointer; }
  .checklist-item input[type=checkbox] { accent-color:var(--accent); margin-top:3px; width:16px; height:16px; }
  .checklist-item span { flex:1; }

  .empty-state { text-align:center; padding:32px; color:var(--text2); }
  .empty-icon { font-size:2rem; display:block; margin-bottom:8px; }

  .footer { text-align:center; color:var(--text2); font-size:.78rem; margin-top:32px; padding:20px;
    border-top:1px solid var(--border); }

  @keyframes fadeUp { from { opacity:0; transform:translateY(20px); } to { opacity:1; transform:translateY(0); } }
  .kpi, .panel { animation: fadeUp .5s ease both; }
  .kpi:nth-child(2) { animation-delay:.05s; }
  .kpi:nth-child(3) { animation-delay:.1s; }
  .kpi:nth-child(4) { animation-delay:.15s; }
  .kpi:nth-child(5) { animation-delay:.2s; }
  .panel:nth-of-type(1) { animation-delay:.25s; }
  .panel:nth-of-type(2) { animation-delay:.3s; }
  .panel:nth-of-type(3) { animation-delay:.35s; }
</style>
</head>
<body>

<div class="header">
  <h1><span class="icon">&#128640;</span>Pipeline Migration Report</h1>
  <div class="meta">
    <span>&#127970; ADO: <strong>$encOrg / $encProj</strong></span>
    <span>&#128049; GitHub: <strong>$encGhOrg</strong></span>
    <span>&#128197; $scanDate</span>
  </div>
  <div class="badge">&#9989; Migration Rate: ${pctMigrated}% ($($successCount + $partialCount) of $totalCount pipelines)</div>
</div>

<div class="container">

  <div class="kpi-row">
    <div class="kpi total">
      <div class="kpi-icon">&#128202;</div>
      <div class="kpi-val">$totalCount</div>
      <div class="kpi-label">Total Pipelines</div>
    </div>
    <div class="kpi success">
      <div class="kpi-icon">&#9989;</div>
      <div class="kpi-val">$successCount</div>
      <div class="kpi-label">Successful</div>
    </div>
    <div class="kpi partial">
      <div class="kpi-icon">&#9888;&#65039;</div>
      <div class="kpi-val">$partialCount</div>
      <div class="kpi-label">Partial</div>
    </div>
    <div class="kpi failed">
      <div class="kpi-icon">&#10060;</div>
      <div class="kpi-val">$failedCount</div>
      <div class="kpi-label">Failed / Error</div>
    </div>
    <div class="kpi nooutput">
      <div class="kpi-icon">&#128196;</div>
      <div class="kpi-val">$noOutputCount</div>
      <div class="kpi-label">No Output</div>
    </div>
  </div>

  <div class="panel">
    <h2><span class="sec-icon">&#127760;</span>Migration Breakdown</h2>
    <div class="chart-grid">
      <div class="donut-wrap">
        <div class="donut"></div>
        <div class="donut-center">
          <div class="big">${pctMigrated}%</div>
          <div class="sub">Migrated</div>
        </div>
      </div>
      <div>
        <table class="breakdown">
$breakdownRows
        </table>
        <div class="stacked-bar">
          <div class="seg" style="width:${pctSuccess}%;background:var(--green)"></div>
          <div class="seg" style="width:${pctPartial}%;background:var(--yellow)"></div>
          <div class="seg" style="width:${pctFailed}%;background:var(--red)"></div>
          <div class="seg" style="width:${pctNoOutput}%;background:var(--gray)"></div>
        </div>
      </div>
    </div>
  </div>

  <div class="panel">
    <h2><span class="sec-icon">&#128736;</span>Pipeline Details</h2>
    <table>
      <thead><tr><th>ID</th><th>Pipeline</th><th>Target Repo</th><th>Mode</th><th>Status</th></tr></thead>
      <tbody>
$pipelineTableRows
      </tbody>
    </table>
  </div>

  <div class="panel">
    <h2><span class="sec-icon">&#128196;</span>Generated Workflow Files</h2>
$workflowSection
  </div>

  <div class="panel">
    <h2><span class="sec-icon">&#9997;&#65039;</span>Post-Migration Checklist</h2>
    <label class="checklist-item"><input type="checkbox"/><span>Review generated GitHub Actions YAML for correctness</span></label>
    <label class="checklist-item"><input type="checkbox"/><span>Create GitHub Actions secrets: Settings &gt; Secrets &gt; Actions</span></label>
    <label class="checklist-item"><input type="checkbox"/><span>Configure environments with protection rules (replaces ADO gates)</span></label>
    <label class="checklist-item"><input type="checkbox"/><span>Set up self-hosted runners if needed</span></label>
    <label class="checklist-item"><input type="checkbox"/><span>Configure OIDC for Azure deployments (replaces service connections)</span></label>
    <label class="checklist-item"><input type="checkbox"/><span>Test trigger each workflow in GitHub Actions</span></label>
    <label class="checklist-item"><input type="checkbox"/><span>Disable original ADO pipelines after verification</span></label>
    <label class="checklist-item"><input type="checkbox"/><span>Update branch policies and PR triggers</span></label>
  </div>

  <div class="footer">
    Generated by <strong>ADO-to-GitHub Migration Accelerator</strong> &mdash; Pipeline Migration Module &bull; $scanDate
  </div>
</div>

</body>
</html>
"@

$htmlOut = Join-Path $dashboardDir "index.html"
$migrationHtml | Out-File -FilePath $htmlOut -Encoding utf8
Write-Host "`nMigration dashboard: $htmlOut" -ForegroundColor Green

Remove-Item Env:\GITHUB_ACCESS_TOKEN -ErrorAction SilentlyContinue
Remove-Item Env:\AZURE_DEVOPS_ACCESS_TOKEN -ErrorAction SilentlyContinue

exit 0
