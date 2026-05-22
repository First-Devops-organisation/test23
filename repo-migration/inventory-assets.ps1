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

    [string]$OutputDir = "./output/inventory",
    # NEW PARAMETER: Optional project name to scope the inventory
    [string]$ProjectName = "" 
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
    $releasesResp = Invoke-AdoApi "$vsrmUrl/$projName/_apis/release/definitions?`$expand=environments"
    if ($releasesResp) {
        foreach ($rd in $releasesResp.value) {
            $envNames = @()
            if ($rd.environments) {
                $envNames = @($rd.environments | ForEach-Object { $_.name })
            }
            $projData.releaseDefinitions += @{
                name             = $rd.name
                id               = $rd.id
                path             = $rd.path
                environmentCount = $envNames.Count
                environmentNames = ($envNames -join ', ')
                createdBy        = if ($rd.createdBy) { $rd.createdBy.displayName } else { 'N/A' }
                modifiedBy       = if ($rd.modifiedBy) { $rd.modifiedBy.displayName } else { 'N/A' }
                modifiedOn       = $rd.modifiedOn
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
                name        = $sc.name
                type        = $sc.type
                id          = $sc.id
                url         = $sc.url
                description = $sc.description
                authScheme  = if ($sc.authorization) { $sc.authorization.scheme } else { 'N/A' }
                isReady     = $sc.isReady
                createdBy   = if ($sc.createdBy) { $sc.createdBy.displayName } else { 'N/A' }
            }
        }
        Write-Host "    Service Connections: $($scResp.count)" -ForegroundColor Gray
    }

    # --- Variable Groups ---
    $vgResp = Invoke-AdoApi "$OrgUrl/$projName/_apis/distributedtask/variablegroups"
    if ($vgResp) {
        foreach ($vg in $vgResp.value) {
            $varNames = @()
            $secretCount = 0
            if ($vg.variables) {
                $vg.variables.PSObject.Properties | ForEach-Object {
                    $varNames += $_.Name
                    if ($_.Value.isSecret) { $secretCount++ }
                }
            }
            $projData.variableGroups += @{
                name          = $vg.name
                id            = $vg.id
                variableCount = $varNames.Count
                secretCount   = $secretCount
                variableNames = ($varNames -join ', ')
                type          = $vg.type
                description   = $vg.description
                providerData  = if ($vg.providerData) { $vg.providerData.vault } else { $null }
                createdBy     = if ($vg.createdBy) { $vg.createdBy.displayName } else { 'N/A' }
                modifiedBy    = if ($vg.modifiedBy) { $vg.modifiedBy.displayName } else { 'N/A' }
                modifiedOn    = $vg.modifiedOn
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

# --- Service Connections CSV ---
$scCsvFile = Join-Path $OutputDir "service-connections.csv"
$scCsvRows = @()
foreach ($proj in $inventory.projects) {
    foreach ($sc in $proj.serviceConnections) {
        $scCsvRows += [PSCustomObject]@{
            Project    = $proj.name
            Name       = $sc.name
            Type       = $sc.type
            AuthScheme = $sc.authScheme
            URL        = $sc.url
            IsReady    = $sc.isReady
            CreatedBy  = $sc.createdBy
        }
    }
}
if ($scCsvRows.Count -gt 0) {
    $scCsvRows | Export-Csv -Path $scCsvFile -NoTypeInformation
    Write-Host "Service connections CSV saved to: $scCsvFile" -ForegroundColor Green
}

# --- Variable Groups CSV ---
$vgCsvFile = Join-Path $OutputDir "variable-groups.csv"
$vgCsvRows = @()
foreach ($proj in $inventory.projects) {
    foreach ($vg in $proj.variableGroups) {
        $vgCsvRows += [PSCustomObject]@{
            Project       = $proj.name
            Name          = $vg.name
            Type          = $vg.type
            VariableCount = $vg.variableCount
            SecretCount   = $vg.secretCount
            VariableNames = $vg.variableNames
            KeyVault      = $vg.providerData
            ModifiedBy    = $vg.modifiedBy
            ModifiedOn    = $vg.modifiedOn
        }
    }
}
if ($vgCsvRows.Count -gt 0) {
    $vgCsvRows | Export-Csv -Path $vgCsvFile -NoTypeInformation
    Write-Host "Variable groups CSV saved to: $vgCsvFile" -ForegroundColor Green
}

# --- Release Definitions CSV ---
$relCsvFile = Join-Path $OutputDir "release-definitions.csv"
$relCsvRows = @()
foreach ($proj in $inventory.projects) {
    foreach ($rd in $proj.releaseDefinitions) {
        $relCsvRows += [PSCustomObject]@{
            Project          = $proj.name
            Name             = $rd.name
            Path             = $rd.path
            EnvironmentCount = $rd.environmentCount
            EnvironmentNames = $rd.environmentNames
            ModifiedBy       = $rd.modifiedBy
            ModifiedOn       = $rd.modifiedOn
        }
    }
}
if ($relCsvRows.Count -gt 0) {
    $relCsvRows | Export-Csv -Path $relCsvFile -NoTypeInformation
    Write-Host "Release definitions CSV saved to: $relCsvFile" -ForegroundColor Green
}

# --- HTML Dashboard ---
$htmlFile = Join-Path $OutputDir "inventory-dashboard.html"
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss UTC"
$totalSizeGB = [math]::Round(($inventory.projects | ForEach-Object { $_.repos } | Measure-Object -Property sizeGB -Sum).Sum, 2)
$totalReleaseDefs = ($inventory.projects | ForEach-Object { $_.releaseDefinitions.Count } | Measure-Object -Sum).Sum
$totalSvcConns = ($inventory.projects | ForEach-Object { $_.serviceConnections.Count } | Measure-Object -Sum).Sum
$totalVarGroups = ($inventory.projects | ForEach-Object { $_.variableGroups.Count } | Measure-Object -Sum).Sum
$totalEnvironments = ($inventory.projects | ForEach-Object { $_.environments.Count } | Measure-Object -Sum).Sum
$largeCount = @($inventory.projects | ForEach-Object { $_.repos } | Where-Object { $_.sizeGB -gt 1 }).Count
$geiBlockedCount = @($inventory.projects | ForEach-Object { $_.repos } | Where-Object { $_.sizeGB -gt 40 }).Count

# Build project-wise summary report table
$reportRows = ""
foreach ($proj in ($inventory.projects | Sort-Object { $_.name })) {
    $pSizeGB = [math]::Round(($proj.repos | Measure-Object -Property sizeGB -Sum).Sum, 2)
    $reportRows += "<tr><td>$([System.Net.WebUtility]::HtmlEncode($proj.name))</td><td>$($proj.visibility)</td><td class='num'>$($proj.repos.Count)</td><td class='num'>$pSizeGB</td><td class='num'>$($proj.pipelines.Count)</td><td class='num'>$($proj.releaseDefinitions.Count)</td><td class='num'>$($proj.teams.Count)</td><td class='num'>$($proj.workItemCount)</td><td class='num'>$($proj.serviceConnections.Count)</td><td class='num'>$($proj.variableGroups.Count)</td><td class='num'>$($proj.environments.Count)</td></tr>`n"
}
$reportRows += "<tr class='total-row'><td>TOTAL</td><td></td><td class='num'>$($inventory.totalRepos)</td><td class='num'>$totalSizeGB</td><td class='num'>$($inventory.totalPipelines)</td><td class='num'>$totalReleaseDefs</td><td class='num'>$($inventory.totalTeams)</td><td class='num'>$($inventory.totalWorkItems)</td><td class='num'>$totalSvcConns</td><td class='num'>$totalVarGroups</td><td class='num'>$totalEnvironments</td></tr>`n"

# Build project cards
$projectCards = ""
foreach ($proj in ($inventory.projects | Sort-Object { $_.name })) {
    $pName = [System.Net.WebUtility]::HtmlEncode($proj.name)
    $repoCount = $proj.repos.Count
    $pipeCount = $proj.pipelines.Count
    $releaseCount = $proj.releaseDefinitions.Count
    $teamCount = $proj.teams.Count
    $wiCount = $proj.workItemCount
    $scCount = $proj.serviceConnections.Count
    $vgCount = $proj.variableGroups.Count
    $envCount = $proj.environments.Count
    $projSizeGB = [math]::Round(($proj.repos | Measure-Object -Property sizeGB -Sum).Sum, 2)

    # Repo table rows
    $repoRows = ""
    foreach ($r in ($proj.repos | Sort-Object { $_.sizeMB } -Descending)) {
        $rName = [System.Net.WebUtility]::HtmlEncode($r.name)
        $rLink = if ($r.url) { "<a href='$([System.Net.WebUtility]::HtmlEncode($r.url))' target='_blank'>$rName</a>" } else { $rName }
        $sizeClass = if ($r.sizeGB -gt 40) { "blocked" } elseif ($r.sizeGB -gt 1) { "warning" } else { "" }
        $branch = [System.Net.WebUtility]::HtmlEncode(("$($r.defaultBranch)" -replace '^refs/heads/', ''))
        $disabled = if ($r.isDisabled) { "Yes" } else { "No" }
        $repoRows += "<tr class='$sizeClass'><td>$rLink</td><td class='num'>$($r.sizeMB)</td><td class='num'>$($r.sizeGB)</td><td>$branch</td><td>$disabled</td></tr>`n"
    }

    # Pipeline table rows
    $pipeRows = ""
    foreach ($p in $proj.pipelines) {
        $pipeRows += "<tr><td>$([System.Net.WebUtility]::HtmlEncode($p.name))</td><td>$($p.type)</td><td>$($p.queueStatus)</td><td>$([System.Net.WebUtility]::HtmlEncode($p.path))</td></tr>`n"
    }

    # Release table rows
    $releaseRows = ""
    foreach ($rd in $proj.releaseDefinitions) {
        $rdEnvNames = if ($rd.environmentNames) { [System.Net.WebUtility]::HtmlEncode($rd.environmentNames) } else { '-' }
        $rdModified = if ($rd.modifiedOn) { ([datetime]$rd.modifiedOn).ToString('yyyy-MM-dd') } else { '-' }
        $releaseRows += "<tr><td>$([System.Net.WebUtility]::HtmlEncode($rd.name))</td><td>$([System.Net.WebUtility]::HtmlEncode($rd.path))</td><td class='num'>$($rd.environmentCount)</td><td>$rdEnvNames</td><td>$([System.Net.WebUtility]::HtmlEncode($rd.modifiedBy))</td><td>$rdModified</td></tr>`n"
    }

    # Teams table rows
    $teamRows = ""
    foreach ($t in $proj.teams) {
        $teamRows += "<tr><td>$([System.Net.WebUtility]::HtmlEncode($t.name))</td><td class='num'>$($t.memberCount)</td><td>$([System.Net.WebUtility]::HtmlEncode($t.description))</td></tr>`n"
    }

    # Service connections
    $scRows = ""
    foreach ($sc in $proj.serviceConnections) {
        $scUrl = if ($sc.url) { [System.Net.WebUtility]::HtmlEncode($sc.url) } else { '-' }
        $scDesc = if ($sc.description) { [System.Net.WebUtility]::HtmlEncode($sc.description) } else { '-' }
        $readyClass = if ($sc.isReady -eq $false) { "warning" } else { "" }
        $scRows += "<tr class='$readyClass'><td>$([System.Net.WebUtility]::HtmlEncode($sc.name))</td><td>$([System.Net.WebUtility]::HtmlEncode($sc.type))</td><td>$([System.Net.WebUtility]::HtmlEncode($sc.authScheme))</td><td>$scUrl</td><td>$scDesc</td><td>$([System.Net.WebUtility]::HtmlEncode($sc.createdBy))</td><td>$(if ($sc.isReady) { 'Yes' } else { 'No' })</td></tr>`n"
    }

    # Variable groups
    $vgRows = ""
    foreach ($vg in $proj.variableGroups) {
        $vgDesc = if ($vg.description) { [System.Net.WebUtility]::HtmlEncode($vg.description) } else { '-' }
        $vgVault = if ($vg.providerData) { [System.Net.WebUtility]::HtmlEncode($vg.providerData) } else { '-' }
        $vgVarNames = if ($vg.variableNames) { "<span class='var-list' title='$([System.Net.WebUtility]::HtmlEncode($vg.variableNames))'>$([System.Net.WebUtility]::HtmlEncode($vg.variableNames))</span>" } else { '-' }
        $vgModified = if ($vg.modifiedOn) { ([datetime]$vg.modifiedOn).ToString('yyyy-MM-dd') } else { '-' }
        $vgRows += "<tr><td>$([System.Net.WebUtility]::HtmlEncode($vg.name))</td><td>$([System.Net.WebUtility]::HtmlEncode($vg.type))</td><td class='num'>$($vg.variableCount)</td><td class='num'>$($vg.secretCount)</td><td class='var-cell'>$vgVarNames</td><td>$vgVault</td><td>$vgDesc</td><td>$([System.Net.WebUtility]::HtmlEncode($vg.modifiedBy))</td><td>$vgModified</td></tr>`n"
    }

    # Environments
    $envRows = ""
    foreach ($e in $proj.environments) {
        $envRows += "<tr><td>$([System.Net.WebUtility]::HtmlEncode($e.name))</td></tr>`n"
    }

    $projectCards += @"
<div class="project-card" id="proj-$($proj.id)">
  <div class="project-header" onclick="toggleProject('$($proj.id)')">
    <h2>$pName <span class="badge-vis">$($proj.visibility)</span> <span class="badge-state">$($proj.state)</span></h2>
    <div class="project-stats">
      <span>Repos: <b>$repoCount</b></span>
      <span>Pipelines: <b>$pipeCount</b></span>
      <span>Releases: <b>$releaseCount</b></span>
      <span>Teams: <b>$teamCount</b></span>
      <span>Work Items: <b>$wiCount</b></span>
      <span>Svc Conns: <b>$scCount</b></span>
      <span>Var Groups: <b>$vgCount</b></span>
      <span>Size: <b>$projSizeGB GB</b></span>
    </div>
  </div>
  <div class="project-body" id="body-$($proj.id)" style="display:none;">
    <h3>Repositories ($repoCount)</h3>
    $(if ($repoCount -gt 0) { "<table><colgroup><col style='width:40%'><col style='width:15%'><col style='width:15%'><col style='width:20%'><col style='width:10%'></colgroup><thead><tr><th>Name</th><th>Size (MB)</th><th>Size (GB)</th><th>Default Branch</th><th>Disabled</th></tr></thead><tbody>$repoRows</tbody></table>" } else { "<p class='empty'>No repositories</p>" })

    <h3>Build Pipelines ($pipeCount)</h3>
    $(if ($pipeCount -gt 0) { "<table><thead><tr><th>Name</th><th>Type</th><th>Queue Status</th><th>Path</th></tr></thead><tbody>$pipeRows</tbody></table>" } else { "<p class='empty'>No build pipelines</p>" })

    <h3>Release Definitions ($releaseCount)</h3>
    $(if ($releaseCount -gt 0) { "<table><thead><tr><th>Name</th><th>Path</th><th>Environments</th><th>Environment Names</th><th>Modified By</th><th>Modified</th></tr></thead><tbody>$releaseRows</tbody></table>" } else { "<p class='empty'>No release definitions</p>" })

    <h3>Teams ($teamCount)</h3>
    $(if ($teamCount -gt 0) { "<table><thead><tr><th>Name</th><th>Members</th><th>Description</th></tr></thead><tbody>$teamRows</tbody></table>" } else { "<p class='empty'>No teams</p>" })

    <h3>Service Connections ($scCount)</h3>
    $(if ($scCount -gt 0) { "<table><colgroup><col style='width:20%'><col style='width:12%'><col style='width:12%'><col style='width:20%'><col style='width:16%'><col style='width:12%'><col style='width:8%'></colgroup><thead><tr><th>Name</th><th>Type</th><th>Auth Scheme</th><th>URL</th><th>Description</th><th>Created By</th><th>Ready</th></tr></thead><tbody>$scRows</tbody></table>" } else { "<p class='empty'>No service connections</p>" })

    <h3>Variable Groups ($vgCount)</h3>
    $(if ($vgCount -gt 0) { "<table><colgroup><col style='width:15%'><col style='width:10%'><col style='width:7%'><col style='width:7%'><col style='width:20%'><col style='width:10%'><col style='width:13%'><col style='width:10%'><col style='width:8%'></colgroup><thead><tr><th>Name</th><th>Type</th><th>Variables</th><th>Secrets</th><th>Variable Names</th><th>Key Vault</th><th>Description</th><th>Modified By</th><th>Modified</th></tr></thead><tbody>$vgRows</tbody></table>" } else { "<p class='empty'>No variable groups</p>" })

    <h3>Environments ($envCount)</h3>
    $(if ($envCount -gt 0) { "<table><thead><tr><th>Name</th></tr></thead><tbody>$envRows</tbody></table>" } else { "<p class='empty'>No environments</p>" })
  </div>
</div>

"@
}

$htmlContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>ADO Inventory Dashboard — $([System.Net.WebUtility]::HtmlEncode($orgName))</title>
<style>
  *{margin:0;padding:0;box-sizing:border-box}
  body{font-family:'Segoe UI',Tahoma,sans-serif;background:#f0f2f5;color:#24292f;padding:20px}
  .container{max-width:1400px;margin:0 auto}
  h1{font-size:1.8rem;margin-bottom:5px;color:#0078d4}
  .subtitle{color:#586069;margin-bottom:20px;font-size:.9rem}
  .cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin-bottom:25px}
  .card{background:#fff;border-radius:8px;padding:16px;box-shadow:0 1px 3px rgba(0,0,0,.12);text-align:center}
  .card .value{font-size:1.8rem;font-weight:700;color:#0078d4}
  .card .label{font-size:.8rem;color:#586069;margin-top:4px}
  .card.warn .value{color:#d29922}
  .card.error .value{color:#cf222e}
  .search-box{margin-bottom:15px}
  .search-box input{width:100%;max-width:400px;padding:10px 14px;border:1px solid #d0d7de;border-radius:6px;font-size:.9rem}
  .search-box input:focus{outline:none;border-color:#0078d4;box-shadow:0 0 0 3px rgba(0,120,212,.15)}
  .project-card{background:#fff;border-radius:8px;margin-bottom:12px;box-shadow:0 1px 3px rgba(0,0,0,.12);overflow:hidden}
  .project-header{padding:16px 20px;cursor:pointer;border-left:4px solid #0078d4;transition:background .2s}
  .project-header:hover{background:#f6f8fa}
  .project-header h2{font-size:1.1rem;color:#24292f;margin-bottom:6px}
  .project-stats{display:flex;gap:18px;flex-wrap:wrap;font-size:.85rem;color:#586069}
  .project-body{padding:0 20px 20px}
  .project-body h3{font-size:.95rem;color:#0078d4;margin:16px 0 8px;border-bottom:1px solid #e1e4e8;padding-bottom:4px}
  table{width:100%;border-collapse:collapse;margin-bottom:10px;font-size:.83rem;table-layout:fixed}
  th{background:#f6f8fa;padding:8px 10px;text-align:left;font-weight:600;border-bottom:2px solid #e1e4e8;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  td{padding:7px 10px;border-bottom:1px solid #e1e4e8;word-wrap:break-word;overflow:hidden;text-overflow:ellipsis}
  tr:hover{background:#f6f8fa}
  tr.blocked{background:#fff0f0}
  tr.warning{background:#fff8e1}
  .num{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
  .badge-vis{font-size:.7rem;padding:2px 8px;border-radius:10px;background:#dafbe1;color:#1a7f37;margin-left:8px}
  .badge-state{font-size:.7rem;padding:2px 8px;border-radius:10px;background:#ddf4ff;color:#0969da;margin-left:4px}
  .empty{color:#8b949e;font-style:italic;font-size:.85rem;padding:4px 0}
  a{color:#0078d4;text-decoration:none}
  a:hover{text-decoration:underline}
  .footer{margin-top:20px;color:#586069;font-size:.8rem;text-align:center}
  .expand-all{margin-bottom:15px}
  .expand-all button{padding:8px 16px;border:1px solid #d0d7de;border-radius:6px;background:#fff;cursor:pointer;font-size:.85rem}
  .expand-all button:hover{background:#f6f8fa}
  .var-cell{max-width:250px}
  .var-list{display:inline-block;max-width:250px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;vertical-align:middle;cursor:help}
  .report-section{background:#fff;border-radius:8px;padding:20px;margin-bottom:20px;box-shadow:0 1px 3px rgba(0,0,0,.12)}
  .report-section h2{font-size:1.1rem;color:#0078d4;margin-bottom:12px;border-bottom:2px solid #e1e4e8;padding-bottom:6px}
  .report-table{width:100%;border-collapse:collapse;font-size:.83rem}
  .report-table th{background:#f6f8fa;padding:8px 10px;text-align:left;font-weight:600;border-bottom:2px solid #e1e4e8;position:sticky;top:0}
  .report-table td{padding:7px 10px;border-bottom:1px solid #e1e4e8}
  .report-table tr:hover{background:#f6f8fa}
  .report-table .total-row{background:#f0f2f5;font-weight:700}
</style>
</head>
<body>
<div class="container">
  <h1>&#128202; ADO Inventory Dashboard</h1>
  <p class="subtitle">Organization: <b>$([System.Net.WebUtility]::HtmlEncode($orgName))</b> &mdash; Generated: $timestamp</p>

  <div class="cards">
    <div class="card"><div class="value">$($inventory.projects.Count)</div><div class="label">Projects</div></div>
    <div class="card"><div class="value">$($inventory.totalRepos)</div><div class="label">Repositories</div></div>
    <div class="card"><div class="value">$totalSizeGB GB</div><div class="label">Total Repo Size</div></div>
    <div class="card"><div class="value">$($inventory.totalPipelines)</div><div class="label">Build Pipelines</div></div>
    <div class="card"><div class="value">$totalReleaseDefs</div><div class="label">Release Defs</div></div>
    <div class="card"><div class="value">$($inventory.totalTeams)</div><div class="label">Teams</div></div>
    <div class="card"><div class="value">$($inventory.totalWorkItems)</div><div class="label">Work Items</div></div>
    <div class="card"><div class="value">$totalSvcConns</div><div class="label">Service Connections</div></div>
    <div class="card"><div class="value">$totalVarGroups</div><div class="label">Variable Groups</div></div>
    <div class="card"><div class="value">$totalEnvironments</div><div class="label">Environments</div></div>
    <div class="card$(if ($largeCount -gt 0) {' warn'})"><div class="value">$largeCount</div><div class="label">Repos &gt; 1 GB</div></div>
    <div class="card$(if ($geiBlockedCount -gt 0) {' error'})"><div class="value">$geiBlockedCount</div><div class="label">GEI Blocked (&gt;40 GB)</div></div>
  </div>
  <div class="report-section">
    <h2>Project-wise Summary Report</h2>
    <table class="report-table">
      <thead>
        <tr><th>Project</th><th>Visibility</th><th>Repos</th><th>Size (GB)</th><th>Pipelines</th><th>Releases</th><th>Teams</th><th>Work Items</th><th>Svc Conns</th><th>Var Groups</th><th>Environments</th></tr>
      </thead>
      <tbody>
`$reportRows
      </tbody>
    </table>
  </div>
  <div class="search-box">
    <input type="text" id="searchInput" placeholder="Search projects..." onkeyup="filterProjects()">
  </div>
  <div class="expand-all">
    <button onclick="expandAll()">Expand All</button>
    <button onclick="collapseAll()">Collapse All</button>
  </div>

$projectCards

  <p class="footer">ADO Inventory &mdash; $([System.Net.WebUtility]::HtmlEncode($orgName)) &mdash; $timestamp</p>
</div>
<script>
function toggleProject(id){
  var el=document.getElementById('body-'+id);
  el.style.display=el.style.display==='none'?'block':'none';
}
function expandAll(){
  document.querySelectorAll('.project-body').forEach(function(el){el.style.display='block';});
}
function collapseAll(){
  document.querySelectorAll('.project-body').forEach(function(el){el.style.display='none';});
}
function filterProjects(){
  var q=document.getElementById('searchInput').value.toLowerCase();
  document.querySelectorAll('.project-card').forEach(function(card){
    card.style.display=card.textContent.toLowerCase().indexOf(q)>-1?'':'none';
  });
}
</script>
</body>
</html>
"@

$htmlContent | Out-File $htmlFile -Encoding utf8
Write-Host "HTML dashboard saved to: $htmlFile" -ForegroundColor Green
