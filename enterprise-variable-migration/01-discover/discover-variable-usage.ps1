param (
    [Parameter(Mandatory=$true)]
    [string]$Organization,

    [Parameter(Mandatory=$true)]
    [string]$Project,

    [Parameter(Mandatory=$true)]
    [string]$Pat
)

$ErrorActionPreference = "Stop"

# Create Auth Header
$base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))
$headers = @{Authorization=("Basic {0}" -f $base64AuthInfo)}

Write-Host "======================================================"
Write-Host " ADO Variable Group to Repository Mapping Discovery"
Write-Host "======================================================"

# 1. Get All Pipelines (Build Definitions) and map them to Repositories
Write-Host "Fetching all pipelines and their repositories..."
$pipelinesUrl = "https://dev.azure.com/$Organization/$Project/_apis/build/definitions?api-version=7.1"
$pipelinesResponse = Invoke-RestMethod -Uri $pipelinesUrl -Method Get -Headers $headers

$pipelineMap = @{}
foreach ($pipeline in $pipelinesResponse.value) {
    $repoName = $pipeline.repository.name
    $repoType = $pipeline.repository.type
    
    # If the summary API didn't return the repo name, fetch the full pipeline definition
    if ([string]::IsNullOrEmpty($repoName)) {
        try {
            $fullDefUrl = "https://dev.azure.com/$Organization/$Project/_apis/build/definitions/$($pipeline.id)?api-version=7.1"
            $fullDef = Invoke-RestMethod -Uri $fullDefUrl -Method Get -Headers $headers
            $repoName = $fullDef.repository.name
            $repoType = $fullDef.repository.type
        } catch {
            $repoName = "Unknown"
        }
    }

    $pipelineMap[$pipeline.id] = @{
        PipelineName = $pipeline.name
        RepoName     = $repoName
        RepoType     = $repoType
    }
}
Write-Host "Found $($pipelinesResponse.count) pipelines."

# 2. Get All Variable Groups
Write-Host "Fetching all variable groups..."
$varGroupsUrl = "https://dev.azure.com/$Organization/$Project/_apis/distributedtask/variablegroups?api-version=7.1-preview.2"
$varGroupsResponse = Invoke-RestMethod -Uri $varGroupsUrl -Method Get -Headers $headers
Write-Host "Found $($varGroupsResponse.count) variable groups."

# 3. Check Pipeline Permissions for each Variable Group
$reportData = @()

Write-Host "Analyzing pipeline usage for each variable group..."
foreach ($group in $varGroupsResponse.value) {
    $groupId = $group.id
    $groupName = $group.name

    # API to get Pipeline Permissions for a specific Variable Group
    $permissionsUrl = "https://dev.azure.com/$Organization/$Project/_apis/pipelines/pipelinepermissions/variablegroup/$groupId`?api-version=7.1-preview.1"
    
    try {
        $permissionsResponse = Invoke-RestMethod -Uri $permissionsUrl -Method Get -Headers $headers
        
        $hasPipelines = $false
        if ($permissionsResponse.pipelines) {
            foreach ($pipeAuth in $permissionsResponse.pipelines) {
                $pipeId = $pipeAuth.id
                $hasPipelines = $true
                
                # Look up the pipeline details from our map
                $pipeDetails = $pipelineMap[$pipeId]
                if ($pipeDetails) {
                    $reportData += [PSCustomObject]@{
                        VariableGroupName = $groupName
                        PipelineName      = $pipeDetails.PipelineName
                        RepositoryName    = $pipeDetails.RepoName
                        Status            = "Mapped"
                    }
                } else {
                    $reportData += [PSCustomObject]@{
                        VariableGroupName = $groupName
                        PipelineName      = "Unknown Pipeline ID: $pipeId"
                        RepositoryName    = "Unknown"
                        Status            = "Pipeline Not Found (Might be deleted or Classic Release)"
                    }
                }
            }
        }
        
        # If no pipelines are authorized to use this group
        if (-not $hasPipelines) {
            $reportData += [PSCustomObject]@{
                VariableGroupName = $groupName
                PipelineName      = "N/A"
                RepositoryName    = "N/A"
                Status            = "Unused / No Pipeline Permissions"
            }
        }

    } catch {
        Write-Host "Failed to get permissions for group: $groupName" -ForegroundColor Red
    }
}

# 4. Export to CSV
$csvPath = Join-Path $PSScriptRoot "VariableGroup-Usage-Report.csv"
$reportData | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

# 5. Generate JSON Mapping Template
Write-Host "Generating JSON Mapping Template..."
$jsonGroups = @()

# Group the report data by VariableGroupName
$groupedData = $reportData | Group-Object VariableGroupName

foreach ($group in $groupedData) {
    # Guess environment based on common ADO naming conventions
    $uniqueRepos = @($group.Group | Where-Object { $_.RepositoryName -ne "N/A" -and $_.RepositoryName -ne "Unknown" } | Select-Object -ExpandProperty RepositoryName -Unique)
    
    $suggestedScope = "repository"
    $suggestedRepo = ""
    $suggestedEnvironment = ""
    
    if ($uniqueRepos.Count -eq 1) {
        $suggestedRepo = $uniqueRepos[0]
        
        # Guess environment based on common ADO naming conventions
        if ($group.Name -match "(?i)-(dev|prod|prd|qa|uat.*|tst|test|stg|staging)$") {
            $suggestedScope = "environment"
            $suggestedEnvironment = $matches[1].ToLower()
            
            # Normalize common abbreviations
            if ($suggestedEnvironment -eq "prd") { $suggestedEnvironment = "production" }
            if ($suggestedEnvironment -eq "tst") { $suggestedEnvironment = "test" }
        }
    } elseif ($uniqueRepos.Count -gt 1) {
        $suggestedScope = "organization"
        $suggestedRepo = "MULTIPLE_REPOS_DETECTED"
    }

    $pipelinesList = ($group.Group.PipelineName | Select-Object -Unique) -join ", "

    $jsonGroups += @{
        adoGroupName      = $group.Name
        action            = "skip" # Default to skip for safety
        targetScope       = $suggestedScope
        targetRepo        = $suggestedRepo
        targetEnvironment = $suggestedEnvironment
        notes             = "Used by pipelines: $pipelinesList"
    }
}

$jsonOutput = @{
    _comment = "Set action to 'migrate'. targetScope can be 'organization', 'repository', or 'environment'."
    targetGitHubOrg = "Second-Devops-organisation1"
    variableGroups = $jsonGroups
}

$jsonPath = Join-Path $PSScriptRoot "variable-mappings-template.json"
$jsonOutput | ConvertTo-Json -Depth 4 | Out-File -FilePath $jsonPath -Encoding utf8

Write-Host "======================================================"
Write-Host "Discovery Complete!" -ForegroundColor Green
Write-Host "CSV Report: $csvPath" -ForegroundColor Cyan
Write-Host "JSON Template: $jsonPath" -ForegroundColor Cyan
Write-Host "======================================================"
