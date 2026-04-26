# ============================================================
#  GitHub REST + GraphQL API Helpers
#  Usage: . .\helpers\github-helpers.ps1
# ============================================================

function Get-GhRestHeaders {
    param([Parameter(Mandatory)][string]$Pat)
    return @{ Authorization = "token $Pat"; Accept = "application/vnd.github.v3+json"; "Content-Type" = "application/json" }
}

function Get-GhGraphQLHeaders {
    param([Parameter(Mandatory)][string]$Pat)
    return @{ Authorization = "bearer $Pat"; "Content-Type" = "application/json" }
}

# --- Invoke GraphQL with retry and rate-limit handling ---
function Invoke-GhGraphQL {
    param([string]$Query, [string]$Pat, [int]$RetryCount = 3)
    $headers = Get-GhGraphQLHeaders -Pat $Pat
    $body = @{ query = $Query } | ConvertTo-Json -Depth 10
    for ($i = 1; $i -le $RetryCount; $i++) {
        try {
            $resp = Invoke-RestMethod -Method POST -Uri "https://api.github.com/graphql" -Headers $headers -Body $body
            if ($resp.errors) {
                Write-Log -Message "GraphQL errors: $($resp.errors | ConvertTo-Json -Compress)" -Level "WARN"
            }
            return $resp
        } catch {
            if ($i -eq $RetryCount) { throw }
            $wait = [math]::Pow(2, $i) * 1000
            Write-Log -Message "GraphQL request failed (attempt $i/$RetryCount), retrying in $($wait/1000)s..." -Level "WARN"
            Start-Sleep -Milliseconds $wait
        }
    }
}

# --- Get GitHub ProjectV2 ID from project number ---
# Supports both user-level and org-level projects
function Get-GhProjectId {
    param(
        [string]$Owner,
        [int]$ProjectNumber,
        [string]$Pat,
        [ValidateSet("user","organization")]
        [string]$OwnerType = "organization"
    )
    Write-Log -Message "Getting project ID: Owner=$Owner, Number=$ProjectNumber, Type=$OwnerType" -Level "INFO"
    if ($OwnerType -eq "user") {
        # Try viewer first (most reliable for personal PATs)
        $q1 = "{ viewer { projectV2(number: $ProjectNumber) { id title } } }"
        $resp1 = Invoke-GhGraphQL -Query $q1 -Pat $Pat
        $id = $resp1.data.viewer.projectV2.id
        Write-Log -Message "viewer query result: $id" -Level "INFO"
        if (-not $id) {
            # Fallback to user query
            $q2 = "{ user(login: `"$Owner`") { projectV2(number: $ProjectNumber) { id title } } }"
            $resp2 = Invoke-GhGraphQL -Query $q2 -Pat $Pat
            $id = $resp2.data.user.projectV2.id
            Write-Log -Message "user query result: $id" -Level "INFO"
        }
        return $id
    } else {
        if ([string]::IsNullOrEmpty($Owner)) {
            Write-Log -Message "Owner is empty - cannot query organization project" -Level "ERROR"
            return $null
        }
        $q = "{ organization(login: `"$Owner`") { projectV2(number: $ProjectNumber) { id title } } }"
        $resp = Invoke-GhGraphQL -Query $q -Pat $Pat
        return $resp.data.organization.projectV2.id
    }
}

# --- Get all ProjectV2 fields (especially Status single-select) ---
function Get-GhProjectFields {
    param([string]$ProjectId, [string]$Pat)
    $q = @"
{ node(id: "$ProjectId") { ... on ProjectV2 { fields(first: 50) { nodes { __typename
  ... on ProjectV2SingleSelectField { id name options { id name } }
  ... on ProjectV2Field { id name }
  ... on ProjectV2IterationField { id name } } } } } }
"@
    $resp = Invoke-GhGraphQL -Query $q -Pat $Pat
    return $resp.data.node.fields.nodes
}

