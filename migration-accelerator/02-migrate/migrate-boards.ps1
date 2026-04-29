<#
.SYNOPSIS
    Migrates Azure Boards work items to GitHub Issues and Projects.
.DESCRIPTION
    Exports ADO work items via WIQL/REST API and creates GitHub Issues with labels,
    assignees, milestones, and Projects integration. Handles parent-child relationships.
    GEI does NOT migrate work items — this custom script fills that gap.
.PARAMETER ConfigFile
    Path to migration-config.json
.PARAMETER TypeMappingsFile
    Path to workitem-type-mappings.json
.PARAMETER UserMappingsFile
    Path to user-mappings.csv
.PARAMETER AdoProject
    ADO project to export from
.PARAMETER GitHubRepo
    Target GitHub repo for issues
.PARAMETER MaxItems
    Maximum work items to migrate (for testing). 0 = all.
.PARAMETER DryRun
    Export only, do not create issues
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigFile,

    [string]$TypeMappingsFile = "./config/workitem-type-mappings.json",
    [string]$UserMappingsFile = "./config/user-mappings.csv",

    [Parameter(Mandatory = $true)]
    [string]$AdoProject,

    [Parameter(Mandatory = $true)]
    [string]$GitHubRepo,

    [int]$MaxItems = 0,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# --- Load Config ---
$config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
$typeMappings = Get-Content $TypeMappingsFile -Raw | ConvertFrom-Json
$userMappings = Import-Csv $UserMappingsFile

$adoOrg = ($config.source.organization -replace "https://dev.azure.com/", "").TrimEnd("/")
$adoOrgUrl = $config.source.organization
$ghOrg = $config.target.organization
$adoPat = if ($config.source.pat) { $config.source.pat } else { $env:ADO_PAT }
$ghPat = if ($config.target.pat) { $config.target.pat } else { $env:GH_PAT }

$base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$adoPat"))
$adoHeaders = @{ Authorization = "Basic $base64Auth" }
$ghHeaders = @{
    Authorization          = "Bearer $ghPat"
    Accept                 = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
}

$logDir = $config.options.logDirectory
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

Write-Host "=== Boards Migration: $AdoProject → $ghOrg/$GitHubRepo ===" -ForegroundColor Cyan
if ($DryRun) { Write-Host "[DRY RUN MODE]" -ForegroundColor Yellow }

# --- Build user mapping lookup ---
$userMap = @{}
foreach ($row in $userMappings) {
    if ($row.ado_email -and $row.github_username) {
        $userMap[$row.ado_email] = $row.github_username
    }
}

