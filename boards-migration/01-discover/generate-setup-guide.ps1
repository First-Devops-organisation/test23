# ============================================================
#  Generate GitHub Project Setup Guide
#  Reads discovery inventory and generates:
#    1. github-project-setup.json  — machine-readable config for prep phase
#    2. github-project-setup-guide.md — human-readable setup instructions
#
#  This tells you EXACTLY what to set up manually and what the pipeline auto-creates.
# ============================================================

param([string]$configPath)

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

# Load helpers and config
. "$scriptRoot\helpers\logging-helpers.ps1"
. "$scriptRoot\helpers\config-helpers.ps1"

if (-not $configPath) { $configPath = Join-Path $scriptRoot "config\boards-migration-config.json" }
$config = Read-JsonConfig -Path $configPath

$reportDir = Join-Path $scriptRoot $config.output.reportDir
$inventoryPath = Join-Path $reportDir "workitem-inventory.json"

if (-not (Test-Path $inventoryPath)) {
    Write-Log -Message "Discovery inventory not found at: $inventoryPath. Run discover phase first." -Level "ERROR"
    exit 1
}

Write-LogSection "Generating GitHub Project Setup Guide"

$inventory = Read-JsonConfig -Path $inventoryPath
$summary = $inventory.summary

# ============================================================
# PART 1: Generate machine-readable setup config
# ============================================================

$statusMappings = Read-JsonConfig -Path (Join-Path $scriptRoot "config\status-mappings.json")

# Build status-to-column mapping for built-in Status field
$statusColumnMap = @{}
foreach ($state in $summary.uniqueStates) {
    $typeOverrides = $statusMappings.typeOverrides
    $mapped = $statusMappings.defaultMapping.$state
    if ($mapped) {
        $statusColumnMap[$state] = $mapped
    } else {
        # Unknown state — map to "Backlog" as fallback
        $statusColumnMap[$state] = "Backlog"
    }
}

# Determine closed states
$closedStates = @()
if ($statusMappings.closedStates) {
    $closedStates = @($statusMappings.closedStates)
} else {
    $closedStates = @("Closed", "Done", "Resolved", "Removed", "Completed", "Inactive")
}

# Build priority mapping
$priOptions = @()
$priValues = @(1, 2, 3, 4)
$priNames = @{ 1 = "P1 - Critical"; 2 = "P2 - High"; 3 = "P3 - Medium"; 4 = "P4 - Low" }
$priColors = @{ 1 = "RED"; 2 = "ORANGE"; 3 = "YELLOW"; 4 = "GREEN" }
foreach ($p in $priValues) {
    $priOptions += @{ name = $priNames[$p]; color = $priColors[$p]; adoValue = $p }
}

# Build severity mapping
$sevOptions = @()
$sevNames = @("1 - Critical", "2 - High", "3 - Medium", "4 - Low")
$sevColors = @{ "1 - Critical" = "RED"; "2 - High" = "ORANGE"; "3 - Medium" = "YELLOW"; "4 - Low" = "GREEN" }
foreach ($s in $sevNames) {
    $sevOptions += @{ name = $s; color = $sevColors[$s] }
}

# Build ADO Status options with colors
$statusColors = @("BLUE", "GREEN", "YELLOW", "ORANGE", "RED", "PINK", "PURPLE", "GRAY")
$adoStatusOptions = @()
$ci = 0
foreach ($state in $summary.uniqueStates) {
    $adoStatusOptions += @{ name = $state; color = $statusColors[$ci % $statusColors.Count] }
    $ci++
}

# Build labels list
$labels = @()
foreach ($type in $summary.uniqueTypes) {
    $labels += "type:$($type.ToLower() -replace ' ','-')"
}
foreach ($pri in $summary.uniquePriorities) {
    $priLabel = $config.priorityMapping."$pri"
    if ($priLabel) { $labels += $priLabel }
}
if ($summary.uniqueSeverities) {
    foreach ($sev in $summary.uniqueSeverities) {
        $sevLabel = $config.severityMapping.$sev
        if ($sevLabel) { $labels += $sevLabel }
    }
}
foreach ($ap in $config.areaPathMapping.PSObject.Properties) {
    $labels += $ap.Value
}

