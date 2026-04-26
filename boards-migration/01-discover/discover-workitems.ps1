# ============================================================
#  Discover Work Items - Inventory all ADO work items
#  Phase: 01-discover
#  Output: reports/workitem-inventory.json
# ============================================================

[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\..\config\boards-migration-config.json"
)

$ErrorActionPreference = "Stop"
$reportsDir = Join-Path $PSScriptRoot "..\reports"
$logsDir    = Join-Path $PSScriptRoot "..\logs"
if (-not (Test-Path $reportsDir)) { New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null }
if (-not (Test-Path $logsDir))    { New-Item -ItemType Directory -Path $logsDir    -Force | Out-Null }
$scriptRoot = Split-Path $PSScriptRoot -Parent

# Load helpers
. "$scriptRoot\helpers\logging.ps1"
. "$scriptRoot\helpers\ado-helpers.ps1"

# Load config
$config = Read-JsonConfig -Path $ConfigPath
$adoOrg     = $config.source.organization
$adoProject = $config.source.project
$areaPath   = $config.source.areaPath
$adoPat     = if ($config.source.pat -match '^\$\(') { $env:ADO_PAT } else { $config.source.pat }
$reportDir  = Join-Path $scriptRoot $config.output.reportDir
$logDir     = Join-Path $scriptRoot $config.output.logDir
$includeClosed = $config.migration.migrateClosedWorkItems

# Initialize logging
Initialize-Log -LogPath (Join-Path $logDir "discover-workitems-$(Get-Date -Format 'yyyyMMdd-HHmmss').log")

Write-LogSection "Phase 1: Discover Work Items"
Write-Log -Message "ADO Org: $adoOrg | Project: $adoProject | Area: $areaPath" -Level "INFO"
Write-Log -Message "Include closed items: $includeClosed" -Level "INFO"

# Query work item IDs
Write-Log -Message "Querying ADO work items via WIQL..." -Level "INFO"
$workItemIds = Get-AdoWorkItemIds -Org $adoOrg -Project $adoProject -AreaPath $areaPath -IncludeClosed $includeClosed -Pat $adoPat
Write-Log -Message "Found $($workItemIds.Count) work items" -Level "SUCCESS"

if ($workItemIds.Count -eq 0) {
    Write-Log -Message "No work items found. Check area path filter." -Level "WARN"
    exit 0
}

# Fetch details for each work item
$inventory = @()
$count = 0
foreach ($id in $workItemIds) {
    $count++
    Write-LogProgress -Current $count -Total $workItemIds.Count -ItemName "work items"

    $details = Get-AdoWorkItemDetails -Org $adoOrg -Project $adoProject -WorkItemId $id -Pat $adoPat
    if (-not $details) { continue }

    $parentId = Get-AdoParentId -WorkItemDetails $details
    $childIds = Get-AdoChildIds -WorkItemDetails $details
    $attachments = Get-AdoWorkItemAttachments -WorkItemDetails $details

    $item = @{
        id              = $details.id
        title           = $details.fields.'System.Title'
        workItemType    = $details.fields.'System.WorkItemType'
        state           = $details.fields.'System.State'
        assignedTo      = @{
            displayName = $details.fields.'System.AssignedTo'.displayName
            uniqueName  = $details.fields.'System.AssignedTo'.uniqueName
        }
        areaPath        = $details.fields.'System.AreaPath'
        iterationPath   = $details.fields.'System.IterationPath'
        tags            = $details.fields.'System.Tags'
        priority        = $details.fields.'Microsoft.VSTS.Common.Priority'
        severity        = $details.fields.'Microsoft.VSTS.Common.Severity'
        createdDate     = $details.fields.'System.CreatedDate'
        createdBy       = $details.fields.'System.CreatedBy'.displayName
        changedDate     = $details.fields.'System.ChangedDate'
        changedBy       = $details.fields.'System.ChangedBy'.displayName
        parentId        = $parentId
        childIds        = $childIds
        childCount      = $childIds.Count
        attachmentCount = $attachments.Count
        storyPoints     = $details.fields.'Microsoft.VSTS.Scheduling.StoryPoints'
        effort          = $details.fields.'Microsoft.VSTS.Scheduling.Effort'
        hasDescription  = (-not [string]::IsNullOrEmpty($details.fields.'System.Description'))
        url             = "https://dev.azure.com/$adoOrg/$adoProject/_workitems/edit/$($details.id)"
    }
    $inventory += $item

    # Rate limiting
    Start-Sleep -Milliseconds 200
}

# Summary statistics
$summary = @{
    totalCount      = $inventory.Count
    byType          = @{}
    byState         = @{}
    byAssignee      = @{}
    uniqueStates    = @()
    statesByType    = @{}
    withParent      = ($inventory | Where-Object { $null -ne $_.parentId }).Count
    withChildren    = ($inventory | Where-Object { $_.childCount -gt 0 }).Count
    withAttachments = ($inventory | Where-Object { $_.attachmentCount -gt 0 }).Count
    generatedAt     = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
}

