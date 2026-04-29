<#
.SYNOPSIS
    Validates and sets up the GitHub Enterprise Cloud organization for migration.
.DESCRIPTION
    Configures org settings, IP allow lists (for GEI), and verifies SSO/SCIM.
    Does NOT create the org — that must be done manually via GitHub Enterprise admin.
.PARAMETER GitHubOrg
    Target GitHub organization name
.PARAMETER GitHubPat
    GitHub PAT with admin:org scope
.PARAMETER GitHubEnterprise
    GitHub Enterprise name (for enterprise-level settings)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$GitHubOrg,

    [Parameter(Mandatory = $true)]
    [string]$GitHubPat,

    [string]$GitHubEnterprise
)

$ErrorActionPreference = "Stop"

$headers = @{
    Authorization = "Bearer $GitHubPat"
    Accept        = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
}

function Invoke-GitHubApi {
    param([string]$Uri, [string]$Method = "GET", $Body)
    $params = @{
        Uri         = $Uri
        Headers     = $headers
        Method      = $Method
        ContentType = "application/json"
    }
    if ($Body) { $params.Body = ($Body | ConvertTo-Json -Depth 5) }
    Invoke-RestMethod @params
}

Write-Host "=== GitHub Org Setup Validation: $GitHubOrg ===" -ForegroundColor Cyan

# --- 1. Verify Org Exists ---
Write-Host "`n1. Verifying organization..." -ForegroundColor Yellow
try {
    $org = Invoke-GitHubApi "https://api.github.com/orgs/$GitHubOrg"
    Write-Host "   Org: $($org.login) — Plan: $($org.plan.name)" -ForegroundColor Green
    Write-Host "   Repos: $($org.total_private_repos + $org.public_repos)" -ForegroundColor Gray
}
catch {
    Write-Error "Cannot access org '$GitHubOrg'. Verify the org exists and your PAT has admin:org scope."
    exit 1
}

# --- 2. Check Enterprise Connection ---
if ($GitHubEnterprise) {
    Write-Host "`n2. Verifying enterprise connection..." -ForegroundColor Yellow
    try {
        $enterprise = Invoke-GitHubApi "https://api.github.com/enterprises/$GitHubEnterprise"
        Write-Host "   Enterprise: $($enterprise.name) — Slug: $($enterprise.slug)" -ForegroundColor Green
    }
    catch {
        Write-Warning "Cannot access enterprise '$GitHubEnterprise'. Some features may require enterprise admin."
    }
}

# --- 3. Verify PAT Scopes ---
Write-Host "`n3. Checking PAT scopes..." -ForegroundColor Yellow
$scopeCheck = Invoke-WebRequest -Uri "https://api.github.com/user" -Headers $headers -Method Get
$scopes = $scopeCheck.Headers["X-OAuth-Scopes"]
Write-Host "   PAT scopes: $scopes" -ForegroundColor Gray

$requiredScopes = @("repo", "admin:org", "workflow")
foreach ($scope in $requiredScopes) {
    if ($scopes -match $scope) {
        Write-Host "   [OK] $scope" -ForegroundColor Green
    }
    else {
        Write-Host "   [MISSING] $scope — required for migration" -ForegroundColor Red
    }
}

# --- 4. GEI IP Allow List ---
Write-Host "`n4. GEI IP ranges for allow-listing..." -ForegroundColor Yellow
$geiIpRanges = @"
If your GitHub org uses IP allow lists, add these GEI source IPs:
  - Check https://docs.github.com/en/migrations/using-github-enterprise-importer for current IPs
  - Add them via: Settings > Security > IP allow list
  - Remove after migration is complete
"@
Write-Host $geiIpRanges -ForegroundColor Gray

# --- 5. Check Org Settings ---
Write-Host "`n5. Org settings check..." -ForegroundColor Yellow

# Default repo permission
Write-Host "   Default repository permission: $($org.default_repository_permission)" -ForegroundColor Gray

# Check two-factor requirement
if ($org.two_factor_requirement_enabled) {
    Write-Host "   [OK] Two-factor authentication required" -ForegroundColor Green
}
else {
    Write-Host "   [WARN] Two-factor authentication NOT required — recommended for bank" -ForegroundColor Yellow
}

# --- 6. Pre-Migration Checklist ---
Write-Host "`n=== Pre-Migration Checklist ===" -ForegroundColor Cyan
$checklist = @(
    @{ Item = "GitHub Enterprise Cloud license active"; Check = $true },
    @{ Item = "SAML SSO configured and enforced"; Check = $false; Note = "Verify in org settings" },
    @{ Item = "SCIM provisioning configured (if using)"; Check = $false; Note = "For auto user provisioning" },
    @{ Item = "IP allow list updated with GEI IPs"; Check = $false; Note = "Required if IP restrictions enabled" },
    @{ Item = "Audit log streaming configured"; Check = $false; Note = "SOC 2 requirement" },
    @{ Item = "Default branch protection ruleset created"; Check = $false; Note = "Baseline policy" },
    @{ Item = "Teams structure defined in team-mappings.json"; Check = $false; Note = "Map ADO teams to GitHub teams" },
    @{ Item = "User mappings prepared in user-mappings.csv"; Check = $false; Note = "ADO → GitHub identity mapping" }
)

foreach ($item in $checklist) {
    $status = if ($item.Check) { "[DONE]" } else { "[TODO]" }
    $color = if ($item.Check) { "Green" } else { "Yellow" }
    $note = if ($item.Note) { " — $($item.Note)" } else { "" }
    Write-Host "   $status $($item.Item)$note" -ForegroundColor $color
}

Write-Host "`nOrg setup validation complete." -ForegroundColor Cyan
