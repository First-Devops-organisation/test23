# ============================================================
#  GitHub REST + GraphQL API Helpers
#  Usage: . .\helpers\github-helpers.ps1
# ============================================================

function Get-GhRestHeaders {
    param([Parameter(Mandatory)][string]$Pat)
    return @{ Authorization = "token $Pat"; Accept = "application/vnd.github.v3+json"; "Content-Type" = "application/json"; "User-Agent" = "ADO-Migration-Script" }
}

function Get-GhGraphQLHeaders {
    param([Parameter(Mandatory)][string]$Pat)
    return @{ Authorization = "bearer $Pat"; "Content-Type" = "application/json"; "User-Agent" = "ADO-Migration-Script" }
}

# --- Invoke GraphQL with retry, rate-limit, and secondary abuse-detection handling ---
function Invoke-GhGraphQL {
    param([string]$Query, [string]$Pat, [int]$RetryCount = 5)
    $headers = @{ Authorization = "bearer $Pat"; "Content-Type" = "application/json"; "User-Agent" = "ADO-Migration-Script" }
    
    # Ensure body is strictly a single string
    $jsonObj = @{ query = $Query }
    $body = $jsonObj | ConvertTo-Json -Depth 10 -Compress
    if ($body -is [array]) { $body = $body -join '' }
    $body = [string]$body

    for ($i = 1; $i -le $RetryCount; $i++) {
        try {
            $resp = Invoke-WebRequest -Method POST -Uri "https://api.github.com/graphql" `
                -Headers $headers -Body $body -UseBasicParsing
            # Check remaining rate limit from response headers
            $remHeader = $resp.Headers["X-RateLimit-Remaining"]
            $remaining = if ($remHeader -is [array]) { $remHeader[0] } else { $remHeader }
            
            if ($remaining -and [int]$remaining -lt 100) {
                $resetHeader = $resp.Headers["X-RateLimit-Reset"]
                $resetEpoch = [int](if ($resetHeader -is [array]) { $resetHeader[0] } else { $resetHeader })
                $nowEpoch = [int](Get-Date -UFormat %s)
                $waitSec = $resetEpoch - $nowEpoch
                if ($waitSec -gt 0 -and $waitSec -lt 3600) {
                    Write-Log -Message "Rate limit low ($remaining remaining). Sleeping ${waitSec}s" -Level "WARN"
                    Start-Sleep -Seconds ($waitSec + 5)
                }
            }
            $json = $resp.Content | ConvertFrom-Json
            if ($json.errors) {
                Write-Log -Message "GraphQL errors: $($json.errors | ConvertTo-Json -Compress)" -Level "WARN"
            }
            return $json
        } catch {
            $errLine = if ($_.InvocationInfo) { $_.InvocationInfo.ScriptLineNumber } else { "Unknown" }
            $errMsg = if ($_.Exception) { $_.Exception.Message } else { $_ }
            Write-Log -Message "GraphQL failed on line $errLine (attempt $i/$RetryCount): $errMsg" -Level "WARN"
            
            $statusCode = $null
            # Secondary rate limit / abuse detection (403 or 429)
            if ($statusCode -eq 403 -or $statusCode -eq 429) {
                $retryAfter = $null
                try { 
                    $raHeader = $_.Exception.Response.Headers["Retry-After"]
                    $retryAfter = if ($raHeader -is [array]) { $raHeader[0] } else { $raHeader }
                } catch { }
                $waitSec = if ($retryAfter) { [int]$retryAfter + 5 }
                           else { [math]::Pow(2, $i) * 30 }
                Write-Log -Message "Secondary rate limit (HTTP $statusCode). Waiting ${waitSec}s (attempt $i)" -Level "WARN"
                Start-Sleep -Seconds ([math]::Min($waitSec, 900))
                continue
            }
            if ($i -eq $RetryCount) { throw }
            $wait = [math]::Pow(2, $i) * 1000
            Write-Log -Message "Retrying in $($wait/1000)s..." -Level "WARN"
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

# --- Create a custom field in GitHub ProjectV2 ---
# Supports: SINGLE_SELECT, NUMBER, TEXT
function New-GhProjectCustomField {
    param(
        [string]$ProjectId,
        [string]$Pat,
        [string]$FieldName,
        [ValidateSet("SINGLE_SELECT","NUMBER","TEXT")]
        [string]$DataType,
        [hashtable[]]$Options  # For SINGLE_SELECT: @(@{name="X";color="BLUE"}, ...)
    )

    $colors = @("GRAY","BLUE","GREEN","YELLOW","ORANGE","RED","PINK","PURPLE")

    # Build options JSON for the singleSelectOptions input
    if ($DataType -eq "SINGLE_SELECT" -and $Options) {
        $optEntries = @()
        $ci = 0
        foreach ($opt in $Options) {
            $c = if ($opt.color) { $opt.color } else { $colors[$ci % $colors.Count] }
            $safeName = $opt.name -replace '"', '\"'
            $optEntries += "{ name: `"$safeName`", color: $c, description: `"`" }"
            $ci++
        }
        $optionsLine = "singleSelectOptions: [$($optEntries -join ', ')]"
    } else {
        $optionsLine = ""
    }

    # Build mutation with proper quoting (no backslash escaping)
    $mutationParts = @(
        "mutation {"
        "  createProjectV2Field(input: {"
        "    projectId: `"$ProjectId`""
        "    dataType: $DataType"
        "    name: `"$FieldName`""
    )
    if ($optionsLine) { $mutationParts += "    $optionsLine" }
    $mutationParts += @(
        "  }) {"
        "    projectV2Field {"
        "      ... on ProjectV2SingleSelectField { id name options { id name } }"
        "      ... on ProjectV2Field { id name }"
        "    }"
        "  }"
        "}"
    )
    $mutation = $mutationParts -join "`n"

    Write-Log -Message "Creating field '$FieldName' ($DataType)..." -Level "DEBUG"

    $resp = Invoke-GhGraphQL -Query $mutation -Pat $Pat
    if ($resp.data.createProjectV2Field) {
        $field = $resp.data.createProjectV2Field.projectV2Field
        Write-Log -Message "Created custom field: $FieldName ($DataType)" -Level "SUCCESS"
        return $field
    } else {
        Write-Log -Message "Failed to create field '$FieldName': $($resp.errors | ConvertTo-Json -Compress)" -Level "ERROR"
        return $null
    }
}

