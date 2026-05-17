<#
.SYNOPSIS
    Creates GitHub teams, syncs/invites members, and applies repository access.
.PARAMETER RunMode
    "CreateTeamsAndInvite" or "AssignRepoAccess"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$GitHubOrg,
    [Parameter(Mandatory = $true)] [string]$GitHubPat,
    [Parameter(Mandatory = $true)] [string]$AdoOrg,
    [Parameter(Mandatory = $true)] [string]$AdoPat,
    [string]$TeamMappingFile = "./config/team-mappings.json",
    [string]$UserMappingFile = "./config/user-mappings.csv",
    [string]$RunMode = "CreateTeamsAndInvite"
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

# --- 1. Load User Mappings, Exclusion List & Invite List ---
$userMap = @{}        # ADO email -> GitHub username (for direct-add)
$excludedUsers = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$inviteList = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

if (Test-Path $UserMappingFile) {
    Write-Host "Loading user mappings from $UserMappingFile..." -ForegroundColor Gray
    $csvData = Get-Content $UserMappingFile | Where-Object { $_.Trim() -ne "" -and -not $_.TrimStart().StartsWith("#") } | ConvertFrom-Csv
    foreach ($row in $csvData) {
        $email   = ($row.ADOEmail, $row.ado_email, $row.Email) | Where-Object { $_ } | Select-Object -First 1
        $notes   = ($row.Notes, $row.notes, $row.Status)       | Where-Object { $_ } | Select-Object -First 1
        $ghUser  = ($row.GitHubUsername, $row.github_username, $row.Username) | Where-Object { $_ } | Select-Object -First 1

        if (-not $email) { continue }
        $emailKey = $email.ToLower().Trim()

        # Excluded (ex-employees) - skip completely
        if ($notes -and $notes.Trim().ToLower() -eq "excluded") {
            $null = $excludedUsers.Add($emailKey)
            continue
        }

        # Has a GitHub username - direct add
        if ($ghUser) {
            $userMap[$emailKey] = $ghUser.Trim()
        } else {
            # In CSV but no GitHub username - queue for email invite
            $null = $inviteList.Add($emailKey)
        }
    }
    Write-Host "   Loaded $($userMap.Count) direct mappings, $($inviteList.Count) queued for invite, $($excludedUsers.Count) excluded." -ForegroundColor Gray
} else {
    Write-Host "⚠️ User mapping file not found. All ADO users will receive email invites." -ForegroundColor Yellow
}

# --- 2. Load Team Mappings ---
$mappingData = Get-Content $TeamMappingFile -Raw | ConvertFrom-Json
$mappings = $mappingData.mappings

Write-Host "=== Starting Mode: $RunMode ===" -ForegroundColor Cyan

