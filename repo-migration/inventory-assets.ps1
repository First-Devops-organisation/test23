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
        $releaseRows += "<tr><td>$([System.Net.WebUtility]::HtmlEncode($rd.name))</td><td>$([System.Net.WebUtility]::HtmlEncode($rd.path))</td><td class='num'>$($rd.environmentCount)</td></tr>`n"
    }

    # Teams table rows
    $teamRows = ""
    foreach ($t in $proj.teams) {
        $teamRows += "<tr><td>$([System.Net.WebUtility]::HtmlEncode($t.name))</td><td class='num'>$($t.memberCount)</td><td>$([System.Net.WebUtility]::HtmlEncode($t.description))</td></tr>`n"
    }

    # Service connections
    $scRows = ""
    foreach ($sc in $proj.serviceConnections) {
        $scRows += "<tr><td>$([System.Net.WebUtility]::HtmlEncode($sc.name))</td><td>$([System.Net.WebUtility]::HtmlEncode($sc.type))</td></tr>`n"
    }

    # Variable groups
    $vgRows = ""
    foreach ($vg in $proj.variableGroups) {
        $vgRows += "<tr><td>$([System.Net.WebUtility]::HtmlEncode($vg.name))</td><td class='num'>$($vg.variableCount)</td><td>$([System.Net.WebUtility]::HtmlEncode($vg.type))</td></tr>`n"
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
      <span>Size: <b>$projSizeGB GB</b></span>
    </div>
  </div>
  <div class="project-body" id="body-$($proj.id)" style="display:none;">
    <h3>Repositories ($repoCount)</h3>
    $(if ($repoCount -gt 0) { "<table><thead><tr><th>Name</th><th>Size (MB)</th><th>Size (GB)</th><th>Default Branch</th><th>Disabled</th></tr></thead><tbody>$repoRows</tbody></table>" } else { "<p class='empty'>No repositories</p>" })

    <h3>Build Pipelines ($pipeCount)</h3>
    $(if ($pipeCount -gt 0) { "<table><thead><tr><th>Name</th><th>Type</th><th>Queue Status</th><th>Path</th></tr></thead><tbody>$pipeRows</tbody></table>" } else { "<p class='empty'>No build pipelines</p>" })

    <h3>Release Definitions ($releaseCount)</h3>
    $(if ($releaseCount -gt 0) { "<table><thead><tr><th>Name</th><th>Path</th><th>Environments</th></tr></thead><tbody>$releaseRows</tbody></table>" } else { "<p class='empty'>No release definitions</p>" })

    <h3>Teams ($teamCount)</h3>
    $(if ($teamCount -gt 0) { "<table><thead><tr><th>Name</th><th>Members</th><th>Description</th></tr></thead><tbody>$teamRows</tbody></table>" } else { "<p class='empty'>No teams</p>" })

    <h3>Service Connections ($scCount)</h3>
    $(if ($scCount -gt 0) { "<table><thead><tr><th>Name</th><th>Type</th></tr></thead><tbody>$scRows</tbody></table>" } else { "<p class='empty'>No service connections</p>" })

    <h3>Variable Groups ($vgCount)</h3>
    $(if ($vgCount -gt 0) { "<table><thead><tr><th>Name</th><th>Variables</th><th>Type</th></tr></thead><tbody>$vgRows</tbody></table>" } else { "<p class='empty'>No variable groups</p>" })

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
  table{width:100%;border-collapse:collapse;margin-bottom:10px;font-size:.83rem}
  th{background:#f6f8fa;padding:8px 10px;text-align:left;font-weight:600;border-bottom:2px solid #e1e4e8}
  td{padding:7px 10px;border-bottom:1px solid #e1e4e8}
  tr:hover{background:#f6f8fa}
  tr.blocked{background:#fff0f0}
  tr.warning{background:#fff8e1}
  .num{text-align:right;font-variant-numeric:tabular-nums}
  .badge-vis{font-size:.7rem;padding:2px 8px;border-radius:10px;background:#dafbe1;color:#1a7f37;margin-left:8px}
  .badge-state{font-size:.7rem;padding:2px 8px;border-radius:10px;background:#ddf4ff;color:#0969da;margin-left:4px}
  .empty{color:#8b949e;font-style:italic;font-size:.85rem;padding:4px 0}
  a{color:#0078d4;text-decoration:none}
  a:hover{text-decoration:underline}
  .footer{margin-top:20px;color:#586069;font-size:.8rem;text-align:center}
  .expand-all{margin-bottom:15px}
  .expand-all button{padding:8px 16px;border:1px solid #d0d7de;border-radius:6px;background:#fff;cursor:pointer;font-size:.85rem}
  .expand-all button:hover{background:#f6f8fa}
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