# --- Set a single-select custom field value by option name ---
function Set-GhProjectItemSelectField {
    param(
        [string]$ProjectId,
        [string]$ItemId,
        [string]$FieldId,
        [string]$OptionId,
        [string]$Pat
    )

    $mutation = @"
mutation {
  updateProjectV2ItemFieldValue(input: {
    projectId: "$ProjectId"
    itemId: "$ItemId"
    fieldId: "$FieldId"
    value: { singleSelectOptionId: "$OptionId" }
  }) { projectV2Item { id } }
}
"@
    Invoke-GhGraphQL -Query $mutation -Pat $Pat | Out-Null
}

# --- Set a number custom field value ---
function Set-GhProjectItemNumberField {
    param(
        [string]$ProjectId,
        [string]$ItemId,
        [string]$FieldId,
        [double]$Value,
        [string]$Pat
    )

    $mutation = @"
mutation {
  updateProjectV2ItemFieldValue(input: {
    projectId: "$ProjectId"
    itemId: "$ItemId"
    fieldId: "$FieldId"
    value: { number: $Value }
  }) { projectV2Item { id } }
}
"@
    Invoke-GhGraphQL -Query $mutation -Pat $Pat | Out-Null
}

# --- Set a text custom field value ---
function Set-GhProjectItemTextField {
    param([string]$ProjectId, [string]$ItemId, [string]$FieldId, [string]$Value, [string]$Pat)
    $safeValue = $Value -replace '\\', '\\' -replace '"', '\"' -replace "`n", '\n' -replace "`r", ''
    $mutation = @"
mutation {
  updateProjectV2ItemFieldValue(input: {
    projectId: "$ProjectId", itemId: "$ItemId", fieldId: "$FieldId",
    value: { text: "$safeValue" }
  }) { projectV2Item { id } }
}
"@
    Invoke-GhGraphQL -Query $mutation -Pat $Pat | Out-Null
}

