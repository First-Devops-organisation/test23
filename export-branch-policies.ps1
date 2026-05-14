<#
.SYNOPSIS
    Discovery: Exports ADO Branch Policies to a JSON mapping file.
#>
param(
    [Parameter(Mandatory = $true)] $AdoOrgUrl,
    [Parameter(Mandatory = $true)] $AdoProject,
    [Parameter(Mandatory = $true)] $AdoPat,
    [string]$AdoRepoName = "", 
    [string]$OutputFile = "./config/branch-policy-mappings.json"
)

$headersAdo = @{ Authorization = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat")))" }

# 1. Fetch repositories
Write-Host "Fetching repositories for project: $AdoProject" -ForegroundColor Cyan
$reposUrl = "$($AdoOrgUrl.TrimEnd('/'))/$($AdoProject.Trim('/'))/_apis/git/repositories?api-version=7.0"
$allRepos = (Invoke-RestMethod -Uri $reposUrl -Headers $headersAdo).value

# Filter by repo name if provided
$repos = if ($AdoRepoName) { 
    $allRepos | Where-Object { $_.name -eq $AdoRepoName } 
} else { 
    $allRepos 
}

if ($repos.Count -eq 0) {
    Write-Error "No repository found matching: $AdoRepoName"
    exit 1
}

# 2. Fetch all policies in the project
$policyUrl = "$($AdoOrgUrl.TrimEnd('/'))/$($AdoProject.Trim('/'))/_apis/policy/configurations?api-version=7.0"
$allPolicies = (Invoke-RestMethod -Uri $policyUrl -Headers $headersAdo).value

$results = @()

foreach ($repo in $repos) {
    Write-Host "  Analyzing Repo: $($repo.name)" -ForegroundColor Gray
    
    $repoPolicies = $allPolicies | Where-Object { $_.settings.scope.repositoryId -eq $repo.id }
    $branchGroups = $repoPolicies | Group-Object { $_.settings.scope.refName }

    foreach ($group in $branchGroups) {
        if (-not $group.Name) { continue }
        
        $branchName = $group.Name -replace "refs/heads/", ""
        
        $policyDetails = @{
            adoBranch    = $branchName
            githubBranch = if ($branchName -eq "master") { "main" } else { $branchName }
            policies     = @()
        }

        foreach ($p in $group.Group) {
            $mapping = switch ($p.type.id) {
                "fa4e907d-c16b-4a4c-9dfa-4906e5d171dd" { 
                    @{ type = "ReviewerCount"; value = $p.settings.minimumApproverCount; ghSetting = "required_approving_review_count" } 
                }
                "7712ba6c-9512-4014-88c1-fc902258c081" { 
                    @{ type = "CommentResolution"; value = $true; ghSetting = "required_conversation_resolution" } 
                }
                "2d05779c-b17b-4024-85bc-205128a1c97a" { 
                    @{ type = "LinearHistory"; value = $true; ghSetting = "required_linear_history" } 
                }
                "fa4e907d-c16b-4a4c-9dfa-4916e5d171ab" { 
                    @{ type = "MergeStrategy"; value = "Enforced"; ghSetting = "allow_squash_merge/rebase" } 
                }
                "0609b952-1397-4640-95ec-e00a01b2c241" { 
                    $defId = $p.settings.buildDefinitionId
                    $defUrl = "$($AdoOrgUrl.TrimEnd('/'))/$($AdoProject.Trim('/'))/_apis/build/definitions/$($defId)?api-version=7.0"
                    $defName = try { (Invoke-RestMethod -Uri $defUrl -Headers $headersAdo).name } catch { "ID: $defId" }
                    
                    @{ type = "BuildValidation"; adoPipeline = $defName; ghStatusCheck = "REPLACE_WITH_GHA_JOB_NAME"; ghSetting = "required_status_checks" } 
                }
                Default { 
                    @{ type = "Other ($($p.type.id))"; value = "Manual Review"; ghSetting = "Manual" } 
                }
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
$outputDir = Split-Path $OutputFile -Parent
if ($outputDir -and -not (Test-Path $outputDir)) { 
    New-Item -ItemType Directory -Path $outputDir -Force 
}

$results | ConvertTo-Json -Depth 10 | Out-File -FilePath $OutputFile -Encoding utf8
Write-Host "`nSUCCESS: Branch policies exported to $OutputFile" -ForegroundColor Green
