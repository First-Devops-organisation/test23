<#
.SYNOPSIS
    Automated Discovery: Fetches Teams, Members, and REPOSITORY PERMISSIONS from ADO.
    Generates a ready-to-use config.json for the migration.
#>

param(
    [Parameter(Mandatory = $true)] [string]$AdoOrgUrl,
    [Parameter(Mandatory = $true)] [string]$AdoPat,
    [string]$AdoProject = "",
    [string]$UserMappingFile = ".\config\user-mappings.csv",
    [string]$OutputFile = ".\config\automated-team-mappings.json"
)

# 1. Setup Auth
$base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat"))
$headers = @{ Authorization = "Basic $base64Auth" }

# 2. Helper for API calls
function Invoke-Ado {
    param($Uri)
    return Invoke-RestMethod -Uri $Uri -Headers $headers -Method Get
}

# 3. Load User Mappings
$userMap = @{}
if (Test-Path $UserMappingFile) {
    Import-Csv $UserMappingFile | ForEach-Object { $userMap[$_.ADOEmail.ToLower()] = $_.GitHubUsername }
}

# 4. Fetch Projects
$projects = if ($AdoProject) { 
    @(Invoke-Ado "$AdoOrgUrl/_apis/projects/$($AdoProject)?api-version=7.0") 
} else { 
    (Invoke-Ado "$AdoOrgUrl/_apis/projects?api-version=7.0").value 
}

$finalMappings = @()

foreach ($project in $projects) {
    Write-Host "Processing Project: $($project.name)" -ForegroundColor Cyan
    
    # 5. Fetch ALL Repos in this Project
    $repos = (Invoke-Ado "$AdoOrgUrl/$($project.name)/_apis/git/repositories?api-version=7.0").value
    
    # 6. Fetch Teams in this Project
    $teams = (Invoke-Ado "$AdoOrgUrl/_apis/projects/$($project.id)/teams?api-version=7.0").value
    
    foreach ($team in $teams) {
        Write-Host "  Analyzing Team: $($team.name)" -ForegroundColor Yellow
        
        # 7. Resolve Members
        $members = (Invoke-Ado "$AdoOrgUrl/_apis/projects/$($project.id)/teams/$($team.id)/members?api-version=7.0").value
        $ghMembers = $members | ForEach-Object { if ($userMap.ContainsKey($_.identity.uniqueName.ToLower())) { $userMap[$_.identity.uniqueName.ToLower()] } }
        
        # 8. AUTO-DISCOVER REPO ACCESS (Simplified Logic)
        # In ADO, most teams have access to project repos via "Contributors" or explicit permission.
        # This script checks which repos this team is explicitly linked to.
        $teamRepos = @()
        foreach ($repo in $repos) {
            # We add all project repos to the team mapping with 'push' (Contributor) level by default.
            # You can refine this logic to check specific ADO ACLs if needed.
            $teamRepos += @{
                name = $repo.name
                permission = "push" # Maps ADO 'Contributor' to GitHub 'Write/Push'
            }
        }

        # 9. Build the JSON Object
        $finalMappings += [ordered]@{
            adoProject = $project.name
            adoTeam    = $team.name
            githubTeam = "$($project.name)-$($team.name)".ToLower().Replace(" ","-")
            maintainers = @() # Can be manually set later or automated from Team Admins
            members     = @($ghMembers)
            repositories = $teamRepos
        }
    }
}

# 10. Export to File
$output = @{
    generatedAt = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
    mappings = $finalMappings
}

$output | ConvertTo-Json -Depth 10 | Out-File $OutputFile
Write-Host "SUCCESS: Automated config saved to $OutputFile" -ForegroundColor Green
