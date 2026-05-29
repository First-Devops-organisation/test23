param (
    [Parameter(Mandatory=$true)][string]$Organization,
    [Parameter(Mandatory=$true)][string]$Project,
    [Parameter(Mandatory=$true)][string]$AdoPat,
    [Parameter(Mandatory=$true)][string]$GhPat,
    [Parameter(Mandatory=$true)][string]$ConfigPath
)

$ErrorActionPreference = "Continue"
$Organization = $Organization.Replace("https://dev.azure.com/", "")

Write-Host "Authenticating with GitHub CLI..."
echo "$GhPat" | gh auth login --with-token

# Helper: Upsert a GitHub variable
function Set-GitHubVariable {
    param(
        [string]$Scope,
        [string]$Org,
        [string]$Repo,
        [string]$Env,
        [string]$Name,
        [string]$Value
    )
    $result = ""
    if ($Scope -eq "organization") {
        $result = gh api -X POST "/orgs/$Org/actions/variables" -f name="$Name" -f value="$Value" -f visibility="private" 2>&1
        if ($result -match "409|Already exists") {
            $result = gh api -X PATCH "/orgs/$Org/actions/variables/$Name" -f value="$Value" -f visibility="private" 2>&1
        }
    } elseif ($Scope -eq "environment") {
        $result = gh variable set "$Name" --body "$Value" --repo "$Org/$Repo" --env "$Env" 2>&1
        if ($result -match "409|Already exists") {
            $repoId = (gh api "/repos/$Org/$Repo" --jq '.id' 2>&1)
            $result = gh api -X PATCH "/repositories/$repoId/environments/$Env/variables/$Name" -f value="$Value" 2>&1
        }
    } else {
        $result = gh variable set "$Name" --body "$Value" --repo "$Org/$Repo" 2>&1
        if ($result -match "409|Already exists") {
            $result = gh api -X PATCH "/repos/$Org/$Repo/actions/variables/$Name" -f value="$Value" 2>&1
        }
    }
    return $result
}

$config = Get-Content $ConfigPath | ConvertFrom-Json
$ghOrg = $config.targetGitHubOrg

$base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat"))
$headers = @{Authorization=("Basic {0}" -f $base64AuthInfo)}
$varGroupsUrl = "https://dev.azure.com/$Organization/$Project/_apis/distributedtask/variablegroups?api-version=7.1-preview.2"
$response = Invoke-RestMethod -Uri $varGroupsUrl -Method Get -Headers $headers
$allAdoGroups = $response.value

$summaryReport = @()
$migratedVariableTracker = @{} 
$secretsByGroup = @{}

