<#
.SYNOPSIS
    Discovery: Exports ADO Branch Policies to a JSON mapping file.
#>
param(
    [Parameter(Mandatory = $true)] $AdoOrgUrl,
    [Parameter(Mandatory = $true)] $AdoProject,
    [Parameter(Mandatory = $true)] $AdoPat,
    [string]$OutputFile = ".\config\branch-policy-export.json"
)

$headersAdo = @{ Authorization = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat")))" }

# 1. Fetch all repositories in the project
Write-Host "Fetching repositories for project: $AdoProject" -ForegroundColor Cyan
$reposUrl = "$($AdoOrgUrl.TrimEnd('/'))/$AdoProject/_apis/git/repositories?api-version=7.0"
$repos = (Invoke-RestMethod -Uri $reposUrl -Headers $headersAdo).value

# 2. Fetch all policies in the project
$policyUrl = "$($AdoOrgUrl.TrimEnd('/'))/$AdoProject/_apis/policy/configurations?api-version=7.0"
$allPolicies = (Invoke-RestMethod -Uri $policyUrl -Headers $headersAdo).value

$results = @()

foreach ($repo in $repos) {
    Write-Host "  Processing: $($repo.name)" -ForegroundColor Gray
    
    $repoPolicies = $allPolicies | Where-Object { $_.settings.scope.repositoryId -eq $repo.id }
    $branchGroups = $repoPolicies | Group-Object { $_.settings.scope.refName }

    foreach ($group in $branchGroups) {
        $branchName = $group.Name -replace "refs/heads/", ""
        if (-not $branchName) { continue }

        $policyDetails = @{
            adoBranch      = $branchName
            githubBranch   = if ($branchName -eq "master") { "main" } else { $branchName }
            policies       = @()
        }

        foreach ($p in $group.Group) {
            $mapping = switch ($p.type.id) {
                "fa4e907d-c16b-4a4c-9dfa-4906e5d171dd" { @{ type = "ReviewerCount"; value = $p.settings.minimumApproverCount; ghSetting = "required_approving_review_count" } }
                "7712ba6c-9512-4014-88c1-fc902258c081" { @{ type = "CommentResolution"; value = $true; ghSetting = "required_conversation_resolution" } }
                "2d05779c-b17b-4024-85bc-205128a1c97a" { @{ type = "LinearHistory"; value = $true; ghSetting = "required_linear_history" } }
                "594f6a2b-e17c-4c25-83f0-5db5344e90c1" { @{ type = "BuildValidation"; value = "Enabled"; ghSetting = "required_status_checks" } }
                Default { @{ type = "Unknown ($($p.type.id))"; value = "N/A"; ghSetting = "Manual" } }
            }
            $policyDetails.policies += $mapping
        }

        $results += [ordered]@{
            repository = $repo.name
            config     = $policyDetails
        }
    }
}

# 3. Export to JSON
$results | ConvertTo-Json -Depth 10 | Out-File -FilePath $OutputFile
Write-Host "`nSUCCESS: Branch policies exported to $OutputFile" -ForegroundColor Green
