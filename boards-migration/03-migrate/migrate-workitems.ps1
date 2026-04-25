# ============================================================
#  Migrate Work Items - Main migration engine
#  Phase: 03-migrate
#  Migrates ADO work items → GitHub Issues + ProjectV2
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

# --- ADO ID → GitHub Issue Number tracking ---
$adoToGhMap = @{}  # adoId → @{ issueNumber; issueNodeId; issueUrl }

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
        Write-Log -Message "  Already migrated → skipping" -Level "DEBUG"
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

    # Tags → labels
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
    $body += "<details><summary>📋 Original Work Item Metadata</summary>`n`n"
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
    $body += "`n</details>"

    # --- Resolve GitHub assignee ---
    $ghAssignees = @()
    if ($updateAssignees -and $assignee.uniqueName) {
        $ghUser = $userLookup[$assignee.uniqueName.ToLower()]
        if ($ghUser) { $ghAssignees = @($ghUser) }
        else { Write-Log -Message "  No GitHub mapping for: $($assignee.uniqueName)" -Level "WARN" }
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
    } catch {
        Write-Log -Message "  FAILED to create issue: $_" -Level "ERROR"
        $failed++
        continue
    }

    # --- Add to GitHub Project + set Status ---
    if ($ghProjectId) {
        try {
            $projectItemId = Add-GhIssueToProject -IssueNodeId $issueNodeId -ProjectId $ghProjectId -Pat $ghPat
            Write-Log -Message "  Added to Project (item: $projectItemId)" -Level "DEBUG"

            if ($statusField) {
                $adoStateLower = $state
                $typeOverride = $statusMappings.typeOverrides.$type
                $mappedStatus = if ($typeOverride -and $typeOverride.$adoStateLower) {
                    $typeOverride.$adoStateLower
                } else {
                    $statusMappings.defaultMapping.$adoStateLower
                }
                if (-not $mappedStatus) { $mappedStatus = $statusMappings.defaultMapping.$state }

                if ($mappedStatus) {
                    $option = $statusOptions | Where-Object { $_.name -eq $mappedStatus }
                    if ($option) {
                        Set-GhProjectItemField -ProjectId $ghProjectId -ItemId $projectItemId `
                            -FieldId $statusField.id -OptionId $option.id -Pat $ghPat
                        Write-Log -Message "  Status → '$mappedStatus'" -Level "DEBUG"
                    }
                }
            }
        } catch {
            Write-Log -Message "  Project/Status update failed: $_" -Level "WARN"
        }
    }

    # --- Migrate Comments ---
    if ($addComments) {
        $comments = Get-AdoWorkItemComments -Org $adoOrg -Project $adoProject -WorkItemId $adoId -Pat $adoPat
        if ($comments -and $comments.Count -gt 0) {
            foreach ($comment in $comments) {
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
                        $attComment = "📎 **Attachment**: [$($att.Name)]($ghUrl)"
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
    $closedStates = $statusMappings.closedStates
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

    foreach ($item in $sortedItems) {
        $adoId = $item.id
        $parentAdoId = Get-AdoParentId -WorkItemDetails $item

        if ($parentAdoId -and $adoToGhMap.ContainsKey($adoId) -and $adoToGhMap.ContainsKey($parentAdoId)) {
            $childNodeId  = $adoToGhMap[$adoId].issueNodeId
            $parentNodeId = $adoToGhMap[$parentAdoId].issueNodeId
            $parentIssueNum = $adoToGhMap[$parentAdoId].issueNumber

            # Try GitHub sub-issues API first
            $success = Add-GhSubIssue -ParentIssueNodeId $parentNodeId -ChildIssueNodeId $childNodeId -Pat $ghPat
            if ($success) {
                Write-Log -Message "  Linked #$($adoToGhMap[$adoId].issueNumber) → parent #$parentIssueNum" -Level "DEBUG"
                $linkedCount++
            } else {
                # Fallback: add cross-reference comment
                $childUrl = $adoToGhMap[$adoId].issueUrl
                $commentBody = "🔗 **Child issue**: $childUrl"
                Add-GhIssueComment -Org $ghOrg -Repo $ghRepo -IssueNumber $parentIssueNum -Body $commentBody -Pat $ghPat | Out-Null
                $linkedCount++
            }
            Start-Sleep -Milliseconds 300
        }
    }
    Write-Log -Message "Established $linkedCount parent-child links" -Level "SUCCESS"
}

# --- Final Summary ---
Write-LogSection "Migration Summary"
Write-Log -Message "Total processed: $total" -Level "INFO"
Write-Log -Message "Migrated: $($total - $skipped - $failed)" -Level "SUCCESS"
Write-Log -Message "Skipped (resume): $skipped" -Level "INFO"
Write-Log -Message "Failed: $failed" -Level $(if ($failed -gt 0) { "ERROR" } else { "INFO" })
Write-Log -Message "Migration log: $migLogPath" -Level "INFO"

# Cleanup temp
if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue }

if ($failed -gt 0) { exit 1 }