# ==========================================
# Setup Development Environment
# ==========================================
[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)][string]$GHOrg,
    [Parameter(Mandatory=$true)][string]$GHRepo,
    [Parameter(Mandatory=$false)][string]$EnvName = "development",
    [Parameter(Mandatory=$false)][string]$BranchName = "develop",
    [Parameter(Mandatory=$false)][string[]]$ReviewerUsernames = @(),
    [Parameter(Mandatory=$false)][int]$WaitTimer = 0
)

Write-Host "Setting up '$EnvName' environment..." -ForegroundColor Cyan

# 1. Fetch User IDs for reviewers (if any)
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

# 3. Write JSON WITHOUT BOM (this fixes the 400 error)
$envJson = $envConfig | ConvertTo-Json -Depth 5
$envJsonFile = Join-Path $env:TEMP "env-config-dev.json"
[System.IO.File]::WriteAllText($envJsonFile, $envJson)

Write-Host "JSON payload:"
Write-Host $envJson

Write-Host "Applying settings to environment..."
gh api -X PUT "repos/$GHOrg/$GHRepo/environments/$EnvName" `
    --header "Accept: application/vnd.github+json" `
    --input $envJsonFile

Write-Host "Environment '$EnvName' created." -ForegroundColor Green

# 4. Remove existing branch policies to avoid duplicates on re-run
Write-Host "Cleaning existing branch policies..." -ForegroundColor Yellow
$existing = gh api "repos/$GHOrg/$GHRepo/environments/$EnvName/deployment-branch-policies" --jq '.branch_policies[].id' 2>$null
foreach ($policyId in $existing) {
    gh api -X DELETE "repos/$GHOrg/$GHRepo/environments/$EnvName/deployment-branch-policies/$policyId" `
        --header "Accept: application/vnd.github+json"
    Write-Host "  -> Deleted old policy $policyId" -ForegroundColor DarkGray
}

# 5. Add Branch Rule
$branchJson = @{ name = $BranchName } | ConvertTo-Json
$branchJsonFile = Join-Path $env:TEMP "branch-config-dev.json"
[System.IO.File]::WriteAllText($branchJsonFile, $branchJson)

Write-Host "Locking to branch: $BranchName..."
gh api -X POST "repos/$GHOrg/$GHRepo/environments/$EnvName/deployment-branch-policies" `
    --header "Accept: application/vnd.github+json" `
    --input $branchJsonFile

Write-Host "Rule added: Only the '$BranchName' branch can deploy." -ForegroundColor Green

# 6. Cleanup
Remove-Item $envJsonFile -ErrorAction SilentlyContinue
Remove-Item $branchJsonFile -ErrorAction SilentlyContinue

Write-Host "Development Setup Complete!" -ForegroundColor Cyan
