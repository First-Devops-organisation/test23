# <#
# .SYNOPSIS
#     Fetches Projects, Teams, and Team Members from Azure DevOps and exports
#     a populated team-mappings JSON template with GitHub usernames resolved from a user mapping CSV.

# .DESCRIPTION
#     This script:
#       1. Reads user mappings from CSV (ADO email -> GitHub username)
#       2. Fetches one specific Project (if -AdoProject is provided) OR all Projects in the org
#       3. Fetches all Teams within each Project
#       4. Fetches all Members within each Team
#       5. Cross-references members against the user mapping CSV
#       6. Auto-populates the 'members' array with resolved GitHub usernames
#       7. Auto-populates the 'maintainers' array from ADO Team Admins
#       8. Flags any unmapped users (no GitHub username found) in a separate section
#       9. Exports the full result to a JSON template ready for review

# .PARAMETER AdoOrgUrl
#     Azure DevOps organization URL. Example: https://dev.azure.com/myorganization

# .PARAMETER AdoPat
#     Azure DevOps Personal Access Token with Project and Team (Read) scope.

# .PARAMETER AdoProject
#     (Optional) Name of a single ADO project to export.
#     If not provided, ALL projects in the organization will be exported.
#     Example: "YASH-DevOps-Serverless"

# .PARAMETER UserMappingFile
#     Path to the CSV file containing ADO email to GitHub username mappings.

# .PARAMETER OutputFile
#     Path to save the generated JSON template.
# #>

# [CmdletBinding()]
# param(
#     [Parameter(Mandatory = $true)]
#     [string]$AdoOrgUrl,

#     [Parameter(Mandatory = $true)]
#     [string]$AdoPat,

#     [string]$AdoProject = "",

#     [string]$UserMappingFile = ".\config\user-mappings.csv",

#     [string]$OutputFile = ".\config\team-mappings-template.json"
# )

# $ErrorActionPreference = "Stop"

# # ----------------------------------------------------------
# # Auth Headers
# # ----------------------------------------------------------
# $base64AdoAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat"))
# $adoHeaders = @{ Authorization = "Basic $base64AdoAuth" }

# # ----------------------------------------------------------
# # Helper: ADO API Call
# # ----------------------------------------------------------
# function Invoke-AdoApi {
#     param([string]$Uri)
#     try {
#         return Invoke-RestMethod -Uri $Uri -Headers $adoHeaders -Method Get -ContentType "application/json"
#     } catch {
#         Write-Warning "ADO API call failed: $Uri | $($_.Exception.Message)"
#         return $null
#     }
# }

# # ----------------------------------------------------------
# # Step 1: Load User Mapping CSV
# # ----------------------------------------------------------
# $userMap = @{}
# $unmappedUsers = @()

# if (Test-Path $UserMappingFile) {
#     Write-Host "Loading user mappings from $UserMappingFile..." -ForegroundColor Cyan
#     $csvContent = Get-Content $UserMappingFile | Where-Object { $_.Trim() -ne "" }
#     $csvData = $csvContent | ConvertFrom-Csv

#     foreach ($row in $csvData) {
#         $adoEmail = @($row.ADOEmail, $row.ado_email, $row.Email) |
#             Where-Object { $_ } | Select-Object -First 1
#         $githubUsername = @($row.GitHubUsername, $row.github_username, $row.Username) |
#             Where-Object { $_ } | Select-Object -First 1

#         if ($adoEmail -and $githubUsername) {
#             $userMap[$adoEmail.ToLower().Trim()] = $githubUsername.Trim()
#         }
#     }
#     Write-Host "Loaded $($userMap.Count) user mappings." -ForegroundColor Green
# } else {
#     Write-Warning "User mapping file not found at '$UserMappingFile'. Members will not be resolved."
# }

# # ----------------------------------------------------------
# # Step 2: Fetch Project(s)
# # ----------------------------------------------------------
# $projectsList = @()

# # Trim whitespace in case the pipeline variable has extra spaces
# $AdoProject = $AdoProject.Trim()

# if ($AdoProject -ne "") {
#     # Single project mode
#     Write-Host "`nFetching single project: '$AdoProject'..." -ForegroundColor Cyan

