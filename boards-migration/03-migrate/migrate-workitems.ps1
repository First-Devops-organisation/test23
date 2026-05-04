# ============================================================
#  Migrate Work Items - Main migration engine
#  Phase: 03-migrate
#  Migrates ADO work items â†’ GitHub Issues + ProjectV2
#  Handles: hierarchy, comments, images, attachments, status,
#           assignees, labels, tags, parent-child links
# ============================================================

[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\..\config\boards-migration-config.json",
    [switch]$DryRun,
    [switch]$Resume
)

$ErrorActionPreference = "Stop"

# Ensure output directories exist
$reportsDir = Join-Path $PSScriptRoot "..\reports"
$logsDir    = Join-Path $PSScriptRoot "..\logs"
if (-not (Test-Path $reportsDir)) { New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null }
if (-not (Test-Path $logsDir))    { New-Item -ItemType Directory -Path $logsDir    -Force | Out-Null }
$scriptRoot = Split-Path $PSScriptRoot -Parent

. "$scriptRoot\helpers\logging.ps1"
. "$scriptRoot\helpers\ado-helpers.ps1"
. "$scriptRoot\helpers\github-helpers.ps1"

# --- Load all configs ---
$config         = Read-JsonConfig -Path $ConfigPath
$userMappings   = Read-JsonConfig -Path (Join-Path $scriptRoot "config\user-mappings.json")
$statusMappings = Read-JsonConfig -Path (Join-Path $scriptRoot "config\status-mappings.json")
$typeMappings   = Read-JsonConfig -Path (Join-Path $scriptRoot "config\workitem-type-mappings.json")

# --- Extract settings ---
$adoOrg       = $config.source.organization
$adoProject   = $config.source.project
$areaPath     = $config.source.areaPath
$adoPat       = if ($config.source.pat -match '^\$\(') { $env:ADO_PAT } else { $config.source.pat }
$ghOrg            = $config.target.organization
$ghRepo           = $config.target.repository
$ghProjNum        = $config.target.projectNumber
$ghProjectOwner = [string]$config.target.projectOwner
$ghProjectOwnerType = [string]$config.target.projectOwnerType
if ([string]::IsNullOrEmpty($ghProjectOwner)) { $ghProjectOwner = $ghOrg }
if ([string]::IsNullOrEmpty($ghProjectOwnerType)) { $ghProjectOwnerType = "user" }
$ghPat            = if ($config.target.pat -match '^\$\(') { $env:GH_PAT } else { $config.target.pat }
$reportDir    = Join-Path $scriptRoot $config.output.reportDir
$logDir       = Join-Path $scriptRoot $config.output.logDir
$tempDir      = Join-Path $scriptRoot "tmp"
$migLogPath   = Join-Path $scriptRoot $config.output.migrationLogFile

$includeClosed     = $config.migration.migrateClosedWorkItems
$productionRun     = $config.migration.productionRun
$updateAssignees   = $config.migration.updateAssignedTo
$addComments       = $config.migration.addAdoComments
$migrateAttach     = $config.migration.migrateAttachments
$preserveHierarchy = $config.migration.preserveParentChild
$rateLimitMs       = $config.migration.rateLimitDelayMs

Initialize-Log -LogPath (Join-Path $logDir "migrate-$(Get-Date -Format 'yyyyMMdd-HHmmss').log")

if ($DryRun) { Write-Log -Message "*** DRY RUN MODE - No changes will be made ***" -Level "WARN" }

Write-LogSection "Phase 3: Migrate Work Items"

# --- Build user lookup hashtable ---
$userLookup = @{}
foreach ($m in $userMappings.mappings) {
    if ($m.githubUsername) {
        $userLookup[$m.adoEmail.ToLower()] = $m.githubUsername
        foreach ($alt in $m.adoAlternateEmails) {
            if ($alt) { $userLookup[$alt.ToLower()] = $m.githubUsername }
        }
    }
}

# --- Load or init migration log (for resume support) ---
$migrationLog = @{}
if ($Resume -and (Test-Path $migLogPath)) {
    $existing = Get-Content $migLogPath -Raw | ConvertFrom-Json
    foreach ($prop in $existing.PSObject.Properties) {
        $migrationLog[$prop.Name] = $prop.Value
    }
    Write-Log -Message "Resuming: $($migrationLog.Count) items already migrated" -Level "INFO"
}

# --- Load closed states (for auto-closing issues) ---
$closedStates = @("Closed", "Done", "Resolved", "Removed", "Completed", "Inactive")
$closedStatesPath = Join-Path $scriptRoot $config.output.reportDir "closed-states.json"
if (Test-Path $closedStatesPath) {
    $csData = Read-JsonConfig -Path $closedStatesPath
    if ($csData.closedStates) { $closedStates = @($csData.closedStates) }
}
Write-Log -Message "Closed states: $($closedStates -join ', ')" -Level "INFO"

