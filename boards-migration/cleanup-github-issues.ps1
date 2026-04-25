# ============================================================
#  Cleanup - Delete ALL issues from GitHub repo
#  Usage: .\cleanup-github-issues.ps1
#  Requires: GH_PAT environment variable
# ============================================================

param(
    [string]$Org = "Urvashi773",
    [string]$Repo = "ado-migration-poc"
)

$ghPat = $env:GH_PAT
if (-not $ghPat) { Write-Host "Set env:GH_PAT first" -ForegroundColor Red; exit 1 }

$headers = @{ Authorization = "bearer $ghPat"; "Content-Type" = "application/json" }
$restHeaders = @{ Authorization = "token $ghPat"; Accept = "application/vnd.github.v3+json" }

Write-Host "Fetching all issues from $Org/$Repo..." -ForegroundColor Cyan

# Get all issues (including closed)
$page = 1; $allIssues = @()
do {
    $uri = "https://api.github.com/repos/$Org/$Repo/issues?state=all&per_page=100&page=$page"
    $issues = Invoke-RestMethod -Uri $uri -Headers $restHeaders
    # Filter out pull requests
    $realIssues = $issues | Where-Object { -not $_.pull_request }
    $allIssues += $realIssues
    $page++
} while ($issues.Count -eq 100)

Write-Host "Found $($allIssues.Count) issues to delete" -ForegroundColor Yellow

if ($allIssues.Count -eq 0) { Write-Host "Nothing to clean up!" -ForegroundColor Green; exit 0 }

# Delete each issue via GraphQL (REST API doesn't support delete)
$deleted = 0
foreach ($issue in $allIssues) {
    $nodeId = $issue.node_id
    $mutation = "mutation { deleteIssue(input: {issueId: `"$nodeId`"}) { repository { name } } }"
    $body = @{ query = $mutation } | ConvertTo-Json
    try {
        Invoke-RestMethod -Method POST -Uri "https://api.github.com/graphql" -Headers $headers -Body $body | Out-Null
        $deleted++
        Write-Host "  Deleted #$($issue.number): $($issue.title)" -ForegroundColor DarkGray
    } catch {
        Write-Host "  Failed to delete #$($issue.number): $_" -ForegroundColor Red
    }
    Start-Sleep -Milliseconds 300
}

Write-Host "`nDeleted $deleted issues. Repo is clean!" -ForegroundColor Green
Write-Host "Now run the pipeline with resume = false for a fresh start." -ForegroundColor Cyan
