<#
.SYNOPSIS
    Migrates ADO Branch Policies to GitHub Branch Protection with enhanced validation.
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

# --- 0. Input Validation ---
if ([string]::IsNullOrWhiteSpace($AdoRepoName)) { 
    Write-Error "ERROR: AdoRepoName is empty. Please check your Variable Group or Pipeline Parameters."; exit 1 
}

$headersAdo = @{ Authorization = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat")))" }
$headersGh  = @{ Authorization = "Bearer $GitHubPat"; Accept = "application/vnd.github.v3+json" }

# --- 1. Fetch ADO Repository ID ---
# We ensure the URL is constructed cleanly
$repoUrl = "$($AdoOrgUrl.TrimEnd('/'))/$($AdoProject.Trim('/'))/_apis/git/repositories/$($AdoRepoName.Trim())?api-version=7.0"

Write-Host "Connecting to ADO: $repoUrl" -ForegroundColor Cyan

try {
    $repoResponse = Invoke-RestMethod -Uri $repoUrl -Headers $headersAdo -Method Get
    $repoId = $repoResponse.id
    Write-Host "Found ADO Repo ID: $repoId" -ForegroundColor Green
} catch {
    Write-Error "Failed to fetch ADO Repository info. Check if '$AdoRepoName' exists and your PAT has permissions."
    Write-Error "Details: $_"
    exit 1
}

# --- 2. Fetch ADO Policies ---
$policyUrl = "$($AdoOrgUrl.TrimEnd('/'))/$($AdoProject.Trim('/'))/_apis/policy/configurations?api-version=7.0"
$policies = (Invoke-RestMethod -Uri $policyUrl -Headers $headersAdo).value | Where-Object { $_.settings.scope.repositoryId -eq $repoId }

# --- 3. Build GitHub Protection Payload ---
$ghPayload = @{
    enforce_admins                = $true
    required_pull_request_reviews = @{ 
        dismiss_stale_reviews           = $true 
        required_approving_review_count = 1 
    }
    required_status_checks        = $null
    restrictions                  = $null
}

foreach ($p in $policies) {
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

# --- 4. Apply to GitHub ---
$ghUrl = "https://api.github.com/repos/$GitHubOrg/$GitHubRepo/branches/main/protection"
try {
    Invoke-RestMethod -Uri $ghUrl -Method Put -Headers $headersGh -Body ($ghPayload | ConvertTo-Json -Depth 10) -ContentType "application/json"
    Write-Host "SUCCESS: Branch policies migrated to $GitHubRepo/main" -ForegroundColor Green
} catch {
    Write-Error "Failed to apply policies to GitHub: $_"
}