#     # Use ${AdoProject} (curly braces) to explicitly bound the variable name.
#     # Without this, PowerShell 7 may misparse $AdoProject?api as a null-conditional
#     # operator, stripping "?api" from the URL and causing a 404.
#     $projectData = Invoke-AdoApi -Uri "$AdoOrgUrl/_apis/projects/${AdoProject}?api-version=7.1"

#     if (-not $projectData) {
#         Write-Error "Project '$AdoProject' not found. Check the project name and your PAT permissions."
#         exit 1
#     }

#     $projectsList = @($projectData)
#     Write-Host "Found project: $($projectData.name)" -ForegroundColor Green
# } else {
#     # Org-wide mode
#     Write-Host "`nNo project specified. Fetching ALL projects from $AdoOrgUrl..." -ForegroundColor Cyan
#     $projectsResponse = Invoke-AdoApi -Uri "$AdoOrgUrl/_apis/projects?api-version=7.1"

#     if (-not $projectsResponse) {
#         Write-Error "Failed to fetch projects. Please check your ADO URL and PAT."
#         exit 1
#     }

#     $projectsList = $projectsResponse.value
#     Write-Host "Found $($projectsList.Count) projects." -ForegroundColor Green
# }

# $mappings = [System.Collections.Generic.List[object]]::new()

# # ----------------------------------------------------------
# # Step 3: Fetch Teams and Members for Each Project
# # ----------------------------------------------------------
# foreach ($project in $projectsList) {

#     Write-Host "`nProject: $($project.name)" -ForegroundColor Yellow

#     $teamsResponse = Invoke-AdoApi -Uri "$AdoOrgUrl/_apis/projects/$($project.id)/teams?api-version=7.1"

#     if (-not $teamsResponse) {
#         Write-Warning "  Could not fetch teams for project: $($project.name)"
#         continue
#     }

#     foreach ($team in $teamsResponse.value) {

#         Write-Host "  Team: $($team.name)" -ForegroundColor Gray

#         $resolvedMembers      = [System.Collections.Generic.List[string]]::new()
#         $resolvedMaintainers  = [System.Collections.Generic.List[string]]::new()
#         $teamUnmapped         = [System.Collections.Generic.List[string]]::new()
#         $adoMembersAudit      = [System.Collections.Generic.List[object]]::new()

#         # Step 4: Fetch Members
#         $membersResponse = Invoke-AdoApi -Uri "$AdoOrgUrl/_apis/projects/$($project.id)/teams/$($team.id)/members?api-version=7.1"

#         if ($membersResponse -and $membersResponse.value.Count -gt 0) {

#             foreach ($member in $membersResponse.value) {
#                 $adoEmail       = $member.identity.uniqueName.ToLower().Trim()
#                 $adoDisplayName = $member.identity.displayName
#                 # ADO returns isTeamAdmin at the top-level member object
#                 $isAdmin        = ($member.isTeamAdmin -eq $true)
#                 $adoRole        = if ($isAdmin) { "Team Admin" } else { "Member" }

#                 if ($userMap.ContainsKey($adoEmail)) {
#                     $ghUser = $userMap[$adoEmail]

#                     # Auto-assign: ADO Team Admin -> GitHub Maintainer, else Member
#                     if ($isAdmin) {
#                         $resolvedMaintainers.Add($ghUser)
#                         Write-Host "    [ADMIN]    $adoDisplayName ($adoEmail) -> $ghUser [maintainer]" -ForegroundColor Cyan
#                     } else {
#                         $resolvedMembers.Add($ghUser)
#                         Write-Host "    [MAPPED]   $adoDisplayName ($adoEmail) -> $ghUser [member]" -ForegroundColor Green
#                     }

#                     $adoMembersAudit.Add([ordered]@{
#                         adoDisplayName  = $adoDisplayName
#                         adoEmail        = $adoEmail
#                         adoRole         = $adoRole
#                         githubUsername  = $ghUser
#                         githubRole      = if ($isAdmin) { "maintainer" } else { "member" }
#                         status          = "mapped"
#                     })
#                 } else {
#                     $teamUnmapped.Add($adoEmail)
#                     $unmappedUsers += [PSCustomObject]@{
#                         Project      = $project.name
#                         Team         = $team.name
#                         ADOEmail     = $adoEmail
#                         ADORole      = $adoRole
#                         DisplayName  = $adoDisplayName
#                     }
#                     Write-Host "    [UNMAPPED] $adoDisplayName ($adoEmail) [$adoRole] - no GitHub username" -ForegroundColor DarkYellow