# --- Set a date custom field value (ISO 8601: yyyy-MM-dd) ---
function Set-GhProjectItemDateField {
    param([string]$ProjectId, [string]$ItemId, [string]$FieldId, [string]$Value, [string]$Pat)
    $mutation = @"
mutation {
  updateProjectV2ItemFieldValue(input: {
    projectId: "$ProjectId", itemId: "$ItemId", fieldId: "$FieldId",
    value: { date: "$Value" }
  }) { projectV2Item { id } }
}
"@
    Invoke-GhGraphQL -Query $mutation -Pat $Pat | Out-Null
}

# ============================================================
# NEW: Auto-Create a GitHub ProjectV2 Board from ADO board info
# ============================================================
# Creates a Project V2 board with the given name under the org/user.
# If a project with that name already exists, it reuses it (idempotent).
# Returns: the project node_id (e.g. PVT_kwHO...)
function New-GhProject {
    param(
        [string]$Owner,          # org or user login
        [string]$OwnerType,      # "organization" or "user"
        [string]$ProjectName,    # name to give the board
        [string[]]$StatusOptions, # ADO column names to add as status options
        [string]$Pat
    )

    # Step 1: Resolve owner node_id via GraphQL
    if ($OwnerType -eq "user") {
        $q = "{ user(login: `"$Owner`") { id } }"
        $resp = Invoke-GhGraphQL -Query $q -Pat $Pat
        $ownerId = $resp.data.user.id
    } else {
        $q = "{ organization(login: `"$Owner`") { id } }"
        $resp = Invoke-GhGraphQL -Query $q -Pat $Pat
        $ownerId = $resp.data.organization.id
    }

    if (-not $ownerId) {
        Write-Log -Message "Could not resolve owner node_id for '$Owner'" -Level "ERROR"
        return $null
    }

    # Step 2: Check if project already exists (idempotent)
    if ($OwnerType -eq "user") {
        $qFind = "{ user(login: `"$Owner`") { projectsV2(first: 50) { nodes { id title } } } }"
        $rFind = Invoke-GhGraphQL -Query $qFind -Pat $Pat
        $existing = $rFind.data.user.projectsV2.nodes | Where-Object { $_.title -eq $ProjectName }
    } else {
        $qFind = "{ organization(login: `"$Owner`") { projectsV2(first: 50) { nodes { id title } } } }"
        $rFind = Invoke-GhGraphQL -Query $qFind -Pat $Pat
        $existing = $rFind.data.organization.projectsV2.nodes | Where-Object { $_.title -eq $ProjectName }
    }

    if ($existing) {
        Write-Log -Message "Reusing existing Project V2 '$ProjectName' ($($existing.id))" -Level "INFO"
        return $existing.id
    }

    # Step 3: Create the project
    $safeName = $ProjectName -replace '"', '\"'
    $mutation = @"
