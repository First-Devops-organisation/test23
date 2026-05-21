<#
.SYNOPSIS
  Phase 4 — Migrate Azure Key Vault Connections from ADO to GitHub Actions.

.DESCRIPTION
  This script:
    1. Discovers all Key Vault-linked variable groups in ADO.
    2. Reads the linked Service Connection to extract:
         - Key Vault name
         - Service Principal (App) ID
         - Tenant ID
         - Subscription ID
    3. Sets the non-sensitive IDs as GitHub Variables on the target repo.
    4. Generates the OIDC federated credential setup commands (Azure CLI).
    5. Generates reusable GitHub Actions workflow snippets for each KV group.
    6. Publishes a KV Connection Migration Report.

.NOTES
  IMPORTANT: This script does NOT migrate the Service Principal's client secret.
  It uses OIDC (passwordless) — far more secure than storing credentials.
  The Service Principal itself is reused — only a new Federated Credential is added.
#>

param (
    [Parameter(Mandatory=$true)][string]$Organization,
    [Parameter(Mandatory=$true)][string]$Project,
    [Parameter(Mandatory=$true)][string]$AdoPat,
    [Parameter(Mandatory=$true)][string]$GhPat,
    [Parameter(Mandatory=$true)][string]$GhOrg,
    [Parameter(Mandatory=$true)][string]$ConfigPath
)

$ErrorActionPreference = "Continue"
$OutputDir = $PSScriptRoot

# ─── Auth ────────────────────────────────────────────────────────────────────
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host " Phase 4: Migrate Key Vault Connections to GitHub"      -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan

$base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat"))
$headers    = @{ Authorization = "Basic $base64Auth"; "Content-Type" = "application/json" }

Write-Host "`n[1/5] Authenticating with GitHub CLI..."
echo "$GhPat" | gh auth login --with-token

# ─── Step 1: Load config to know which groups to process ─────────────────────
Write-Host "`n[2/5] Loading variable-mappings.json config..."
$config = Get-Content $ConfigPath | ConvertFrom-Json
$groupsToMigrate = $config.variableGroups | Where-Object { $_.action -eq "migrate" }

# ─── Step 2: Fetch all variable groups from ADO ───────────────────────────────
Write-Host "`n[3/5] Fetching all ADO variable groups..."
$vgUrl      = "https://dev.azure.com/$Organization/$Project/_apis/distributedtask/variablegroups?api-version=7.1-preview.2"
$vgResponse = Invoke-RestMethod -Uri $vgUrl -Method Get -Headers $headers
$allGroups  = $vgResponse.value

# Filter to only Key Vault-linked groups
$kvGroups = $allGroups | Where-Object { $_.type -eq "AzureKeyVault" }

Write-Host "  Found $($kvGroups.Count) Key Vault-linked variable group(s)." -ForegroundColor Yellow

if ($kvGroups.Count -eq 0) {
    Write-Host "  No Key Vault-linked groups found. Nothing to migrate." -ForegroundColor Green
    exit 0
}

# ─── Step 3: Fetch all Service Connections ────────────────────────────────────
Write-Host "`n[4/5] Fetching ADO Service Connections..."
$scUrl      = "https://dev.azure.com/$Organization/$Project/_apis/serviceendpoint/endpoints?api-version=7.1"
$scResponse = Invoke-RestMethod -Uri $scUrl -Method Get -Headers $headers
$allSCs     = $scResponse.value

# Build a lookup map: endpointId → service connection details
$scMap = @{}
foreach ($sc in $allSCs) {
    $scMap[$sc.id] = $sc
}

# ─── Step 4: Process each KV-linked group ────────────────────────────────────
Write-Host "`n[5/5] Processing Key Vault-linked groups..."

$report          = @()
$workflowSnippets = @{}

