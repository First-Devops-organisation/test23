<#
.SYNOPSIS
    Sets repository visibility and branch protection rules post-migration.
.DESCRIPTION
    After GEI migration, repos default to private. This script sets correct visibility
    and applies baseline branch protection rules matching ADO policies.
.PARAMETER ConfigFile
    Path to migration-config.json
.PARAMETER Visibility
    Repository visibility: private, internal, or public
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigFile,

    [ValidateSet("private", "internal", "public")]
    [string]$Visibility
)

$ErrorActionPreference = "Stop"

$config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
$ghOrg = $config.target.organization
$ghPat = if ($config.target.pat) { $config.target.pat } else { $env:GH_PAT }
$targetVisibility = if ($Visibility) { $Visibility } else { $config.options.repoVisibility }

$headers = @{
    Authorization          = "Bearer $ghPat"
    Accept                 = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
}

Write-Host "=== Post-Migration: Visibility & Branch Protection ===" -ForegroundColor Cyan

# --- Get all repos in org ---
Write-Host "Fetching repositories..." -ForegroundColor Yellow
$page = 1
$allRepos = @()
do {
    $repos = Invoke-RestMethod -Uri "https://api.github.com/orgs/$ghOrg/repos?per_page=100&page=$page" -Headers $headers
    $allRepos += $repos
    $page++
} while ($repos.Count -eq 100)

Write-Host "Found $($allRepos.Count) repositories" -ForegroundColor Green

foreach ($repo in $allRepos) {
    $repoName = $repo.name
    Write-Host "`n  $repoName" -ForegroundColor Yellow

    # --- Set Visibility ---
    if ($repo.visibility -ne $targetVisibility) {
        Write-Host "    Visibility: $($repo.visibility) → $targetVisibility" -ForegroundColor Gray
        try {
            Invoke-RestMethod -Uri "https://api.github.com/repos/$ghOrg/$repoName" `
                -Headers $headers -Method Patch -ContentType "application/json" `
                -Body (@{ visibility = $targetVisibility } | ConvertTo-Json) | Out-Null
            Write-Host "    [OK] Visibility updated" -ForegroundColor Green
        }
        catch {
            Write-Warning "    Failed to update visibility: $_"
        }
    }
    else {
        Write-Host "    Visibility already: $targetVisibility" -ForegroundColor Gray
    }

    # --- Apply Branch Protection ---
    $defaultBranch = $repo.default_branch
    if (-not $defaultBranch) { $defaultBranch = "main" }

    Write-Host "    Applying branch protection to: $defaultBranch" -ForegroundColor Gray

    $branchProtection = @{
        required_status_checks            = @{
            strict   = $true
            contexts = @()
        }
        enforce_admins                    = $true
        required_pull_request_reviews     = @{
            required_approving_review_count = 1
            dismiss_stale_reviews          = $true
            require_code_owner_reviews     = $false
        }
        restrictions                      = $null
        required_linear_history           = $false
        allow_force_pushes                = $false
        allow_deletions                   = $false
        required_conversation_resolution  = $true
    }

    try {
        Invoke-RestMethod -Uri "https://api.github.com/repos/$ghOrg/$repoName/branches/$defaultBranch/protection" `
            -Headers $headers -Method Put -ContentType "application/json" `
            -Body ($branchProtection | ConvertTo-Json -Depth 5) | Out-Null
        Write-Host "    [OK] Branch protection applied" -ForegroundColor Green
    }
    catch {
        Write-Warning "    Failed to apply branch protection: $_"
    }
}

Write-Host "`n=== Visibility & Protection Complete ===" -ForegroundColor Cyan