#                     $adoMembersAudit.Add([ordered]@{
#                         adoDisplayName  = $adoDisplayName
#                         adoEmail        = $adoEmail
#                         adoRole         = $adoRole
#                         githubUsername  = $null
#                         githubRole      = $null
#                         status          = "unmapped - add to user-mappings.csv"
#                     })
#                 }
#             }
#         } else {
#             Write-Host "    No members found." -ForegroundColor DarkGray
#         }

#         # Step 5: Build Mapping Entry
#         $teamEntry = [ordered]@{
#             adoProject            = $project.name
#             adoTeam               = $team.name
#             githubTeam            = $team.name.ToLower() -replace '[^a-z0-9\-]', '-' -replace '-+', '-'
#             githubTeamDescription = $team.description
#             parentTeam            = $null
#             privacy               = "closed"
#             maintainers           = @($resolvedMaintainers)   # Auto-populated from ADO Team Admins
#             members               = @($resolvedMembers)       # Auto-populated from ADO Members
#             unmappedAdoUsers      = @($teamUnmapped)          # ACTION REQUIRED: add to user-mappings.csv
#             adoMembersAudit       = @($adoMembersAudit)       # Full audit: ADO role -> GitHub role mapping
#         }

#         $mappings.Add($teamEntry)
#     }
# }

# # ----------------------------------------------------------
# # Step 6: Export to JSON
# # ----------------------------------------------------------
# $outputData = [ordered]@{
#     generatedAt       = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
#     adoOrgUrl         = $AdoOrgUrl
#     totalTeams        = $mappings.Count
#     totalUnmappedUsers = $unmappedUsers.Count
#     mappings          = $mappings
# }

# # Ensure output directory exists
# $outputDir = Split-Path $OutputFile -Parent
# if ($outputDir -and -not (Test-Path $outputDir)) {
#     New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
# }

# $outputData | ConvertTo-Json -Depth 10 | Out-File -FilePath $OutputFile -Encoding utf8

# # ----------------------------------------------------------
# # Step 7: Summary Report
# # ----------------------------------------------------------
# Write-Host "`n=========================================" -ForegroundColor Cyan
# Write-Host " Export Complete" -ForegroundColor Cyan
# Write-Host "=========================================" -ForegroundColor Cyan
# Write-Host " Total Teams Exported : $($mappings.Count)" -ForegroundColor Green
# Write-Host " Total Mapped Members : $($userMap.Count)" -ForegroundColor Green

# if ($unmappedUsers.Count -gt 0) {
#     Write-Host " Unmapped ADO Users   : $($unmappedUsers.Count) (no GitHub username found)" -ForegroundColor Yellow
#     Write-Host "`n [ACTION REQUIRED] The following ADO users have no GitHub mapping:" -ForegroundColor Yellow
#     $unmappedUsers | Format-Table -AutoSize
# } else {
#     Write-Host " Unmapped ADO Users   : 0 - All members resolved!" -ForegroundColor Green
# }

# Write-Host "`n Output saved to: $OutputFile" -ForegroundColor Cyan
# Write-Host " Next Step: Review the file, assign 'maintainers', then run the team sync pipeline." -ForegroundColor Yellow




<#
.SYNOPSIS
    Fetches all Projects, Teams, and Team Members from Azure DevOps and exports
    a populated team-mappings JSON template with GitHub usernames resolved from a user mapping CSV.

.DESCRIPTION
    This script:
      1. Reads user mappings from CSV (ADO email -> GitHub username)
      2. Fetches all Projects from the ADO organization
      3. Fetches all Teams within each Project
      4. Fetches all Members within each Team
      5. Cross-references members against the user mapping CSV
      6. Auto-populates the 'members' array with resolved GitHub usernames
      7. Flags any unmapped users (no GitHub username found) in a separate section
      8. Exports the full result to a JSON template ready for review

.PARAMETER AdoOrgUrl
    Azure DevOps organization URL. Example: https://dev.azure.com/myorganization

.PARAMETER AdoPat
    Azure DevOps Personal Access Token with Project and Team (Read) scope.

.PARAMETER UserMappingFile
    Path to the CSV file containing ADO email to GitHub username mappings.