# API call estimation for 17K items
$itemCount = $summary.totalCount
$apiCallsPerItem = 7  # create issue + add to project + set status + 5 custom fields
$commentItems = ($inventory.workItems | Where-Object { $true }).Count  # rough estimate
$estimatedApiCalls = $itemCount * $apiCallsPerItem
$estimatedMinutes = [math]::Ceiling($estimatedApiCalls / 5000 * 60)  # 5000 calls/hour limit

$setupConfig = @{
    generatedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    sourceProject = "$($config.source.organization)/$($config.source.project)"
    totalWorkItems = $itemCount

    # Built-in Status field setup (MANUAL)
    statusOptions = @{
        description = "Add these options to the built-in Status field via GitHub Project UI"
        required = $summary.uniqueStates
        currentDefaults = @("Backlog", "Ready", "In progress", "In review", "Done")
        columnMapping = $statusColumnMap
    }

    # Custom fields (AUTO-CREATED by pipeline)
    customFields = @{
        adoStatus = @{
            type = "SINGLE_SELECT"
            description = "Exact ADO work item state"
            options = $adoStatusOptions
        }
        priority = @{
            type = "SINGLE_SELECT"
            description = "Work item priority (P1-P4)"
            options = $priOptions
        }
        severity = @{
            type = "SINGLE_SELECT"
            description = "Bug severity level"
            options = $sevOptions
        }
        storyPoints = @{
            type = "NUMBER"
            description = "Story points / effort estimation"
            range = $summary.storyPointsRange
        }
        adoId = @{
            type = "NUMBER"
            description = "Original Azure DevOps work item ID"
        }
    }

    # Labels (AUTO-CREATED by pipeline)
    labels = @($labels | Sort-Object -Unique)

    # Closed states (issues will be created then closed)
    closedStates = $closedStates

    # Estimation
    estimation = @{
        totalApiCalls = $estimatedApiCalls
        estimatedMinutes = $estimatedMinutes
        rateLimitNote = "GitHub REST API: 5000 requests/hour. GraphQL: 5000 points/hour."
    }
}

$setupConfigPath = Join-Path $reportDir "github-project-setup.json"
$setupConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $setupConfigPath -Encoding UTF8
Write-Log -Message "Setup config saved: $setupConfigPath" -Level "SUCCESS"

# ============================================================
# PART 2: Generate human-readable setup guide
# ============================================================

$closedCount = ($inventory.workItems | Where-Object { $_.state -in $closedStates }).Count
$openCount = $itemCount - $closedCount

$guide = @"
# GitHub Project Setup Guide
> Auto-generated by discovery pipeline on $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
> Source: $($config.source.organization) / $($config.source.project)

---

## Migration Overview

| Metric | Value |
|:--|:--|
| Total Work Items | $itemCount |
| Open Items | $openCount |
| Closed Items | $closedCount |
| Work Item Types | $($summary.uniqueTypes.Count) ($($summary.uniqueTypes -join ', ')) |
| Unique States | $($summary.uniqueStates.Count) ($($summary.uniqueStates -join ', ')) |
| Unique Tags | $($summary.uniqueTags.Count) |
| Items with Attachments | $($summary.withAttachments) |
| Items with Children | $($summary.withChildren) |
| Estimated API Calls | ~$estimatedApiCalls |
| Estimated Migration Time | ~$estimatedMinutes minutes |

---

## MANUAL SETUP REQUIRED (1 step)

### Add Status Options to GitHub Project

Go to: **GitHub Project → Settings → Status** field

The pipeline maps ADO states to board columns. For **exact board column replication**, add these status options:

| # | Status Option to Add | Current Column Mapping |
|:--|:--|:--|
"@

$idx = 1
foreach ($state in $summary.uniqueStates) {
    $mapping = $statusColumnMap[$state]
    $guide += "| $idx | **$state** | $mapping |`n"
    $idx++
}

$guide += @"

