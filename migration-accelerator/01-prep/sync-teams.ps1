<#
.SYNOPSIS
    Creates GitHub teams based on mappings defined in team-mappings.json.
.DESCRIPTION
    Reads the team-mappings.json file and ensures all mapped teams exist in the target GitHub organization.
.PARAMETER GitHubOrg
    Target GitHub organization name.
.PARAMETER GitHubPat
    GitHub PAT with admin:org scope.
.PARAMETER MappingFile
    Path to the team-mappings.json file.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$GitHubOrg,

    [Parameter(Mandatory = $true)]
    [string]$GitHubPat,

    [string]$MappingFile = "./config/team-mappings.json"
)

$ErrorActionPreference = "Continue"

$headers = @{
    Authorization = "Bearer $GitHubPat"
    Accept        = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
}

if (-not (Test-Path $MappingFile)) {
    Write-Error "Mapping file not found: $MappingFile"
    exit 1
}

$mappingData = Get-Content $MappingFile -Raw | ConvertFrom-Json
$mappings = $mappingData.mappings
$defaultVisibility = if ($mappingData.defaultVisibility) { $mappingData.defaultVisibility } else { "closed" }

Write-Host "=== Syncing GitHub Teams to $GitHubOrg ===" -ForegroundColor Cyan

foreach ($team in $mappings) {
    Write-Host "`nProcessing team: $($team.githubTeam)" -ForegroundColor Yellow
    
    $teamName = $team.githubTeam
    $description = if ($team.githubTeamDescription) { $team.githubTeamDescription } else { "Migrated from ADO" }
    
    # Check if team already exists
    try {
        $existingTeam = Invoke-RestMethod -Uri "https://api.github.com/orgs/$GitHubOrg/teams/$teamName" -Headers $headers -Method Get -ErrorAction Stop
        Write-Host "   [EXISTS] Team '$teamName' already exists. Updating description..." -ForegroundColor Gray
        
        $updateBody = @{
            description = $description
        } | ConvertTo-Json
        
        Invoke-RestMethod -Uri "https://api.github.com/orgs/$GitHubOrg/teams/$teamName" -Headers $headers -Method Patch -Body $updateBody -ContentType "application/json"
    }
    catch {
        # Team doesn't exist, create it
        Write-Host "   [MISSING] Creating team '$teamName'..." -ForegroundColor Green
        
        $createBody = @{
            name        = $teamName
            description = $description
            privacy     = $defaultVisibility
        }
        
        if ($team.parentTeam) {
            # Note: This requires getting the parent team ID first. Simplification: skip parent for now or handle later.
            Write-Host "   [INFO] Parent team specified ($($team.parentTeam)). Manual nesting may be required." -ForegroundColor Gray
        }
        
        try {
            $newTeam = Invoke-RestMethod -Uri "https://api.github.com/orgs/$GitHubOrg/teams" -Headers $headers -Method Post -Body ($createBody | ConvertTo-Json) -ContentType "application/json"
            Write-Host "   [SUCCESS] Created team: $($newTeam.name)" -ForegroundColor Green
        }
        catch {
            Write-Error "   [FAILED] Could not create team '$teamName': $($_.Exception.Message)"
        }
    }
}

Write-Host "`nTeam synchronization complete." -ForegroundColor Cyan
