<#
.SYNOPSIS
    Inventories all Azure DevOps assets (projects, repos, pipelines, teams, work items, service connections, etc.)
.DESCRIPTION
    Connects to ADO REST API and produces a JSON inventory report for migration planning.
.PARAMETER OrgUrl
    Azure DevOps organization URL (e.g., https://dev.azure.com/myorg)
.PARAMETER Pat
    Personal Access Token with full scope or at minimum: Code(Read), Build(Read), Release(Read), Work Items(Read), Project(Read)
.PARAMETER OutputDir
    Directory for output files. Defaults to ./output/inventory
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OrgUrl,

    [Parameter(Mandatory = $true)]
    [string]$Pat,

    [string]$OutputDir = "./output/inventory"
)

$ErrorActionPreference = "Stop"

# --- Auth Header ---
$base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))
$headers = @{ Authorization = "Basic $base64Auth" }

function Invoke-AdoApi {
    param([string]$Uri, [string]$ApiVersion = "7.1")
    $separator = if ($Uri.Contains("?")) { "&" } else { "?" }
    $fullUri = "$Uri${separator}api-version=$ApiVersion"
    try {
        $response = Invoke-RestMethod -Uri $fullUri -Headers $headers -Method Get -ContentType "application/json"
        return $response
    }
    catch {
        Write-Warning "API call failed: $fullUri — $_"
        return $null
    }
}

# --- Setup ---
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

$orgName = ($OrgUrl -replace "https://dev.azure.com/", "").TrimEnd("/")
Write-Host "=== ADO Inventory: $orgName ===" -ForegroundColor Cyan

$inventory = @{
    organization    = $orgName
    scanDate        = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    projects        = @()
    totalRepos      = 0
    totalPipelines  = 0
    totalWorkItems  = 0
    totalTeams      = 0
}

# --- List Projects ---
$projectsResp = Invoke-AdoApi "$OrgUrl/_apis/projects"
if (-not $projectsResp) { Write-Error "Failed to list projects. Check PAT and org URL."; exit 1 }

Write-Host "Found $($projectsResp.count) projects" -ForegroundColor Green

foreach ($project in $projectsResp.value) {
    $projName = $project.name
    Write-Host "  Scanning project: $projName" -ForegroundColor Yellow

    $projData = @{
        name             = $projName
        id               = $project.id
        state            = $project.state
        visibility       = $project.visibility
        repos            = @()
        pipelines        = @()
        releaseDefinitions = @()
        teams            = @()
        workItemCount    = 0
        serviceConnections = @()
        variableGroups   = @()
        environments     = @()
    }

    # --- Repos ---
    $reposResp = Invoke-AdoApi "$OrgUrl/$projName/_apis/git/repositories"
    if ($reposResp) {
        foreach ($repo in $reposResp.value) {
            $repoData = @{
                name      = $repo.name
                id        = $repo.id
                sizeBytes = $repo.size
                sizeMB    = [math]::Round($repo.size / 1MB, 2)
                sizeGB    = [math]::Round($repo.size / 1GB, 4)
                defaultBranch = $repo.defaultBranch
                isDisabled = $repo.isDisabled
                url       = $repo.webUrl
            }
            $projData.repos += $repoData
        }
        $inventory.totalRepos += $reposResp.count
        Write-Host "    Repos: $($reposResp.count)" -ForegroundColor Gray
    }

    # --- Build Pipelines ---
    $pipelinesResp = Invoke-AdoApi "$OrgUrl/$projName/_apis/build/definitions"
    if ($pipelinesResp) {
        foreach ($pipeline in $pipelinesResp.value) {
            $pipelineData = @{
                name           = $pipeline.name
                id             = $pipeline.id
                type           = $pipeline.type
                queueStatus    = $pipeline.queueStatus
                path           = $pipeline.path
                createdDate    = $pipeline.createdDate
                url            = $pipeline.url
                processType    = if ($pipeline.process) { $pipeline.process.type } else { "unknown" }
            }
            $projData.pipelines += $pipelineData
        }
        $inventory.totalPipelines += $pipelinesResp.count
        Write-Host "    Build Pipelines: $($pipelinesResp.count)" -ForegroundColor Gray
    }

    # --- Release Definitions (Classic) ---
    $vsrmUrl = $OrgUrl -replace "dev.azure.com", "vsrm.dev.azure.com"
    $releasesResp = Invoke-AdoApi "$vsrmUrl/$projName/_apis/release/definitions"
    if ($releasesResp) {
        foreach ($rd in $releasesResp.value) {
            $projData.releaseDefinitions += @{
                name = $rd.name
                id   = $rd.id
                path = $rd.path
                environmentCount = if ($rd.environments) { $rd.environments.Count } else { 0 }
            }
        }
        Write-Host "    Release Definitions: $($releasesResp.count)" -ForegroundColor Gray
    }

    # --- Teams ---
    $teamsResp = Invoke-AdoApi "$OrgUrl/_apis/projects/$($project.id)/teams"
    if ($teamsResp) {
        foreach ($team in $teamsResp.value) {
            $membersResp = Invoke-AdoApi "$OrgUrl/_apis/projects/$($project.id)/teams/$($team.id)/members"
            $memberCount = if ($membersResp) { $membersResp.count } else { 0 }
            $projData.teams += @{
                name        = $team.name
                id          = $team.id
                description = $team.description
                memberCount = $memberCount
            }
        }
        $inventory.totalTeams += $teamsResp.count
        Write-Host "    Teams: $($teamsResp.count)" -ForegroundColor Gray
    }

    # --- Work Item Count (via WIQL) ---
    $wiqlBody = @{
        query = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = '$projName'"
    } | ConvertTo-Json
    try {
        $wiqlUri = "$OrgUrl/$projName/_apis/wit/wiql?api-version=7.1"
        $wiqlResp = Invoke-RestMethod -Uri $wiqlUri -Headers $headers -Method Post -Body $wiqlBody -ContentType "application/json"
        $projData.workItemCount = $wiqlResp.workItems.Count
        $inventory.totalWorkItems += $wiqlResp.workItems.Count
        Write-Host "    Work Items: $($wiqlResp.workItems.Count)" -ForegroundColor Gray
    }
    catch {
        Write-Warning "    Failed to query work items for $projName"
    }

    # --- Service Connections ---
    $scResp = Invoke-AdoApi "$OrgUrl/$projName/_apis/serviceendpoint/endpoints"
    if ($scResp) {
        foreach ($sc in $scResp.value) {
            $projData.serviceConnections += @{
                name = $sc.name
                type = $sc.type
                id   = $sc.id
            }
        }
        Write-Host "    Service Connections: $($scResp.count)" -ForegroundColor Gray
    }

    # --- Variable Groups ---
    $vgResp = Invoke-AdoApi "$OrgUrl/$projName/_apis/distributedtask/variablegroups"
    if ($vgResp) {
        foreach ($vg in $vgResp.value) {
            $projData.variableGroups += @{
                name         = $vg.name
                id           = $vg.id
                variableCount = ($vg.variables.PSObject.Properties | Measure-Object).Count
                type         = $vg.type
            }
        }
        Write-Host "    Variable Groups: $($vgResp.count)" -ForegroundColor Gray
    }

    # --- Environments ---
    $envResp = Invoke-AdoApi "$OrgUrl/$projName/_apis/distributedtask/environments"
    if ($envResp) {
        foreach ($env in $envResp.value) {
            $projData.environments += @{
                name = $env.name
                id   = $env.id
            }
        }
        Write-Host "    Environments: $($envResp.count)" -ForegroundColor Gray
    }

    $inventory.projects += $projData
}

