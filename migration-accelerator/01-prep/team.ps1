<#
.SYNOPSIS
    Automatically creates GitHub teams and syncs members from Azure DevOps using mapping files.

.DESCRIPTION
    This script:
      1. Reads user mappings from CSV (ADO email -> GitHub username)
      2. Reads team mappings from JSON
      3. Creates GitHub teams if they do not exist
      4. Retrieves members from Azure DevOps teams
      5. Adds mapped users to GitHub teams as members or maintainers

.PARAMETER GitHubOrg
    GitHub organization name.

.PARAMETER GitHubPat
    GitHub Personal Access Token with admin:org scope.

.PARAMETER AdoOrgUrl
    Azure DevOps organization URL.
    Example: https://dev.azure.com/myorganization

.PARAMETER AdoPat
    Azure DevOps Personal Access Token with:
      - Project and Team (Read)

.PARAMETER TeamMappingFile
    Path to JSON file containing ADO-to-GitHub team mappings.

.PARAMETER UserMappingFile
    Path to CSV file containing ADO email to GitHub username mappings.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$GitHubOrg,

    [Parameter(Mandatory = $true)]
    [string]$GitHubPat,

    [Parameter(Mandatory = $true)]
    [string]$AdoOrgUrl,

    [Parameter(Mandatory = $true)]
    [string]$AdoPat,

    [string]$TeamMappingFile = "./config/team-mappings.json",

    [string]$UserMappingFile = "./config/user-mappings.csv"
)

$ErrorActionPreference = "Stop"

# ----------------------------------------------------------
# GitHub Headers
# ----------------------------------------------------------
$ghHeaders = @{
    Authorization         = "Bearer $GitHubPat"
    Accept                = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
}

# ----------------------------------------------------------
# Azure DevOps Headers
# ----------------------------------------------------------
$base64AdoAuth = [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes(":$AdoPat")
)

$adoHeaders = @{
    Authorization = "Basic $base64AdoAuth"
}

# ----------------------------------------------------------
# Helper Function - Azure DevOps API
# ----------------------------------------------------------
function Invoke-AdoApi {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    try {
        return Invoke-RestMethod `
            -Uri $Uri `
            -Headers $adoHeaders `
            -Method Get `
            -ContentType "application/json"
    }
    catch {
        Write-Warning "ADO API call failed: $Uri"
        Write-Warning $_.Exception.Message
        return $null
    }
}

# ----------------------------------------------------------
# Helper Function - GitHub API
# ----------------------------------------------------------
function Invoke-GitHubApi {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [string]$Method = "GET",

        $Body = $null
    )

    $params = @{
        Uri         = $Uri
        Headers     = $ghHeaders
        Method      = $Method
        ContentType = "application/json"
    }

    if ($null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 5)
    }

    try {
        return Invoke-RestMethod @params
    }
    catch {
        throw $_
    }
}

# ----------------------------------------------------------
# Validate Input Files
# ----------------------------------------------------------
if (-not (Test-Path $UserMappingFile)) {
    Write-Error "User mapping file not found: $UserMappingFile"
    exit 1
}

if (-not (Test-Path $TeamMappingFile)) {
    Write-Error "Team mapping file not found: $TeamMappingFile"
    exit 1
}

# ----------------------------------------------------------
# Load User Mapping CSV
# ----------------------------------------------------------
Write-Host "Loading user mappings..." -ForegroundColor Cyan

$userMap = @{}

$csvContent = Get-Content $UserMappingFile |
    Where-Object { $_.Trim() -ne "" }

$csvData = $csvContent | ConvertFrom-Csv

foreach ($row in $csvData) {

    $adoEmail = @(
        $row.ADOEmail,
        $row.ado_email,
        $row.Email
    ) | Where-Object { $_ } | Select-Object -First 1

    $githubUsername = @(
        $row.GitHubUsername,
        $row.github_username,
        $row.Username
    ) | Where-Object { $_ } | Select-Object -First 1

    if ($adoEmail -and $githubUsername) {
        $userMap[$adoEmail.ToLower().Trim()] = $githubUsername.Trim()
    }
}

Write-Host "Loaded $($userMap.Count) user mappings." -ForegroundColor Green

# ----------------------------------------------------------
# Load Team Mapping JSON
# ----------------------------------------------------------
Write-Host "Loading team mappings..." -ForegroundColor Cyan