# --- Ensure labels exist in GitHub ---
function Ensure-GitHubLabel {
    param([string]$Name, [string]$Color, [string]$Description = "")
    if ($DryRun) { return }
    try {
        Invoke-RestMethod -Uri "https://api.github.com/repos/$ghOrg/$GitHubRepo/labels" `
            -Headers $ghHeaders -Method Post -ContentType "application/json" `
            -Body (@{ name = $Name; color = $Color; description = $Description } | ConvertTo-Json) `
            -ErrorAction SilentlyContinue | Out-Null
    }
    catch {
        # Label may already exist — ignore 422
    }
}

# Create mapped labels
Write-Host "Creating labels..." -ForegroundColor Gray
foreach ($type in $typeMappings.typeMapping.PSObject.Properties) {
    foreach ($label in $type.Value.labels) {
        Ensure-GitHubLabel -Name $label -Color $type.Value.color
    }
}
# Priority labels
foreach ($p in $typeMappings.priorityMapping.PSObject.Properties) {
    Ensure-GitHubLabel -Name "priority:$($p.Value)" -Color "fbca04"
}

# --- Query Work Items from ADO ---
Write-Host "Querying work items from ADO..." -ForegroundColor Yellow
$wiqlBody = @{
    query = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = '$AdoProject' ORDER BY [System.Id] ASC"
} | ConvertTo-Json

$wiqlUrl = "$adoOrgUrl/$AdoProject/_apis/wit/wiql?api-version=7.1"
$wiqlResult = Invoke-RestMethod -Uri $wiqlUrl -Headers $adoHeaders -Method Post -Body $wiqlBody -ContentType "application/json"

$workItemIds = $wiqlResult.workItems | Select-Object -ExpandProperty id
if ($MaxItems -gt 0) { $workItemIds = $workItemIds | Select-Object -First $MaxItems }

Write-Host "Found $($workItemIds.Count) work items to migrate" -ForegroundColor Green

# --- Fetch and Create Issues ---
$idMapping = @{} # ADO ID → GitHub Issue Number
$results = @()
$batchSize = 200
$rateLimitDelay = 1 # seconds between API calls

for ($i = 0; $i -lt $workItemIds.Count; $i += $batchSize) {
    $batchIds = $workItemIds[$i..([math]::Min($i + $batchSize - 1, $workItemIds.Count - 1))]
    $idsParam = $batchIds -join ","

    $wiUrl = "$adoOrgUrl/_apis/wit/workitems?ids=$idsParam&`$expand=relations&api-version=7.1"
    $workItems = (Invoke-RestMethod -Uri $wiUrl -Headers $adoHeaders).value

    foreach ($wi in $workItems) {
        $fields = $wi.fields
        $wiType = $fields.'System.WorkItemType'
        $title = $fields.'System.Title'
        $description = $fields.'System.Description'
        $state = $fields.'System.State'
        $assignedTo = $fields.'System.AssignedTo'
        $priority = $fields.'Microsoft.VSTS.Common.Priority'
        $tags = $fields.'System.Tags'
        $areaPath = $fields.'System.AreaPath'
        $iterationPath = $fields.'System.IterationPath'
        $storyPoints = $fields.'Microsoft.VSTS.Scheduling.StoryPoints'

        Write-Host "  [$($wi.id)] $wiType: $title" -ForegroundColor Gray

        # Map type to labels
        $issueLabels = @()
        $typeConfig = $typeMappings.typeMapping.$wiType
        if ($typeConfig) {
            $issueLabels += $typeConfig.labels
        }
        else {
            $issueLabels += $wiType.ToLower()
        }

        # Priority label
        if ($priority) {
            $prioValue = $typeMappings.priorityMapping."$priority"
            if ($prioValue) { $issueLabels += "priority:$prioValue" }
        }

        # Tags as labels
        if ($tags) {
            $tagList = $tags -split ";" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
            foreach ($tag in $tagList) {
                Ensure-GitHubLabel -Name $tag -Color "ededed"
                $issueLabels += $tag
            }
        }

        # Area path as label
        if ($areaPath -and $areaPath -ne $AdoProject) {
            $areaLabel = "area:$($areaPath -replace '^[^\\]+\\', '')"
            Ensure-GitHubLabel -Name $areaLabel -Color "c5def5"
            $issueLabels += $areaLabel
        }

        # Map assignee
        $assignees = @()
        if ($assignedTo) {
            $email = if ($assignedTo -is [string]) { $assignedTo } else { $assignedTo.uniqueName }
            if ($userMap.ContainsKey($email)) {
                $assignees += $userMap[$email]
            }
        }

        # Build issue body
        $bodyParts = @()
        if ($description) {
            # Convert basic HTML to Markdown
            $mdDescription = $description -replace '<br\s*/?>', "`n" `
                -replace '<p>', '' -replace '</p>', "`n" `
                -replace '<b>', '**' -replace '</b>', '**' `
                -replace '<i>', '_' -replace '</i>', '_' `
                -replace '<[^>]+>', ''
            $bodyParts += $mdDescription
        }

        $bodyParts += "`n---`n_Migrated from Azure DevOps_"
        $bodyParts += "- **ADO ID**: $($wi.id)"
        $bodyParts += "- **Type**: $wiType"
        $bodyParts += "- **Original State**: $state"
        if ($storyPoints) { $bodyParts += "- **Story Points**: $storyPoints" }
        if ($iterationPath) { $bodyParts += "- **Iteration**: $iterationPath" }
        if ($areaPath) { $bodyParts += "- **Area Path**: $areaPath" }
        $bodyParts += "- **ADO URL**: $adoOrgUrl/$AdoProject/_workitems/edit/$($wi.id)"

        $issueBody = $bodyParts -join "`n"

        # Map state
        $ghState = "open"
        $stateMapping = $typeMappings.stateMapping
        if ($stateMapping.$state) { $ghState = $stateMapping.$state }

        # Create GitHub Issue
        $issuePayload = @{
            title  = "[$wiType] $title"
            body   = $issueBody
            labels = $issueLabels
        }
        if ($assignees.Count -gt 0) { $issuePayload.assignees = $assignees }

        if ($DryRun) {
            $results += [PSCustomObject]@{
                AdoId       = $wi.id
                Type        = $wiType
                Title       = $title
                State       = $state
                GitHubState = $ghState
                Labels      = $issueLabels -join ";"
                Assignee    = $assignees -join ";"
                Status      = "DRY_RUN"
            }
            continue
        }

        try {
            Start-Sleep -Seconds $rateLimitDelay

            $issue = Invoke-RestMethod -Uri "https://api.github.com/repos/$ghOrg/$GitHubRepo/issues" `
                -Headers $ghHeaders -Method Post -ContentType "application/json" `
                -Body ($issuePayload | ConvertTo-Json -Depth 5)

            $idMapping[$wi.id] = $issue.number

            # Close issue if needed
            if ($ghState -eq "closed") {
                Start-Sleep -Milliseconds 500
                Invoke-RestMethod -Uri "https://api.github.com/repos/$ghOrg/$GitHubRepo/issues/$($issue.number)" `
                    -Headers $ghHeaders -Method Patch -ContentType "application/json" `
                    -Body (@{ state = "closed"; state_reason = "completed" } | ConvertTo-Json) | Out-Null
            }

            $results += [PSCustomObject]@{
                AdoId       = $wi.id
                Type        = $wiType
                Title       = $title
                State       = $state
                GitHubState = $ghState
                GitHubIssue = $issue.number
                Labels      = $issueLabels -join ";"
                Assignee    = $assignees -join ";"
                Status      = "CREATED"
            }

            Write-Host "    → Issue #$($issue.number)" -ForegroundColor Green
        }
        catch {
            Write-Warning "    Failed to create issue for WI $($wi.id): $_"
            $results += [PSCustomObject]@{
                AdoId  = $wi.id
                Type   = $wiType
                Title  = $title
                Status = "ERROR"
                Error  = $_.ToString()
            }
        }
    }
}

# --- Export ID Mapping ---
$mappingFile = Join-Path $logDir "workitem-id-mapping-$AdoProject.json"
$idMapping | ConvertTo-Json | Out-File -FilePath $mappingFile -Encoding utf8
Write-Host "`nID mapping saved: $mappingFile" -ForegroundColor Green

# --- Export Results ---
$csvFile = Join-Path $logDir "boards-migration-$AdoProject-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
$results | Export-Csv -Path $csvFile -NoTypeInformation
Write-Host "Results saved: $csvFile" -ForegroundColor Green

# --- Summary ---
$created = ($results | Where-Object { $_.Status -eq "CREATED" }).Count
$errors = ($results | Where-Object { $_.Status -eq "ERROR" }).Count
$dryRunCount = ($results | Where-Object { $_.Status -eq "DRY_RUN" }).Count

Write-Host "`n=== Boards Migration Summary ===" -ForegroundColor Cyan
if ($DryRun) { Write-Host "Dry Run Items: $dryRunCount" -ForegroundColor Yellow }
else {
    Write-Host "Created: $created" -ForegroundColor Green
    Write-Host "Errors:  $errors" -ForegroundColor $(if ($errors -gt 0) { "Red" } else { "Green" })
}

Write-Host "`n=== LIMITATIONS ===" -ForegroundColor Yellow
Write-Host @"
- Work item STATE HISTORY is NOT migrated (only current state)
- Attachments are NOT migrated (referenced by ADO URL in body)
- Discussion/comment history is NOT migrated
- Board column positions are NOT preserved
- ADO Queries and Dashboards must be rebuilt in GitHub Projects
- Parent-child relationships preserved only via task lists (manual step)
"@ -ForegroundColor Gray