# --- Summary ---
Write-Host "`n=== Inventory Summary ===" -ForegroundColor Cyan
Write-Host "Projects:    $($inventory.projects.Count)"
Write-Host "Repos:       $($inventory.totalRepos)"
Write-Host "Pipelines:   $($inventory.totalPipelines)"
Write-Host "Work Items:  $($inventory.totalWorkItems)"
Write-Host "Teams:       $($inventory.totalTeams)"

# --- Large Repo Warnings ---
$largeRepos = $inventory.projects | ForEach-Object { $_.repos } | Where-Object { $_.sizeGB -gt 1 }
if ($largeRepos) {
    Write-Host "`n=== WARNING: Large Repos (>1 GB) ===" -ForegroundColor Red
    $largeRepos | ForEach-Object { Write-Host "  $($_.name): $($_.sizeGB) GB" -ForegroundColor Red }
}

$oversizedRepos = $inventory.projects | ForEach-Object { $_.repos } | Where-Object { $_.sizeGB -gt 40 }
if ($oversizedRepos) {
    Write-Host "`n=== BLOCKER: Repos > 40 GB (GEI limit) ===" -ForegroundColor Red
    $oversizedRepos | ForEach-Object { Write-Host "  $($_.name): $($_.sizeGB) GB — CANNOT migrate with GEI" -ForegroundColor Red }
}

# --- Export ---
$outputFile = Join-Path $OutputDir "inventory-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
$inventory | ConvertTo-Json -Depth 10 | Out-File -FilePath $outputFile -Encoding utf8
Write-Host "`nInventory saved to: $outputFile" -ForegroundColor Green

# --- CSV Summary ---
$csvFile = Join-Path $OutputDir "repo-summary.csv"
$csvRows = @()
foreach ($proj in $inventory.projects) {
    foreach ($repo in $proj.repos) {
        $csvRows += [PSCustomObject]@{
            Project       = $proj.name
            Repo          = $repo.name
            SizeMB        = $repo.sizeMB
            SizeGB        = $repo.sizeGB
            DefaultBranch = $repo.defaultBranch
            Disabled      = $repo.isDisabled
            OverGEILimit  = ($repo.sizeGB -gt 40)
        }
    }
}
$csvRows | Export-Csv -Path $csvFile -NoTypeInformation
Write-Host "Repo summary CSV saved to: $csvFile" -ForegroundColor Green