.PARAMETER OutputFile
    Path to save the generated JSON template.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AdoOrgUrl,

    [Parameter(Mandatory = $true)]
    [string]$AdoPat,

    [string]$UserMappingFile = ".\config\user-mappings.csv",

    [string]$OutputFile = ".\config\team-mappings-template.json"
)

$ErrorActionPreference = "Stop"

# ----------------------------------------------------------
# Auth Headers
# ----------------------------------------------------------
$base64AdoAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat"))
$adoHeaders = @{ Authorization = "Basic $base64AdoAuth" }

# ----------------------------------------------------------
# Helper: ADO API Call
# ----------------------------------------------------------
function Invoke-AdoApi {
    param([string]$Uri)
    try {
        return Invoke-RestMethod -Uri $Uri -Headers $adoHeaders -Method Get -ContentType "application/json"
    } catch {
        Write-Warning "ADO API call failed: $Uri | $($_.Exception.Message)"
        return $null
    }
}

# ----------------------------------------------------------
# Step 1: Load User Mapping CSV
# ----------------------------------------------------------
$userMap = @{}
$unmappedUsers = @()

if (Test-Path $UserMappingFile) {
    Write-Host "Loading user mappings from $UserMappingFile..." -ForegroundColor Cyan
    $csvContent = Get-Content $UserMappingFile | Where-Object { $_.Trim() -ne "" }
    $csvData = $csvContent | ConvertFrom-Csv

    foreach ($row in $csvData) {
        $adoEmail = @($row.ADOEmail, $row.ado_email, $row.Email) |
            Where-Object { $_ } | Select-Object -First 1
        $githubUsername = @($row.GitHubUsername, $row.github_username, $row.Username) |
            Where-Object { $_ } | Select-Object -First 1

        if ($adoEmail -and $githubUsername) {
            $userMap[$adoEmail.ToLower().Trim()] = $githubUsername.Trim()
        }
    }
    Write-Host "Loaded $($userMap.Count) user mappings." -ForegroundColor Green
} else {
    Write-Warning "User mapping file not found at '$UserMappingFile'. Members will not be resolved."
}

# ----------------------------------------------------------
# Step 2: Fetch All Projects
# ----------------------------------------------------------
Write-Host "`nFetching projects from $AdoOrgUrl..." -ForegroundColor Cyan

$projectsResponse = Invoke-AdoApi -Uri "$AdoOrgUrl/_apis/projects?api-version=7.1"

if (-not $projectsResponse) {
    Write-Error "Failed to fetch projects. Please check your ADO URL and PAT."
    exit 1
}

Write-Host "Found $($projectsResponse.value.Count) projects." -ForegroundColor Green

$mappings = [System.Collections.Generic.List[object]]::new()