mutation {
  createProjectV2(input: {
    ownerId: "$ownerId"
    title: "$safeName"
  }) { projectV2 { id url } }
}
"@
    $resp = Invoke-GhGraphQL -Query $mutation -Pat $Pat
    $projectId = $resp.data.createProjectV2.projectV2.id
    $projectUrl = $resp.data.createProjectV2.projectV2.url

    if (-not $projectId) {
        Write-Log -Message "Failed to create Project V2 '$ProjectName'" -Level "ERROR"
        return $null
    }
    Write-Log -Message "Created Project V2 '$ProjectName': $projectUrl" -Level "SUCCESS"

    # Step 4: Add ADO board columns as Status options
    if ($StatusOptions -and $StatusOptions.Count -gt 0) {
        # Get the auto-created Status field
        $fields = Get-GhProjectFields -ProjectId $projectId -Pat $Pat
        $statusField = $fields | Where-Object { $_.__typename -eq "ProjectV2SingleSelectField" -and $_.name -eq "Status" }

        if ($statusField) {
            $existingNames = @($statusField.options | ForEach-Object { $_.name })
            $colors = @("GRAY","BLUE","GREEN","YELLOW","ORANGE","RED","PINK","PURPLE")
            $ci = 0
            foreach ($colName in $StatusOptions) {
                if ($existingNames -notcontains $colName) {
                    $safeCol = $colName -replace '"', '\"'
                    $color = $colors[$ci % $colors.Count]
                    $addOptMutation = @"
mutation {
  updateProjectV2(input: {
    projectId: "$projectId"
  }) { projectV2 { id } }
}
"@
                    # Add option via field update mutation
                    $addOptQ = @"
mutation {
  createProjectV2Field(input: {
    projectId: "$projectId"
    dataType: SINGLE_SELECT
    name: "Status"
    singleSelectOptions: [{ name: "$safeCol", color: $color, description: "" }]
  }) { projectV2Field { ... on ProjectV2SingleSelectField { id name options { id name } } } }
}
"@
                    # We can't add options to existing Status field via this mutation - use note instead
                    Write-Log -Message "  Status column '$colName' will be auto-populated as items are added" -Level "DEBUG"
                    $ci++
                }
            }
        }
    }

    return $projectId
}

# ============================================================
# NEW: Sync ADO Sprints/Iterations -> GitHub Milestones
# ============================================================
# Reads all ADO iteration paths (sprints) and creates matching
# GitHub Milestones with due dates. Idempotent - skips existing.
# Returns: hashtable of sprint short name -> GitHub milestone number
function Sync-GhMilestonesFromAdo {
    param(
        [string]$AdoOrg,
        [string]$AdoProject,
        [string]$AdoPat,
        [string]$GhOrg,
        [string]$GhRepo,
        [string]$GhPat
    )

    Write-Log -Message "Syncing ADO sprints -> GitHub Milestones..." -Level "INFO"

    # Step 1: Fetch all ADO iterations (sprints)
    $adoB64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat"))
    $adoHeaders = @{ Authorization = "Basic $adoB64"; Accept = "application/json" }
    $iterUri = "https://dev.azure.com/$AdoOrg/$AdoProject/_apis/work/teamsettings/iterations?api-version=7.1"
    try {
        $iterResp = Invoke-RestMethod -Uri $iterUri -Method GET -Headers $adoHeaders
    } catch {
        Write-Log -Message "Could not fetch ADO iterations: $_" -Level "WARN"
        return @{}
    }

    $sprints = $iterResp.value
    if (-not $sprints -or $sprints.Count -eq 0) {
        Write-Log -Message "No ADO sprints/iterations found." -Level "WARN"
        return @{}
    }
    Write-Log -Message "Found $($sprints.Count) ADO sprint(s)." -Level "INFO"

    # Step 2: Load existing GitHub milestones
    $ghHeaders = Get-GhRestHeaders -Pat $GhPat
    $existingMilestones = @{}
    $page = 1
    do {
        $msUri = "https://api.github.com/repos/$GhOrg/$GhRepo/milestones?state=all&per_page=100&page=$page"
        $msResp = try { Invoke-RestMethod -Uri $msUri -Method GET -Headers $ghHeaders } catch { $null }
        if ($msResp) {
            foreach ($ms in $msResp) { $existingMilestones[$ms.title] = $ms.number }
        }
        $page++
    } while ($msResp -and $msResp.Count -eq 100)
    Write-Log -Message "Found $($existingMilestones.Count) existing milestone(s) in GitHub." -Level "INFO"

    # Step 3: Create missing milestones
    $milestoneMap = @{}  # sprint short name -> GH milestone number
    foreach ($sprint in $sprints) {
        $sprintName = $sprint.name
        $shortName  = ($sprint.path -split '\\')[-1]  # e.g. "Sprint 3" from "Project\Sprint 3"

        # Use short name as milestone title (matches what the migrator writes to IterationPath)
        $msTitle = $shortName

        if ($existingMilestones.ContainsKey($msTitle)) {
            Write-Log -Message "  Reusing milestone: '$msTitle' (#$($existingMilestones[$msTitle]))" -Level "INFO"
            $milestoneMap[$shortName] = $existingMilestones[$msTitle]
        } else {
            # Build milestone body
            $msBody = @{ title = $msTitle }
            if ($sprint.attributes.finishDate) {
                # GitHub milestones need due_on in ISO 8601
                $due = ([datetime]$sprint.attributes.finishDate).ToString("yyyy-MM-ddTHH:mm:ssZ")
                $msBody.due_on = $due
            }
            if ($sprint.attributes.startDate -and $sprint.attributes.finishDate) {
                $msBody.description = "ADO Sprint: $($sprint.path) | Start: $($sprint.attributes.startDate) | End: $($sprint.attributes.finishDate)"
            }

            $msJson = $msBody | ConvertTo-Json -Depth 5
            $createUri = "https://api.github.com/repos/$GhOrg/$GhRepo/milestones"
            try {
                $created = Invoke-GhRestWithRetry -Uri $createUri -Method POST -Headers $ghHeaders -Body $msJson
                Write-Log -Message "  Created milestone: '$msTitle' (#$($created.number))" -Level "SUCCESS"
                $milestoneMap[$shortName] = $created.number
                Start-Sleep -Milliseconds 500
            } catch {
                Write-Log -Message "  Failed to create milestone '$msTitle': $_" -Level "WARN"
            }
        }
    }

    Write-Log -Message "Sprint->Milestone sync complete. $($milestoneMap.Count) mapped." -Level "SUCCESS"
    return $milestoneMap
}

