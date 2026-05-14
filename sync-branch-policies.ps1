<#
.SYNOPSIS
    Sync: Reads the JSON mapping file and applies branch policies to GitHub.
#>
param(
    [Parameter(Mandatory = $true)] $GitHubOrg,
    [Parameter(Mandatory = $true)] $GitHubPat,
    [string]$MappingFile = "./config/branch-policy-mappings.json"
)

if (-not (Test-Path $MappingFile)) { Write-Error "Mapping file not found: $MappingFile"; exit 1 }

$headersGh = @{ Authorization = "Bearer $GitHubPat"; Accept = "application/vnd.github.v3+json" }
$mappings = Get-Content $MappingFile | ConvertFrom-Json

Write-Host "Starting Sync for $($mappings.Count) branch configurations..." -ForegroundColor Cyan

foreach ($map in $mappings) {
    $repo = $map.repository
    $branch = $map.config.githubBranch
    
    Write-Host "`nSyncing: $repo / $branch" -ForegroundColor Yellow

    # Initialize GitHub Payload
    $ghPayload = @{
        enforce_admins = $true
        required_pull_request_reviews = @{ 
            dismiss_stale_reviews = $true 
            required_approving_review_count = 1 
        }
        required_status_checks = $null
        restrictions = $null
    }

    # Map from JSON config
    foreach ($p in $map.config.policies) {
        switch ($p.type) {
            "ReviewerCount" { $ghPayload.required_pull_request_reviews.required_approving_review_count = $p.value }
            "CommentResolution" { $ghPayload.required_conversation_resolution = $true }
            "LinearHistory" { $ghPayload.required_linear_history = $true }
            "MergeStrategy" { $ghPayload.required_linear_history = $true } # Squash/Rebase enforcement
            "BuildValidation" {
                # Note: In GitHub, you must manually add the status check name to the JSON if you want it automated
                if ($p.ghStatusCheck) {
                    $ghPayload.required_status_checks = @{ strict = $true; contexts = @($p.ghStatusCheck) }
                }
            }
        }
    }

    # Apply to GitHub
    $ghUrl = "https://api.github.com/repos/$GitHubOrg/$repo/branches/$branch/protection"
    try {
        Invoke-RestMethod -Uri $ghUrl -Method Put -Headers $headersGh -Body ($ghPayload | ConvertTo-Json -Depth 10) -ContentType "application/json"
        Write-Host "  SUCCESS: Applied policies to $repo/$branch" -ForegroundColor Green
    } catch {
        Write-Warning "  FAILED: Could not apply policies to $repo/$branch. Ensure branch exists."
    }
}