# --- Get GitHub Project info ---
$ghProjectId = $null; $statusField = $null; $statusOptions = $null
if ($ghProjNum) {
    Write-Log -Message "Fetching GitHub Project #$ghProjNum..." -Level "INFO"
    $ghProjectId = Get-GhProjectId -Owner $ghProjectOwner -ProjectNumber $ghProjNum -Pat $ghPat -OwnerType $ghProjectOwnerType
    Write-Log -Message "Project ID: $ghProjectId" -Level "INFO"
    $fields = Get-GhProjectFields -ProjectId $ghProjectId -Pat $ghPat
    $statusField = $fields | Where-Object { $_.__typename -eq "ProjectV2SingleSelectField" -and $_.name -eq "Status" }
    if ($statusField) {
        $statusOptions = $statusField.options
        Write-Log -Message "Status options: $(($statusOptions | ForEach-Object { $_.name }) -join ', ')" -Level "INFO"
    }

    # Load ALL project fields for enterprise migration
    $adoStatusField = $fields | Where-Object { $_.__typename -eq "ProjectV2SingleSelectField" -and $_.name -eq "ADO Status" }
    $itemTypeField  = $fields | Where-Object { $_.__typename -eq "ProjectV2SingleSelectField" -and $_.name -eq "Item Type" }
    $severityField  = $fields | Where-Object { $_.__typename -eq "ProjectV2SingleSelectField" -and $_.name -eq "Severity" -and $_.options }
    $storyPtsField  = $fields | Where-Object { $_.name -eq "Story Points" }
    $adoIdField     = $fields | Where-Object { $_.name -eq "ADO ID" }
    $valueAreaField = $fields | Where-Object { $_.__typename -eq "ProjectV2SingleSelectField" -and $_.name -eq "Value Area" }

    # Priority field - find it (built-in OR custom) and read its actual options
    $priorityField = $fields | Where-Object { $_.__typename -eq "ProjectV2SingleSelectField" -and $_.name -eq "Priority" }
    $priorityOptionMap = @{}
    if ($priorityField -and $priorityField.options) {
        Write-Log -Message "Priority field found with $($priorityField.options.Count) options:" -Level "INFO"
        foreach ($opt in $priorityField.options) {
            Write-Log -Message "  Option: '$($opt.name)' (id: $($opt.id))" -Level "INFO"
        }
        # Build dynamic mapping: ADO Priority 1-4 → GitHub options by smart matching
        $opts = @($priorityField.options)
        foreach ($adoPri in @(1, 2, 3, 4)) {
            $matched = $null
            # Try exact name matches first (our custom P1-P4)
            $matched = $opts | Where-Object { $_.name -eq "P$adoPri - Critical" -or $_.name -eq "P$adoPri - High" -or $_.name -eq "P$adoPri - Medium" -or $_.name -eq "P$adoPri - Low" } | Select-Object -First 1
            # Try GitHub built-in format: "P0", "P1", etc (GitHub uses 0-indexed)
            if (-not $matched) { $matched = $opts | Where-Object { $_.name -match "P$($adoPri - 1)\b" } | Select-Object -First 1 }
            # Try name contains keywords
            if (-not $matched -and $adoPri -eq 1) { $matched = $opts | Where-Object { $_.name -match "urgent|critical|p0|p1" } | Select-Object -First 1 }
            if (-not $matched -and $adoPri -eq 2) { $matched = $opts | Where-Object { $_.name -match "high|p1|p2" } | Select-Object -First 1 }
            if (-not $matched -and $adoPri -eq 3) { $matched = $opts | Where-Object { $_.name -match "medium|p2|p3" } | Select-Object -First 1 }
            if (-not $matched -and $adoPri -eq 4) { $matched = $opts | Where-Object { $_.name -match "low|p3|p4" } | Select-Object -First 1 }
            # Fallback: map by position index
            if (-not $matched -and ($adoPri - 1) -lt $opts.Count) { $matched = $opts[$adoPri - 1] }
            if ($matched) {
                $priorityOptionMap[$adoPri] = $matched
                Write-Log -Message "  ADO Priority $adoPri → '$($matched.name)'" -Level "INFO"
            }
        }
    } else {
        Write-Log -Message "Priority field NOT found or has no options" -Level "WARN"
    }

    # Size field (built-in GitHub field)
    $sizeField = $fields | Where-Object { $_.__typename -eq "ProjectV2SingleSelectField" -and $_.name -eq "Size" }
    # Estimate field (built-in number field)
    $estimateField = $fields | Where-Object { $_.name -eq "Estimate" }
    # Iteration field (built-in)
    $iterationField = $fields | Where-Object { $_.__typename -eq "ProjectV2IterationField" -and $_.name -eq "Iteration" }

    # Log all discovered fields
    if ($adoStatusField) { Write-Log -Message "Field 'ADO Status': $($adoStatusField.options.Count) options" -Level "INFO" }
    if ($itemTypeField)  { Write-Log -Message "Field 'Item Type': $($itemTypeField.options.Count) options" -Level "INFO" }
    if ($severityField)  { Write-Log -Message "Field 'Severity': $($severityField.options.Count) options" -Level "INFO" }
    if ($storyPtsField)  { Write-Log -Message "Field 'Story Points': ready (number)" -Level "INFO" }
    if ($adoIdField)     { Write-Log -Message "Field 'ADO ID': ready" -Level "INFO" }
    if ($valueAreaField) { Write-Log -Message "Field 'Value Area': $($valueAreaField.options.Count) options" -Level "INFO" }
    if ($sizeField)      { Write-Log -Message "Field 'Size': $($sizeField.options.Count) options" -Level "INFO" }
    if ($estimateField)  { Write-Log -Message "Field 'Estimate': ready (number)" -Level "INFO" }
    if ($iterationField) { Write-Log -Message "Field 'Iteration': ready" -Level "INFO" }

    # --- Discover ALL 20 custom fields from Master Plan ---
    $activityField       = $fields | Where-Object { $_.__typename -eq "ProjectV2SingleSelectField" -and $_.name -eq "Activity" }
    $envField            = $fields | Where-Object { $_.__typename -eq "ProjectV2SingleSelectField" -and $_.name -eq "Current Environment" }
    $itemCategoryField   = $fields | Where-Object { $_.__typename -eq "ProjectV2SingleSelectField" -and $_.name -eq "Item Category" }
    $itemSubCatField     = $fields | Where-Object { $_.name -eq "Item SubCategory" }
    $origEstimateField   = $fields | Where-Object { $_.name -eq "Original Estimate (hrs)" }
    $completedWorkField  = $fields | Where-Object { $_.name -eq "Completed Work (hrs)" }
    $remainingWorkField  = $fields | Where-Object { $_.name -eq "Remaining Work (hrs)" }
    $riskField           = $fields | Where-Object { $_.__typename -eq "ProjectV2SingleSelectField" -and $_.name -eq "Risk" }
    $tShirtField         = $fields | Where-Object { $_.__typename -eq "ProjectV2SingleSelectField" -and $_.name -eq "T-Shirt Size" }
    $areaPathTextField   = $fields | Where-Object { $_.name -eq "Area Path" }
    $iterPathTextField   = $fields | Where-Object { $_.name -eq "Iteration Path" }
    $startDateField      = $fields | Where-Object { $_.name -eq "Start Date" }
    $targetDateField     = $fields | Where-Object { $_.name -eq "Target Date" }
    $valueStreamField    = $fields | Where-Object { $_.__typename -eq "ProjectV2SingleSelectField" -and $_.name -eq "Value Stream" }

    # Log new field discovery
    $newFields = @($activityField, $envField, $itemCategoryField, $itemSubCatField,
        $origEstimateField, $completedWorkField, $remainingWorkField, $riskField,
        $tShirtField, $areaPathTextField, $iterPathTextField, $startDateField,
        $targetDateField, $valueStreamField)
    $discoveredCount = ($newFields | Where-Object { $_ }).Count
    Write-Log -Message "Extended fields discovered: $discoveredCount of 14" -Level "INFO"

    # Load field mappings config if available
    $fieldMappingsPath = Join-Path $scriptRoot "config\field-mappings.json"
    $fieldMappings = if (Test-Path $fieldMappingsPath) { Read-JsonConfig -Path $fieldMappingsPath } else { $null }
}

