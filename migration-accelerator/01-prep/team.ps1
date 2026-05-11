<#
.SYNOPSIS
    Exports Azure DevOps teams and members for GitHub migration planning.

.DESCRIPTION
    Connects to Azure DevOps and exports:
      1. Team details
      2. Team members

.PARAMETER AdoOrgUrl
    Azure DevOps organization URL.
    Example: https://dev.azure.com/myorg

.PARAMETER AdoPat
    Azure DevOps PAT with:
      - Project and Team (Read)
      - Member Entitlement Management (Read)

.PARAMETER OutputDir
    Directory to save output files.

.EXAMPLE
    .\Export-AdoTeams.ps1 `
        -AdoOrgUrl "https://dev.azure.com/myorg" `
        -AdoPat "xxxxxxxxxxxx" `
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
# Create Output Folder
#----------------------------------------------------------
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

#----------------------------------------------------------
# Authentication Header
#----------------------------------------------------------
$base64Auth = [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes(":$AdoPat")
)

$headers = @{
    Authorization = "Basic $base64Auth"
}

#----------------------------------------------------------
# Helper Function
#----------------------------------------------------------
function Invoke-AdoApi {
    param([string]$Uri)

    try {
        return Invoke-RestMethod `
            -Uri $Uri `
            -Headers $headers `
            -Method Get `
            -ContentType "application/json"
    }
    catch {
        Write-Warning "Failed: $Uri"
        Write-Warning $_.Exception.Message
        return $null
    }
}

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host " Azure DevOps Team Export" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

#----------------------------------------------------------
# Get Projects
#----------------------------------------------------------
$projectsUrl = "$AdoOrgUrl/_apis/projects?api-version=7.1"
$projects = Invoke-AdoApi $projectsUrl

if (-not $projects) {
    Write-Error "Unable to fetch projects."
    exit 1
}

Write-Host "Projects found: $($projects.count)" -ForegroundColor Green

$teamResults = @()
$memberResults = @()

#----------------------------------------------------------
# Process Each Project
#----------------------------------------------------------
foreach ($project in $projects.value) {

    $projectName = $project.name
    $projectId   = $project.id

    Write-Host "`nProject: $projectName" -ForegroundColor Yellow

    # Get Teams
    $teamsUrl = "$AdoOrgUrl/_apis/projects/$projectId/teams?api-version=7.1"
    $teams = Invoke-AdoApi $teamsUrl

    if (-not $teams) {
        Write-Warning "No teams found in project $projectName"
        continue
    }

    Write-Host "  Teams found: $($teams.count)" -ForegroundColor Gray

    foreach ($team in $teams.value) {

        # Save team info
        $teamResults += [PSCustomObject]@{
            ProjectName     = $projectName
            TeamName        = $team.name
            TeamDescription = $team.description
            TeamId          = $team.id
        }

        Write-Host "    Team: $($team.name)" -ForegroundColor Cyan

        # Get Team Members
        $membersUrl = "$AdoOrgUrl/_apis/projects/$projectId/teams/$($team.id)/members?api-version=7.1"
        $members = Invoke-AdoApi $membersUrl

        if ($members -and $members.value.Count -gt 0) {
            foreach ($member in $members.value) {

                $memberResults += [PSCustomObject]@{
                    ProjectName       = $projectName
                    TeamName          = $team.name
                    TeamId            = $team.id
                    MemberDisplayName = $member.identity.displayName
                    MemberEmail       = $member.identity.uniqueName
                }

                Write-Host "      Member: $($member.identity.displayName)" -ForegroundColor DarkGray
            }
        }
        else {
            Write-Host "      No members found." -ForegroundColor DarkGray
        }
    }
}

#----------------------------------------------------------
# Export CSV Files
#----------------------------------------------------------
$teamsCsv = Join-Path $OutputDir "ado-teams.csv"
$membersCsv = Join-Path $OutputDir "ado-team-members.csv"

$teamResults |
    Sort-Object ProjectName, TeamName |
    Export-Csv -Path $teamsCsv -NoTypeInformation -Encoding UTF8

$memberResults |
    Sort-Object ProjectName, TeamName, MemberDisplayName |
    Export-Csv -Path $membersCsv -NoTypeInformation -Encoding UTF8

#----------------------------------------------------------
# Summary
#----------------------------------------------------------
Write-Host "`n=========================================" -ForegroundColor Green
Write-Host " Export Completed" -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Green
Write-Host "Teams exported   : $($teamResults.Count)"
Write-Host "Members exported : $($memberResults.Count)"
Write-Host "Teams CSV        : $teamsCsv"
Write-Host "Members CSV      : $membersCsv"