# --- Sync GitHub Project Status options to match ADO states ---
# Creates any missing ADO states as Status field options, keeps existing ones.
function Sync-GhProjectStatusOptions {
    param(
        [string]$ProjectId,
        [string]$Pat,
        [string[]]$RequiredStates
    )

    # Color palette for status options (GitHub ProjectV2 supported colors)
    $colors = @("GRAY", "BLUE", "GREEN", "YELLOW", "ORANGE", "RED", "PINK", "PURPLE")

    # Get the current Status field
    $fields = Get-GhProjectFields -ProjectId $ProjectId -Pat $Pat
    $statusField = $fields | Where-Object { $_.__typename -eq "ProjectV2SingleSelectField" -and $_.name -eq "Status" }

    if (-not $statusField) {
        Write-Log -Message "No Status field found in GitHub Project" -Level "ERROR"
        return $null
    }

    $existingNames = @($statusField.options | ForEach-Object { $_.name })
    $missingStates = @($RequiredStates | Where-Object { $_ -notin $existingNames })

    if ($missingStates.Count -eq 0) {
        Write-Log -Message "All $($RequiredStates.Count) ADO states already exist in GitHub Project Status field" -Level "SUCCESS"
        return $statusField
    }

    Write-Log -Message "Adding $($missingStates.Count) missing status options: $($missingStates -join ', ')" -Level "INFO"

    # Build the full options list: existing + missing
    $allOptions = [System.Collections.Generic.List[object]]::new()

    # Keep existing options with their IDs
    foreach ($opt in $statusField.options) {
        $allOptions.Add(@{ id = $opt.id; name = $opt.name })
    }

    # Add missing options with colors
    $colorIdx = 0
    foreach ($state in $missingStates) {
        $color = $colors[$colorIdx % $colors.Count]
        $allOptions.Add(@{ name = $state; color = $color })
        $colorIdx++
    }

    # Build the options JSON for the mutation
    $optionEntries = @()
    foreach ($opt in $allOptions) {
        if ($opt.id) {
            $optionEntries += "{ id: \`"$($opt.id)\`", name: \`"$($opt.name)\`" }"
        } else {
            $optionEntries += "{ name: \`"$($opt.name)\`", color: $($opt.color) }"
        }
    }
    $optionsStr = $optionEntries -join ", "

    $mutation = @"
mutation {
  updateProjectV2Field(input: {
    fieldId: "$($statusField.id)"
    singleSelectOptions: [$optionsStr]
  }) {
    projectV2Field {
      ... on ProjectV2SingleSelectField { id name options { id name } }
    }
  }
}
"@

    $resp = Invoke-GhGraphQL -Query $mutation -Pat $Pat
    if ($resp.data.updateProjectV2Field) {
        $updated = $resp.data.updateProjectV2Field.projectV2Field
        Write-Log -Message "Status field updated: $($updated.options.Count) options total" -Level "SUCCESS"
        foreach ($opt in $updated.options) {
            Write-Log -Message "  - $($opt.name)" -Level "DEBUG"
        }
        return $updated
    } else {
        Write-Log -Message "Failed to update Status field options" -Level "ERROR"
        return $statusField
    }
}

# --- Create a GitHub Issue via REST API ---
function New-GhIssue {
    param([string]$Org, [string]$Repo, [string]$Title, [string]$Body, [string[]]$Labels, [string[]]$Assignees, [string]$Pat)
    $headers = Get-GhRestHeaders -Pat $Pat
    $issueData = @{ title = $Title; body = $Body; labels = $Labels }
    if ($Assignees -and $Assignees.Count -gt 0) {
        $validAssignees = @($Assignees | Where-Object { -not [string]::IsNullOrEmpty($_) })
        if ($validAssignees.Count -gt 0) { $issueData.assignees = @($validAssignees) }
    }
    $jsonBody = $issueData | ConvertTo-Json -Depth 10
    $uri = "https://api.github.com/repos/$Org/$Repo/issues"
    try {
        $resp = Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -Body $jsonBody
        return $resp
    } catch {
        # If assignees caused the failure (user not a collaborator), retry without them
        if ($issueData.assignees -and $issueData.assignees.Count -gt 0) {
            $intendedAssignees = $issueData.assignees -join ', '
            Write-Log -Message "Assignee(s) [$intendedAssignees] not collaborator(s). Creating issue without assignment. Original assignee preserved in metadata." -Level "WARN"
            $issueData.Remove('assignees')
            $jsonBody = $issueData | ConvertTo-Json -Depth 10
            try {
                $resp = Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -Body $jsonBody
                return $resp
            } catch {
                Write-Log -Message "Failed to create issue '$Title' (even without assignees): $_" -Level "ERROR"
                throw
            }
        }
        Write-Log -Message "Failed to create issue '$Title': $_" -Level "ERROR"
        throw
    }
}

# --- Add a comment to a GitHub Issue ---
function Add-GhIssueComment {
    param([string]$Org, [string]$Repo, [int]$IssueNumber, [string]$Body, [string]$Pat)
    $headers = Get-GhRestHeaders -Pat $Pat
    $jsonBody = @{ body = $Body } | ConvertTo-Json -Depth 5
    $uri = "https://api.github.com/repos/$Org/$Repo/issues/$IssueNumber/comments"
    try {
        return Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -Body $jsonBody
    } catch {
        Write-Log -Message "Failed to add comment to issue #$IssueNumber`: $_" -Level "WARN"
        return $null
    }
}

# --- Close a GitHub Issue ---
function Close-GhIssue {
    param([string]$Org, [string]$Repo, [int]$IssueNumber, [string]$Pat)
    $headers = Get-GhRestHeaders -Pat $Pat
    $jsonBody = @{ state = "closed" } | ConvertTo-Json
    $uri = "https://api.github.com/repos/$Org/$Repo/issues/$IssueNumber"
    try {
        Invoke-RestMethod -Uri $uri -Method PATCH -Headers $headers -Body $jsonBody | Out-Null
    } catch {
        Write-Log -Message "Failed to close issue #$IssueNumber`: $_" -Level "WARN"
    }
}

# --- Add issue to GitHub ProjectV2 ---
function Add-GhIssueToProject {
    param([string]$IssueNodeId, [string]$ProjectId, [string]$Pat)
    $mutation = "mutation { addProjectV2ItemById(input: {projectId: `"$ProjectId`", contentId: `"$IssueNodeId`"}) { item { id } } }"
    $resp = Invoke-GhGraphQL -Query $mutation -Pat $Pat
    return $resp.data.addProjectV2ItemById.item.id
}

