<#
.SYNOPSIS
    Automatically creates GitHub parent/child teams, syncs members from ADO using a user mapping CSV, 
    and applies repository access permissions.
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

# --- Helper Function for GitHub API ---
function Invoke-GhRest {
    param($Method, $Uri, $Body)
    $params = @{ Method = $Method; Uri = $Uri; Headers = $ghHeaders }
    if ($Body) { $params.Body = ($Body | ConvertTo-Json -Depth 10); $params.ContentType = "application/json" }
    try {
        return Invoke-RestMethod @params
    } catch {
        if ($Method -eq "Get" -and $_.Exception.Response.StatusCode -eq "NotFound") { return $null }
        throw $_
    }
}

# --- 1. Load User Mappings ---
Write-Host "Loading user mappings from $UserMappingFile..." -ForegroundColor Gray
if (-not (Test-Path $UserMappingFile)) { Write-Error "User mapping file not found!"; exit 1 }
$userMap = @{}

$csvContent = Get-Content $UserMappingFile | Where-Object { $_.Trim() -ne "" }
$csvData = $csvContent | ConvertFrom-Csv

foreach ($row in $csvData) {
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

Write-Host "=== Starting Automated Team Sync & Repo Access ===" -ForegroundColor Cyan

foreach ($map in $mappings) {
    Write-Host "`nProcessing: $($map.adoProject) / $($map.adoTeam) -> $($map.githubTeam)" -ForegroundColor Yellow
    
    $parentId = $null

    # A. Handle Parent Team Creation/Lookup
    if (-not [string]::IsNullOrEmpty($map.parentTeam)) {
        $parentSlug = $map.parentTeam.ToLower() -replace "\s+","-"
        $parentTeamInfo = Invoke-GhRest -Method Get -Uri "https://api.github.com/orgs/$GitHubOrg/teams/$parentSlug"
        
        if ($parentTeamInfo) {
            $parentId = $parentTeamInfo.id
            Write-Host "   [OK] Parent team '$($map.parentTeam)' exists (ID: $parentId)." -ForegroundColor DarkGray
        } else {
            Write-Host "   [NEW] Creating Parent team '$($map.parentTeam)'..." -ForegroundColor Green
            $newParent = Invoke-GhRest -Method Post -Uri "https://api.github.com/orgs/$GitHubOrg/teams" -Body @{
                name = $map.parentTeam
                description = "Parent team for ADO Project: $($map.adoProject)"
                privacy = "closed"
            }
            $parentId = $newParent.id
        }
    }

    # B. Ensure GitHub Child Team Exists
    $teamName = $map.githubTeam
    $ghTeam = Invoke-GhRest -Method Get -Uri "https://api.github.com/orgs/$GitHubOrg/teams/$teamName"
    
    if ($ghTeam) {
        Write-Host "   [OK] GitHub team '$teamName' already exists." -ForegroundColor Green
    } else {
        Write-Host "   [NEW] Creating GitHub team '$teamName'..." -ForegroundColor Green
        $createBody = @{ name = $teamName; description = $map.githubTeamDescription; privacy = "closed" }
        if ($parentId) { $createBody.parent_team_id = $parentId }
        
        $ghTeam = Invoke-GhRest -Method Post -Uri "https://api.github.com/orgs/$GitHubOrg/teams" -Body $createBody
    }

    # C. Fetch ADO Team Members and Sync
    Write-Host "   Fetching members from ADO..." -ForegroundColor Gray
    try {
        $project = Invoke-RestMethod -Uri "$AdoOrg/_apis/projects/$($map.adoProject)?api-version=7.1" -Headers $adoHeaders
        $teams = Invoke-RestMethod -Uri "$AdoOrg/_apis/projects/$($project.id)/teams?api-version=7.1" -Headers $adoHeaders
        $adoTeam = $teams.value | Where-Object { $_.name -eq $map.adoTeam }
        
        if (-not $adoTeam) {
            Write-Warning "      [WARNING] Could not find ADO team: $($map.adoTeam). Skipping user sync."
        } else {
            $members = Invoke-RestMethod -Uri "$AdoOrg/_apis/projects/$($project.id)/teams/$($adoTeam.id)/members?api-version=7.1" -Headers $adoHeaders
            
            foreach ($member in $members.value) {
                $email = $member.identity.uniqueName.ToLower().Trim()
                if ($userMap.ContainsKey($email)) {
                    $ghUser = $userMap[$email]
                    $role = if ($map.maintainers -contains $ghUser) { "maintainer" } else { "member" }
                    try {
                        $null = Invoke-GhRest -Method Put -Uri "https://api.github.com/orgs/$GitHubOrg/teams/$teamName/memberships/$ghUser" -Body @{ role = $role }
                        Write-Host "      [ADDED] $ghUser as $role" -ForegroundColor Green
                    } catch {
                        Write-Warning "      [FAILED] Could not add $ghUser to team."
                    }
                } else {
                    Write-Host "   [SKIP] No mapping found for $email" -ForegroundColor DarkGray
                }
            }
        }
    } catch {
        Write-Error "   [ERROR] Could not process ADO members for $($map.adoTeam): $($_.Exception.Message)"
    }

    # D. Grant Repository Access
    if ($map.repositories) {
        Write-Host "   Assigning Repository Access..." -ForegroundColor Gray
        foreach ($repo in $map.repositories) {
            try {
                $null = Invoke-GhRest -Method Put -Uri "https://api.github.com/orgs/$GitHubOrg/teams/$teamName/repos/$GitHubOrg/$($repo.name)" -Body @{ permission = $repo.permission }
                Write-Host "      [ACCESS GRANTED] $($repo.permission) access to repo: $($repo.name)" -ForegroundColor Green
            } catch {
                Write-Warning "      [ACCESS FAILED] Could not grant $($repo.permission) to $($repo.name). Does the repo exist yet?"
            }
        }
    }
}

Write-Host "`n✅ Team Sync & Access Update Complete!" -ForegroundColor Cyan
