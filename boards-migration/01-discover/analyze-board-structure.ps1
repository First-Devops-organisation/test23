# ============================================================
#  Analyze Board Structure - Detect hierarchy, fields, states
#  Phase: 01-discover
#  Input:  reports/workitem-inventory.json
#  Output: reports/board-analysis.json
# ============================================================

[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\..\config\boards-migration-config.json"
)

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path $PSScriptRoot -Parent

. "$scriptRoot\helpers\logging.ps1"
. "$scriptRoot\helpers\ado-helpers.ps1"

$config    = Read-JsonConfig -Path $ConfigPath
$reportDir = Join-Path $scriptRoot $config.output.reportDir
$logDir    = Join-Path $scriptRoot $config.output.logDir

Initialize-Log -LogPath (Join-Path $logDir "analyze-board-$(Get-Date -Format 'yyyyMMdd-HHmmss').log")

Write-LogSection "Phase 1b: Analyze Board Structure"

# Load inventory
$inventoryPath = Join-Path $reportDir "workitem-inventory.json"
if (-not (Test-Path $inventoryPath)) {
    Write-Log -Message "Inventory not found. Run discover-workitems.ps1 first." -Level "ERROR"
    exit 1
}
$inventory = Read-JsonConfig -Path $inventoryPath

# Load mapping configs
$userMappings      = Read-JsonConfig -Path (Join-Path $scriptRoot "config\user-mappings.json")
$statusMappings    = Read-JsonConfig -Path (Join-Path $scriptRoot "config\status-mappings.json")
$typeMappings      = Read-JsonConfig -Path (Join-Path $scriptRoot "config\workitem-type-mappings.json")

$items = $inventory.workItems

# --- Unique States per Work Item Type ---
$statesByType = @{}
foreach ($item in $items) {
    $type = $item.workItemType
    if (-not $statesByType[$type]) { $statesByType[$type] = @() }
    if ($item.state -and $item.state -notin $statesByType[$type]) {
        $statesByType[$type] += $item.state
    }
}

# --- Unique Area Paths ---
$areaPaths = ($items | ForEach-Object { $_.areaPath } | Sort-Object -Unique)

# --- Unique Iteration Paths ---
$iterationPaths = ($items | ForEach-Object { $_.iterationPath } | Sort-Object -Unique)

# --- Unique Tags ---
$allTags = @()
foreach ($item in $items) {
    if ($item.tags) {
        $tags = $item.tags -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        $allTags += $tags
    }
}
$uniqueTags = $allTags | Sort-Object -Unique

# --- Hierarchy Depth Analysis ---
$parentMap = @{}
foreach ($item in $items) {
    $parentMap[$item.id] = $item.parentId
}

function Get-HierarchyDepth {
    param([int]$ItemId, [hashtable]$Map, [int]$MaxDepth = 10)
    $depth = 0; $current = $ItemId
    while ($Map.ContainsKey($current) -and $null -ne $Map[$current] -and $depth -lt $MaxDepth) {
        $depth++; $current = $Map[$current]
    }
    return $depth
}

$depthDistribution = @{}
foreach ($item in $items) {
    $depth = Get-HierarchyDepth -ItemId $item.id -Map $parentMap
    $key = "depth_$depth"
    if (-not $depthDistribution[$key]) { $depthDistribution[$key] = 0 }
    $depthDistribution[$key]++
}

# --- Unmapped Users Check ---
$mappedEmails = @()
foreach ($m in $userMappings.mappings) {
    $mappedEmails += $m.adoEmail
    $mappedEmails += $m.adoAlternateEmails
}
$unmappedUsers = @()
foreach ($item in $items) {
    $email = $item.assignedTo.uniqueName
    if ($email -and $email -notin $mappedEmails -and $email -notin $unmappedUsers) {
        $unmappedUsers += $email
    }
}

# --- Unmapped States Check ---
$unmappedStates = @()
$defaultMap = $statusMappings.defaultMapping
foreach ($type in $statesByType.Keys) {
    foreach ($state in $statesByType[$type]) {
        $typeOverride = $statusMappings.typeOverrides.$type
        $mapped = if ($typeOverride -and $typeOverride.$state) { $typeOverride.$state } else { $defaultMap.$state }
        if (-not $mapped -and $state -notin $unmappedStates) {
            $unmappedStates += "${type}::$state"
        }
    }
}

# --- Unmapped Work Item Types ---
$knownTypes = $typeMappings.types.PSObject.Properties.Name
$unmappedTypes = ($items | ForEach-Object { $_.workItemType } | Sort-Object -Unique) | Where-Object { $_ -notin $knownTypes }

# --- Build Analysis Report ---
$analysis = @{
    generatedAt       = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    totalWorkItems    = $items.Count
    statesByType      = $statesByType
    areaPaths         = $areaPaths
    iterationPaths    = $iterationPaths
    uniqueTags        = $uniqueTags
    tagCount          = $uniqueTags.Count
    hierarchyDepth    = $depthDistribution
    maxDepth          = ($depthDistribution.Keys | ForEach-Object { [int]($_ -replace 'depth_','') } | Measure-Object -Maximum).Maximum
    unmappedUsers     = $unmappedUsers
    unmappedStates    = $unmappedStates
    unmappedTypes     = $unmappedTypes
    readiness         = @{
        usersReady    = ($unmappedUsers.Count -eq 0)
        statesReady   = ($unmappedStates.Count -eq 0)
        typesReady    = ($unmappedTypes.Count -eq 0)
        overallReady  = ($unmappedUsers.Count -eq 0 -and $unmappedStates.Count -eq 0 -and $unmappedTypes.Count -eq 0)
    }
}

Save-Report -Data $analysis -ReportPath (Join-Path $reportDir "board-analysis.json")

# Print results
Write-LogSection "Board Analysis Results"
Write-Log -Message "Area Paths: $($areaPaths -join ', ')" -Level "INFO"
Write-Log -Message "Iteration Paths: $($iterationPaths -join ', ')" -Level "INFO"
Write-Log -Message "Unique Tags: $($uniqueTags.Count)" -Level "INFO"
Write-Log -Message "Max Hierarchy Depth: $($analysis.maxDepth)" -Level "INFO"

if ($unmappedUsers.Count -gt 0) {
    Write-Log -Message "UNMAPPED USERS ($($unmappedUsers.Count)): $($unmappedUsers -join ', ')" -Level "WARN"
    Write-Log -Message "  → Add these to config/user-mappings.json" -Level "WARN"
}
if ($unmappedStates.Count -gt 0) {
    Write-Log -Message "UNMAPPED STATES ($($unmappedStates.Count)): $($unmappedStates -join ', ')" -Level "WARN"
    Write-Log -Message "  → Add these to config/status-mappings.json" -Level "WARN"
}
if ($unmappedTypes.Count -gt 0) {
    Write-Log -Message "UNMAPPED TYPES ($($unmappedTypes.Count)): $($unmappedTypes -join ', ')" -Level "WARN"
    Write-Log -Message "  → Add these to config/workitem-type-mappings.json" -Level "WARN"
}

if ($analysis.readiness.overallReady) {
    Write-Log -Message "All mappings are complete. Ready to migrate!" -Level "SUCCESS"
} else {
    Write-Log -Message "Fix mapping gaps above before proceeding to migration." -Level "WARN"
}