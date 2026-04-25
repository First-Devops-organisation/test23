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

# --- Upload image to GitHub (via issue comment hack for CDN URL) ---
function Upload-ImageToGitHub {
    param([string]$FilePath, [string]$GhOrg, [string]$GhRepo, [string]$GhPat)
    # Upload as repo content to a dedicated attachments branch
    $fileName = Split-Path $FilePath -Leaf
    $uploadPath = "migrated-attachments/$fileName"
    $content = [Convert]::ToBase64String([IO.File]::ReadAllBytes($FilePath))
    $headers = Get-GhRestHeaders -Pat $GhPat
    $body = @{
        message = "Migration: upload attachment $fileName"
        content = $content
        branch  = "main"
    } | ConvertTo-Json
    $uri = "https://api.github.com/repos/$GhOrg/$GhRepo/contents/$uploadPath"
    try {
        $resp = Invoke-RestMethod -Uri $uri -Method PUT -Headers $headers -Body $body
        return $resp.content.download_url
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