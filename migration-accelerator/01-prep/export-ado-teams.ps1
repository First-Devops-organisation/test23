<#
.SYNOPSIS
    Fetches all Projects and Teams from an Azure DevOps organization and exports them to a JSON mapping template.

.DESCRIPTION
    This script connects to Azure DevOps, retrieves a list of all projects, and then retrieves all teams within those projects. 
    It outputs a base `team-mappings.json` structure that you can use as a starting point to map your ADO teams to GitHub teams.

.PARAMETER AdoOrgUrl
    Azure DevOps organization URL. Example: https://dev.azure.com/myorganization

.PARAMETER AdoPat
    Azure DevOps Personal Access Token with at least Project and Team (Read) scope.

.PARAMETER OutputFile
    Path to save the generated JSON template.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AdoOrgUrl,

    [Parameter(Mandatory = $true)]
    [string]$AdoPat,

    [string]$OutputFile = ".\config\team-mappings-template.json"
)

$ErrorActionPreference = "Stop"

$base64AdoAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat"))
$adoHeaders = @{ Authorization = "Basic $base64AdoAuth" }

Write-Host "Fetching projects from $AdoOrgUrl..." -ForegroundColor Cyan

# 1. Get All Projects
$projectsUrl = "$AdoOrgUrl/_apis/projects?api-version=7.1"
try {
    $projectsResponse = Invoke-RestMethod -Uri $projectsUrl -Headers $adoHeaders -Method Get
} catch {
    Write-Error "Failed to fetch projects. Please check your URL and PAT."
    exit 1
}

$mappings = @()

# 2. Get Teams for each Project
foreach ($project in $projectsResponse.value) {
    Write-Host "Fetching teams for project: $($project.name)..." -ForegroundColor Gray
    
    $teamsUrl = "$AdoOrgUrl/_apis/projects/$($project.id)/teams?api-version=7.1"
    
    try {
        $teamsResponse = Invoke-RestMethod -Uri $teamsUrl -Headers $adoHeaders -Method Get
        
        foreach ($team in $teamsResponse.value) {
            # Create a template object for team-mappings.json
            $teamMapping = [ordered]@{
                adoProject            = $project.name
                adoTeam               = $team.name
                githubTeam            = $team.name.ToLower().Replace(" ", "-")
                githubTeamDescription = $team.description
                parentTeam            = $null
                privacy               = "closed"
                maintainers           = @()
                members               = @()
            }
            $mappings += $teamMapping
        }
    } catch {
        Write-Warning "Failed to fetch teams for project $($project.name)."
    }
}

# 3. Export to JSON
$outputData = @{
    mappings = $mappings
    defaultVisibility = "closed"
}

$outputData | ConvertTo-Json -Depth 10 | Out-File -FilePath $OutputFile -Encoding utf8

Write-Host "`nSuccessfully exported $($mappings.Count) teams to $OutputFile" -ForegroundColor Green
Write-Host "You can now edit this file to map users to GitHub usernames and run the sync-teams.ps1 script." -ForegroundColor Yellow