# --- Ensure repo has at least one commit (required for image/attachment uploads) ---
Ensure-RepoInitialized -Org $ghOrg -Repo $ghRepo -Pat $ghPat

# --- Query all work items ---
Write-Log -Message "Querying ADO work items..." -Level "INFO"
$allIds = Get-AdoWorkItemIds -Org $adoOrg -Project $adoProject -AreaPath $areaPath -IncludeClosed $includeClosed -Pat $adoPat
Write-Log -Message "Total work items to process: $($allIds.Count)" -Level "INFO"

# --- Fetch all details and organize by migration order ---
Write-Log -Message "Fetching work item details..." -Level "INFO"
$allItems = @{}
foreach ($id in $allIds) {
    $details = Get-AdoWorkItemDetails -Org $adoOrg -Project $adoProject -WorkItemId $id -Pat $adoPat
    if ($details) { $allItems[$id] = $details }
    Start-Sleep -Milliseconds 100
}

# Sort by migration order (hierarchy: epics first, then features, etc.)
$sortedItems = $allItems.Values | Sort-Object {
    $type = $_.fields.'System.WorkItemType'
    $typeConfig = $typeMappings.types.$type
    if ($typeConfig) { $typeConfig.migrationOrder } else { 99 }
}, { $_.id }

Write-Log -Message "Items sorted by hierarchy. Migration order ready." -Level "INFO"

# --- ADO ID â†’ GitHub Issue Number tracking ---
$adoToGhMap = @{}  # adoId â†’ @{ issueNumber; issueNodeId; issueUrl }

# --- Fetch GitHub Milestones for mapping ---
Write-Log -Message "Fetching GitHub milestones..." -Level "INFO"
$ghMilestones = @{}
$page = 1
do {
    $uri = "https://api.github.com/repos/$ghOrg/$ghRepo/milestones?state=all&per_page=100&page=$page"
    $ghHeaders = Get-GhRestHeaders -Pat $ghPat
    $resp = try { Invoke-RestMethod -Uri $uri -Method GET -Headers $ghHeaders } catch { $null }
    if ($resp) {
        foreach ($ms in $resp) {
            $ghMilestones[$ms.title] = $ms.number
        }
    }
    $page++
} while ($resp -and $resp.Count -eq 100)
Write-Log -Message "Loaded $($ghMilestones.Count) milestones." -Level "INFO"

# ============================================================
#  MAIN MIGRATION LOOP
# ============================================================
$migrated = 0; $skipped = 0; $failed = 0
$total = $sortedItems.Count

