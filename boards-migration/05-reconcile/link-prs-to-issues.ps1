<#
.SYNOPSIS
    Post-Migration PR Reconciliation Script
    Links migrated GitHub PRs to their corresponding GitHub Issues by:
    1. Reading migration-log.json (ADO ID → GitHub Issue Number mapping)
    2. Scanning all GitHub PRs for GEI-injected "AzureDevOps/#XXXX" references
    3. Updating each PR description to add "Closes #N" so the Development sidebar auto-populates
#>

param(
    [string]$ConfigPath = "$PSScriptRoot\..\config\boards-migration-config.json",
    [string]$MigrationLogPath = "$PSScriptRoot\..\reports\migration-log.json",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# --- Load config ---
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$ghOrg  = $config.target.organization
$ghRepo = $config.target.repository
$ghPat  = if ($config.target.pat -match '^\$\(') { $env:GH_PAT } else { $config.target.pat }

$headers = @{
    Authorization  = "token $ghPat"
    Accept         = "application/vnd.github.v3+json"
    "User-Agent"   = "ADO-Migration-Reconcile"
    "Content-Type" = "application/json"
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  PR → Issue Reconciliation Script" -ForegroundColor Cyan
Write-Host "  Repo: $ghOrg/$ghRepo" -ForegroundColor Cyan
if ($DryRun) { Write-Host "  *** DRY RUN - No changes will be made ***" -ForegroundColor Yellow }
Write-Host "============================================================" -ForegroundColor Cyan

# --- Load migration log (ADO ID → GitHub Issue Number) ---
if (-not (Test-Path $MigrationLogPath)) {
    Write-Host "ERROR: Migration log not found at $MigrationLogPath" -ForegroundColor Red
    exit 1
}
$migLog = Get-Content $MigrationLogPath -Raw | ConvertFrom-Json
# Build lookup: ADO ID (string) → GitHub Issue Number
$adoToIssue = @{}
foreach ($prop in $migLog.PSObject.Properties) {
    $adoId      = $prop.Name
    $issueNum   = $prop.Value.issueNumber
    if ($issueNum) { $adoToIssue[$adoId] = $issueNum }
}
Write-Host "Loaded $($adoToIssue.Count) ADO→Issue mappings from migration log." -ForegroundColor Green

# --- Fetch all PRs (open and closed) ---
Write-Host "`nFetching all PRs from $ghOrg/$ghRepo..." -ForegroundColor Cyan
$allPRs = @()
$page = 1
do {
    $uri  = "https://api.github.com/repos/$ghOrg/$ghRepo/pulls?state=all&per_page=100&page=$page"
    $resp = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers
    $allPRs += $resp
    $page++
} while ($resp.Count -eq 100)
Write-Host "Found $($allPRs.Count) total PRs." -ForegroundColor Green

# --- Also check PR comments for GEI-injected AzureDevOps links ---
$updated = 0; $skipped = 0

foreach ($pr in $allPRs) {
    $prNumber = $pr.number
    $prTitle  = $pr.title
    Write-Host "`n--- PR #$prNumber : $prTitle ---" -ForegroundColor White

    # Collect text to scan: PR body + all comments
    $scanText = "$($pr.body)"

    # Fetch PR comments
    $commentsUri = "https://api.github.com/repos/$ghOrg/$ghRepo/issues/$prNumber/comments"
    $comments    = Invoke-RestMethod -Uri $commentsUri -Method GET -Headers $headers
    foreach ($c in $comments) { $scanText += "`n$($c.body)" }

    # Find all AzureDevOps/#XXXX references
    $adoMatches = [regex]::Matches($scanText, 'AzureDevOps/#(\d+)')
    if ($adoMatches.Count -eq 0) {
        Write-Host "  No AzureDevOps references found. Skipping." -ForegroundColor Gray
        $skipped++
        continue
    }

    # Map ADO IDs → GitHub Issue Numbers
    $closesRefs  = @()
    $foundAdoIds = @()
    foreach ($m in $adoMatches) {
        $adoId = $m.Groups[1].Value
        $foundAdoIds += $adoId
        if ($adoToIssue.ContainsKey($adoId)) {
            $issueNum = $adoToIssue[$adoId]
            $closesRefs += "Closes #$issueNum"
            Write-Host "  ADO #$adoId → GitHub Issue #$issueNum" -ForegroundColor Green
        } else {
            Write-Host "  ADO #$adoId → NOT FOUND in migration log (may not have been migrated)" -ForegroundColor Yellow
        }
    }

    if ($closesRefs.Count -eq 0) {
        Write-Host "  No matching issues found. Skipping PR #$prNumber." -ForegroundColor Yellow
        $skipped++
        continue
    }

    # Check if PR body already has Closes references (avoid duplicates)
    $existingBody = "$($pr.body)"
    if ($existingBody -match "<!-- Reconciled by ADO Migration Script -->") {
        # Strip old reconciled block
        $existingBody = $existingBody -replace "(?s)\n\n---\n<!-- Reconciled by ADO Migration Script -->.*$", ""
    }

    # Build new PR body with Closes references appended
    $closesLine  = $closesRefs -join ", "
    $newBody = $existingBody.TrimEnd()
    $newBody += "`n`n---`n<!-- Reconciled by ADO Migration Script -->`n$closesLine"

    if ($DryRun) {
        Write-Host "  [DRY RUN] Would update PR #$prNumber body to add: $closesLine" -ForegroundColor Magenta
        $updated++
        continue
    }

    # Update the PR via REST API
    $updateUri  = "https://api.github.com/repos/$ghOrg/$ghRepo/pulls/$prNumber"
    $updateBody = @{ body = $newBody } | ConvertTo-Json -Depth 5
    try {
        Invoke-RestMethod -Uri $updateUri -Method PATCH -Headers $headers -Body $updateBody | Out-Null
        Write-Host "  ✅ PR #$prNumber updated: $closesLine" -ForegroundColor Green
        $updated++
        Start-Sleep -Milliseconds 1000
    } catch {
        Write-Host "  ❌ Failed to update PR #${prNumber}: $_" -ForegroundColor Red
    }
}

Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host "  Reconciliation Complete" -ForegroundColor Cyan
Write-Host "  PRs Updated : $updated" -ForegroundColor Green
Write-Host "  PRs Skipped : $skipped" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "`nThe Development sidebar on linked GitHub Issues will now show PR connections!" -ForegroundColor Green
