<#
.SYNOPSIS
    Migrates ADO Branch Policies to GitHub for multiple branches (main, develop, release, etc.)
#>
param(
    [Parameter(Mandatory = $true)] $AdoOrgUrl,
    [Parameter(Mandatory = $true)] $AdoProject,
    [Parameter(Mandatory = $true)] $AdoRepoName,
    [Parameter(Mandatory = $true)] $AdoPat,
    [Parameter(Mandatory = $true)] $GitHubOrg,
    [Parameter(Mandatory = $true)] $GitHubRepo,
    [Parameter(Mandatory = $true)] $GitHubPat
)

$headersAdo = @{ Authorization = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat")))" }
$headersGh  = @{ Authorization = "Bearer $GitHubPat"; Accept = "application/vnd.github.v3+json" }

# 1. Fetch ADO Repository ID
$repoUrl = "$($AdoOrgUrl.TrimEnd('/'))/$AdoProject/_apis/git/repositories/$AdoRepoName?api-version=7.0"
$repoId = (Invoke-RestMethod -Uri $repoUrl -Headers $headersAdo).id

# 2. Fetch ALL Policies for this repository
$policyUrl = "$($AdoOrgUrl.TrimEnd('/'))/$AdoProject/_apis/policy/configurations?api-version=7.0"
$allPolicies = (Invoke-RestMethod -Uri $policyUrl -Headers $headersAdo).value | Where-Object { 
    $_.settings.scope.repositoryId -eq $repoId 
}

# 3. Group policies by Branch (refName)
# ADO uses refs/heads/branchname
$branchGroups = $allPolicies | Group-Object { $_.settings.scope.refName }

Write-Host "Found policies for $($branchGroups.Count) branches in ADO." -ForegroundColor Cyan

foreach ($group in $branchGroups) {
    $rawRefName = $group.Name
    if (-not $rawRefName) { continue } # Skip repo-wide policies not tied to a branch
    
    $branchName = $rawRefName -replace "refs/heads/", ""
    
    # Optional: Map 'master' to 'main' if your GitHub default is 'main'
    $targetBranch = $branchName
    if ($branchName -eq "master") { $targetBranch = "main" }

    Write-Host "`nProcessing Branch: $branchName -> GitHub: $targetBranch" -ForegroundColor Yellow

    # Build GitHub Protection Payload for this specific branch
    $ghPayload = @{
        enforce_admins = $true
        required_pull_request_reviews = @{ 
            dismiss_stale_reviews = $true 
            required_approving_review_count = 1 
        }
        required_status_checks = $null
        restrictions = $null
    }

    foreach ($p in $group.Group) {
        switch ($p.type.id) {
            "fa4e907d-c16b-4a4c-9dfa-4906e5d171dd" { # Minimum Reviewers
                $ghPayload.required_pull_request_reviews.required_approving_review_count = $p.settings.minimumApproverCount
            }
            "7712ba6c-9512-4014-88c1-fc902258c081" { # Comment Resolution
                $ghPayload.required_conversation_resolution = $true
            }
            "2d05779c-b17b-4024-85bc-205128a1c97a" { # Require Linear History
                $ghPayload.required_linear_history = $true
            }
        }
    }

    # 4. Apply to GitHub for this specific branch
    $ghUrl = "https://api.github.com/repos/$GitHubOrg/$GitHubRepo/branches/$targetBranch/protection"
    try {
        Invoke-RestMethod -Uri $ghUrl -Method Put -Headers $headersGh -Body ($ghPayload | ConvertTo-Json -Depth 10) -ContentType "application/json"
        Write-Host "SUCCESS: Policies applied to $targetBranch" -ForegroundColor Green
    } catch {
        Write-Warning "Could not apply policies to branch '$targetBranch'. Ensure the branch exists on GitHub."
    }
}
