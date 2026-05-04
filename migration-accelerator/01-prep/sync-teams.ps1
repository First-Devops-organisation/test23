<#
.SYNOPSIS
    Automatically creates GitHub teams and syncs members from ADO using a user mapping CSV.
.PARAMETER GitHubOrg
    Target GitHub organization name.
.PARAMETER GitHubPat
    GitHub PAT with admin:org scope.
.PARAMETER AdoOrg
    Azure DevOps Org URL (e.g., https://dev.azure.com/myorg).
.PARAMETER AdoPat
    Azure DevOps PAT with Project & Team (Read) scope.
.PARAMETER TeamMappingFile
    Path to team-mappings.json.
.PARAMETER UserMappingFile
    Path to user-mappings.csv.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$GitHubOrg,
    [Parameter(Mandatory = $true)]
    [string]$GitHubPat,
    [Parameter(Mandatory = $true)]
    [string]$AdoOrg,
    [Parameter(Mandatory = $true)]
    [string]$AdoPat,
    [string]$TeamMappingFile = "./config/team-mappings.json",
    [string]$UserMappingFile = "./config/user-mappings.csv"
)

$ErrorActionPreference = "Stop"

# --- Setup Headers ---
$ghHeaders = @{
    Authorization = "Bearer $GitHubPat"
    Accept        = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
}

$base64AdoAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat"))
$adoHeaders = @{ Authorization = "Basic $base64AdoAuth" }

# --- 1. Load User Mappings ---
Write-Host "Loading user mappings from $UserMappingFile..." -ForegroundColor Gray
if (-not (Test-Path $UserMappingFile)) { Write-Error "User mapping file not found!"; exit 1 }
$userMap = @{}

# Robust CSV Loading
$csvContent = Get-Content $UserMappingFile | Where-Object { $_.Trim() -ne "" }
$csvData = $csvContent | ConvertFrom-Csv

foreach ($row in $csvData) {
    # Match various possible header names
    $email = ($row.ADOEmail, $row.ado_email, $row.Email) | Where-Object { $_ } | Select-Object -First 1
    $ghUser = ($row.GitHubUsername, $row.github_username, $row.Username) | Where-Object { $_ } | Select-Object -First 1
    
    if ($email -and $ghUser) {
        $userMap[$email.ToLower().Trim()] = $ghUser.Trim()
    }
}

Write-Host "   Loaded $($userMap.Count) user mappings." -ForegroundColor Gray

# --- 2. Load Team Mappings ---
$mappingData = Get-Content $TeamMappingFile -Raw | ConvertFrom-Json
$mappings = $mappingData.mappings

Write-Host "=== Starting Automated Team Sync ===" -ForegroundColor Cyan

foreach ($map in $mappings) {
    Write-Host "`nProcessing: $($map.adoProject) / $($map.adoTeam) -> $($map.githubTeam)" -ForegroundColor Yellow
    
    # A. Ensure GitHub Team Exists
    $teamName = $map.githubTeam
    try {
        $ghTeam = Invoke-RestMethod -Uri "https://api.github.com/orgs/$GitHubOrg/teams/$teamName" -Headers $ghHeaders -Method Get
        Write-Host "   [OK] GitHub team '$teamName' exists." -ForegroundColor Green
    }
    catch {
        Write-Host "   [NEW] Creating GitHub team '$teamName'..." -ForegroundColor Green
        $createBody = @{ name = $teamName; description = $map.githubTeamDescription; privacy = "closed" }
        $ghTeam = Invoke-RestMethod -Uri "https://api.github.com/orgs/$GitHubOrg/teams" -Headers $ghHeaders -Method Post -Body ($createBody | ConvertTo-Json) -ContentType "application/json"
    }

    # B. Fetch ADO Team Members
    Write-Host "   Fetching members from ADO..." -ForegroundColor Gray
    try {
        # Get Project ID
        $project = Invoke-RestMethod -Uri "$AdoOrg/_apis/projects/$($map.adoProject)?api-version=7.1" -Headers $adoHeaders
        # Get Team ID
        $teams = Invoke-RestMethod -Uri "$AdoOrg/_apis/projects/$($project.id)/teams?api-version=7.1" -Headers $adoHeaders
        $adoTeam = $teams.value | Where-Object { $_.name -eq $map.adoTeam }
        
        if (-not $adoTeam) {
            Write-Error "      [ERROR] Could not find ADO team: $($map.adoTeam) in project $($map.adoProject)"
            continue
        }

        # Get Members
        $members = Invoke-RestMethod -Uri "$AdoOrg/_apis/projects/$($project.id)/teams/$($adoTeam.id)/members?api-version=7.1" -Headers $adoHeaders
        
        foreach ($member in $members.value) {
            $email = $member.identity.uniqueName.ToLower().Trim()
            if ($userMap.ContainsKey($email)) {
                $ghUser = $userMap[$email]
                Write-Host "   Mapping: $email -> $ghUser" -ForegroundColor Gray
                
                # C. Add to GitHub Team
                $role = if ($map.maintainers -contains $ghUser) { "maintainer" } else { "member" }
                try {
                    Invoke-RestMethod -Uri "https://api.github.com/orgs/$GitHubOrg/teams/$teamName/memberships/$ghUser" -Headers $ghHeaders -Method Put -Body (@{ role = $role } | ConvertTo-Json) -ContentType "application/json"
                    Write-Host "      [ADDED] $ghUser as $role" -ForegroundColor Green
                }
                catch {
                    Write-Warning "      [FAILED] Could not add $ghUser to team."
                }
            }
            else {
                Write-Host "   [SKIP] No mapping found for $email" -ForegroundColor DarkGray
            }
        }
    }
    catch {
        Write-Error "   [ERROR] Could not process ADO members for $($map.adoTeam): $($_.Exception.Message)"
    }
}

Write-Host "`nSync Complete!" -ForegroundColor Cyan
