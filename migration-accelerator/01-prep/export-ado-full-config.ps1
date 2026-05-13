<#
.SYNOPSIS
    Automated Discovery: Fetches Teams, Members, and Repository lists from ADO.
    Generates a ready-to-use team-mappings JSON for migration.

.DESCRIPTION
    1. Fetches all Projects (or a specific one).
    2. Fetches all Repositories in each project.
    3. Fetches all Teams and Members.
    4. Maps ADO Members to GitHub usernames using user-mappings.csv.
    5. Lists 'unmappedUsers' (ADO emails) for easy auditing.
    6. Automatically assigns ADO Team Admins as GitHub Maintainers.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AdoOrgUrl,

    [Parameter(Mandatory = $true)]
    [string]$AdoPat,

    [string]$AdoProject = "",

    [string]$UserMappingFile = ".\config\user-mappings.csv",

    [string]$OutputFile = ".\config\automated-team-mappings.json"
)

$ErrorActionPreference = "Stop"

# ----------------------------------------------------------
# 1. Setup Authentication
# ----------------------------------------------------------
$base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat"))
$headers = @{ 
    Authorization = "Basic $base64Auth"
    Accept        = "application/json"
}

# Helper: ADO API Call
function Invoke-Ado {
    param($Uri)
    try {
        return Invoke-RestMethod -Uri $Uri -Headers $headers -Method Get -ContentType "application/json"
    } catch {
        Write-Warning "ADO API Call Failed: $Uri"
        return $null
    }
}

# ----------------------------------------------------------
# 2. Load User Mappings from CSV
# ----------------------------------------------------------
$userMap = @{}
if (Test-Path $UserMappingFile) {
    Write-Host "Loading user mappings from $UserMappingFile..." -ForegroundColor Cyan
    $csvData = Import-Csv $UserMappingFile
    foreach ($row in $csvData) {
        if ($row.ADOEmail -and $row.GitHubUsername) {
            $userMap[$row.ADOEmail.ToLower().Trim()] = $row.GitHubUsername.Trim()
        }
    }
    Write-Host "Loaded $($userMap.Count) user mappings." -ForegroundColor Green
} else {
    Write-Warning "User mapping file not found at $UserMappingFile. All users will be 'unmapped'."
}

# ----------------------------------------------------------
# 3. Fetch Project(s)
# ----------------------------------------------------------
$projectsList = @()
if ($AdoProject -and $AdoProject.Trim() -ne "") {
    $p = Invoke-Ado -Uri "$AdoOrgUrl/_apis/projects/$($AdoProject.Trim())?api-version=7.0"
    if ($p) { $projectsList = @($p) }
} else {
    $response = Invoke-Ado -Uri "$AdoOrgUrl/_apis/projects?api-version=7.0"
    if ($response) { $projectsList = $response.value }
}

if ($projectsList.Count -eq 0) {
    Write-Error "No projects found. Check your ADO URL and PAT."
    exit 1
}

# ----------------------------------------------------------
# 4. Main Discovery Loop
# ----------------------------------------------------------
$finalMappings = @()

foreach ($project in $projectsList) {
    Write-Host "`nProcessing Project: $($project.name)" -ForegroundColor Cyan
    
    # Fetch all repos in project
    $repos = (Invoke-Ado -Uri "$AdoOrgUrl/$($project.id)/_apis/git/repositories?api-version=7.0").value
    Write-Host "  Found $($repos.Count) repositories." -ForegroundColor Gray

    # Fetch all teams in project
    $teams = (Invoke-Ado -Uri "$AdoOrgUrl/_apis/projects/$($project.id)/teams?api-version=7.0").value
    
    foreach ($team in $teams) {
        Write-Host "  Analyzing Team: $($team.name)" -ForegroundColor Yellow
        
        # Fetch members and team admin status
        $membersResponse = Invoke-Ado -Uri "$AdoOrgUrl/_apis/projects/$($project.id)/teams/$($team.id)/members?api-version=7.0"
        
        $ghMembers = @()
        $ghMaintainers = @()
        $unmappedEmails = @()

        if ($membersResponse -and $membersResponse.value) {
            foreach ($m in $membersResponse.value) {
                $email = $m.identity.uniqueName.ToLower().Trim()
                $isAdmin = ($m.isTeamAdmin -eq $true)

                if ($userMap.ContainsKey($email)) {
                    $githubUser = $userMap[$email]
                    if ($isAdmin) {
                        $ghMaintainers += $githubUser
                    } else {
                        $ghMembers += $githubUser
                    }
                } else {
                    $unmappedEmails += $email
                }
            }
        }

        # Repository mapping logic
        # Default: All repositories in the project are assigned to the team with 'push' access
        $teamRepos = @()
        foreach ($repo in $repos) {
            $teamRepos += [ordered]@{
                name       = $repo.name
                permission = "push"
            }
        }

        # Build final team object
        $finalMappings += [ordered]@{
            adoProject    = $project.name
            adoTeam       = $team.name
            githubTeam    = "$($project.name)-$($team.name)".ToLower() -replace '[^a-z0-9\-]', '-' -replace '-+', '-'
            maintainers   = @($ghMaintainers | Select-Object -Unique)
            members       = @($ghMembers | Select-Object -Unique)
            unmappedUsers = @($unmappedEmails | Select-Object -Unique)
            repositories  = $teamRepos
        }
    }
}

# ----------------------------------------------------------
# 5. Export to JSON
# ----------------------------------------------------------
$outputObj = [ordered]@{
    generatedAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    adoOrgUrl   = $AdoOrgUrl
    totalTeams  = $finalMappings.Count
    mappings    = $finalMappings
}

$outputDir = Split-Path $OutputFile -Parent
if ($outputDir -and -not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force }

$outputObj | ConvertTo-Json -Depth 10 | Out-File -FilePath $OutputFile -Encoding utf8
Write-Host "`nSUCCESS: Automated config saved to $OutputFile" -ForegroundColor Green
Write-Host "Action Required: Check the 'unmappedUsers' list in the JSON and update your CSV mapping file." -ForegroundColor Yellow