foreach ($kvGroup in $kvGroups) {
    $groupName = $kvGroup.name

    # Only process groups that are in the "migrate" config
    $mappingEntry = $groupsToMigrate | Where-Object { $_.adoGroupName -eq $groupName }
    if (-not $mappingEntry) {
        Write-Host "  SKIP: $groupName (not in migrate config)" -ForegroundColor DarkGray
        continue
    }

    Write-Host "`n  Processing: $groupName" -ForegroundColor Cyan

    # Extract Key Vault details from the variable group
    $kvName        = $kvGroup.providerData.vault
    $scEndpointId  = $kvGroup.providerData.serviceEndpointId

    if ([string]::IsNullOrWhiteSpace($kvName)) {
        Write-Warning "  Cannot determine Key Vault name for group '$groupName'. Skipping."
        $report += [PSCustomObject]@{
            ADOGroup       = $groupName
            KeyVaultName   = "UNKNOWN"
            ServicePrincipalId = "N/A"
            TenantId       = "N/A"
            SubscriptionId = "N/A"
            TargetRepo     = $mappingEntry.targetRepo
            Status         = "Failed — Key Vault name not found"
        }
        continue
    }

    Write-Host "    Key Vault: $kvName"

    # Look up the Service Connection
    $sc            = $scMap[$scEndpointId]
    $spAppId       = $null
    $tenantId      = $null
    $subscriptionId = $null

    if ($sc) {
        $spAppId        = $sc.authorization.parameters.serviceprincipalid
        $tenantId       = $sc.data.creationMode  # fallback
        $tenantId       = if ($sc.authorization.parameters.tenantid) { $sc.authorization.parameters.tenantid } else { $sc.data.azureTenantId }
        $subscriptionId = $sc.data.subscriptionId
        Write-Host "    Service Principal ID : $spAppId"
        Write-Host "    Tenant ID            : $tenantId"
        Write-Host "    Subscription ID      : $subscriptionId"
    } else {
        Write-Warning "    Service Connection not found (ID: $scEndpointId). Skipping GitHub variable setup."
    }

    $targetRepo  = $mappingEntry.targetRepo
    $targetEnv   = $mappingEntry.targetEnvironment
    $targetScope = $mappingEntry.targetScope

    # ── Set GitHub Variables (non-sensitive IDs only) ──────────────────────
    if ($spAppId -and $tenantId -and $subscriptionId -and $targetRepo) {
        Write-Host "    Setting GitHub Variables on $GhOrg/$targetRepo..."

        # Variable names: scoped to be clear which KV they belong to
        $safeVaultName = $kvName -replace '[^a-zA-Z0-9]', '_'

        $vars = @{
            "KV_${safeVaultName}_CLIENT_ID"       = $spAppId
            "KV_${safeVaultName}_TENANT_ID"        = $tenantId
            "KV_${safeVaultName}_SUBSCRIPTION_ID"  = $subscriptionId
            "KV_${safeVaultName}_VAULT_NAME"       = $kvName
        }

        foreach ($v in $vars.GetEnumerator()) {
            $result = gh variable set $v.Key --body $v.Value --repo "$GhOrg/$targetRepo" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "      ✅ Set variable: $($v.Key)" -ForegroundColor Green
            } else {
                Write-Warning "      ❌ Failed to set $($v.Key): $result"
            }
        }
    }

    # ── Generate OIDC Federated Credential Setup Command ───────────────────
    $oidcSubject = if ($targetEnv) {
        "repo:$GhOrg/${targetRepo}:environment:$targetEnv"
    } else {
        "repo:$GhOrg/${targetRepo}:ref:refs/heads/main"
    }

    $oidcCmd = @"
# OIDC Setup for: $groupName → $kvName
az ad app federated-credential create --id "$spAppId" --parameters '{
  "name": "gha-$($targetRepo.ToLower())-$($targetEnv.ToLower())",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "$oidcSubject",
  "audiences": ["api://AzureADTokenExchange"]
}'

# Grant Key Vault Secrets User role:
az role assignment create --role "Key Vault Secrets User" --assignee "$spAppId" --scope "/subscriptions/$subscriptionId/resourceGroups/<RESOURCE_GROUP>/providers/Microsoft.KeyVault/vaults/$kvName"
"@

    # ── Generate GitHub Actions Workflow Snippet ────────────────────────────
    $secretNames   = ($kvGroup.variables.PSObject.Properties.Name) -join ", "
    $safeGroupName = $groupName -replace '[^a-zA-Z0-9]', '_'

    $workflowSnippet = @"
  # ── Key Vault: $kvName (migrated from ADO group: $groupName) ──
  - name: Azure Login ($kvName)
    uses: azure/login@v2
    with:
      client-id: `${{ vars.KV_${safeVaultName}_CLIENT_ID }}
      tenant-id: `${{ vars.KV_${safeVaultName}_TENANT_ID }}
      subscription-id: `${{ vars.KV_${safeVaultName}_SUBSCRIPTION_ID }}

  - name: Get Secrets from $kvName
    uses: azure/get-keyvault-secrets@v1
    with:
      keyvault: `${{ vars.KV_${safeVaultName}_VAULT_NAME }}
      secrets: "$secretNames"
    id: kv_$safeGroupName
