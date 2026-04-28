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
    $severityField  = $fields | Where-Object { $_.__typename -eq "ProjectV2SingleSelectField" -and $_.name -eq "Severity" -and $_.options }
    $storyPtsField  = $fields | Where-Object { $_.name -eq "Story Points" }
    $adoIdField     = $fields | Where-Object { $_.name -eq "ADO ID" }

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
    if ($severityField)  { Write-Log -Message "Field 'Severity': $($severityField.options.Count) options" -Level "INFO" }
    if ($storyPtsField)  { Write-Log -Message "Field 'Story Points': ready (number)" -Level "INFO" }
    if ($adoIdField)     { Write-Log -Message "Field 'ADO ID': ready (number)" -Level "INFO" }
    if ($sizeField)      { Write-Log -Message "Field 'Size': $($sizeField.options.Count) options" -Level "INFO" }
    if ($estimateField)  { Write-Log -Message "Field 'Estimate': ready (number)" -Level "INFO" }
    if ($iterationField) { Write-Log -Message "Field 'Iteration': ready" -Level "INFO" }
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

# ============================================================
#  MAIN MIGRATION LOOP
# ============================================================
$migrated = 0; $skipped = 0; $failed = 0
$total = $sortedItems.Count

foreach ($item in $sortedItems) {
    $adoId    = $item.id
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
        $issue = New-GhIssue -Org $ghOrg -Repo $ghRepo -Title $title -Body $body `
            -Labels $labels -Assignees $ghAssignees -Pat $ghPat

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

                # --- Custom Field: ADO Status (exact ADO state) ---
                if ($adoStatusField -and $state) {
                    $adoOpt = $adoStatusField.options | Where-Object { $_.name -eq $state }
                    if ($adoOpt) {
                        Set-GhProjectItemSelectField -ProjectId $ghProjectId -ItemId $projectItemId `
                            -FieldId $adoStatusField.id -OptionId $adoOpt.id -Pat $ghPat
                        Write-Log -Message "  ADO Status: '$state'" -Level "DEBUG"
                    }
                }

                # --- Field: Priority (dynamic mapping) ---
                if ($priorityField -and $priorityOptionMap.Count -gt 0) {
                    $adoPriority = $item.fields.'Microsoft.VSTS.Common.Priority'
                    if ($adoPriority) {
                        $priOpt = $priorityOptionMap[[int]$adoPriority]
                        if ($priOpt) {
                            Set-GhProjectItemSelectField -ProjectId $ghProjectId -ItemId $projectItemId `
                                -FieldId $priorityField.id -OptionId $priOpt.id -Pat $ghPat
                            Write-Log -Message "  Priority: ADO $adoPriority -> '$($priOpt.name)'" -Level "DEBUG"
                        } else {
                            Write-Log -Message "  No priority mapping for ADO value: $adoPriority" -Level "WARN"
                        }
                    }
                }

                # --- Field: Severity (Bugs) ---
                if ($severityField) {
                    $adoSeverity = $item.fields.'Microsoft.VSTS.Common.Severity'
                    if ($adoSeverity) {
                        # Try exact match first, then partial match
                        $sevOpt = $severityField.options | Where-Object { $_.name -eq $adoSeverity } | Select-Object -First 1
                        if (-not $sevOpt) {
                            $sevOpt = $severityField.options | Where-Object { $_.name -match [regex]::Escape($adoSeverity) } | Select-Object -First 1
                        }
                        if ($sevOpt) {
                            Set-GhProjectItemSelectField -ProjectId $ghProjectId -ItemId $projectItemId `
                                -FieldId $severityField.id -OptionId $sevOpt.id -Pat $ghPat
                            Write-Log -Message "  Severity: '$adoSeverity'" -Level "DEBUG"
                        }
                    }
                }

                # --- Field: Story Points (only from StoryPoints, NOT Effort) ---
                $sp = $item.fields.'Microsoft.VSTS.Scheduling.StoryPoints'
                if ($sp -and [double]$sp -gt 0) {
                    if ($storyPtsField) {
                        Set-GhProjectItemNumberField -ProjectId $ghProjectId -ItemId $projectItemId `
                            -FieldId $storyPtsField.id -Value ([double]$sp) -Pat $ghPat
                        Write-Log -Message "  Story Points: $sp" -Level "DEBUG"
                    }
                }

                # --- Field: ADO ID ---
                if ($adoIdField) {
                    Set-GhProjectItemNumberField -ProjectId $ghProjectId -ItemId $projectItemId `
                        -FieldId $adoIdField.id -Value ([double]$adoId) -Pat $ghPat
                    Write-Log -Message "  ADO ID: $adoId" -Level "DEBUG"
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
    $migrationLog["$adoId"] = $adoToGhMap[$adoId]
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
        $adoId = $item.id
        $parentAdoId = Get-AdoParentId -WorkItemDetails $item
        if (-not $parentAdoId) { continue }
        if (-not $adoToGhMap.ContainsKey($adoId) -or -not $adoToGhMap.ContainsKey($parentAdoId)) {
            Write-Log -Message "  ADO#$adoId parent=$parentAdoId - one or both not in map, skipping" -Level "DEBUG"
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
                $childItem     = $allItems[$childAdoId]
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
