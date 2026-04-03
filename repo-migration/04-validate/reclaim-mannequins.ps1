<#
.SYNOPSIS
    Reclaims mannequin (placeholder) users created by GEI migration.
.DESCRIPTION
    After GEI migration, all non-Git activity (PRs, comments) is attributed to 
    "mannequin" placeholder accounts. This script:
      1. Lists all mannequins in the GitHub org
      2. Maps them to real GitHub users using config/user-mappings.csv
      3. Sends reclaim invitations via gh gei reclaim-mannequin
.PARAMETER ConfigPath
    Path to repo-migration-config.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "$PSScriptRoot\..\config\repo-migration-config.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$config    = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$ghOrg     = $config.target.organization
$reportDir = $config.output.reportDir

$ghPat = if ($config.target.pat -eq '$(GH_PAT)') { $env:GH_PAT } else { $config.target.pat }
if ([string]::IsNullOrWhiteSpace($ghPat)) { Write-Error "Set GH_PAT environment variable" }
$env:GH_PAT = $ghPat

# ── Load user mappings ───────────────────────────────────────────────────────
$mappingPath = "$PSScriptRoot\..\config\user-mappings.csv"
if (-not (Test-Path $mappingPath)) {
    Write-Error "user-mappings.csv not found at $mappingPath"
}
$mappings = Import-Csv $mappingPath

Write-Host "=== Reclaiming Mannequins for $ghOrg ===" -ForegroundColor Cyan
Write-Host "  User mappings loaded: $($mappings.Count)"

# ── List mannequins ──────────────────────────────────────────────────────────
Write-Host "`nFetching mannequins from GitHub org..."
try {
    $mannequinOutput = & gh gei generate-mannequin-csv --github-org $ghOrg 2>&1
    $mannequinCsv = Join-Path $reportDir "mannequins.csv"
    $mannequinOutput | Out-File $mannequinCsv -Encoding utf8

    $mannequins = $mannequinOutput | ConvertFrom-Csv
    Write-Host "  Found $($mannequins.Count) mannequin(s)"
}
catch {
    Write-Error "Failed to list mannequins: $_"
}

if ($mannequins.Count -eq 0) {
    Write-Host "No mannequins to reclaim." -ForegroundColor Green
    return
}

# ── Match and reclaim ────────────────────────────────────────────────────────
$reclaimResults = @()

foreach ($m in $mannequins) {
    $mannequinLogin = $m.login
    $mannequinId    = $m.id

    # Find matching GitHub user from mappings (match on ADO email or username)
    $match = $mappings | Where-Object {
        $_.ADOEmail -eq $mannequinLogin -or
        $_.ADOUsername -eq $mannequinLogin -or
        $_.ADODisplayName -eq $mannequinLogin
    } | Select-Object -First 1

    if ($match) {
        $targetGhUser = $match.GitHubUsername
        Write-Host "  $mannequinLogin → $targetGhUser" -ForegroundColor Yellow

        try {
            & gh gei reclaim-mannequin --github-org $ghOrg --mannequin-user $mannequinLogin --target-user $targetGhUser --force 2>&1 | Out-Null
            Write-Host "    Reclaim request sent" -ForegroundColor Green
            $reclaimResults += [PSCustomObject]@{
                Mannequin = $mannequinLogin; TargetUser = $targetGhUser; Status = "SENT"
            }
        }
        catch {
            Write-Warning "    Reclaim failed: $_"
            $reclaimResults += [PSCustomObject]@{
                Mannequin = $mannequinLogin; TargetUser = $targetGhUser; Status = "FAILED"
            }
        }
    }
    else {
        Write-Warning "  $mannequinLogin — NO MAPPING FOUND. Add to user-mappings.csv"
        $reclaimResults += [PSCustomObject]@{
            Mannequin = $mannequinLogin; TargetUser = ""; Status = "NO_MAPPING"
        }
    }
}

# ── Report ───────────────────────────────────────────────────────────────────
$resultPath = Join-Path $reportDir "mannequin-reclaim-results.json"
$reclaimResults | ConvertTo-Json -Depth 3 | Out-File $resultPath -Encoding utf8

Write-Host "`n=== Reclaim Summary ===" -ForegroundColor Green
Write-Host "  Total mannequins : $($reclaimResults.Count)"
Write-Host "  Reclaim sent     : $(($reclaimResults | Where-Object Status -eq 'SENT').Count)"
Write-Host "  Failed           : $(($reclaimResults | Where-Object Status -eq 'FAILED').Count)"
Write-Host "  No mapping       : $(($reclaimResults | Where-Object Status -eq 'NO_MAPPING').Count)"
Write-Host "`nNote: Target users must ACCEPT the reclaim invitation in GitHub."
Write-Host "Report: $resultPath"