# --- Update a ProjectV2 item single-select field (e.g., Status) ---
function Set-GhProjectItemField {
    param([string]$ProjectId, [string]$ItemId, [string]$FieldId, [string]$OptionId, [string]$Pat)
    $mutation = @"
mutation { updateProjectV2ItemFieldValue(input: {
  projectId: "$ProjectId", itemId: "$ItemId", fieldId: "$FieldId",
  value: { singleSelectOptionId: "$OptionId" }
}) { projectV2Item { id } } }
"@
    Invoke-GhGraphQL -Query $mutation -Pat $Pat | Out-Null
}

# --- Create or get a GitHub label ---
function Ensure-GhLabel {
    param([string]$Org, [string]$Repo, [string]$Name, [string]$Color, [string]$Description, [string]$Pat)
    $headers = Get-GhRestHeaders -Pat $Pat
    $uri = "https://api.github.com/repos/$Org/$Repo/labels/$([System.Uri]::EscapeDataString($Name))"
    try {
        $existing = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers
        Write-Log -Message "Label '$Name' already exists" -Level "DEBUG"
        return $existing
    } catch {
        # Label doesn't exist, create it
        $labelData = @{ name = $Name; color = $Color; description = $Description } | ConvertTo-Json
        $createUri = "https://api.github.com/repos/$Org/$Repo/labels"
        try {
            $created = Invoke-RestMethod -Uri $createUri -Method POST -Headers $headers -Body $labelData
            Write-Log -Message "Created label '$Name'" -Level "SUCCESS"
            return $created
        } catch {
            Write-Log -Message "Failed to create label '$Name': $_" -Level "WARN"
            return $null
        }
    }
}

# --- Upload image/attachment to GitHub repo contents ---
function Upload-ImageToGitHub {
    param([string]$FilePath, [string]$GhOrg, [string]$GhRepo, [string]$GhPat)

    $fileName = Split-Path $FilePath -Leaf
    # Use unique path with timestamp + GUID to avoid collisions on re-runs
    $uniqueName = "$(Get-Date -Format 'yyyyMMddHHmmss')_$([guid]::NewGuid().ToString('N').Substring(0,6))_$fileName"
    $uploadPath = "migrated-attachments/$uniqueName"
    $headers = Get-GhRestHeaders -Pat $GhPat

    # Detect default branch
    $defaultBranch = "main"
    try {
        $repoInfo = Invoke-RestMethod -Uri "https://api.github.com/repos/$GhOrg/$GhRepo" -Headers $headers
        $defaultBranch = $repoInfo.default_branch
    } catch {
        Write-Log -Message "Could not detect default branch, using 'main'" -Level "WARN"
    }

    $content = [Convert]::ToBase64String([IO.File]::ReadAllBytes($FilePath))
    $body = @{
        message = "Migration: upload attachment $fileName"
        content = $content
        branch  = $defaultBranch
    } | ConvertTo-Json

    $uri = "https://api.github.com/repos/$GhOrg/$GhRepo/contents/$uploadPath"
    try {
        $resp = Invoke-RestMethod -Uri $uri -Method PUT -Headers $headers -Body $body
        $downloadUrl = $resp.content.download_url
        Write-Log -Message "Uploaded image: $fileName -> $downloadUrl" -Level "DEBUG"
        return $downloadUrl
    } catch {
        Write-Log -Message "Failed to upload image $fileName to GitHub: $_" -Level "WARN"
        return $null
    }
}