foreach ($item in $sortedItems) {
    $adoId    = "$($item.id)"
    $title    = $item.fields.'System.Title'
    $type     = $item.fields.'System.WorkItemType'
    $state    = $item.fields.'System.State'
    $assignee = $item.fields.'System.AssignedTo'

    $migrated++
    Write-LogProgress -Current $migrated -Total $total -ItemName "work items"
    Write-Log -Message "[$adoId] ${type}: $title" -Level "INFO"

    # --- Skip if already migrated (resume mode) ---
    if ($migrationLog.ContainsKey("$adoId")) {
        Write-Log -Message "  Already migrated â†’ skipping" -Level "DEBUG"
        $adoToGhMap[$adoId] = $migrationLog["$adoId"]
        $skipped++
        continue
    }

    if ($DryRun) {
        Write-Log -Message "  [DRY RUN] Would migrate: $title" -Level "INFO"
        continue
    }

    # --- Build labels ---
    $labels = @("migrated")
    $typeConfig = $typeMappings.types.$type
    if ($typeConfig) { $labels += $typeConfig.githubLabel }

    # Tags â†’ labels
    if ($item.fields.'System.Tags') {
        $tags = $item.fields.'System.Tags' -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne "copied-to-github" }
        foreach ($tag in $tags) { $labels += "tag:$tag" }
    }

    # Priority label
    $priority = $item.fields.'Microsoft.VSTS.Common.Priority'
    if ($priority -and $config.priorityMapping."$priority") {
        $labels += $config.priorityMapping."$priority"
    }

    # Severity label (bugs)
    $severity = $item.fields.'Microsoft.VSTS.Common.Severity'
    if ($severity -and $config.severityMapping."$severity") {
        $labels += $config.severityMapping."$severity"
    }

    # Area path label
    $areaPathValue = $item.fields.'System.AreaPath'
    if ($areaPathValue -and $config.areaPathMapping.$areaPathValue) {
        $labels += $config.areaPathMapping.$areaPathValue
    }

    # --- Build issue body ---
    $body = ""

    # Description
    if ($typeConfig -and $typeConfig.includeFields.reproSteps -and $item.fields.'Microsoft.VSTS.TCM.ReproSteps') {
        $body += "## Repro Steps`n`n"
        $body += Convert-AdoHtmlToMarkdown -Html $item.fields.'Microsoft.VSTS.TCM.ReproSteps' `
            -AdoOrg $adoOrg -Pat $adoPat -TempDir $tempDir -GhOrg $ghOrg -GhRepo $ghRepo -GhPat $ghPat
        $body += "`n`n"
    }
    if ($typeConfig -and $typeConfig.includeFields.systemInfo -and $item.fields.'Microsoft.VSTS.TCM.SystemInfo') {
        $body += "## System Info`n`n"
        $body += Convert-AdoHtmlToMarkdown -Html $item.fields.'Microsoft.VSTS.TCM.SystemInfo' `
            -AdoOrg $adoOrg -Pat $adoPat -TempDir $tempDir -GhOrg $ghOrg -GhRepo $ghRepo -GhPat $ghPat
        $body += "`n`n"
    }
    if ($typeConfig -and $typeConfig.includeFields.description -and $item.fields.'System.Description') {
        $body += Convert-AdoHtmlToMarkdown -Html $item.fields.'System.Description' `
            -AdoOrg $adoOrg -Pat $adoPat -TempDir $tempDir -GhOrg $ghOrg -GhRepo $ghRepo -GhPat $ghPat
        $body += "`n`n"
    }
    if ($typeConfig -and $typeConfig.includeFields.acceptanceCriteria -and $item.fields.'Microsoft.VSTS.Common.AcceptanceCriteria') {
        $body += "## Acceptance Criteria`n`n"
        $body += Convert-AdoHtmlToMarkdown -Html $item.fields.'Microsoft.VSTS.Common.AcceptanceCriteria' `
            -AdoOrg $adoOrg -Pat $adoPat -TempDir $tempDir -GhOrg $ghOrg -GhRepo $ghRepo -GhPat $ghPat
        $body += "`n`n"
    }

    # Test Steps (Test Case / Shared Steps)
    if ($typeConfig -and $typeConfig.includeFields.testSteps -and $item.fields.'Microsoft.VSTS.TCM.Steps') {
        $testStepsMd = Convert-TestStepsToMarkdown -StepsXml $item.fields.'Microsoft.VSTS.TCM.Steps'
        if ($testStepsMd) {
            $body += $testStepsMd
            $body += "`n`n"
        }
    }

    if ([string]::IsNullOrWhiteSpace($body)) {
        $body = "_No description provided in Azure DevOps._`n`n"
    }

    # ADO metadata footer
    $adoUrl = "https://dev.azure.com/$adoOrg/$adoProject/_workitems/edit/$adoId"
    $body += "`n---`n"
    $body += "> **Migrated from Azure DevOps** | [Original Work Item #$adoId]($adoUrl)`n`n"
    $body += "**Original Work Item Metadata**`n`n"
    $body += "| Field | Value |`n|---|---|`n"
    $body += "| ADO ID | $adoId |`n"
    $body += "| Type | $type |`n"
    $body += "| State | $state |`n"
    $body += "| Created | $($item.fields.'System.CreatedDate') |`n"
    $body += "| Created By | $($item.fields.'System.CreatedBy'.displayName) |`n"
    $body += "| Changed | $($item.fields.'System.ChangedDate') |`n"
    $body += "| Assigned To | $($assignee.displayName) |`n"
    $body += "| Area Path | $areaPathValue |`n"
    $body += "| Iteration | $($item.fields.'System.IterationPath') |`n"
    # Add optional ADO fields only if they have values
    $valueArea = $item.fields.'Microsoft.VSTS.Common.ValueArea'
    if ($valueArea) { $body += "| Value Area | $valueArea |`n" }
    $storyPts = $item.fields.'Microsoft.VSTS.Scheduling.StoryPoints'
    if ($storyPts) { $body += "| Story Points | $storyPts |`n" }
    $effort = $item.fields.'Microsoft.VSTS.Scheduling.Effort'
    if ($effort) { $body += "| Effort | $effort |`n" }
    $reason = $item.fields.'System.Reason'
    if ($reason) { $body += "| Reason | $reason |`n" }
    $priority = $item.fields.'Microsoft.VSTS.Common.Priority'
    if ($priority) { $body += "| Priority | $priority |`n" }
    $severity = $item.fields.'Microsoft.VSTS.Common.Severity'
    if ($severity) { $body += "| Severity | $severity |`n" }

    # --- Resolve GitHub assignee ---
    $ghAssignees = @()
    $unmappedAssignee = $null
    if ($updateAssignees -and $assignee.uniqueName) {
        $ghUser = $userLookup[$assignee.uniqueName.ToLower()]
        if ($ghUser) { $ghAssignees = @($ghUser) }
        else {
            $unmappedAssignee = @{
                name  = $assignee.displayName
                email = $assignee.uniqueName
                adoId = $adoId
                title = $title
            }
            # Track for notification report
            if (-not $script:unmappedUsers) { $script:unmappedUsers = @() }
            $script:unmappedUsers += $unmappedAssignee
            Write-Log -Message "  No GitHub mapping for: $($assignee.displayName) ($($assignee.uniqueName)) - will notify" -Level "WARN"
        }
    }

    # Add note if assignee couldn't be mapped
    if ($unmappedAssignee) {
        $body += "`n> :warning: **Unmapped Assignee**: $($unmappedAssignee.name) ($($unmappedAssignee.email)) does not have a GitHub mapping. Please invite them or update user-mappings.json.`n"
    }

    # --- Create GitHub Issue ---
    try {
        $milestoneNumber = 0
        $adoIterPathRaw = $item.fields.'System.IterationPath'
        if ($adoIterPathRaw) {
            $msTitle = ($adoIterPathRaw -split '\\')[-1]
            if ($ghMilestones.ContainsKey($msTitle)) {
                $milestoneNumber = $ghMilestones[$msTitle]
            }
        }

        $issue = New-GhIssue -Org $ghOrg -Repo $ghRepo -Title $title -Body $body `
            -Labels $labels -Assignees $ghAssignees -Milestone $milestoneNumber -Pat $ghPat

        $issueNum    = $issue.number
        $issueNodeId = $issue.node_id
        $issueUrl    = $issue.html_url

        Write-Log -Message "  Created Issue #$issueNum`: $issueUrl" -Level "SUCCESS"

        $adoToGhMap[$adoId] = @{
            issueNumber = $issueNum
            issueNodeId = $issueNodeId
            issueUrl    = $issueUrl
        }
        
        # --- Add to GitHub Project + set Status + custom fields ---
        if ($ghProjectId) {
            try {
                $projectItemId = Add-GhIssueToProject -IssueNodeId $issueNodeId -ProjectId $ghProjectId -Pat $ghPat
                Write-Log -Message "  Added to Project (item: $projectItemId)" -Level "DEBUG"

                # --- Built-in Status (board columns) ---
                if ($statusField) {
                    $adoState = $state
                    $targetStatus = $null
                    $option = $null

                    # Strategy 1: Exact match - ADO state exists as a GitHub status option
                    $option = $statusOptions | Where-Object { $_.name -eq $adoState }
                    if ($option) {
                        $targetStatus = $adoState
                    }

                    # Strategy 2: Fallback to status-mappings.json
                    if (-not $option) {
                        $typeOverride = $statusMappings.typeOverrides.$type
                        $mappedStatus = if ($typeOverride -and $typeOverride.$adoState) {
                            $typeOverride.$adoState
                        } else {
                            $statusMappings.defaultMapping.$adoState
                        }
                        if ($mappedStatus) {
                            $option = $statusOptions | Where-Object { $_.name -eq $mappedStatus }
                            $targetStatus = $mappedStatus
                        }
                    }

                    if ($option) {
                        Set-GhProjectItemField -ProjectId $ghProjectId -ItemId $projectItemId `
                            -FieldId $statusField.id -OptionId $option.id -Pat $ghPat
                        Write-Log -Message "  Status: '$adoState' -> '$targetStatus'" -Level "DEBUG"
                    } else {
                        Write-Log -Message "  No status match for ADO state: '$adoState'" -Level "WARN"
                    }
                }

                # --- BATCH: Collect all field updates and send in one GraphQL call ---
                $fieldUpdates = @()

                # Helper: find option by name in a select field
                function Find-SelectOption($field, $value) {
                    if (-not $field -or -not $field.options -or -not $value) { return $null }
                    $opt = $field.options | Where-Object { $_.name -eq $value } | Select-Object -First 1
                    if (-not $opt) { $opt = $field.options | Where-Object { $_.name -match [regex]::Escape($value) } | Select-Object -First 1 }
                    return $opt
                }

                # ADO Status (exact ADO state)
                if ($adoStatusField -and $state) {
                    $adoOpt = Find-SelectOption $adoStatusField $state
                    if ($adoOpt) {
                        $fieldUpdates += @{ fieldId = $adoStatusField.id; value = $adoOpt.id; type = "select" }
                    }
                }

                # Item Type
                if ($itemTypeField -and $type) {
                    $typeOpt = Find-SelectOption $itemTypeField $type
                    if ($typeOpt) {
                        $fieldUpdates += @{ fieldId = $itemTypeField.id; value = $typeOpt.id; type = "select" }
                    }
                }

                # Priority (dynamic mapping)
                if ($priorityField -and $priorityOptionMap.Count -gt 0) {
                    $adoPriority = $item.fields.'Microsoft.VSTS.Common.Priority'
                    if ($adoPriority) {
                        $priOpt = $priorityOptionMap[[int]$adoPriority]
                        if ($priOpt) { $fieldUpdates += @{ fieldId = $priorityField.id; value = $priOpt.id; type = "select" } }
                    }
                }

                # Severity
                if ($severityField) {
                    $adoSev = $item.fields.'Microsoft.VSTS.Common.Severity'
                    $sevOpt = Find-SelectOption $severityField $adoSev
                    if ($sevOpt) { $fieldUpdates += @{ fieldId = $severityField.id; value = $sevOpt.id; type = "select" } }
                }

                # Story Points
                $sp = $item.fields.'Microsoft.VSTS.Scheduling.StoryPoints'
                if ($sp -ne $null -and $sp -ne '' -and [double]$sp -gt 0 -and $storyPtsField) {
                    $fieldUpdates += @{ fieldId = $storyPtsField.id; value = [double]$sp; type = "number" }
                }

                # ADO ID (text)
                if ($adoIdField) {
                    $fieldUpdates += @{ fieldId = $adoIdField.id; value = "$adoId"; type = "text" }
                }

                # Value Area
                $adoValueArea = $item.fields.'Microsoft.VSTS.Common.ValueArea'
                if ($adoValueArea -and $valueAreaField) {
                    $vaOpt = Find-SelectOption $valueAreaField $adoValueArea
                    if ($vaOpt) { $fieldUpdates += @{ fieldId = $valueAreaField.id; value = $vaOpt.id; type = "select" } }
                }

                # Activity
                $adoActivity = $item.fields.'Microsoft.VSTS.Common.Activity'
                if ($adoActivity -and $activityField) {
                    $actOpt = Find-SelectOption $activityField $adoActivity
                    if ($actOpt) { $fieldUpdates += @{ fieldId = $activityField.id; value = $actOpt.id; type = "select" } }
                }

                # Current Environment
                $adoEnv = $item.fields.'Custom.CurrentEnvironment'
                if ($adoEnv -and $envField) {
                    $envOpt = Find-SelectOption $envField $adoEnv
                    if ($envOpt) { $fieldUpdates += @{ fieldId = $envField.id; value = $envOpt.id; type = "select" } }
                }

                # Item Category
                $adoCat = $item.fields.'Custom.ItemCategory'
                if ($adoCat -and $itemCategoryField) {
                    $catOpt = Find-SelectOption $itemCategoryField $adoCat
                    if ($catOpt) { $fieldUpdates += @{ fieldId = $itemCategoryField.id; value = $catOpt.id; type = "select" } }
                }

                # Item SubCategory (text)
                $adoSubCat = $item.fields.'Custom.ItemSubCategory'
                if ($adoSubCat -and $itemSubCatField) {
                    $fieldUpdates += @{ fieldId = $itemSubCatField.id; value = "$adoSubCat"; type = "text" }
                }

                # Original Estimate / Completed Work / Remaining Work
                $origEst = $item.fields.'Microsoft.VSTS.Scheduling.OriginalEstimate'
                if ($origEst -ne $null -and $origEst -ne '' -and $origEstimateField) {
                    $fieldUpdates += @{ fieldId = $origEstimateField.id; value = [double]$origEst; type = "number" }
                }
                $compWork = $item.fields.'Microsoft.VSTS.Scheduling.CompletedWork'
                if ($compWork -ne $null -and $compWork -ne '' -and $completedWorkField) {
                    $fieldUpdates += @{ fieldId = $completedWorkField.id; value = [double]$compWork; type = "number" }
                }
                $remWork = $item.fields.'Microsoft.VSTS.Scheduling.RemainingWork'
                if ($remWork -ne $null -and $remWork -ne '' -and $remainingWorkField) {
                    $fieldUpdates += @{ fieldId = $remainingWorkField.id; value = [double]$remWork; type = "number" }
                }

                # Risk
                $adoRisk = $item.fields.'Microsoft.VSTS.Common.Risk'
                if ($adoRisk -and $riskField) {
                    $riskOpt = Find-SelectOption $riskField $adoRisk
                    if ($riskOpt) { $fieldUpdates += @{ fieldId = $riskField.id; value = $riskOpt.id; type = "select" } }
                }

                # T-Shirt Size
                $adoTShirt = $item.fields.'Custom.TShirtSize'
                if ($adoTShirt -and $tShirtField) {
                    $tsOpt = Find-SelectOption $tShirtField $adoTShirt
                    if ($tsOpt) { $fieldUpdates += @{ fieldId = $tShirtField.id; value = $tsOpt.id; type = "select" } }
                }

                # Area Path (text)
                $adoAreaPath = $item.fields.'System.AreaPath'
                if ($adoAreaPath -and $areaPathTextField) {
                    $fieldUpdates += @{ fieldId = $areaPathTextField.id; value = "$adoAreaPath"; type = "text" }
                }

                # Iteration Path (text)
                $adoIterPath = $item.fields.'System.IterationPath'
                if ($adoIterPath -and $iterPathTextField) {
                    $fieldUpdates += @{ fieldId = $iterPathTextField.id; value = "$adoIterPath"; type = "text" }
                }

                # Start Date / Target Date (text as ISO date)
                $adoStartDate = $item.fields.'Microsoft.VSTS.Scheduling.StartDate'
                if ($adoStartDate -and $startDateField) {
                    $dateStr = try { (Get-Date $adoStartDate -Format "yyyy-MM-dd") } catch { "$adoStartDate" }
                    $fieldUpdates += @{ fieldId = $startDateField.id; value = $dateStr; type = "text" }
                }
                $adoTargetDate = $item.fields.'Microsoft.VSTS.Scheduling.TargetDate'
                if ($adoTargetDate -and $targetDateField) {
                    $dateStr = try { (Get-Date $adoTargetDate -Format "yyyy-MM-dd") } catch { "$adoTargetDate" }
                    $fieldUpdates += @{ fieldId = $targetDateField.id; value = $dateStr; type = "text" }
                }

                # Value Stream
                $adoVS = $item.fields.'Custom.ValueStream'
                if ($adoVS -and $valueStreamField) {
                    $vsOpt = Find-SelectOption $valueStreamField $adoVS
                    if ($vsOpt) { $fieldUpdates += @{ fieldId = $valueStreamField.id; value = $vsOpt.id; type = "select" } }
                }

                # --- Execute batch mutation (all fields in ONE GraphQL call) ---
                if ($fieldUpdates.Count -gt 0) {
                    Set-GhProjectItemFieldsBatch -ProjectId $ghProjectId -ItemId $projectItemId `
                        -FieldUpdates $fieldUpdates -Pat $ghPat
                    Write-Log -Message "  Batch updated $($fieldUpdates.Count) fields" -Level "INFO"
                }


            } catch {
                Write-Log -Message "  Project/Field update failed: $_" -Level "WARN"
            }
        }
    } catch {
        Write-Log -Message "  FAILED to create issue: $_" -Level "ERROR"
        $failed++
        continue
    }

    # --- Migrate Comments ---
    if ($addComments) {
        $comments = Get-AdoWorkItemComments -Org $adoOrg -Project $adoProject -WorkItemId $adoId -Pat $adoPat
        if ($comments -and $comments.Count -gt 0) {
            foreach ($comment in $comments) {
                # Debug: log raw HTML to find image format
                $rawPreview = if ($comment.text.Length -gt 200) { $comment.text.Substring(0, 200) + "..." } else { $comment.text }
                if ($comment.text -match '<img|\.jpg|\.png|\.jpeg|\.gif|attachment') {
                    Write-Log -Message "  Comment has image/attachment. Raw HTML: $rawPreview" -Level "INFO"
                }
                $commentBody = "**$($comment.createdBy.displayName)** _($($comment.createdDate))_:`n`n"
                $commentBody += Convert-AdoHtmlToMarkdown -Html $comment.text `
                    -AdoOrg $adoOrg -Pat $adoPat -TempDir $tempDir -GhOrg $ghOrg -GhRepo $ghRepo -GhPat $ghPat
                Add-GhIssueComment -Org $ghOrg -Repo $ghRepo -IssueNumber $issueNum -Body $commentBody -Pat $ghPat | Out-Null
                Start-Sleep -Milliseconds 300
            }
            Write-Log -Message "  Migrated $($comments.Count) comments" -Level "DEBUG"
        }
    }

    # --- Migrate Attachments ---
    if ($migrateAttach) {
        $attachments = Get-AdoWorkItemAttachments -WorkItemDetails $item
        if ($attachments.Count -gt 0) {
            foreach ($att in $attachments) {
                $localFile = Save-AdoAttachment -AttachmentUrl $att.Url -FileName $att.Name -TempDir $tempDir -Pat $adoPat
                if ($localFile) {
                    $ghUrl = Upload-ImageToGitHub -FilePath $localFile -GhOrg $ghOrg -GhRepo $ghRepo -GhPat $ghPat
                    if ($ghUrl) {
                        $attComment = "**Attachment**: [$($att.Name)]($ghUrl)"
                        if ($att.Comment) { $attComment += "`n> $($att.Comment)" }
                        Add-GhIssueComment -Org $ghOrg -Repo $ghRepo -IssueNumber $issueNum -Body $attComment -Pat $ghPat | Out-Null
                    }
                    Remove-Item $localFile -Force -ErrorAction SilentlyContinue
                }
            }
            Write-Log -Message "  Migrated $($attachments.Count) attachments" -Level "DEBUG"
        }
    }

    # --- Close issue if ADO state is terminal ---
    if ($closedStates -contains $state) {
        Close-GhIssue -Org $ghOrg -Repo $ghRepo -IssueNumber $issueNum -Pat $ghPat
        Write-Log -Message "  Closed (ADO state: $state)" -Level "DEBUG"
    }

    # --- Tag ADO work item ---
    if ($productionRun) {
        Tag-AdoWorkItemAsMigrated -Org $adoOrg -Project $adoProject -WorkItemId $adoId -GitHubIssueUrl $issueUrl -Pat $adoPat
    }

    # --- Save progress ---
    $migrationLog["$adoId"] = $adoToGhMap["$adoId"]
    $migrationLog | ConvertTo-Json -Depth 10 | Set-Content -Path $migLogPath -Encoding UTF8

    Start-Sleep -Milliseconds $rateLimitMs
}