foreach ($mapping in $config.variableGroups) {
    if ($mapping.action -ne "migrate") { continue }

    $adoGroup = $allAdoGroups | Where-Object { $_.name -eq $mapping.adoGroupName }
    if (-not $adoGroup) { continue }
    
    # Check if this group is linked to Azure Key Vault
    $isKeyVault = ($adoGroup.type -eq "AzureKeyVault")

    $targetScope = $mapping.targetScope
    $targetRepos = @($mapping.targetRepo -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
    $targetEnv = $mapping.targetEnvironment

    if ($targetRepos.Count -eq 0 -and $targetScope -ne "organization") { $targetScope = "organization" }
    if ($targetScope -eq "organization") { $targetRepos = @("ORG_LEVEL") }

    foreach ($targetRepo in $targetRepos) {
        $scopeKey = if ($targetScope -eq "organization") { "org" } elseif ($targetScope -eq "environment") { "env:{0}:{1}" -f $targetRepo, $targetEnv } else { "repo:{0}" -f $targetRepo }
        if (-not $migratedVariableTracker.ContainsKey($scopeKey)) { $migratedVariableTracker[$scopeKey] = @() }

        foreach ($varNameRaw in $adoGroup.variables.PSObject.Properties.Name) {
            $varObj = $adoGroup.variables.$varNameRaw
            $varName = $varNameRaw

            if ($varName -match "(?i)^GITHUB_(.*)") { $varName = "GIT_$($matches[1])" }
            if ($migratedVariableTracker[$scopeKey] -contains $varName) {
                $safeGroupName = $mapping.adoGroupName -replace "[^a-zA-Z0-9]","_"
                $varName = "${safeGroupName}_${varName}"
            }
            $migratedVariableTracker[$scopeKey] += $varName

            # FULL KEY VAULT SUPPORT: Pass Key Vault variables into Phase 3
            if ($varObj.isSecret -eq $true -or $isKeyVault -eq $true) {
                if (-not $secretsByGroup.ContainsKey($mapping.adoGroupName)) {
                    $secretsByGroup[$mapping.adoGroupName] = @()
                }
                $secretsByGroup[$mapping.adoGroupName] += @{
                    OriginalName = $varNameRaw
                    MigratedName = $varName
                    TargetScope  = $targetScope
                    TargetRepo   = if ($targetScope -eq "organization") { "" } else { $targetRepo }
                    TargetEnv    = $targetEnv
                }
                
                $summaryReport += [PSCustomObject]@{
                    AdoGroup = $mapping.adoGroupName
                    Variable = $varName
                    Type = if ($isKeyVault) { "Key Vault Secret" } else { "Secret" }
                    Scope = $targetScope
                    Destination = if($targetScope -eq "organization"){"Org"}elseif($targetScope -eq "environment"){"{0} ({1})" -f $targetRepo, $targetEnv}else{$targetRepo}
                    Status = "Queued for Phase 3"
                }
                continue
            }

            if ([string]::IsNullOrWhiteSpace($varObj.value)) { continue }
            
            # Normal plain text variables get migrated immediately
            $status = "Failed"
            try {
                $result = Set-GitHubVariable -Scope $targetScope -Org $ghOrg -Repo $targetRepo -Env $targetEnv -Name $varName -Value $varObj.value
                if ($result -match "404|Not Found|error|failed") {
                    $status = "Error: $result"
                } else {
                    $status = "Success"
                }
            } catch {
                $status = "Error: $_"
            }

            $summaryReport += [PSCustomObject]@{
                AdoGroup = $mapping.adoGroupName
                Variable = $varName
                Type = "Variable"
                Scope = $targetScope
                Destination = if($targetScope -eq "organization"){"Org"}elseif($targetScope -eq "environment"){"{0} ({1})" -f $targetRepo, $targetEnv}else{$targetRepo}
                Status = $status
            }
        }
    }
}

# -------------------------------------------------------------
# DYNAMIC PHASE 3 YAML GENERATION FOR SECRETS & KEY VAULT
# -------------------------------------------------------------
if ($secretsByGroup.Keys.Count -gt 0) {
    Write-Host "Generating Phase 3 Pipeline for Secrets & Key Vaults..."
    $yamlPath = Join-Path $PSScriptRoot "phase3-secrets-migration.yml"
    
    $yamlContent = @"
trigger: none
pool:
  vmImage: ubuntu-latest
variables:
- group: repo-migration-discove
- group: repo-migration-migrate
jobs:
"@

    foreach ($groupName in $secretsByGroup.Keys) {
        $safeJobName = $groupName -replace "[^a-zA-Z0-9]","_"
        $yamlContent += "`n  - job: Migrate_Secrets_$safeJobName`n"
        $yamlContent += "    variables:`n"
        $yamlContent += "    - group: repo-migration-discove`n"
        $yamlContent += "    - group: repo-migration-migrate`n"
        $yamlContent += "    - group: '$groupName'`n"
        $yamlContent += "    steps:`n"
        $yamlContent += "    - task: PowerShell@2`n"
        $yamlContent += "      displayName: 'Migrate Secrets for $groupName'`n"
        $yamlContent += "      inputs:`n"
        $yamlContent += "        targetType: 'inline'`n"
        $yamlContent += "        pwsh: true`n"
        $yamlContent += "        script: |`n"
        $yamlContent += "          `$ghPatMacro = `"`$`" + `"(GH_PAT)`"`n"
        $yamlContent += "          `$gitPatMacro = `"`$`" + `"(Git_pat)`"`n"
        $yamlContent += "          `$token = `$env:MY_GH_PAT`n"
        $yamlContent += "          if (`$token -eq `$ghPatMacro -or [string]::IsNullOrWhiteSpace(`$token)) {`n"
        $yamlContent += "              `$token = `$env:MY_GIT_PAT`n"
        $yamlContent += "          }`n"
        $yamlContent += "          if (`$token -eq `$gitPatMacro -or [string]::IsNullOrWhiteSpace(`$token)) {`n"
        $yamlContent += "              Write-Host `"##[error] Azure DevOps failed to inject GH_PAT or Git_pat!`"`n"
        $yamlContent += "              exit 1`n"
        $yamlContent += "          }`n"
        $yamlContent += "          `$env:GH_TOKEN = `$token.Trim()`n`n"

        $envMappings = "      env:`n"
        $envMappings += "        MY_GH_PAT: `$(GH_PAT)`n"
        $envMappings += "        MY_GIT_PAT: `$(Git_pat)`n"

        foreach ($secret in $secretsByGroup[$groupName]) {
            $origName    = $secret['OriginalName']
            $migratedName = $secret['MigratedName']
            $secScope    = $secret['TargetScope']
            $secRepo     = $secret['TargetRepo']
            $secEnv      = $secret['TargetEnv']
            
            # Map the exact secret dynamically
            $safeEnvVar = "MY_SEC_" + ($origName -replace "[^a-zA-Z0-9]","_").ToUpper()
            $envMappings += "        ${safeEnvVar}: `$($origName)`n"
            
            $cmd = ""
            if ($secScope -eq "organization") {
                $cmd = "gh secret set `"$migratedName`" --body `"`$env:$safeEnvVar`" --org `"$ghOrg`" --visibility private"
            } elseif ($secScope -eq "repository") {
                $cmd = "gh secret set `"$migratedName`" --body `"`$env:$safeEnvVar`" --repo `"$ghOrg/$secRepo`""
            } elseif ($secScope -eq "environment") {
                $cmd = "gh secret set `"$migratedName`" --body `"`$env:$safeEnvVar`" --repo `"$ghOrg/$secRepo`" --env `"$secEnv`""
            }
            $yamlContent += "          $cmd`n"
        }
        $yamlContent += $envMappings
    }
    Set-Content -Path $yamlPath -Value $yamlContent
} else {
    Write-Host "No secrets found to migrate. Generating placeholder Phase 3 YAML."
    $yamlPath = Join-Path $PSScriptRoot "phase3-secrets-migration.yml"
    Set-Content -Path $yamlPath -Value "# No secrets were found in the variable groups marked for migration. Phase 3 is not required."
}

# -------------------------------------------------------------
# Generate Summary Dashboard & CSV
# -------------------------------------------------------------
$csvPath = Join-Path $PSScriptRoot "Migration-Summary.csv"
$summaryReport | Export-Csv -Path $csvPath -NoTypeInformation

$mdPath = Join-Path $PSScriptRoot "Migration-Dashboard.md"
$mdContent = "# Enterprise Migration Summary Dashboard`n`n"
$mdContent += "| ADO Group | Variable | Type | Target Scope | Destination | Status |`n"
$mdContent += "|---|---|---|---|---|---|`n"
foreach ($row in $summaryReport) {
    $mdContent += "| $($row.AdoGroup) | $($row.Variable) | $($row.Type) | $($row.Scope) | $($row.Destination) | $($row.Status) |`n"
}
Set-Content -Path $mdPath -Value $mdContent

Write-Host "Dashboard generated at: $mdPath"
Write-Host "======================================================"
Write-Host "Phase 2 Migration Complete!" -ForegroundColor Green
Write-Host "======================================================"
exit 0