# ----------------------------------------------------------
# Step 3: Fetch Teams and Members for Each Project
# ----------------------------------------------------------
foreach ($project in $projectsResponse.value) {

    Write-Host "`nProject: $($project.name)" -ForegroundColor Yellow

    $teamsResponse = Invoke-AdoApi -Uri "$AdoOrgUrl/_apis/projects/$($project.id)/teams?api-version=7.1"

    if (-not $teamsResponse) {
        Write-Warning "  Could not fetch teams for project: $($project.name)"
        continue
    }

    foreach ($team in $teamsResponse.value) {

        Write-Host "  Team: $($team.name)" -ForegroundColor Gray

        $resolvedMembers      = [System.Collections.Generic.List[string]]::new()
        $resolvedMaintainers  = [System.Collections.Generic.List[string]]::new()
        $teamUnmapped         = [System.Collections.Generic.List[string]]::new()
        $adoMembersAudit      = [System.Collections.Generic.List[object]]::new()

        # Step 4: Fetch Members
        $membersResponse = Invoke-AdoApi -Uri "$AdoOrgUrl/_apis/projects/$($project.id)/teams/$($team.id)/members?api-version=7.1"

        if ($membersResponse -and $membersResponse.value.Count -gt 0) {

            foreach ($member in $membersResponse.value) {
                $adoEmail       = $member.identity.uniqueName.ToLower().Trim()
                $adoDisplayName = $member.identity.displayName
                # ADO returns isTeamAdmin at the top-level member object
                $isAdmin        = ($member.isTeamAdmin -eq $true)
                $adoRole        = if ($isAdmin) { "Team Admin" } else { "Member" }

                if ($userMap.ContainsKey($adoEmail)) {
                    $ghUser = $userMap[$adoEmail]

                    # Auto-assign: ADO Team Admin -> GitHub Maintainer, else Member
                    if ($isAdmin) {
                        $resolvedMaintainers.Add($ghUser)
                        Write-Host "    [ADMIN]    $adoDisplayName ($adoEmail) -> $ghUser [maintainer]" -ForegroundColor Cyan
                    } else {
                        $resolvedMembers.Add($ghUser)
                        Write-Host "    [MAPPED]   $adoDisplayName ($adoEmail) -> $ghUser [member]" -ForegroundColor Green
                    }

                    $adoMembersAudit.Add([ordered]@{
                        adoDisplayName  = $adoDisplayName
                        adoEmail        = $adoEmail
                        adoRole         = $adoRole
                        githubUsername  = $ghUser
                        githubRole      = if ($isAdmin) { "maintainer" } else { "member" }
                        status          = "mapped"
                    })
                } else {
                    $teamUnmapped.Add($adoEmail)
                    $unmappedUsers += [PSCustomObject]@{
                        Project      = $project.name
                        Team         = $team.name
                        ADOEmail     = $adoEmail
                        ADORole      = $adoRole
                        DisplayName  = $adoDisplayName
                    }
                    Write-Host "    [UNMAPPED] $adoDisplayName ($adoEmail) [$adoRole] - no GitHub username" -ForegroundColor DarkYellow

                    $adoMembersAudit.Add([ordered]@{
                        adoDisplayName  = $adoDisplayName
                        adoEmail        = $adoEmail
                        adoRole         = $adoRole
                        githubUsername  = $null
                        githubRole      = $null
                        status          = "unmapped - add to user-mappings.csv"
                    })
                }
            }
        } else {
            Write-Host "    No members found." -ForegroundColor DarkGray
        }

        # Step 5: Build Mapping Entry
        $teamEntry = [ordered]@{
            adoProject            = $project.name
            adoTeam               = $team.name
            githubTeam            = $team.name.ToLower() -replace '[^a-z0-9\-]', '-' -replace '-+', '-'
            githubTeamDescription = $team.description
            parentTeam            = $null
            privacy               = "closed"
            maintainers           = @($resolvedMaintainers)   # Auto-populated from ADO Team Admins
            members               = @($resolvedMembers)       # Auto-populated from ADO Members
            unmappedAdoUsers      = @($teamUnmapped)          # ACTION REQUIRED: add to user-mappings.csv
            adoMembersAudit       = @($adoMembersAudit)       # Full audit: ADO role -> GitHub role mapping
        }

        $mappings.Add($teamEntry)
    }
}

# ----------------------------------------------------------
# Step 6: Export to JSON
# ----------------------------------------------------------
$outputData = [ordered]@{
    generatedAt       = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    adoOrgUrl         = $AdoOrgUrl
    totalTeams        = $mappings.Count
    totalUnmappedUsers = $unmappedUsers.Count
    mappings          = $mappings
}

# Ensure output directory exists
$outputDir = Split-Path $OutputFile -Parent
if ($outputDir -and -not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$outputData | ConvertTo-Json -Depth 10 | Out-File -FilePath $OutputFile -Encoding utf8

# ----------------------------------------------------------
# Step 7: Summary Report
# ----------------------------------------------------------
Write-Host "`n=========================================" -ForegroundColor Cyan
Write-Host " Export Complete" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host " Total Teams Exported : $($mappings.Count)" -ForegroundColor Green
Write-Host " Total Mapped Members : $($userMap.Count)" -ForegroundColor Green

if ($unmappedUsers.Count -gt 0) {
    Write-Host " Unmapped ADO Users   : $($unmappedUsers.Count) (no GitHub username found)" -ForegroundColor Yellow
    Write-Host "`n [ACTION REQUIRED] The following ADO users have no GitHub mapping:" -ForegroundColor Yellow
    $unmappedUsers | Format-Table -AutoSize
} else {
    Write-Host " Unmapped ADO Users   : 0 - All members resolved!" -ForegroundColor Green
}

Write-Host "`n Output saved to: $OutputFile" -ForegroundColor Cyan
Write-Host " Next Step: Review the file, assign 'maintainers', then run the team sync pipeline." -ForegroundColor Yellow
