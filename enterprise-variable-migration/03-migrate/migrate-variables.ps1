param (
    [Parameter(Mandatory=$true)][string]$Organization,
    [Parameter(Mandatory=$true)][string]$Project,
    [Parameter(Mandatory=$true)][string]$AdoPat,
    [Parameter(Mandatory=$true)][string]$GhPat,
    [Parameter(Mandatory=$true)][string]$ConfigPath
)

$ErrorActionPreference = "Stop"

Write-Host "Authenticating with GitHub CLI..."
echo "$GhPat" | gh auth login --with-token

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

    $targetScope = $mapping.targetScope
    $targetRepos = @($mapping.targetRepo -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
    $targetEnv = $mapping.targetEnvironment

    # REQUIREMENT 2: If action is migrate but no repo, fallback to Organization
    if ($targetRepos.Count -eq 0 -and $targetScope -ne "organization") {
        $targetScope = "organization"
    }
    
    if ($targetScope -eq "organization") {
        $targetRepos = @("ORG_LEVEL")
    }

    # REQUIREMENT 3: Loop through comma-separated multiple repos
    foreach ($targetRepo in $targetRepos) {
        $scopeKey = if ($targetScope -eq "organization") { "org" } elseif ($targetScope -eq "environment") { "env:$targetRepo:$targetEnv" } else { "repo:$targetRepo" }
        if (-not $migratedVariableTracker.ContainsKey($scopeKey)) { $migratedVariableTracker[$scopeKey] = @() }

        foreach ($varNameRaw in $adoGroup.variables.PSObject.Properties.Name) {
            $varObj = $adoGroup.variables.$varNameRaw
            $varName = $varNameRaw

            # REQUIREMENT 5 (Reserved Names): Rename GITHUB_
            if ($varName -match "(?i)^GITHUB_(.*)") {
                $varName = "GIT_$($matches[1])"
            }

            # REQUIREMENT 4 (Name Collisions): Prefix if variable already exists in this scope
            if ($migratedVariableTracker[$scopeKey] -contains $varName) {
                $safeGroupName = $mapping.adoGroupName -replace "[^a-zA-Z0-9]","_"
                $varName = "${safeGroupName}_${varName}"
            }
            $migratedVariableTracker[$scopeKey] += $varName

            # REQUIREMENT 5 (Secrets): Store for Phase 3 dynamic pipeline
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

                $summaryReport += [PSCustomObject]@{
                    AdoGroup = $mapping.adoGroupName
                    Variable = $varName
                    Type = "Secret"
                    Scope = $targetScope
                    Destination = if($targetScope -eq "organization"){"Org"}elseif($targetScope -eq "environment"){"$targetRepo ($targetEnv)"}else{$targetRepo}
                    Status = "Queued for Phase 3"
                }
                continue
            }

            if ([string]::IsNullOrWhiteSpace($varObj.value)) { continue }

            $varValue = $varObj.value
            $status = "Failed"

            try {
                if ($targetScope -eq "organization") {
                    gh api -X POST "/orgs/$ghOrg/actions/variables" -f name="$varName" -f value="$varValue" -f visibility="private" --silent
                    $status = "Success"
                } elseif ($targetScope -eq "repository") {
                    gh variable set "$varName" --body "$varValue" --repo "$ghOrg/$targetRepo"
                    $status = "Success"
                } elseif ($targetScope -eq "environment") {
                    gh variable set "$varName" --body "$varValue" --repo "$ghOrg/$targetRepo" --env "$targetEnv"
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
                Destination = if($targetScope -eq "organization"){"Org"}elseif($targetScope -eq "environment"){"$targetRepo ($targetEnv)"}else{$targetRepo}
                Status = $status
            }
        }
    }
}

# Phase 3 YAML Generation for Secrets
if ($secretsByGroup.Keys.Count -gt 0) {
    Write-Host "Generating Phase 3 Pipeline for Secrets..."
    $yamlPath = Join-Path $PSScriptRoot "phase3-secrets-migration.yml"
    
    $yamlContent = @"
trigger: none
pool:
  vmImage: ubuntu-latest
variables:
- group: DevOpsConfig
jobs:
"@

    foreach ($groupName in $secretsByGroup.Keys) {
        $safeJobName = $groupName -replace "[^a-zA-Z0-9]","_"
        $yamlContent += "`n- job: Migrate_Secrets_$safeJobName`n"
        $yamlContent += "  variables:`n"
        $yamlContent += "  - group: DevOpsConfig`n"
        $yamlContent += "  - group: '$groupName'`n"
        $yamlContent += "  steps:`n"
        $yamlContent += "  - task: PowerShell@2`n"
        $yamlContent += "    displayName: 'Migrate Secrets for $groupName'`n"
        $yamlContent += "    inputs:`n"
        $yamlContent += "      targetType: 'inline'`n"
        $yamlContent += "      script: |`n"
        $yamlContent += "        echo `"`$(Git_pat)`" | gh auth login --with-token`n"

        foreach ($secret in $secretsByGroup[$groupName]) {
            $cmd = ""
            $val = "`$(`$($secret.OriginalName))"
            if ($secret.TargetScope -eq "organization") {
                $cmd = "gh secret set `"$($secret.MigratedName)`" --body `"$val`" --org `"$ghOrg`" --visibility private"
            } elseif ($secret.TargetScope -eq "repository") {
                $cmd = "gh secret set `"$($secret.MigratedName)`" --body `"$val`" --repo `"$ghOrg/$($secret.TargetRepo)`""
            } elseif ($secret.TargetScope -eq "environment") {
                $cmd = "gh secret set `"$($secret.MigratedName)`" --body `"$val`" --repo `"$ghOrg/$($secret.TargetRepo)`" --env `"$($secret.TargetEnv)`""
            }
            $yamlContent += "        $cmd`n"
        }
    }
    
    Set-Content -Path $yamlPath -Value $yamlContent
    Write-Host "Generated phase3-secrets-migration.yml"
}

# Generate Summary Dashboard
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