# --- Create or get a GitHub Milestone ---
function Ensure-GhMilestone {
    param([string]$Org, [string]$Repo, [string]$Title, [string]$Pat)
    $headers = Get-GhRestHeaders -Pat $Pat
    $uri = "https://api.github.com/repos/$Org/$Repo/milestones?state=all&per_page=100"
    try {
        $milestones = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers
        $existing = $milestones | Where-Object { $_.title -eq $Title }
        if ($existing) { return $existing.number }
    } catch { }
    $body = @{ title = $Title } | ConvertTo-Json
    $createUri = "https://api.github.com/repos/$Org/$Repo/milestones"
    try {
        $created = Invoke-RestMethod -Uri $createUri -Method POST -Headers $headers -Body $body
        return $created.number
    } catch {
        Write-Log -Message "Failed to create milestone '$Title': $_" -Level "WARN"
        return $null
    }
}

# --- Add sub-issue relationship (GitHub Sub-Issues API) ---
function Add-GhSubIssue {
    param([string]$ParentIssueNodeId, [string]$ChildIssueNodeId, [string]$Pat)
    $mutation = "mutation { addSubIssue(input: {issueId: `"$ParentIssueNodeId`", subIssueId: `"$ChildIssueNodeId`"}) { issue { id } subIssue { id } } }"
    try {
        $resp = Invoke-GhGraphQL -Query $mutation -Pat $Pat
        if ($resp.errors) {
            Write-Log -Message "Sub-issue API not available, falling back to task list" -Level "WARN"
            return $false
        }
        return $true
    } catch {
        Write-Log -Message "Failed to add sub-issue relationship: $_" -Level "WARN"
        return $false
    }
}

# --- Get total issue count in a repo ---
function Get-GhIssueCount {
    param([string]$Org, [string]$Repo, [string]$Pat, [string]$State = "all")
    $headers = Get-GhRestHeaders -Pat $Pat
    $uri = "https://api.github.com/repos/$Org/$Repo/issues?state=$State&per_page=1"
    try {
        $resp = Invoke-WebRequest -Uri $uri -Method GET -Headers $headers
        # Parse Link header for total count
        $linkHeader = $resp.Headers["Link"]
        if ($linkHeader -and $linkHeader -match 'page=(\d+)>; rel="last"') {
            return [int]$Matches[1]
        }
        $issues = $resp.Content | ConvertFrom-Json
        return ($issues | Where-Object { -not $_.pull_request }).Count
    } catch { return 0 }
}

# --- Invite a GitHub user as a repo collaborator ---
function Invite-GhCollaborator {
    param([string]$Org, [string]$Repo, [string]$Username, [string]$Pat, [string]$Permission = "push")
    $headers = Get-GhRestHeaders -Pat $Pat
    $uri = "https://api.github.com/repos/$Org/$Repo/collaborators/$Username"
    $body = @{ permission = $Permission } | ConvertTo-Json
    try {
        $resp = Invoke-WebRequest -Uri $uri -Method PUT -Headers $headers -Body $body -UseBasicParsing
        if ($resp.StatusCode -eq 201) {
            Write-Log -Message "Invited '$Username' as collaborator ($Permission)" -Level "SUCCESS"
        } elseif ($resp.StatusCode -eq 204) {
            Write-Log -Message "'$Username' is already a collaborator" -Level "DEBUG"
        }
        return $true
    } catch {
        Write-Log -Message "Failed to invite '$Username': $_" -Level "WARN"
        return $false
    }
}

# --- Ensure repo has at least one commit (required for image uploads) ---
function Ensure-RepoInitialized {
    param([string]$Org, [string]$Repo, [string]$Pat)
    $headers = Get-GhRestHeaders -Pat $Pat
    # Check if repo has any commits
    try {
        $uri = "https://api.github.com/repos/$Org/$Repo/commits?per_page=1"
        Invoke-RestMethod -Uri $uri -Headers $headers | Out-Null
        return  # repo has commits, nothing to do
    } catch {
        # No commits - create initial README
        Write-Log -Message "Repo is empty. Creating initial commit for image uploads..." -Level "INFO"
        $content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("# $Repo`n`nRepository for migrated Azure DevOps work items.`n"))
        $body = @{
            message = "Initial commit - migration setup"
            content = $content
        } | ConvertTo-Json
        try {
            Invoke-RestMethod -Uri "https://api.github.com/repos/$Org/$Repo/contents/README.md" `
                -Method PUT -Headers $headers -Body $body | Out-Null
            Write-Log -Message "Created initial commit with README.md" -Level "SUCCESS"
        } catch {
            Write-Log -Message "Failed to initialize repo: $_" -Level "WARN"
        }
    }
}