**How to add:**
1. Open: ``https://github.com/users/$($config.target.organization)/projects/$($config.target.projectNumber)/settings/fields/Status``
2. Scroll to bottom → Click **"Add option..."**
3. Type each status name exactly as shown above
4. Click **Add** for each one

> **If you skip this step:** Migration still works! Items will use the column mapping above (e.g., "New" → "Backlog"). The custom `ADO Status` field always shows the exact ADO state regardless.

---

## AUTO-CREATED BY PIPELINE (no action needed)

### Custom Fields (5 fields)

| Field | Type | Options / Range |
|:--|:--|:--|
| **ADO Status** | Single Select | $($summary.uniqueStates -join ', ') |
| **Priority** | Single Select | P1 - Critical, P2 - High, P3 - Medium, P4 - Low |
| **Severity** | Single Select | 1 - Critical, 2 - High, 3 - Medium, 4 - Low |
| **Story Points** | Number | Range: $($summary.storyPointsRange.min) - $($summary.storyPointsRange.max) ($($summary.storyPointsRange.count) items) |
| **ADO ID** | Number | Original work item ID for cross-reference |

### Labels ($($labels.Count) labels)

"@

# Group labels by type
$typeLabels = @($labels | Where-Object { $_ -match "^type:" })
$priLabels  = @($labels | Where-Object { $_ -match "^priority:" })
$sevLabels  = @($labels | Where-Object { $_ -match "^severity:" })
$areaLabels = @($labels | Where-Object { $_ -match "^area:" })
$otherLabels = @($labels | Where-Object { $_ -notmatch "^(type|priority|severity|area):" })

$guide += "| Category | Labels |`n"
$guide += "|:--|:--|`n"
if ($typeLabels) { $guide += "| Type | $($typeLabels -join ', ') |`n" }
if ($priLabels)  { $guide += "| Priority | $($priLabels -join ', ') |`n" }
if ($sevLabels)  { $guide += "| Severity | $($sevLabels -join ', ') |`n" }
if ($areaLabels) { $guide += "| Area | $($areaLabels -join ', ') |`n" }
if ($otherLabels) { $guide += "| Other | $($otherLabels -join ', ') |`n" }

$guide += @"

---

## Items by Type and State

"@

$guide += "| Type |"
foreach ($state in $summary.uniqueStates) { $guide += " $state |" }
$guide += " Total |`n"
$guide += "|:--|"
foreach ($state in $summary.uniqueStates) { $guide += ":--|" }
$guide += ":--|`n"

foreach ($type in $summary.uniqueTypes) {
    $guide += "| $type |"
    $typeTotal = 0
    foreach ($state in $summary.uniqueStates) {
        $c = @($inventory.workItems | Where-Object { $_.workItemType -eq $type -and $_.state -eq $state }).Count
        $typeTotal += $c
        $guide += " $c |"
    }
    $guide += " $typeTotal |`n"
}

$guide += @"

---

## Closed States

Items in these states will be **created as closed issues** in GitHub:

"@
foreach ($cs in $closedStates) {
    $csCount = @($inventory.workItems | Where-Object { $_.state -eq $cs }).Count
    if ($csCount -gt 0) {
        $guide += "- **$cs** ($csCount items)`n"
    }
}

$guide += @"

---

## Tags Found ($($summary.uniqueTags.Count))

"@
if ($summary.uniqueTags.Count -gt 0) {
    $guide += "``$($summary.uniqueTags -join '``, ``')```n"
}

$guide += @"

---

## Next Steps

1. **Add Status options** (see Manual Setup section above) — or skip for default mapping
2. **Run the full pipeline** with ``phase = all``, ``dryRun = false``, ``resume = false``
3. **Verify** the migration report and spot-check items in GitHub Project
"@

$guidePath = Join-Path $reportDir "github-project-setup-guide.md"
$guide | Set-Content -Path $guidePath -Encoding UTF8
Write-Log -Message "Setup guide saved: $guidePath" -Level "SUCCESS"

Write-Log -Message "Setup guide generation complete!" -Level "SUCCESS"
Write-Log -Message "  Config: $setupConfigPath" -Level "INFO"
Write-Log -Message "  Guide:  $guidePath" -Level "INFO"
