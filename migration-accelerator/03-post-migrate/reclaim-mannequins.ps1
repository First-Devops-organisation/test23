<#
.SYNOPSIS
    Reclaims mannequin users created by GEI migration.
.DESCRIPTION
    After GEI migration, non-Git contributions (PRs, issues) are attributed to
    mannequin placeholder accounts. This script maps mannequins to real GitHub users
    using the user-mappings.csv file.
.PARAMETER GitHubOrg
    GitHub organization name
.PARAMETER GitHubPat
    GitHub PAT with admin:org scope
.PARAMETER UserMappingsFile
    Path to user-mappings.csv
.PARAMETER DryRun
    List mannequins without reclaiming
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$GitHubOrg,

    [Parameter(Mandatory = $true)]
    [string]$GitHubPat,

    [string]$UserMappingsFile = "./config/user-mappings.csv",

    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$env:GH_PAT = $GitHubPat

Write-Host "=== Mannequin Reclaim: $GitHubOrg ===" -ForegroundColor Cyan
if ($DryRun) { Write-Host "[DRY RUN]" -ForegroundColor Yellow }

# --- List mannequins ---
Write-Host "`nFetching mannequins..." -ForegroundColor Yellow
$mannequinOutput = gh ado2gh inventory-mannequins --github-org $GitHubOrg 2>&1
$mannequinStr = $mannequinOutput | Out-String

Write-Host $mannequinStr -ForegroundColor Gray

# --- Load user mappings ---
if (Test-Path $UserMappingsFile) {
    $userMappings = Import-Csv $UserMappingsFile
    Write-Host "Loaded $($userMappings.Count) user mappings" -ForegroundColor Green
}
else {
    Write-Warning "User mappings file not found: $UserMappingsFile"
    Write-Host "Create user-mappings.csv first, then re-run." -ForegroundColor Red
    exit 1
}

# --- Generate reclaim CSV ---
$reclaimCsvPath = "./output/mannequin-reclaim.csv"
$outputDir = Split-Path $reclaimCsvPath -Parent
if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

# The reclaim CSV format expected by GEI:
# mannequin-user,mannequin-id,target-user
Write-Host "`nGenerating reclaim mappings..." -ForegroundColor Yellow

$reclaimArgs = @(
    "ado2gh", "generate-mannequin-csv",
    "--github-org", $GitHubOrg,
    "--output", $reclaimCsvPath
)

try {
    gh @reclaimArgs 2>&1
    Write-Host "Mannequin CSV generated: $reclaimCsvPath" -ForegroundColor Green

    # Enrich with target users from our mappings
    if (Test-Path $reclaimCsvPath) {
        $reclaimData = Import-Csv $reclaimCsvPath
        $matched = 0
        $unmatched = 0

        foreach ($row in $reclaimData) {
            $mannequinName = $row.'mannequin-user'
            # Try to find matching GitHub user from our mapping
            $match = $userMappings | Where-Object {
                $_.ado_display_name -eq $mannequinName -or
                $_.ado_email -match $mannequinName
            } | Select-Object -First 1

            if ($match -and $match.github_username) {
                $row.'target-user' = $match.github_username
                $matched++
            }
            else {
                $unmatched++
            }
        }

        $reclaimData | Export-Csv -Path $reclaimCsvPath -NoTypeInformation
        Write-Host "Matched: $matched | Unmatched: $unmatched" -ForegroundColor $(if ($unmatched -gt 0) { "Yellow" } else { "Green" })

        if ($unmatched -gt 0) {
            Write-Host "`nUnmatched mannequins need manual mapping in: $reclaimCsvPath" -ForegroundColor Yellow
        }
    }
}
catch {
    Write-Warning "Error generating mannequin CSV: $_"
}

# --- Execute Reclaim ---
if (-not $DryRun) {
    Write-Host "`nReclaiming mannequins..." -ForegroundColor Yellow

    $reclaimExecArgs = @(
        "ado2gh", "reclaim-mannequin",
        "--github-org", $GitHubOrg,
        "--csv", $reclaimCsvPath
    )

    try {
        gh @reclaimExecArgs 2>&1
        Write-Host "Mannequin reclaim complete!" -ForegroundColor Green
    }
    catch {
        Write-Warning "Reclaim error: $_"
        Write-Host "Review $reclaimCsvPath and retry manually." -ForegroundColor Yellow
    }
}

Write-Host "`n=== NOTES ===" -ForegroundColor Yellow
Write-Host @"
- Users must accept the GitHub org invitation for reclaim to work
- If SSO is enforced, users must authorize their PAT for the org
- Mannequin reclaim can be re-run (idempotent for already-claimed users)
- Unmatched mannequins will show as 'ghost' accounts on PRs
"@ -ForegroundColor Gray

Remove-Item Env:\GH_PAT -ErrorAction SilentlyContinue
