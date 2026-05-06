# # ==========================================
# # Setup QA Environment
# # ==========================================
# $GHOrg = "First-Devops-organisation"
# $GHRepo = "dummy-secretymigr"
# $EnvName = "qa"
# $BranchName = "release"
# $ReviewerUsernames = @("varsha-patilyash")

# Write-Host "Setting up '$EnvName' environment..." -ForegroundColor Cyan

# # Fetch User IDs
# $reviewerObjects = @()
# foreach ($username in $ReviewerUsernames) {
#     Write-Host "Looking up User ID for $username..."
#     $userId = (gh api users/$username --jq '.id' 2>$null)
#     if ($userId) {
#         Write-Host "  -> Found ID: $userId" -ForegroundColor DarkGray
#         $reviewerObjects += @{ type = "User"; id = [int]$userId }
#     } else {
#         Write-Host "  -> Error: Could not find user '$username'" -ForegroundColor Red
#     }
# }

# if ($reviewerObjects.Count -eq 0) {
#     Write-Host "No valid reviewers found. Exiting." -ForegroundColor Red
#     exit
# }

# # Build Configuration
# $envConfig = @{
#     wait_timer = 5 
#     reviewers = $reviewerObjects
#     deployment_branch_policy = @{
#         protected_branches = $false
#         custom_branch_policies = $true
#     }
# } | ConvertTo-Json -Depth 5 -Compress

# # Create Environment
# Write-Host "Applying settings to environment..."
# $envConfig | gh api -X PUT "repos/$GHOrg/$GHRepo/environments/$EnvName" `
#     --header "Accept: application/vnd.github+json" --input -

# # Add Branch Rule
# $branchConfig = @{ name = $BranchName } | ConvertTo-Json -Compress
# $branchConfig | gh api -X POST "repos/$GHOrg/$GHRepo/environments/$EnvName/deployment-branch-policies" `
#     --header "Accept: application/vnd.github+json" --input -

# Write-Host "QA Setup Complete!" -ForegroundColor Cyan


# ==========================================
# Setup GitHub Environment with Multiple Reviewers (Parameterised)
# ==========================================
[CmdletBinding()]
param (
    [Parameter(Mandatory=$true, HelpMessage="The GitHub Organization name")]
    [string]$GHOrg,

    [Parameter(Mandatory=$true, HelpMessage="The Repository name")]
    [string]$GHRepo,

    [Parameter(Mandatory=$true, HelpMessage="The Environment name (e.g., dev, qa, production)")]
    [string]$EnvName,

    [Parameter(Mandatory=$true, HelpMessage="The branch allowed to deploy to this environment")]
    [string]$BranchName,

    [Parameter(Mandatory=$false, HelpMessage="Array of GitHub usernames to act as reviewers")]
    [string[]]$ReviewerUsernames = @(),

    [Parameter(Mandatory=$false, HelpMessage="Wait timer in minutes before deployment begins")]
    [int]$WaitTimer = 0,

    [Parameter(Mandatory=$false, HelpMessage="Prevent the deployer from approving their own deployment")]
    [switch]$PreventSelfReview
)

Write-Host "Setting up '$EnvName' environment..." -ForegroundColor Cyan

# 1. Fetch User IDs for ALL reviewers
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

# 2. Build the Configuration
$envConfig = @{
    wait_timer = $WaitTimer
    prevent_self_review = $PreventSelfReview.IsPresent
    deployment_branch_policy = @{
        protected_branches = $false
        custom_branch_policies = $true
    }
}

# Only add reviewers if any were provided and found
if ($reviewerObjects.Count -gt 0) {
    $envConfig.Add("reviewers", $reviewerObjects)
}

$envConfigJson = $envConfig | ConvertTo-Json -Depth 5 -Compress

# 3. CREATE the Environment
Write-Host "Applying settings to environment..."
$envConfigJson | gh api -X PUT "repos/$GHOrg/$GHRepo/environments/$EnvName" `
    --header "Accept: application/vnd.github+json" `
    --input -

Write-Host "Environment '$EnvName' created." -ForegroundColor Green

# 4. Add Branch Rule
$branchConfig = @{ name = $BranchName } | ConvertTo-Json -Compress

$branchConfig | gh api -X POST "repos/$GHOrg/$GHRepo/environments/$EnvName/deployment-branch-policies" `
    --header "Accept: application/vnd.github+json" `
    --input -

Write-Host "Rule added: Only the '$BranchName' branch can deploy." -ForegroundColor Green
Write-Host "Setup Complete!" -ForegroundColor Cyan