foreach ($map in $mappings) {
    Write-Host "`n▶ Processing: $($map.adoProject) / $($map.adoTeam) -> $($map.githubTeam)" -ForegroundColor Yellow
    
    $teamName = $map.githubTeam
    $teamSlug = $teamName.ToLower() -replace "\s+","-"
    $ghTeamInfo = Invoke-GhRest -Method Get -Uri "https://api.github.com/orgs/$GitHubOrg/teams/$teamSlug"

    # ==========================================
    # MODE: Create Teams & Invite Users
    # ==========================================
    if ($RunMode -eq "CreateTeamsAndInvite") {
        $parentId = $null

        # A. Parent Team Logic
        if (-not [string]::IsNullOrEmpty($map.parentTeam)) {
            $parentSlug = $map.parentTeam.ToLower() -replace "\s+","-"
            $parentTeamInfo = Invoke-GhRest -Method Get -Uri "https://api.github.com/orgs/$GitHubOrg/teams/$parentSlug"
            if ($parentTeamInfo) {
                $parentId = $parentTeamInfo.id
                Write-Host "   [OK] Parent team '$($map.parentTeam)' exists." -ForegroundColor DarkGray
            } else {
                Write-Host "   [NEW] Creating Parent team '$($map.parentTeam)'..." -ForegroundColor Green
                $newParent = Invoke-GhRest -Method Post -Uri "https://api.github.com/orgs/$GitHubOrg/teams" -Body @{ name = $map.parentTeam; privacy = "closed" }
                $parentId = $newParent.id
            }
        }

        # B. Child Team Logic
        if ($ghTeamInfo) {
            Write-Host "   [OK] GitHub team '$teamName' exists." -ForegroundColor DarkGray
        } else {
            Write-Host "   [NEW] Creating GitHub team '$teamName'..." -ForegroundColor Green
            $createBody = @{ name = $teamName; description = $map.githubTeamDescription; privacy = "closed" }
            if ($parentId) { $createBody.parent_team_id = $parentId }
            $ghTeamInfo = Invoke-GhRest -Method Post -Uri "https://api.github.com/orgs/$GitHubOrg/teams" -Body $createBody
        }

        # C. User Sync & Invites
        Write-Host "   Fetching members from ADO..." -ForegroundColor Gray
        try {
            $project = Invoke-RestMethod -Uri "$AdoOrg/_apis/projects/$($map.adoProject)?api-version=7.1" -Headers $adoHeaders
            $teams = Invoke-RestMethod -Uri "$AdoOrg/_apis/projects/$($project.id)/teams?api-version=7.1" -Headers $adoHeaders
            $adoTeam = $teams.value | Where-Object { $_.name -eq $map.adoTeam }
            
            if ($adoTeam) {
                $members = Invoke-RestMethod -Uri "$AdoOrg/_apis/projects/$($project.id)/teams/$($adoTeam.id)/members?api-version=7.1" -Headers $adoHeaders
                foreach ($member in $members.value) {
                    $email = $member.identity.uniqueName.ToLower().Trim()

                    # 1. Excluded? Skip entirely.
                    if ($excludedUsers.Contains($email)) {
                        Write-Host "      [EXCLUDED] $email is an ex-employee. Skipping." -ForegroundColor DarkYellow
                        continue
                    }

                    # 2. Has a GitHub mapping? Direct add.
                    if ($userMap.ContainsKey($email)) {
                        $ghUser = $userMap[$email]
                        $role = if ($map.maintainers -contains $ghUser) { "maintainer" } else { "member" }
                        try {
                            $null = Invoke-GhRest -Method Put -Uri "https://api.github.com/orgs/$GitHubOrg/teams/$teamSlug/memberships/$ghUser" -Body @{ role = $role }
                            Write-Host "      [ADDED] $ghUser as $role" -ForegroundColor Green
                        } catch {
                            Write-Warning "      [FAILED] Could not add $ghUser."
                        }
                    # 3. Explicitly listed in CSV but no GitHub username? Send invite.
                    } elseif ($inviteList.Contains($email)) {
                        Write-Host "      [INVITE] $email is in CSV but has no GitHub account. Sending invite..." -ForegroundColor Magenta
                        try {
                            $null = Invoke-GhRest -Method Post -Uri "https://api.github.com/orgs/$GitHubOrg/invitations" -Body @{
                                email = $email
                                role  = "direct_member"
                                team_ids = @( [int]$ghTeamInfo.id )
                            }
                            Write-Host "         -> Invite sent to $email!" -ForegroundColor Green
                        } catch {
                            $errMsg = $_.Exception.Message
                            if ($errMsg -match "already a part of") {
                                Write-Host "         -> $email is already in the org." -ForegroundColor Yellow
                            } else {
                                Write-Warning "         -> Failed to invite $email. ($errMsg)"
                            }
                        }
                    # 4. Not in CSV at all? Silently skip — do NOT invite.
                    } else {
                        Write-Host "      [SKIPPED] $email not in user-mappings.csv. Add them to the CSV to invite." -ForegroundColor DarkGray
                    }
                }
            }
        } catch {
            Write-Error "   [ERROR] Could not process ADO members: $($_.Exception.Message)"
        }
    }

    # ==========================================
    # MODE: Assign Repo Access
    # ==========================================
    if ($RunMode -eq "AssignRepoAccess") {
        if (-not $ghTeamInfo) {
            Write-Warning "   [SKIPPED] GitHub team '$teamName' does not exist. Did you run the 'CreateTeams' step first?"
            continue
        }

        if ($map.repositories) {
            Write-Host "   Assigning Repository Access for team '$teamName'..." -ForegroundColor Gray
            foreach ($repo in $map.repositories) {
                try {
                    $null = Invoke-GhRest -Method Put -Uri "https://api.github.com/orgs/$GitHubOrg/teams/$teamSlug/repos/$GitHubOrg/$($repo.name)" -Body @{ permission = $repo.permission }
                    Write-Host "      [ACCESS GRANTED] $($repo.permission) access to repo: $($repo.name)" -ForegroundColor Green
                } catch {
                    Write-Warning "      [ACCESS FAILED] Could not grant access to $($repo.name). (Does the repo exist yet?)"
                }
            }
        } else {
            Write-Host "   [SKIP] No repositories defined for this team." -ForegroundColor DarkGray
        }
    }
}

Write-Host "`n✅ Script Execution Complete!" -ForegroundColor Cyan
