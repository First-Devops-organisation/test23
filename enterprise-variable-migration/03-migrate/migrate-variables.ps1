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
    if ($adoGroup.type -eq "AzureKeyVault") { continue }

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

            if ($varObj.isSecret -eq $true) {
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
                continue
            }

            if ([string]::IsNullOrWhiteSpace($varObj.value)) { continue }
            Set-GitHubVariable -Scope $targetScope -Org $ghOrg -Repo $targetRepo -Env $targetEnv -Name $varName -Value $varObj.value
        }
    }
}

# -------------------------------------------------------------
# DYNAMIC PHASE 3 YAML GENERATION FOR SECRETS
# -------------------------------------------------------------
if ($secretsByGroup.Keys.Count -gt 0) {
    Write-Host "Generating Phase 3 Pipeline for Secrets..."
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
            $envMappings += "        ${safeEnvVar}: `$$($origName)`n"
            
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
    Set-Content -Path (Join-Path $PSScriptRoot "phase3-secrets-migration.yml") -Value "# No secrets found."
}
exit 0