# ============================================================
#  PASS 2: Establish parent-child links
# ============================================================
if ($preserveHierarchy -and -not $DryRun) {
    Write-LogSection "Pass 2: Establishing Parent-Child Links"
    $linkedCount = 0
    $failedLinks = 0

    # Group children by parent for batch processing
    $parentChildMap = @{}  # parentAdoId -> @(childAdoIds)
    foreach ($item in $sortedItems) {
        $adoId = "$($item.id)"
        $parentAdoIdRaw = Get-AdoParentId -WorkItemDetails $item
        if (-not $parentAdoIdRaw) { 
            Write-Log -Message "  ADO#$adoId has no parent link." -Level "DEBUG"
            continue 
        }
        $parentAdoId = "$parentAdoIdRaw"
        
        if (-not $adoToGhMap.ContainsKey($adoId) -or -not $adoToGhMap.ContainsKey($parentAdoId)) {
            Write-Log -Message "  ADO#$adoId parent=$parentAdoId - one or both not in map, skipping. (adoId in map: $($adoToGhMap.ContainsKey($adoId)), parent in map: $($adoToGhMap.ContainsKey($parentAdoId)))" -Level "WARN"
            continue
        }
        if (-not $parentChildMap.ContainsKey($parentAdoId)) { $parentChildMap[$parentAdoId] = @() }
        $parentChildMap[$parentAdoId] += $adoId
    }

    Write-Log -Message "Found $($parentChildMap.Count) parent(s) with children to link" -Level "INFO"

    foreach ($parentAdoId in $parentChildMap.Keys) {
        $parentIssueNum = $adoToGhMap[$parentAdoId].issueNumber
        $parentNodeId   = $adoToGhMap[$parentAdoId].issueNodeId
        $children       = $parentChildMap[$parentAdoId]

        Write-Log -Message "  Parent: ADO#$parentAdoId (GH#$parentIssueNum) -> $($children.Count) children" -Level "INFO"

        $subIssueSuccess = $true

        foreach ($childAdoId in $children) {
            $childNodeId   = $adoToGhMap[$childAdoId].issueNodeId
            $childIssueNum = $adoToGhMap[$childAdoId].issueNumber

            # Try sub-issues API
            $success = Add-GhSubIssue -ParentIssueNodeId $parentNodeId -ChildIssueNodeId $childNodeId -Pat $ghPat
            if ($success) {
                Write-Log -Message "    Sub-issue: GH#$childIssueNum linked" -Level "SUCCESS"
                $linkedCount++
            } else {
                $subIssueSuccess = $false
                Write-Log -Message "    Sub-issue API failed for GH#$childIssueNum" -Level "DEBUG"
            }
            Start-Sleep -Milliseconds 300
        }

        # If sub-issues API failed, use task-list fallback (update parent body)
        if (-not $subIssueSuccess) {
            $taskListLines = @()
            $taskListLines += ""
            $taskListLines += "## Child Work Items"
            $taskListLines += ""
            foreach ($childAdoId in $children) {
                $childIssueNum = $adoToGhMap[$childAdoId].issueNumber
                $childUrl      = $adoToGhMap[$childAdoId].issueUrl
                $childItem     = $allItems[[int]$childAdoId]
                $childTitle    = if ($childItem) { $childItem.fields.'System.Title' } else { "Issue #$childIssueNum" }
                $childType     = if ($childItem) { $childItem.fields.'System.WorkItemType' } else { "Item" }
                $taskListLines += "- [ ] [${childType}: ${childTitle}]($childUrl)"
                $linkedCount++
                $failedLinks++
            }
            $taskListBody = $taskListLines -join "`n"

            # Append task list to parent issue body
            try {
                $headers = Get-GhRestHeaders -Pat $ghPat
                $parentIssue = Invoke-RestMethod -Uri "https://api.github.com/repos/$ghOrg/$ghRepo/issues/$parentIssueNum" -Headers $headers
                $updatedBody = $parentIssue.body + "`n`n$taskListBody"
                $updateBody = @{ body = $updatedBody } | ConvertTo-Json -Depth 5
                Invoke-RestMethod -Uri "https://api.github.com/repos/$ghOrg/$ghRepo/issues/$parentIssueNum" `
                    -Method PATCH -Headers $headers -Body $updateBody | Out-Null
                Write-Log -Message "    Updated GH#$parentIssueNum body with $($children.Count) child task-list links" -Level "SUCCESS"
            } catch {
                Write-Log -Message "    Failed to update parent body: $_" -Level "WARN"
            }
        }
    }
    Write-Log -Message "Established $linkedCount parent-child links ($failedLinks used task-list fallback)" -Level "SUCCESS"
}

# --- Final Summary ---
Write-LogSection "Migration Summary"
Write-Log -Message "Total processed: $total" -Level "INFO"
Write-Log -Message "Migrated: $($total - $skipped - $failed)" -Level "SUCCESS"
Write-Log -Message "Skipped (resume): $skipped" -Level "INFO"
Write-Log -Message "Failed: $failed" -Level $(if ($failed -gt 0) { "ERROR" } else { "INFO" })
Write-Log -Message "Migration log: $migLogPath" -Level "INFO"

# --- Generate unmapped user notification report ---
if ($script:unmappedUsers -and $script:unmappedUsers.Count -gt 0) {
    Write-LogSection "Unmapped Assignee Notification Report"

    # Deduplicate by email
    $uniqueUnmapped = @{}
    foreach ($u in $script:unmappedUsers) {
        if (-not $uniqueUnmapped.ContainsKey($u.email)) {
            $uniqueUnmapped[$u.email] = @{
                name       = $u.name
                email      = $u.email
                workItems  = @()
            }
        }
        $uniqueUnmapped[$u.email].workItems += @{ adoId = $u.adoId; title = $u.title }
    }

    Write-Log -Message "Unmapped users: $($uniqueUnmapped.Count)" -Level "WARN"
    foreach ($email in $uniqueUnmapped.Keys) {
        $info = $uniqueUnmapped[$email]
        Write-Log -Message "  $($info.name) ($email) - $($info.workItems.Count) work items" -Level "WARN"
    }

    # Save notification report
    $notificationReport = @{
        generatedAt   = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        unmappedUsers = @($uniqueUnmapped.Values)
        message       = "These ADO users do not have GitHub account mappings. Send them an invitation to join GitHub and update user-mappings.json."
    }
    $notifPath = Join-Path $reportDir "unmapped-users-notification.json"
    $notificationReport | ConvertTo-Json -Depth 10 | Set-Content -Path $notifPath -Encoding UTF8
    Write-Log -Message "Notification report saved: $notifPath" -Level "INFO"

    # Also generate a simple CSV for email tool import
    $csvData = @()
    foreach ($email in $uniqueUnmapped.Keys) {
        $info = $uniqueUnmapped[$email]
        $csvData += [PSCustomObject]@{
            Name          = $info.name
            Email         = $email
            WorkItemCount = $info.workItems.Count
            Action        = "Invite to GitHub and map in user-mappings.json"
        }
    }
    $csvPath = Join-Path $reportDir "unmapped-users-email-list.csv"
    $csvData | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    Write-Log -Message "Email list CSV saved: $csvPath" -Level "INFO"
    Write-Log -Message "Import this CSV into your email system to notify unmapped users." -Level "INFO"
}

# Cleanup temp
if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue }

if ($failed -gt 0) { exit 1 }
