[CmdletBinding()]
param (
    [Parameter(Mandatory=$true, HelpMessage="The GitHub Organization name")]
    [string]$Org,

    [Parameter(Mandatory=$true, HelpMessage="The Repository name")]
    [string]$Repo,

    [Parameter(Mandatory=$true, HelpMessage="The name of the Environment (e.g., dev, qa, production)")]
    [string]$EnvName,

    [Parameter(Mandatory=$true, HelpMessage="The branch allowed to deploy to this environment")]
    [string]$BranchName,

    [Parameter(Mandatory=$false, HelpMessage="Array of GitHub usernames to act as reviewers")]
    [string[]]$Reviewers = @(),

    [Parameter(Mandatory=$false, HelpMessage="Wait timer in minutes before deployment begins")]
    [int]$WaitTimer = 0,

    [Parameter(Mandatory=$false, HelpMessage="Switch to prevent the user who triggered the deployment from approving it")]
    [switch]$PreventSelfReview
)

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Setting up '$EnvName' in $Org/$Repo" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# 1. Fetch User IDs for reviewers (if any were provided)
$reviewerObjects = @()
if ($Reviewers.Count -gt 0) {
    foreach ($username in $Reviewers) {
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
        Write-Host "Failed to resolve any provided reviewers. Exiting." -ForegroundColor Red
        exit
    }
}

# 2. Build the Configuration Payload
$envConfig = @{
    wait_timer = $WaitTimer
    prevent_self_review = $PreventSelfReview.IsPresent
    deployment_branch_policy = @{
        protected_branches = $false
        custom_branch_policies = $true
    }
}

# Only add the 'reviewers' array if we actually have reviewers
if ($reviewerObjects.Count -gt 0) {
    $envConfig.Add("reviewers", $reviewerObjects)
}

$envConfigJson = $envConfig | ConvertTo-Json -Depth 5 -Compress

# 3. Create the Environment
Write-Host "Applying settings to environment..."
$envConfigJson | gh api -X PUT "repos/$Org/$Repo/environments/$EnvName" `
    --header "Accept: application/vnd.github+json" --input - | Out-Null

# 4. Add the Branch Rule
$branchConfig = @{ name = $BranchName } | ConvertTo-Json -Compress
Write-Host "Locking to branch: $BranchName..."
$branchConfig | gh api -X POST "repos/$Org/$Repo/environments/$EnvName/deployment-branch-policies" `
    --header "Accept: application/vnd.github+json" --input - | Out-Null

Write-Host "[SUCCESS] Environment '$EnvName' is fully configured!" -ForegroundColor Green