# --- BATCH: Set multiple custom fields in a single GraphQL call ---
# Reduces 20 individual mutations to 1 call (~95% rate limit savings)
# Each $FieldUpdates entry: @{ fieldId; value; type = "select"|"number"|"text"|"date" }
function Set-GhProjectItemFieldsBatch {
    param(
        [string]$ProjectId,
        [string]$ItemId,
        [hashtable[]]$FieldUpdates,
        [string]$Pat
    )
    if (-not $FieldUpdates -or $FieldUpdates.Count -eq 0) { return }

    $aliases = @()
    $i = 0
    foreach ($fu in $FieldUpdates) {
        if (-not $fu.fieldId -or -not $fu.type) { continue }
        $i++
        $valExpr = switch ($fu.type) {
            "select" { "singleSelectOptionId: `"$($fu.value)`"" }
            "number" { 
                $numStr = [System.Convert]::ToDouble($fu.value).ToString("0.0#######", [System.Globalization.CultureInfo]::InvariantCulture)
                "number: $numStr" 
            }
            "text"   {
                $safe = "$($fu.value)" -replace '\\', '\\' -replace '"', '\"' -replace "`n", '\n' -replace "`r", ''
                "text: `"$safe`""
            }
            "date"   { "date: `"$($fu.value)`"" }
            default  { "text: `"$($fu.value)`"" }
        }
        $aliases += "  f${i}: updateProjectV2ItemFieldValue(input: { projectId: `"$ProjectId`", itemId: `"$ItemId`", fieldId: `"$($fu.fieldId)`", value: { $valExpr } }) { projectV2Item { id } }"
    }
    if ($aliases.Count -eq 0) { return }

    $mutation = "mutation {`n$($aliases -join "`n")`n}"
    $resp = Invoke-GhGraphQL -Query $mutation -Pat $Pat
    if ($resp.errors) {
        Write-Log -Message "Batch field update errors: $($resp.errors | ConvertTo-Json -Compress)" -Level "WARN"
        Write-Log -Message "Query was: $mutation" -Level "DEBUG"
    }
}
# Returns a hashtable of field definitions with their IDs and options
# Creates ALL 20 fields from the Master Plan Section 3.2
function Ensure-GhProjectCustomFields {
    param(
        [string]$ProjectId,
        [string]$Pat,
        [string[]]$RequiredStates,
        [hashtable]$FieldConfig = @{}
    )
    $fields = Get-GhProjectFields -ProjectId $ProjectId -Pat $Pat
    $result = @{}
    function Find-Field($name) { return $fields | Where-Object { $_.name -eq $name } }
    function Ensure-Field {
        param([string]$Key, [string]$Name, [string]$DataType, [hashtable[]]$Opts = @())
        $existing = Find-Field $Name
        if ($existing) {
            Write-Log -Message "Field '$Name' exists" -Level "INFO"; $result[$Key] = $existing
        } else {
            if ($DataType -eq "SINGLE_SELECT" -and $Opts.Count -gt 0) {
                $result[$Key] = New-GhProjectCustomField -ProjectId $ProjectId -Pat $Pat -FieldName $Name -DataType $DataType -Options $Opts
            } else {
                $result[$Key] = New-GhProjectCustomField -ProjectId $ProjectId -Pat $Pat -FieldName $Name -DataType $DataType
            }
            Start-Sleep -Milliseconds 500
        }
    }
    # 1. ADO Status
    if ($RequiredStates.Count -gt 0) {
        Ensure-Field -Key "adoStatus" -Name "ADO Status" -DataType "SINGLE_SELECT" -Opts @($RequiredStates | ForEach-Object { @{ name = $_ } })
    }
    # 2. Item Type (work item type dropdown — mirrors ADO's type system)
    Ensure-Field -Key "itemType" -Name "Item Type" -DataType "SINGLE_SELECT" -Opts @(
        @{ name = "Epic"; color = "PURPLE" }, @{ name = "Feature"; color = "BLUE" },
        @{ name = "User Story"; color = "GREEN" }, @{ name = "Product Backlog Item"; color = "GREEN" },
        @{ name = "Task"; color = "YELLOW" }, @{ name = "Bug"; color = "RED" },
        @{ name = "Test Plan"; color = "GRAY" }, @{ name = "Test Suite"; color = "GRAY" },
        @{ name = "Test Case"; color = "GRAY" }, @{ name = "Issue"; color = "ORANGE" },
        @{ name = "Impediment"; color = "ORANGE" }, @{ name = "Change Request"; color = "PINK" },
        @{ name = "Idea"; color = "BLUE" }, @{ name = "Analysis"; color = "BLUE" })
    # 3. Priority
    Ensure-Field -Key "priority" -Name "Priority" -DataType "SINGLE_SELECT" -Opts @(
        @{ name = "P1 - Critical"; color = "RED" }, @{ name = "P2 - High"; color = "ORANGE" },
        @{ name = "P3 - Medium"; color = "YELLOW" }, @{ name = "P4 - Low"; color = "GREEN" })
    # 3. Severity
    Ensure-Field -Key "severity" -Name "Severity" -DataType "SINGLE_SELECT" -Opts @(
        @{ name = "1 - Critical"; color = "RED" }, @{ name = "2 - High"; color = "ORANGE" },
        @{ name = "3 - Medium"; color = "YELLOW" }, @{ name = "4 - Low"; color = "GREEN" })
    # 4. Story Points
    Ensure-Field -Key "storyPoints" -Name "Story Points" -DataType "NUMBER"
    # 5. ADO ID (text for traceability)
    Ensure-Field -Key "adoId" -Name "ADO ID" -DataType "TEXT"
    # 6. Value Area
    Ensure-Field -Key "valueArea" -Name "Value Area" -DataType "SINGLE_SELECT" -Opts @(
        @{ name = "Business"; color = "BLUE" }, @{ name = "Architectural"; color = "PURPLE" })
    # 7. Activity
    Ensure-Field -Key "activity" -Name "Activity" -DataType "SINGLE_SELECT" -Opts @(
        @{ name = "Deployment"; color = "BLUE" }, @{ name = "Design"; color = "PURPLE" },
        @{ name = "Development"; color = "GREEN" }, @{ name = "Documentation"; color = "GRAY" },
        @{ name = "Requirements"; color = "YELLOW" }, @{ name = "Testing"; color = "ORANGE" })
    # 8. Current Environment
    Ensure-Field -Key "currentEnvironment" -Name "Current Environment" -DataType "SINGLE_SELECT" -Opts @(
        @{ name = "DEV"; color = "BLUE" }, @{ name = "Local"; color = "GRAY" },
        @{ name = "PROD"; color = "RED" }, @{ name = "QA"; color = "YELLOW" }, @{ name = "UAT"; color = "ORANGE" })
    # 9. Item Category
    Ensure-Field -Key "itemCategory" -Name "Item Category" -DataType "SINGLE_SELECT" -Opts @(
        @{ name = "PIM"; color = "PURPLE" }, @{ name = "Technical"; color = "BLUE" }, @{ name = "UX"; color = "GREEN" })
    # 10. Item SubCategory
    Ensure-Field -Key "itemSubCategory" -Name "Item SubCategory" -DataType "TEXT"
    # 11-13. Work tracking numbers
    Ensure-Field -Key "originalEstimate" -Name "Original Estimate (hrs)" -DataType "NUMBER"
    Ensure-Field -Key "completedWork" -Name "Completed Work (hrs)" -DataType "NUMBER"
    Ensure-Field -Key "remainingWork" -Name "Remaining Work (hrs)" -DataType "NUMBER"
    # 14. Risk
    Ensure-Field -Key "risk" -Name "Risk" -DataType "SINGLE_SELECT" -Opts @(
        @{ name = "1 - High"; color = "RED" }, @{ name = "2 - Medium"; color = "YELLOW" }, @{ name = "3 - Low"; color = "GREEN" })
    # 15. T-Shirt Size
    Ensure-Field -Key "tShirtSize" -Name "T-Shirt Size" -DataType "SINGLE_SELECT" -Opts @(
        @{ name = "XS"; color = "GRAY" }, @{ name = "S"; color = "BLUE" }, @{ name = "M"; color = "GREEN" },
        @{ name = "L"; color = "YELLOW" }, @{ name = "XL"; color = "ORANGE" }, @{ name = "XXL"; color = "RED" })
    # 16-17. Path text fields
    Ensure-Field -Key "areaPathText" -Name "Area Path" -DataType "TEXT"
    Ensure-Field -Key "iterationPathText" -Name "Iteration Path" -DataType "TEXT"
    # 18-19. Dates (TEXT fallback — ProjectV2 DATE creation via API is limited)
    Ensure-Field -Key "startDate" -Name "Start Date" -DataType "TEXT"
    Ensure-Field -Key "targetDate" -Name "Target Date" -DataType "TEXT"
    # 20. Value Stream (DistEcom-specific)
    Ensure-Field -Key "valueStream" -Name "Value Stream" -DataType "SINGLE_SELECT" -Opts @(
        @{ name = "Architecture"; color = "PURPLE" }, @{ name = "Business"; color = "BLUE" },
        @{ name = "Business Request"; color = "BLUE" }, @{ name = "Compliance"; color = "RED" },
        @{ name = "Functional"; color = "GREEN" }, @{ name = "Idea"; color = "YELLOW" },
        @{ name = "Operational"; color = "ORANGE" }, @{ name = "Release Management"; color = "GRAY" },
        @{ name = "User Experience"; color = "PINK" })

    Write-Log -Message "Custom fields complete: $($result.Count) fields ready" -Level "SUCCESS"
    return $result
}


