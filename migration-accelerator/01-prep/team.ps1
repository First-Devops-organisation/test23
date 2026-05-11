<#
.SYNOPSIS
    Collects Azure DevOps team information for migration to GitHub.

.DESCRIPTION
    This script connects to Azure DevOps and exports:
      - Project names
      - Team names
      - Team descriptions
      - Team members
      - Member email addresses
      - Suggested role (Maintainer or Member)

    The script only collects data and does NOT create anything in GitHub.

.OUTPUTS
    1. ado-team-members.csv
    2. team-mappings.json
    3. user-mappings-template.csv

.PARAMETER AdoOrgUrl
    Azure DevOps organization URL.
    Example: https://dev.azure.com/myorg

.PARAMETER AdoPat
    Azure DevOps PAT with Project and Team Read permissions.

.PARAMETER OutputDir
    Directory where output files will be generated.

.EXAMPLE
    .\Export-AdoTeams.ps1 `
        -AdoOrgUrl "https://dev.azure.com/myorg" `
        -AdoPat "your-pat" `
        -OutputDir "./output"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AdoOrgUrl,

    [Parameter(Mandatory = $true)]
    [string]$AdoPat,

    [string]$OutputDir = "./output"
)

$ErrorActionPreference = "Stop"

#----------------------------------------------------------
# Authentication
#----------------------------------------------------------
$base64Auth = [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes(":$AdoPat")
)

$Headers = @{
    Authorization = "Basic $base64Auth"
}

#----------------------------------------------------------
# Helper Function
#----------------------------------------------------------
function Invoke-AdoApi {
    param(
        [string]$Uri
    )

    if ($Uri -notmatch "api-version=") {
        if ($Uri.Contains("?")) {
            $Uri += "&api-version=7.1"
        }
        else {
            $Uri += "?api-version=7.1"
        }
    }

    try {
        return Invoke-RestMethod -Uri $Uri -Headers $Headers -Method Get
    }
    catch {
        Write-Warning "Failed: $Uri"
        Write-Warning $_.Exception.Message
        return $null
    }
}

#----------------------------------------------------------
# Prepare Output Directory
#----------------------------------------------------------
if (-not (Test-Path $OutputDir)) {
    New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
}

#----------------------------------------------------------
# Output Collections
#----------------------------------------------------------
$TeamMemberRows = @()
$TeamMappings   = @()
$UniqueUsers    = @{}

Write-Host "Collecting Azure DevOps teams..." -ForegroundColor Cyan

#----------------------------------------------------------
# Get Projects
#----------------------------------------------------------
$projects = Invoke-AdoApi "$AdoOrgUrl/_apis/projects"

if (-not $projects -or $projects.count -eq 0) {
    Write-Error "No projects found."
    exit 1
}

foreach ($project in $projects.value) {

    $projectName = $project.name
    $projectId   = $project.id

    Write-Host "Project: $projectName" -ForegroundColor Yellow

    #------------------------------------------------------
    # Get Teams
    #------------------------------------------------------
    $teams = Invoke-AdoApi "$AdoOrgUrl/_apis/projects/$projectId/teams"

    if (-not $teams) {
        continue
    }

    foreach ($team in $teams.value) {

        $teamName = $team.name
        $teamId   = $team.id
        $teamDesc = $team.description

        Write-Host "  Team: $teamName" -ForegroundColor Green

        # GitHub team slug recommendation
        $githubTeam = (
            $teamName.ToLower() `
                -replace '[^a-z0-9\- ]', '' `
                -replace '\s+', '-'
        )

        # Add team mapping template
        $TeamMappings += [PSCustomObject]@{
            adoProject            = $projectName
            adoTeam               = $teamName
            githubTeam            = $githubTeam
            githubTeamDescription = if ($teamDesc) {
                $teamDesc
            }
            else {
                "$teamName migrated from Azure DevOps"
            }
            maintainers           = @()
        }

        #--------------------------------------------------
        # Get Team Members
        #--------------------------------------------------
        $members = Invoke-AdoApi "$AdoOrgUrl/_apis/projects/$projectId/teams/$teamId/members"

        if (-not $members) {
            continue
        }

        foreach ($member in $members.value) {

            $displayName = $member.identity.displayName
            $email       = $member.identity.uniqueName

            if ([string]::IsNullOrWhiteSpace($email)) {
                continue
            }

            # Track unique users
            if (-not $UniqueUsers.ContainsKey($email.ToLower())) {
                $UniqueUsers[$email.ToLower()] = $displayName
            }

            # Export row
            $TeamMemberRows += [PSCustomObject]@{
                Project             = $projectName
                Team                = $teamName
                TeamDescription     = $teamDesc
                MemberDisplayName   = $displayName
                MemberEmail         = $email
                SuggestedGitHubTeam = $githubTeam
                SuggestedRole       = "member"
            }
        }
    }
}

#----------------------------------------------------------
# Export Team Members CSV
#----------------------------------------------------------
$teamMembersCsv = Join-Path $OutputDir "ado-team-members.csv"
$TeamMemberRows |
    Sort-Object Project, Team, MemberEmail |
    Export-Csv -Path $teamMembersCsv -NoTypeInformation -Encoding UTF8

Write-Host "Created: $teamMembersCsv" -ForegroundColor Green

#----------------------------------------------------------
# Export Team Mapping JSON
#----------------------------------------------------------
$teamMappingsJson = Join-Path $OutputDir "team-mappings.json"

@{
    mappings = $TeamMappings
} | ConvertTo-Json -Depth 10 |
    Out-File -FilePath $teamMappingsJson -Encoding UTF8

Write-Host "Created: $teamMappingsJson" -ForegroundColor Green

#----------------------------------------------------------
# Export User Mapping Template CSV
#----------------------------------------------------------
$userMappingsCsv = Join-Path $OutputDir "user-mappings-template.csv"

$UniqueUsers.GetEnumerator() |
    Sort-Object Name |
    ForEach-Object {
        [PSCustomObject]@{
            ADOEmail         = $_.Key
            DisplayName      = $_.Value
            GitHubUsername   = ""
        }
    } |
    Export-Csv -Path $userMappingsCsv -NoTypeInformation -Encoding UTF8

Write-Host "Created: $userMappingsCsv" -ForegroundColor Green

#----------------------------------------------------------
# Summary
#----------------------------------------------------------
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Team Data Collection Complete"
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Projects      : $($projects.count)"
Write-Host "Teams         : $($TeamMappings.Count)"
Write-Host "Unique Users  : $($UniqueUsers.Count)"
Write-Host ""
Write-Host "Files Generated:"
Write-Host " - $teamMembersCsv"
Write-Host " - $teamMappingsJson"
Write-Host " - $userMappingsCsv"
Write-Host ""
Write-Host "Next Steps:"
Write-Host "1. Populate GitHubUsername column in user-mappings-template.csv"
Write-Host "2. Review and update team-mappings.json"
Write-Host "3. Run the GitHub team migration script"
Write-Host "========================================" -ForegroundColor Cyan