"@

    $workflowSnippets[$groupName] = @{
        Snippet = $workflowSnippet
        OidcCmd = $oidcCmd
        KvName  = $kvName
        Repo    = $targetRepo
        Env     = $targetEnv
    }

    $report += [PSCustomObject]@{
        ADOGroup           = $groupName
        KeyVaultName       = $kvName
        ServicePrincipalId = $spAppId
        TenantId           = $tenantId
        SubscriptionId     = $subscriptionId
        TargetRepo         = $targetRepo
        TargetEnvironment  = $targetEnv
        OidcSubject        = $oidcSubject
        Status             = if ($spAppId) { "GitHub Variables Set — OIDC Setup Pending" } else { "Service Connection Not Found" }
    }
}

# ─── Generate OIDC Setup Script ───────────────────────────────────────────────
$oidcScriptPath = Join-Path $OutputDir "setup-keyvault-oidc.sh"
$oidcContent    = "#!/bin/bash`n# Auto-generated OIDC setup script`n# Run this ONCE in Azure Cloud Shell or Azure CLI`n`n"

foreach ($entry in $workflowSnippets.GetEnumerator()) {
    $oidcContent += "# ════════════════════════════════════════`n"
    $oidcContent += "# $($entry.Key)`n"
    $oidcContent += "# ════════════════════════════════════════`n"
    $oidcContent += $entry.Value.OidcCmd + "`n`n"
}

Set-Content -Path $oidcScriptPath -Value $oidcContent
Write-Host "`n✅ OIDC setup script: $oidcScriptPath" -ForegroundColor Green

# ─── Generate GitHub Workflow Template ────────────────────────────────────────
$workflowPath    = Join-Path $OutputDir "keyvault-workflow-template.yml"
$workflowContent = @"
# ══════════════════════════════════════════════════════════════════
# Auto-generated: GitHub Actions Workflow — Key Vault Integration
# Generated by: Phase 4 Key Vault Connection Migration
# Replace <YOUR_JOB_STEPS_HERE> with your actual deployment steps
# ══════════════════════════════════════════════════════════════════

name: Deploy with Key Vault Secrets
on:
  push:
    branches: [main]

permissions:
  id-token: write   # REQUIRED for OIDC authentication
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

"@

foreach ($entry in $workflowSnippets.GetEnumerator()) {
    $workflowContent += $entry.Value.Snippet + "`n"
}

$workflowContent += @"

      # ── Your deployment steps go here ──
      # Reference secrets like: `${{ steps.kv_<group_name>.outputs.SECRET_NAME }}
      - name: <YOUR_JOB_STEPS_HERE>
        env:
          EXAMPLE_SECRET: `${{ steps.kv_<group_name>.outputs.<SECRET_NAME> }}
        run: |
          echo "Deploying..."
"@

Set-Content -Path $workflowPath -Value $workflowContent
Write-Host "✅ Workflow template: $workflowPath" -ForegroundColor Green

# ─── Generate CSV Report ──────────────────────────────────────────────────────
$csvPath = Join-Path $OutputDir "KV-Connection-Migration-Report.csv"
$report  | Export-Csv -Path $csvPath -NoTypeInformation
Write-Host "✅ CSV report: $csvPath" -ForegroundColor Green

# ─── Generate Markdown Report ─────────────────────────────────────────────────
$mdPath = Join-Path $OutputDir "KV-Connection-Migration-Dashboard.md"
$md     = "# Phase 4: Key Vault Connection Migration Dashboard`n`n"
$md    += "| ADO Group | Key Vault | SP App ID | Tenant ID | Subscription | Target Repo | Environment | OIDC Subject | Status |`n"
$md    += "|---|---|---|---|---|---|---|---|---|`n"

foreach ($row in $report) {
    $md += "| $($row.ADOGroup) | $($row.KeyVaultName) | $($row.ServicePrincipalId) | $($row.TenantId) | $($row.SubscriptionId) | $($row.TargetRepo) | $($row.TargetEnvironment) | $($row.OidcSubject) | $($row.Status) |`n"
}

$md += "`n`n## ✅ Next Steps`n"
$md += "1. **Run** \`setup-keyvault-oidc.sh\` in Azure Cloud Shell to register OIDC credentials`n"
$md += "2. **Copy** snippets from \`keyvault-workflow-template.yml\` into your GitHub workflow files`n"
$md += "3. **Verify** GitHub Variables were set: Repo → Settings → Secrets and Variables → Actions → Variables`n"

Set-Content -Path $mdPath -Value $md

Write-Host "`n======================================================"
Write-Host " Phase 4 Complete!" -ForegroundColor Green
Write-Host "======================================================"
Write-Host " Outputs:"
Write-Host "   CSV Report  : $csvPath"
Write-Host "   MD Dashboard: $mdPath"
Write-Host "   OIDC Script : $oidcScriptPath"
Write-Host "   GH Workflow : $workflowPath"
Write-Host "======================================================`n"