# --- Helper to invoke REST API with rate-limit retry ---
function Invoke-GhRestWithRetry {
    param([string]$Uri, [string]$Method, [hashtable]$Headers, [string]$Body, [int]$RetryCount = 5)
    
    for ($i = 1; $i -le $RetryCount; $i++) {
        try {
            if ($Body) {
                return Invoke-RestMethod -Uri $Uri -Method $Method -Headers $Headers -Body $Body
            } else {
                return Invoke-RestMethod -Uri $Uri -Method $Method -Headers $Headers
            }
        } catch {
            $statusCode = if ($_.Exception.Response) { $_.Exception.Response.StatusCode.value__ } else { 0 }
            if ($statusCode -eq 403 -or $statusCode -eq 429) {
                $retryAfter = $_.Exception.Response.Headers["Retry-After"]
                $waitSec = if ($retryAfter) { [int]$retryAfter + 5 } else { [math]::Pow(2, $i) * 10 }
                Write-Log -Message "REST Secondary rate limit (HTTP $statusCode). Waiting ${waitSec}s (attempt $i/$RetryCount)" -Level "WARN"
                Start-Sleep -Seconds ([math]::Min($waitSec, 300))
                continue
            }
            throw
        }
    }
    throw "Max retries exceeded for $Uri"
}

