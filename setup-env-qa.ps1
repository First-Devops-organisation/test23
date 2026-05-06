# ==========================================
# Setup QA Environment
# ==========================================
$GHOrg = "First-Devops-organisation"
$GHRepo = "dummy-secretymigr"
$EnvName = "qa"
$BranchName = "release"
$ReviewerUsernames = @("varsha-patilyash")

Write-Host "Setting up '$EnvName' environment..." -ForegroundColor Cyan

# Fetch User IDs
$reviewerObjects = @()
foreach ($username in $ReviewerUsernames) {
    Write-Host "Looking up User ID for $username..."
    $userId = (gh api users/$username --jq '.id' 2>$null)
    if ($userId) {
        Write-Host "  -> Found ID: $userId" -ForegroundColor DarkGray
        $reviewerObjects += @{ type = "User"; id = [int]$userId }
    } else {
        Write-Host "  -> Error: Could not find user '$username'" -ForegroundColor Red
    }
}

if ($reviewerObjects.Count -eq 0) {
    Write-Host "No valid reviewers found. Exiting." -ForegroundColor Red
    exit
}

# Build Configuration
$envConfig = @{
    wait_timer = 5 
    reviewers = $reviewerObjects
    deployment_branch_policy = @{
        protected_branches = $false
        custom_branch_policies = $true
    }
} | ConvertTo-Json -Depth 5 -Compress

# Create Environment
Write-Host "Applying settings to environment..."
$envConfig | gh api -X PUT "repos/$GHOrg/$GHRepo/environments/$EnvName" `
    --header "Accept: application/vnd.github+json" --input -

# Add Branch Rule
$branchConfig = @{ name = $BranchName } | ConvertTo-Json -Compress
$branchConfig | gh api -X POST "repos/$GHOrg/$GHRepo/environments/$EnvName/deployment-branch-policies" `
    --header "Accept: application/vnd.github+json" --input -

Write-Host "QA Setup Complete!" -ForegroundColor Cyan
