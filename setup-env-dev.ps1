# ==========================================
# Setup DEV Environment
# ==========================================
$GHOrg = "First-Devops-organisation"
$GHRepo = "dummy-secretymigr"
$EnvName = "dev"
$BranchName = "develop"

Write-Host "Setting up '$EnvName' environment..." -ForegroundColor Cyan

# Build the Configuration
$envConfig = @{
    deployment_branch_policy = @{
        protected_branches = $false
        custom_branch_policies = $true
    }
} | ConvertTo-Json -Depth 5 -Compress

# Create the Environment
Write-Host "Applying settings to environment..."
$envConfig | gh api -X PUT "repos/$GHOrg/$GHRepo/environments/$EnvName" `
    --header "Accept: application/vnd.github+json" `
    --input -

# Add Branch Rule
$branchConfig = @{ name = $BranchName } | ConvertTo-Json -Compress
$branchConfig | gh api -X POST "repos/$GHOrg/$GHRepo/environments/$EnvName/deployment-branch-policies" `
    --header "Accept: application/vnd.github+json" `
    --input -

Write-Host "Rule added: Only the '$BranchName' branch can deploy." -ForegroundColor Green
Write-Host "Dev Setup Complete!" -ForegroundColor Cyan