# --- Create a GitHub Issue via REST API ---
function New-GhIssue {
    param([string]$Org, [string]$Repo, [string]$Title, [string]$Body, [string[]]$Labels, [string[]]$Assignees, [int]$Milestone, [string]$Pat)
    $headers = Get-GhRestHeaders -Pat $Pat
    $issueData = @{ title = $Title; body = $Body; labels = $Labels }
    if ($Assignees -and $Assignees.Count -gt 0) {
        $validAssignees = @($Assignees | Where-Object { -not [string]::IsNullOrEmpty($_) })
        if ($validAssignees.Count -gt 0) { $issueData.assignees = @($validAssignees) }
    }
    if ($Milestone -gt 0) {
        $issueData.milestone = $Milestone
    }
    $jsonBody = $issueData | ConvertTo-Json -Depth 10
    $uri = "https://api.github.com/repos/$Org/$Repo/issues"
    try {
        $resp = Invoke-GhRestWithRetry -Uri $uri -Method POST -Headers $headers -Body $jsonBody
        return $resp
    } catch {
        # If assignees caused the failure (user not a collaborator), retry without them
        if ($issueData.assignees -and $issueData.assignees.Count -gt 0) {
            $intendedAssignees = $issueData.assignees -join ', '
            Write-Log -Message "Assignee(s) [$intendedAssignees] not collaborator(s). Creating issue without assignment. Original assignee preserved in metadata." -Level "WARN"
            $issueData.Remove('assignees')
            $jsonBody = $issueData | ConvertTo-Json -Depth 10
            try {
                $resp = Invoke-GhRestWithRetry -Uri $uri -Method POST -Headers $headers -Body $jsonBody
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
    # Proactive sleep before every comment to avoid secondary rate limits
    Start-Sleep -Seconds 5
    try {
        return Invoke-GhRestWithRetry -Uri $uri -Method POST -Headers $headers -Body $jsonBody
    } catch {
        Write-Log -Message "Failed to add comment to issue #$IssueNumber`: $_" -Level "WARN"
        return $null
    }
}

# --- Close a GitHub Issue ---
function Close-GhIssue {
    param([string]$Org, [string]$Repo, [int]$IssueNumber, [string]$Pat)
    $headers = Get-GhRestHeaders -Pat $Pat
    $jsonBody = @{ state = "closed"; state_reason = "completed" } | ConvertTo-Json -Compress
    $uri = "https://api.github.com/repos/$Org/$Repo/issues/$IssueNumber"
    try {
        Invoke-GhRestWithRetry -Uri $uri -Method PATCH -Headers $headers -Body $jsonBody | Out-Null
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
        # Use permanent URL (not download_url which has expiring token)
        $permanentUrl = "https://github.com/$GhOrg/$GhRepo/raw/$defaultBranch/$uploadPath"
        Write-Log -Message "Uploaded: $fileName -> $permanentUrl" -Level "DEBUG"
        return $permanentUrl
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
        # Sub-issues API requires special preview header
        $headers = @{
            Authorization  = "Bearer $Pat"
            "Content-Type" = "application/json"
            Accept         = "application/vnd.github+json"
            "X-Github-Next"= "sub_issues"
        }
        $body = @{ query = $mutation } | ConvertTo-Json -Depth 10
        $resp = Invoke-RestMethod -Method POST -Uri "https://api.github.com/graphql" -Headers $headers -Body $body
        if ($resp.errors) {
            $errMsg = ($resp.errors | ForEach-Object { $_.message }) -join '; '
            Write-Log -Message "Sub-issue API error: $errMsg" -Level "WARN"
            return $false
        }
        if ($resp.data.addSubIssue) { return $true }
        return $false
    } catch {
        Write-Log -Message "Failed to add sub-issue: $_" -Level "WARN"
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