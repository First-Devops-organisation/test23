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
# Setup QA Environment (Fixed for ADO Pipeline)
# ==========================================
[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)][string]$GHOrg,
    [Parameter(Mandatory=$true)][string]$GHRepo,
    [Parameter(Mandatory=$true)][string]$EnvName,
    [Parameter(Mandatory=$true)][string]$BranchName,
    [Parameter(Mandatory=$false)][string[]]$ReviewerUsernames = @(),
    [Parameter(Mandatory=$false)][int]$WaitTimer = 0
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
    deployment_branch_policy = @{
        protected_branches = $false
        custom_branch_policies = $true
    }
}

if ($reviewerObjects.Count -gt 0) {
    $envConfig.Add("reviewers", $reviewerObjects)
}

# 3. Write JSON to a temp file (avoids piping issues on ADO agents)
$envJsonFile = Join-Path $env:TEMP "env-config.json"
$envConfig | ConvertTo-Json -Depth 5 | Out-File -FilePath $envJsonFile -Encoding utf8

Write-Host "Applying settings to environment..."
gh api -X PUT "repos/$GHOrg/$GHRepo/environments/$EnvName" `
    --header "Accept: application/vnd.github+json" `
    --input $envJsonFile

Write-Host "Environment '$EnvName' created." -ForegroundColor Green

# 4. Add Branch Rule
$branchJsonFile = Join-Path $env:TEMP "branch-config.json"
@{ name = $BranchName } | ConvertTo-Json | Out-File -FilePath $branchJsonFile -Encoding utf8

Write-Host "Locking to branch: $BranchName..."
gh api -X POST "repos/$GHOrg/$GHRepo/environments/$EnvName/deployment-branch-policies" `
    --header "Accept: application/vnd.github+json" `
    --input $branchJsonFile

Write-Host "Rule added: Only the '$BranchName' branch can deploy." -ForegroundColor Green

# 5. Cleanup temp files
Remove-Item $envJsonFile -ErrorAction SilentlyContinue
Remove-Item $branchJsonFile -ErrorAction SilentlyContinue

Write-Host "Setup Complete!" -ForegroundColor Cyan