# Count by type
$inventory | Group-Object -Property workItemType | ForEach-Object {
    $summary.byType[$_.Name] = $_.Count
}
# Count by state
$inventory | Group-Object -Property state | ForEach-Object {
    $summary.byState[$_.Name] = $_.Count
}
# Count by assignee
$inventory | ForEach-Object {
    $name = if ($_.assignedTo.displayName) { $_.assignedTo.displayName } else { "Unassigned" }
    if (-not $summary.byAssignee[$name]) { $summary.byAssignee[$name] = 0 }
    $summary.byAssignee[$name]++
}

# Collect unique states (for auto-creating GitHub Project status options)
$summary.uniqueStates = @($inventory | ForEach-Object { $_.state } | Sort-Object -Unique)
$inventory | Group-Object -Property workItemType | ForEach-Object {
    $summary.statesByType[$_.Name] = @($_.Group | ForEach-Object { $_.state } | Sort-Object -Unique)
}
Write-Log -Message "Unique states found: $($summary.uniqueStates -join ', ')" -Level "INFO"

# Collect ALL unique field values for setup guide
$summary.uniquePriorities = @($inventory | Where-Object { $null -ne $_.priority } | ForEach-Object { $_.priority } | Sort-Object -Unique)
$summary.uniqueSeverities = @($inventory | Where-Object { $_.severity } | ForEach-Object { $_.severity } | Sort-Object -Unique)
$summary.uniqueAreaPaths  = @($inventory | ForEach-Object { $_.areaPath } | Sort-Object -Unique)
$summary.uniqueIterations = @($inventory | ForEach-Object { $_.iterationPath } | Sort-Object -Unique)
$summary.uniqueTypes      = @($inventory | ForEach-Object { $_.workItemType } | Sort-Object -Unique)

# Collect all unique tags (split semicolon-separated values)
$allTags = @()
$inventory | ForEach-Object {
    if ($_.tags) { $allTags += ($_.tags -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
}
$summary.uniqueTags = @($allTags | Sort-Object -Unique)

# Story points range
$spValues = @($inventory | Where-Object { $null -ne $_.storyPoints } | ForEach-Object { [double]$_.storyPoints })
$efValues = @($inventory | Where-Object { $null -ne $_.effort } | ForEach-Object { [double]$_.effort })
$summary.storyPointsRange = @{
    min = if ($spValues.Count -gt 0) { ($spValues | Measure-Object -Minimum).Minimum } else { $null }
    max = if ($spValues.Count -gt 0) { ($spValues | Measure-Object -Maximum).Maximum } else { $null }
    count = $spValues.Count
}
$summary.effortRange = @{
    min = if ($efValues.Count -gt 0) { ($efValues | Measure-Object -Minimum).Minimum } else { $null }
    max = if ($efValues.Count -gt 0) { ($efValues | Measure-Object -Maximum).Maximum } else { $null }
    count = $efValues.Count
}

Write-Log -Message "Unique priorities: $($summary.uniquePriorities -join ', ')" -Level "INFO"
Write-Log -Message "Unique severities: $($summary.uniqueSeverities -join ', ')" -Level "INFO"
Write-Log -Message "Unique tags: $($summary.uniqueTags.Count) tags" -Level "INFO"
Write-Log -Message "Unique area paths: $($summary.uniqueAreaPaths -join ', ')" -Level "INFO"
Write-Log -Message "Unique iterations: $($summary.uniqueIterations -join ', ')" -Level "INFO"
Write-Log -Message "Story points: $($summary.storyPointsRange.count) items (range: $($summary.storyPointsRange.min)-$($summary.storyPointsRange.max))" -Level "INFO"

$report = @{ summary = $summary; workItems = $inventory }

# Save report
Save-Report -Data $report -ReportPath (Join-Path $reportDir "workitem-inventory.json")

# Print summary
Write-LogSection "Discovery Summary"
Write-Log -Message "Total work items: $($summary.totalCount)" -Level "INFO"
Write-Log -Message "By Type:" -Level "INFO"
foreach ($t in $summary.byType.GetEnumerator()) { Write-Log -Message "  $($t.Key): $($t.Value)" -Level "INFO" }
Write-Log -Message "By State:" -Level "INFO"
foreach ($s in $summary.byState.GetEnumerator()) { Write-Log -Message "  $($s.Key): $($s.Value)" -Level "INFO" }
Write-Log -Message "Items with parent: $($summary.withParent)" -Level "INFO"
Write-Log -Message "Items with children: $($summary.withChildren)" -Level "INFO"
Write-Log -Message "Items with attachments: $($summary.withAttachments)" -Level "INFO"

Write-Log -Message "Discovery complete! Review: reports/workitem-inventory.json" -Level "SUCCESS"