param (
    [Parameter(Mandatory=$true)][string]$Organization,
    [Parameter(Mandatory=$true)][string]$Project,
    [Parameter(Mandatory=$true)][string]$AdoPat,
    [Parameter(Mandatory=$true)][string]$GhPat,
    [Parameter(Mandatory=$true)][string]$ConfigPath
)

$ErrorActionPreference = "Stop"

# 1. Login to GitHub
Write-Host "Authenticating with GitHub CLI..."
echo "$GhPat" | gh auth login --with-token

# 2. Read JSON Configuration
Write-Host "Loading configuration from $ConfigPath..."
if (-not (Test-Path $ConfigPath)) {
    Write-Host "ERROR: Configuration file not found!" -ForegroundColor Red
    exit 1
}
$config = Get-Content $ConfigPath | ConvertFrom-Json
$ghOrg = $config.targetGitHubOrg

# 3. Fetch all ADO Variable Groups
Write-Host "Fetching all Variable Groups from ADO..."
$base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat"))
$headers = @{Authorization=("Basic {0}" -f $base64AuthInfo)}
$varGroupsUrl = "https://dev.azure.com/$Organization/$Project/_apis/distributedtask/variablegroups?api-version=7.1-preview.2"
$response = Invoke-RestMethod -Uri $varGroupsUrl -Method Get -Headers $headers
$allAdoGroups = $response.value

# 4. Process each mapping rule
foreach ($mapping in $config.variableGroups) {
    Write-Host "`n---------------------------------------------------"
    Write-Host "Processing Group: $($mapping.adoGroupName)"

    if ($mapping.action -ne "migrate") {
        Write-Host "Action is set to '$($mapping.action)'. Skipping." -ForegroundColor Yellow
        continue
    }

    $adoGroup = $allAdoGroups | Where-Object { $_.name -eq $mapping.adoGroupName }
    if (-not $adoGroup) {
        Write-Host "WARNING: Group $($mapping.adoGroupName) not found in ADO!" -ForegroundColor Red
        continue
    }

    $targetRepo = $mapping.targetRepo
    $targetEnv = $mapping.targetEnvironment

    # Loop through variables in the group
    foreach ($varName in $adoGroup.variables.PSObject.Properties.Name) {
        $varObj = $adoGroup.variables.$varName

        # Skip Secrets
        if ($varObj.isSecret -eq $true) {
            Write-Host "Skipping SECRET: $varName (Cannot read via API)" -ForegroundColor DarkGray
            continue
        }

        # Skip Empty
        if ([string]::IsNullOrWhiteSpace($varObj.value)) {
            Write-Host "Skipping empty variable: $varName" -ForegroundColor DarkGray
            continue
        }

        $varValue = $varObj.value
        Write-Host "Migrating variable: $varName -> Target Scope: $($mapping.targetScope)"

        # Handle different scopes
        try {
            if ($mapping.targetScope -eq "organization") {
                # Org-level variable
                gh api -X POST "/orgs/$ghOrg/actions/variables" -f name="$varName" -f value="$varValue" --silent
                Write-Host "  [OK] Set Org Variable: $varName" -ForegroundColor Green

            } elseif ($mapping.targetScope -eq "repository") {
                # Repo-level variable
                gh variable set "$varName" --body "$varValue" --repo "$ghOrg/$targetRepo"
                Write-Host "  [OK] Set Repo Variable: $varName in $targetRepo" -ForegroundColor Green

            } elseif ($mapping.targetScope -eq "environment") {
                # Environment-level variable
                gh variable set "$varName" --body "$varValue" --repo "$ghOrg/$targetRepo" --env "$targetEnv"
                Write-Host "  [OK] Set Env Variable: $varName in $targetRepo ($targetEnv)" -ForegroundColor Green

            } else {
                Write-Host "  [!] Unknown target scope: $($mapping.targetScope)" -ForegroundColor Red
            }
        } catch {
            Write-Host "  [ERROR] Failed to set $varName" -ForegroundColor Red
        }
    }
}

Write-Host "`n======================================================"
Write-Host "Migration Run Complete!"
Write-Host "======================================================"