$mappingData = Get-Content $TeamMappingFile -Raw | ConvertFrom-Json
$mappings = $mappingData.mappings

Write-Host "Loaded $($mappings.Count) team mappings." -ForegroundColor Green

Write-Host "`n=== Starting Team Synchronization ===" -ForegroundColor Cyan

# ----------------------------------------------------------
# Process Each Mapping
# ----------------------------------------------------------
foreach ($map in $mappings) {

    Write-Host "`nProcessing:" -ForegroundColor Yellow
    Write-Host "  ADO Project : $($map.adoProject)"
    Write-Host "  ADO Team    : $($map.adoTeam)"
    Write-Host "  GitHub Team : $($map.githubTeam)"

    $githubTeamName = $map.githubTeam

    # ------------------------------------------------------
    # Step 1 - Ensure GitHub Team Exists
    # ------------------------------------------------------
    try {
        $ghTeam = Invoke-GitHubApi `
            -Uri "https://api.github.com/orgs/$GitHubOrg/teams/$githubTeamName"

        Write-Host "  [OK] GitHub team exists." -ForegroundColor Green
    }
    catch {
        Write-Host "  [NEW] Creating GitHub team..." -ForegroundColor Cyan

        $createBody = @{
            name        = $githubTeamName
            description = $map.githubTeamDescription
            privacy     = "closed"
        }

        $ghTeam = Invoke-GitHubApi `
            -Uri "https://api.github.com/orgs/$GitHubOrg/teams" `
            -Method "POST" `
            -Body $createBody

        Write-Host "  [CREATED] GitHub team '$githubTeamName'" -ForegroundColor Green
    }

    # ------------------------------------------------------
    # Step 2 - Get ADO Project
    # ------------------------------------------------------
    $project = Invoke-AdoApi `
        -Uri "$AdoOrgUrl/_apis/projects/$($map.adoProject)?api-version=7.1"

    if (-not $project) {
        Write-Warning "  Project not found: $($map.adoProject)"
        continue
    }

    # ------------------------------------------------------
    # Step 3 - Get Teams in Project
    # ------------------------------------------------------
    $teams = Invoke-AdoApi `
        -Uri "$AdoOrgUrl/_apis/projects/$($project.id)/teams?api-version=7.1"

    if (-not $teams) {
        Write-Warning "  No teams found in project."
        continue
    }

    # ------------------------------------------------------
    # Step 4 - Find Specific ADO Team
    # ------------------------------------------------------
    $adoTeam = $teams.value |
        Where-Object { $_.name -eq $map.adoTeam }

    if (-not $adoTeam) {
        Write-Warning "  ADO team not found: $($map.adoTeam)"
        continue
    }

    Write-Host "  Found ADO team." -ForegroundColor Green

    # ------------------------------------------------------
    # Step 5 - Get Team Members
    # ------------------------------------------------------
    $members = Invoke-AdoApi `
        -Uri "$AdoOrgUrl/_apis/projects/$($project.id)/teams/$($adoTeam.id)/members?api-version=7.1"

    if (-not $members -or $members.value.Count -eq 0) {
        Write-Host "  No members found." -ForegroundColor DarkGray
        continue
    }

    # ------------------------------------------------------
    # Step 6 - Add Members to GitHub Team
    # ------------------------------------------------------
    foreach ($member in $members.value) {

        $adoEmail = $member.identity.uniqueName.ToLower().Trim()

        if (-not $userMap.ContainsKey($adoEmail)) {
            Write-Host "  [SKIP] No GitHub mapping for $adoEmail" -ForegroundColor DarkGray
            continue
        }

        $githubUsername = $userMap[$adoEmail]

        $role = if (
            $map.maintainers -and
            ($map.maintainers -contains $githubUsername)
        ) {
            "maintainer"
        }
        else {
            "member"
        }

        Write-Host "  Adding $githubUsername as $role..." -ForegroundColor Gray

        try {
            Invoke-GitHubApi `
                -Uri "https://api.github.com/orgs/$GitHubOrg/teams/$githubTeamName/memberships/$githubUsername" `
                -Method "PUT" `
                -Body @{ role = $role }

            Write-Host "    [ADDED]" -ForegroundColor Green
        }
        catch {
            Write-Warning "    Failed to add $githubUsername"
        }
    }
}

Write-Host "`n=========================================" -ForegroundColor Cyan
Write-Host " Team Synchronization Complete" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan