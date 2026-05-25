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
    [string]$ProjectName,

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

# --- Fetch Project ---
$project = Invoke-AdoApi "$OrgUrl/_apis/projects/$ProjectName"
if (-not $project) { Write-Error "Failed to find project '$ProjectName'. Check PAT and project name."; exit 1 }

$projName = $project.name
Write-Host "Scanning project: $projName" -ForegroundColor Yellow

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
#!/usr/bin/env bash
set -euo pipefail

# Parse arguments
ORG_URL=""
PAT=""
OUTPUT_DIR="./output/inventory"

while [[ $# -gt 0 ]]; do
  case $1 in
    --org-url|-OrgUrl) ORG_URL="$2"; shift 2 ;;
    --pat|-Pat) PAT="$2"; shift 2 ;;
    --output-dir|-OutputDir) OUTPUT_DIR="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; shift ;;
  esac
done

if [ -z "$ORG_URL" ] || [ -z "$PAT" ]; then
  echo "Error: --org-url and --pat are mandatory parameters" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
orgName=$(echo "$ORG_URL" | sed -E 's|https://dev.azure.com/||g' | sed 's|/||g')
echo "=== ADO Inventory: $orgName ==="

invoke_ado_api() {
  local url="$1"
  local api_version="${2:-7.1}"
  local separator="?"
  if [[ "$url" == *"?"* ]]; then
    separator="&"
  fi
  local full_url="${url}${separator}api-version=${api_version}"
  curl -s -f -u ":$PAT" -H "Accept: application/json" "$full_url" || echo ""
}

scanDate=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
timestamp=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

projectsResp=$(invoke_ado_api "$ORG_URL/_apis/projects")
if [ -z "$projectsResp" ]; then
  echo "Error: Failed to list projects. Check PAT and org URL." >&2
  exit 1
fi

projectCount=$(echo "$projectsResp" | jq '.count // 0')
echo "Found $projectCount projects"

totalRepos=0
totalPipelines=0
totalWorkItems=0
totalTeams=0
totalSizeGB=0
totalReleaseDefs=0
totalSvcConns=0
totalVarGroups=0
totalEnvironments=0
largeCount=0
geiBlockedCount=0

projectListJson="[]"
repoSummaryCsv="\"Project\",\"Repo\",\"SizeMB\",\"SizeGB\",\"DefaultBranch\",\"Disabled\",\"OverGEILimit\"\n"
scCsv="\"Project\",\"Name\",\"Type\",\"AuthScheme\",\"URL\",\"IsReady\",\"CreatedBy\"\n"
vgCsv="\"Project\",\"Name\",\"Type\",\"VariableCount\",\"SecretCount\",\"VariableNames\",\"KeyVault\",\"ModifiedBy\",\"ModifiedOn\"\n"
relCsv="\"Project\",\"Name\",\"Path\",\"EnvironmentCount\",\"EnvironmentNames\",\"ModifiedBy\",\"ModifiedOn\"\n"

projectRowsHtml=""
projectCardsHtml=""

if [ "$projectCount" -gt 0 ]; then
  readarray -t project_ids < <(echo "$projectsResp" | jq -r '.value[].id')
  readarray -t project_names < <(echo "$projectsResp" | jq -r '.value[].name')
  readarray -t project_states < <(echo "$projectsResp" | jq -r '.value[].state')
  readarray -t project_visibilities < <(echo "$projectsResp" | jq -r '.value[].visibility')

  for i in "${!project_ids[@]}"; do
    pId="${project_ids[$i]}"
    pName="${project_names[$i]}"
    pState="${project_states[$i]}"
    pVis="${project_visibilities[$i]}"
    
    echo "  Scanning project: $pName"
    
    # 1. Repos
    reposResp=$(invoke_ado_api "$ORG_URL/$pName/_apis/git/repositories")
    repoCount=0
    projSizeGB=0
    repoHtmlRows=""
    reposJson="[]"
    
    if [ -n "$reposResp" ] && [ "$reposResp" != "{}" ]; then
      repoCount=$(echo "$reposResp" | jq '.count // 0')
      while read -r r; do
        if [ -n "$r" ]; then
          rName=$(echo "$r" | jq -r '.name')
          rId=$(echo "$r" | jq -r '.id')
          rSize=$(echo "$r" | jq -r '.size // 0')
          rUrl=$(echo "$r" | jq -r '.webUrl // ""')
          rDisabled=$(echo "$r" | jq -r '.isDisabled // false')
          rDefaultBranch=$(echo "$r" | jq -r '.defaultBranch // ""')
          
          rSizeMB=$(awk -v size="$rSize" 'BEGIN { printf "%.2f", size / 1048576 }')
          rSizeGB=$(awk -v size="$rSize" 'BEGIN { printf "%.4f", size / 1073741824 }')
          
          overLimit="false"
          if (( $(awk 'BEGIN {print ('$rSizeGB' > 40.0)}') )); then
            overLimit="true"
            geiBlockedCount=$((geiBlockedCount + 1))
          elif (( $(awk 'BEGIN {print ('$rSizeGB' > 1.0)}') )); then
            largeCount=$((largeCount + 1))
          fi
          
          repoSummaryCsv+="\"$pName\",\"$rName\",$rSizeMB,$rSizeGB,\"$rDefaultBranch\",$rDisabled,$overLimit\n"
          
          sizeClass=""
          if [ "$overLimit" = "true" ]; then
            sizeClass="blocked"
          elif (( $(awk 'BEGIN {print ('$rSizeGB' > 1.0)}') )); then
            sizeClass="warning"
          fi
          
          branchClean=${rDefaultBranch#refs/heads/}
          repoHtmlRows+="<tr class='$sizeClass'><td><a href='$rUrl' target='_blank'>$rName</a></td><td class='num'>$rSizeMB</td><td class='num'>$rSizeGB</td><td>$branchClean</td><td>$rDisabled</td></tr>\n"
          
          projSizeGB=$(awk -v s1="$projSizeGB" -v s2="$rSizeGB" 'BEGIN { printf "%.4f", s1 + s2 }')
          totalSizeGB=$(awk -v s1="$totalSizeGB" -v s2="$rSizeGB" 'BEGIN { printf "%.4f", s1 + s2 }')
          
          reposJson=$(jq --arg name "$rName" --arg id "$rId" --argjson sz "$rSize" --arg smb "$rSizeMB" --arg sgb "$rSizeGB" --arg db "$rDefaultBranch" --argjson dis "$rDisabled" --arg url "$rUrl" \
            '. + [{name: $name, id: $id, sizeBytes: $sz, sizeMB: ($smb|tonumber), sizeGB: ($sgb|tonumber), defaultBranch: $db, isDisabled: $dis, url: $url}]' <<< "$reposJson")
        fi
      done < <(echo "$reposResp" | jq -c '.value[] // empty')
    fi
    totalRepos=$((totalRepos + repoCount))
    
    # 2. Pipelines
    pipelinesResp=$(invoke_ado_api "$ORG_URL/$pName/_apis/build/definitions")
    pipeCount=0
    pipeHtmlRows=""
    pipelinesJson="[]"
    
    if [ -n "$pipelinesResp" ] && [ "$pipelinesResp" != "{}" ]; then
      pipeCount=$(echo "$pipelinesResp" | jq '.count // 0')
      while read -r p; do
        if [ -n "$p" ]; then
          piName=$(echo "$p" | jq -r '.name')
          piId=$(echo "$p" | jq -r '.id')
          piType=$(echo "$p" | jq -r '.type')
          piStatus=$(echo "$p" | jq -r '.queueStatus')
          piPath=$(echo "$p" | jq -r '.path')
          piCreated=$(echo "$p" | jq -r '.createdDate')
          piUrl=$(echo "$p" | jq -r '.url')
          piProcessType=$(echo "$p" | jq -r '.process.type // "unknown"')
          
          pipeHtmlRows+="<tr><td>$piName</td><td>$piType</td><td>$piStatus</td><td>$piPath</td></tr>\n"
          
          pipelinesJson=$(jq --arg name "$piName" --arg id "$piId" --arg type "$piType" --arg status "$piStatus" --arg path "$piPath" --arg created "$piCreated" --arg url "$piUrl" --arg ptype "$piProcessType" \
            '. + [{name: $name, id: $id, type: $type, queueStatus: $status, path: $path, createdDate: $created, url: $url, processType: $ptype}]' <<< "$pipelinesJson")
        fi
      done < <(echo "$pipelinesResp" | jq -c '.value[] // empty')
    fi
    totalPipelines=$((totalPipelines + pipeCount))
    
    # 3. Release Definitions
    vsrmUrl=$(echo "$ORG_URL" | sed 's/dev.azure.com/vsrm.dev.azure.com/')
    releasesResp=$(invoke_ado_api "$vsrmUrl/$pName/_apis/release/definitions?\$expand=environments")
    relCount=0
    relHtmlRows=""
    releasesJson="[]"
    
    if [ -n "$releasesResp" ] && [ "$releasesResp" != "{}" ]; then
      relCount=$(echo "$releasesResp" | jq '.count // 0')
      while read -r rd; do
        if [ -n "$rd" ]; then
          rdName=$(echo "$rd" | jq -r '.name')
          rdId=$(echo "$rd" | jq -r '.id')
          rdPath=$(echo "$rd" | jq -r '.path')
          rdCreatedBy=$(echo "$rd" | jq -r '.createdBy.displayName // "N/A"')
          rdModifiedBy=$(echo "$rd" | jq -r '.modifiedBy.displayName // "N/A"')
          rdModifiedOn=$(echo "$rd" | jq -r '.modifiedOn // "N/A"')
          
          envNames=$(echo "$rd" | jq -r '[.environments[].name] | join(", ") // ""')
          envCount=$(echo "$rd" | jq '.environments | length // 0')
          
          relCsv+="\"$pName\",\"$rdName\",\"$rdPath\",$envCount,\"$envNames\",\"$rdModifiedBy\",\"$rdModifiedOn\"\n"
          relHtmlRows+="<tr><td>$rdName</td><td>$rdPath</td><td class='num'>$envCount</td><td>$envNames</td><td>$rdModifiedBy</td><td>$rdModifiedOn</td></tr>\n"
          
          releasesJson=$(jq --arg name "$rdName" --arg id "$rdId" --arg path "$rdPath" --argjson ec "$envCount" --arg enames "$envNames" --arg cb "$rdCreatedBy" --arg mb "$rdModifiedBy" --arg mo "$rdModifiedOn" \
            '. + [{name: $name, id: $id, path: $path, environmentCount: $ec, environmentNames: $enames, createdBy: $cb, modifiedBy: $mb, modifiedOn: $mo}]' <<< "$releasesJson")
        fi
      done < <(echo "$releasesResp" | jq -c '.value[] // empty')
    fi
    totalReleaseDefs=$((totalReleaseDefs + relCount))
    
    # 4. Teams & Members
    teamsResp=$(invoke_ado_api "$ORG_URL/_apis/projects/$pId/teams")
    teamCount=0
    teamHtmlRows=""
    teamsJson="[]"
    
    if [ -n "$teamsResp" ] && [ "$teamsResp" != "{}" ]; then
      teamCount=$(echo "$teamsResp" | jq '.count // 0')
      while read -r t; do
        if [ -n "$t" ]; then
          tName=$(echo "$t" | jq -r '.name')
          tId=$(echo "$t" | jq -r '.id')
          tDesc=$(echo "$t" | jq -r '.description // ""')
          
          membersResp=$(invoke_ado_api "$ORG_URL/_apis/projects/$pId/teams/$tId/members")
          memberCount=0
          if [ -n "$membersResp" ] && [ "$membersResp" != "{}" ]; then
            memberCount=$(echo "$membersResp" | jq '.count // 0')
          fi
          
          teamHtmlRows+="<tr><td>$tName</td><td class='num'>$memberCount</td><td>$tDesc</td></tr>\n"
          
          teamsJson=$(jq --arg name "$tName" --arg id "$tId" --arg desc "$tDesc" --argjson mc "$memberCount" \
            '. + [{name: $name, id: $id, description: $desc, memberCount: $mc}]' <<< "$teamsJson")
        fi
      done < <(echo "$teamsResp" | jq -c '.value[] // empty')
    fi
    totalTeams=$((totalTeams + teamCount))
    
    # 5. Work Item Count (WIQL)
    wiqlBody=$(jq -n --arg proj "$pName" '{query: "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = \($proj)"}')
    wiCount=0
    set +e
    wiqlResp=$(curl -s -f -u ":$PAT" -X POST -H "Content-Type: application/json" -d "$wiqlBody" "$ORG_URL/$pName/_apis/wit/wiql?api-version=7.1" 2>/dev/null || echo "")
    set -e
    if [ -n "$wiqlResp" ]; then
      wiCount=$(echo "$wiqlResp" | jq '.workItems | length // 0')
    fi
    totalWorkItems=$((totalWorkItems + wiCount))
    
    # 6. Service Connections
    scResp=$(invoke_ado_api "$ORG_URL/$pName/_apis/serviceendpoint/endpoints")
    scCount=0
    scHtmlRows=""
    scJson="[]"
    
    if [ -n "$scResp" ] && [ "$scResp" != "{}" ]; then
      scCount=$(echo "$scResp" | jq '.count // 0')
      while read -r sc; do
        if [ -n "$sc" ]; then
          scName=$(echo "$sc" | jq -r '.name')
          scId=$(echo "$sc" | jq -r '.id')
          scType=$(echo "$sc" | jq -r '.type')
          scUrl=$(echo "$sc" | jq -r '.url // ""')
          scDesc=$(echo "$sc" | jq -r '.description // ""')
          scAuth=$(echo "$sc" | jq -r '.authorization.scheme // "N/A"')
          scReady=$(echo "$sc" | jq -r '.isReady // false')
          scCreatedBy=$(echo "$sc" | jq -r '.createdBy.displayName // "N/A"')
          
          scCsv+="\"$pName\",\"$scName\",\"$scType\",\"$scAuth\",\"$scUrl\",$scReady,\"$scCreatedBy\"\n"
          readyClass=""
          if [ "$scReady" = "false" ]; then readyClass="warning"; fi
          scHtmlRows+="<tr class='$readyClass'><td>$scName</td><td>$scType</td><td>$scAuth</td><td>$scUrl</td><td>$scDesc</td><td>$scCreatedBy</td><td>$scReady</td></tr>\n"
          
          scJson=$(jq --arg name "$scName" --arg type "$scType" --arg id "$scId" --arg url "$scUrl" --arg desc "$scDesc" --arg auth "$scAuth" --argjson ready "$scReady" --arg cb "$scCreatedBy" \
            '. + [{name: $name, type: $type, id: $id, url: $url, description: $desc, authScheme: $auth, isReady: $ready, createdBy: $cb}]' <<< "$scJson")
        fi
      done < <(echo "$scResp" | jq -c '.value[] // empty')
    fi
    totalSvcConns=$((totalSvcConns + scCount))
    
    # 7. Variable Groups
    vgResp=$(invoke_ado_api "$ORG_URL/$pName/_apis/distributedtask/variablegroups")
    vgCount=0
    vgHtmlRows=""
    vgJson="[]"
    
    if [ -n "$vgResp" ] && [ "$vgResp" != "{}" ]; then
      vgValue="$vgResp"
      if echo "$vgResp" | jq -e '.value' >/dev/null 2>&1; then
        vgValue=$(echo "$vgResp" | jq '.value')
        vgCount=$(echo "$vgResp" | jq '.count // 0')
      else
        vgCount=$(echo "$vgResp" | jq '. | length // 0')
      fi
      
      while read -r vg; do
        if [ -n "$vg" ]; then
          vgName=$(echo "$vg" | jq -r '.name')
          vgId=$(echo "$vg" | jq -r '.id')
          vgType=$(echo "$vg" | jq -r '.type')
          vgDesc=$(echo "$vg" | jq -r '.description // ""')
          vgVault=$(echo "$vg" | jq -r '.providerData.vault // ""')
          vgModifiedBy=$(echo "$vg" | jq -r '.modifiedBy.displayName // "N/A"')
          vgModifiedOn=$(echo "$vg" | jq -r '.modifiedOn // "N/A"')
          
          varNames=$(echo "$vg" | jq -r '.variables | keys | join(", ") // ""')
          varCount=$(echo "$vg" | jq '.variables | length // 0')
          secretCount=$(echo "$vg" | jq '[.variables[] | select(.isSecret == true)] | length // 0')
          
          vgCsv+="\"$pName\",\"$vgName\",\"$vgType\",$varCount,$secretCount,\"$varNames\",\"$vgVault\",\"$vgModifiedBy\",\"$vgModifiedOn\"\n"
          
          varNamesEscaped=$(echo "$varNames" | sed 's/"/\\"/g')
          vgHtmlRows+="<tr><td>$vgName</td><td>$vgType</td><td class='num'>$varCount</td><td class='num'>$secretCount</td><td class='var-cell'><span class='var-list' title=\"$varNamesEscaped\">$varNames</span></td><td>$vgVault</td><td>$vgDesc</td><td>$vgModifiedBy</td><td>$vgModifiedOn</td></tr>\n"
          
          vgJson=$(jq --arg name "$vgName" --arg id "$vgId" --arg type "$vgType" --argjson vc "$varCount" --argjson sc "$secretCount" --arg vnames "$varNames" --arg vault "$vgVault" --arg desc "$vgDesc" --arg mb "$vgModifiedBy" --arg mo "$vgModifiedOn" \
            '. + [{name: $name, id: $id, type: $type, variableCount: $vc, secretCount: $sc, variableNames: $vnames, providerData: $vault, description: $desc, modifiedBy: $mb, modifiedOn: $mo}]' <<< "$vgJson")
        fi
      done < <(echo "$vgValue" | jq -c '.[] // empty')
    fi
    totalVarGroups=$((totalVarGroups + vgCount))
    
    # 8. Environments
    envResp=$(invoke_ado_api "$ORG_URL/$pName/_apis/distributedtask/environments")
    envCount=0
    envHtmlRows=""
    environmentsJson="[]"
    
    if [ -n "$envResp" ] && [ "$envResp" != "{}" ]; then
      envCount=$(echo "$envResp" | jq '.count // 0')
      while read -r env; do
        if [ -n "$env" ]; then
          envName=$(echo "$env" | jq -r '.name')
          envId=$(echo "$env" | jq -r '.id')
          envHtmlRows+="<tr><td>$envName</td></tr>\n"
          environmentsJson=$(jq --arg name "$envName" --arg id "$envId" '. + [{name: $name, id: $id}]' <<< "$environmentsJson")
        fi
      done < <(echo "$envResp" | jq -c '.value[] // empty')
    fi
    totalEnvironments=$((totalEnvironments + envCount))
    
    projectRowsHtml+="<tr><td>$pName</td><td>$pVis</td><td class='num'>$repoCount</td><td class='num'>$projSizeGB</td><td class='num'>$pipeCount</td><td class='num'>$relCount</td><td class='num'>$teamCount</td><td class='num'>$wiCount</td><td class='num'>$scCount</td><td class='num'>$vgCount</td><td class='num'>$envCount</td></tr>\n"
    
    projectCardsHtml+=$(cat <<CARD_EOF
<div class="project-card" id="proj-$pId">
  <div class="project-header" onclick="toggleProject('$pId')">
    <h2>$pName <span class="badge-vis">$pVis</span> <span class="badge-state">$pState</span></h2>
    <div class="project-stats">
      <span>Repos: <b>$repoCount</b></span>
      <span>Pipelines: <b>$pipeCount</b></span>
      <span>Releases: <b>$relCount</b></span>
      <span>Teams: <b>$teamCount</b></span>
      <span>Work Items: <b>$wiCount</b></span>
      <span>Svc Conns: <b>$scCount</b></span>
      <span>Var Groups: <b>$vgCount</b></span>
      <span>Size: <b>$projSizeGB GB</b></span>
    </div>
  </div>
  <div class="project-body" id="body-$pId" style="display:none;">
    <h3>Repositories ($repoCount)</h3>
    $( [ "$repoCount" -gt 0 ] && echo "<table><colgroup><col style='width:40%'><col style='width:15%'><col style='width:15%'><col style='width:20%'><col style='width:10%'></colgroup><thead><tr><th>Name</th><th>Size (MB)</th><th>Size (GB)</th><th>Default Branch</th><th>Disabled</th></tr></thead><tbody>$repoHtmlRows</tbody></table>" || echo "<p class='empty'>No repositories</p>" )

    <h3>Build Pipelines ($pipeCount)</h3>
    $( [ "$pipeCount" -gt 0 ] && echo "<table><thead><tr><th>Name</th><th>Type</th><th>Queue Status</th><th>Path</th></tr></thead><tbody>$pipeHtmlRows</tbody></table>" || echo "<p class='empty'>No build pipelines</p>" )

    <h3>Release Definitions ($relCount)</h3>
    $( [ "$relCount" -gt 0 ] && echo "<table><thead><tr><th>Name</th><th>Path</th><th>Environments</th><th>Environment Names</th><th>Modified By</th><th>Modified</th></tr></thead><tbody>$relHtmlRows</tbody></table>" || echo "<p class='empty'>No release definitions</p>" )

    <h3>Teams ($teamCount)</h3>
    $( [ "$teamCount" -gt 0 ] && echo "<table><thead><tr><th>Name</th><th>Members</th><th>Description</th></tr></thead><tbody>$teamHtmlRows</tbody></table>" || echo "<p class='empty'>No teams</p>" )

    <h3>Service Connections ($scCount)</h3>
    $( [ "$scCount" -gt 0 ] && echo "<table><colgroup><col style='width:20%'><col style='width:12%'><col style='width:12%'><col style='width:20%'><col style='width:16%'><col style='width:12%'><col style='width:8%'></colgroup><thead><tr><th>Name</th><th>Type</th><th>Auth Scheme</th><th>URL</th><th>Description</th><th>Created By</th><th>Ready</th></tr></thead><tbody>$scHtmlRows</tbody></table>" || echo "<p class='empty'>No service connections</p>" )

    <h3>Variable Groups ($vgCount)</h3>
    $( [ "$vgCount" -gt 0 ] && echo "<table><colgroup><col style='width:15%'><col style='width:10%'><col style='width:7%'><col style='width:7%'><col style='width:20%'><col style='width:10%'><col style='width:13%'><col style='width:10%'><col style='width:8%'></colgroup><thead><tr><th>Name</th><th>Type</th><th>Variables</th><th>Secrets</th><th>Variable Names</th><th>Key Vault</th><th>Description</th><th>Modified By</th><th>Modified</th></tr></thead><tbody>$vgHtmlRows</tbody></table>" || echo "<p class='empty'>No variable groups</p>" )

    <h3>Environments ($envCount)</h3>
    $( [ "$envCount" -gt 0 ] && echo "<table><thead><tr><th>Name</th></tr></thead><tbody>$envHtmlRows</tbody></table>" || echo "<p class='empty'>No environments</p>" )
  </div>
</div>
CARD_EOF
)
    
    projectListJson=$(jq --arg name "$pName" --arg id "$pId" --arg state "$pState" --arg vis "$pVis" --argjson repos "$reposJson" --argjson pipes "$pipelinesJson" --argjson rels "$releasesJson" --argjson teams "$teamsJson" --argjson wic "$wiCount" --argjson scs "$scJson" --argjson vgs "$vgJson" --argjson envs "$environmentsJson" \
      '. + [{name: $name, id: $id, state: $state, visibility: $vis, repos: $repos, pipelines: $pipes, releaseDefinitions: $rels, teams: $teams, workItemCount: $wic, serviceConnections: $scs, variableGroups: $vgs, environments: $envs}]' <<< "$projectListJson")
  done
fi

timestampFilename=$(date +"%Y%m%d-%H%M%S")
outputJsonFile="$OUTPUT_DIR/inventory-$timestampFilename.json"
jq -n --arg org "$orgName" --arg date "$scanDate" --argjson tr "$totalRepos" --argjson tp "$totalPipelines" --argjson twi "$totalWorkItems" --argjson tt "$totalTeams" --argjson projs "$projectListJson" \
  '{organization: $org, scanDate: $date, totalRepos: $tr, totalPipelines: $tp, totalWorkItems: $twi, totalTeams: $tt, projects: $projs}' > "$outputJsonFile"

echo "=== Inventory Summary ==="
echo "Projects:    $projectCount"
echo "Repos:       $totalRepos"
echo "Pipelines:   $totalPipelines"
echo "Work Items:  $totalWorkItems"
echo "Teams:       $totalTeams"

echo -ne "$repoSummaryCsv" > "$OUTPUT_DIR/repo-summary.csv"
if [ "$totalSvcConns" -gt 0 ]; then echo -ne "$scCsv" > "$OUTPUT_DIR/service-connections.csv"; fi
if [ "$totalVarGroups" -gt 0 ]; then echo -ne "$vgCsv" > "$OUTPUT_DIR/variable-groups.csv"; fi
if [ "$totalReleaseDefs" -gt 0 ]; then echo -ne "$relCsv" > "$OUTPUT_DIR/release-definitions.csv"; fi

echo "Repo summary CSV saved to: $OUTPUT_DIR/repo-summary.csv"

projectRowsHtml+="<tr class='total-row'><td>TOTAL</td><td></td><td class='num'>$totalRepos</td><td class='num'>$totalSizeGB</td><td class='num'>$totalPipelines</td><td class='num'>$totalReleaseDefs</td><td class='num'>$totalTeams</td><td class='num'>$totalWorkItems</td><td class='num'>$totalSvcConns</td><td class='num'>$totalVarGroups</td><td class='num'>$totalEnvironments</td></tr>"

htmlFile="$OUTPUT_DIR/inventory-dashboard.html"

cat <<EOF > "$htmlFile"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>ADO Inventory Dashboard — $orgName</title>
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
  <p class="subtitle">Organization: <b>$orgName</b> &mdash; Generated: $timestamp</p>

  <div class="cards">
    <div class="card"><div class="value">$projectCount</div><div class="label">Projects</div></div>
    <div class="card"><div class="value">$totalRepos</div><div class="label">Repositories</div></div>
    <div class="card"><div class="value">$totalSizeGB GB</div><div class="label">Total Repo Size</div></div>
    <div class="card"><div class="value">$totalPipelines</div><div class="label">Build Pipelines</div></div>
    <div class="card"><div class="value">$totalReleaseDefs</div><div class="label">Release Defs</div></div>
    <div class="card"><div class="value">$totalTeams</div><div class="label">Teams</div></div>
    <div class="card"><div class="value">$totalWorkItems</div><div class="label">Work Items</div></div>
    <div class="card"><div class="value">$totalSvcConns</div><div class="label">Service Connections</div></div>
    <div class="card"><div class="value">$totalVarGroups</div><div class="label">Variable Groups</div></div>
    <div class="card"><div class="value">$totalEnvironments</div><div class="label">Environments</div></div>
    <div class="card$( [ "$largeCount" -gt 0 ] && echo ' warn' )"><div class="value">$largeCount</div><div class="label">Repos &gt; 1 GB</div></div>
    <div class="card$( [ "$geiBlockedCount" -gt 0 ] && echo ' error' )"><div class="value">$geiBlockedCount</div><div class="label">GEI Blocked (&gt;40 GB)</div></div>
  </div>
  <div class="report-section">
    <h2>Project-wise Summary Report</h2>
    <table class="report-table">
      <thead>
        <tr><th>Project</th><th>Visibility</th><th>Repos</th><th>Size (GB)</th><th>Pipelines</th><th>Releases</th><th>Teams</th><th>Work Items</th><th>Svc Conns</th><th>Var Groups</th><th>Environments</th></tr>
      </thead>
      <tbody>
$(echo -ne "$projectRowsHtml")
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

$(echo -ne "$projectCardsHtml")

  <p class="footer">ADO Inventory &mdash; $orgName &mdash; $timestamp</p>
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
EOF

echo "HTML dashboard saved to: $htmlFile"
