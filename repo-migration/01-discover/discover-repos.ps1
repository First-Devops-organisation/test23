<#
.SYNOPSIS
    Discovers all Git repositories in an Azure DevOps project. 
    Outputs repo list with metadata (size, default branch, last commit, LFS usage).
.DESCRIPTION
    Calls the ADO REST API to enumerate repos, then enriches each with:
      - Size on disk (from ADO API)
      - Default branch
      - Last commit date
      - Whether the repo is disabled/in maintenance
      - LFS object presence
    Results are saved as JSON + CSV for downstream scripts.
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

# ── Load config ──────────────────────────────────────────────────────────────
if (-not (Test-Path $ConfigPath)) {
    Write-Error "Config not found at $ConfigPath. Copy repo-migration-config.json and fill in your values."
}
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$adoOrg   = $config.source.organization.TrimEnd('/')
$adoProj  = $config.source.project
$adoPat   = if ($config.source.pat -eq '$(ADO_PAT)') { $env:ADO_PAT } else { $config.source.pat }

if ([string]::IsNullOrWhiteSpace($adoPat)) {
    Write-Error "Set the ADO_PAT environment variable or update config.source.pat"
}

$reportDir = $config.output.reportDir
if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }

# ── Auth header ──────────────────────────────────────────────────────────────
$base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$adoPat"))
$headers = @{ Authorization = "Basic $base64Auth" }

# ── Fetch all repos ─────────────────────────────────────────────────────────
Write-Host "=== Discovering repos in $adoOrg/$adoProj ===" -ForegroundColor Cyan
$repoApiUrl = "$adoOrg/$adoProj/_apis/git/repositories?api-version=7.1"
$response = Invoke-RestMethod -Uri $repoApiUrl -Headers $headers -Method Get

$repos = @($response.value | ForEach-Object {
    $repo = $_
    $lastCommitDate = $null
    $hasLfs = $false

    # Get last commit on default branch
    try {
        $defaultBranch = if ($repo.PSObject.Properties['defaultBranch']) { $repo.defaultBranch -replace '^refs/heads/', '' } else { $null }
        if ($defaultBranch) {
            $commitUrl = "$adoOrg/$adoProj/_apis/git/repositories/$($repo.id)/commits?searchCriteria.`$top=1&searchCriteria.itemVersion.version=$defaultBranch&api-version=7.1"
            $commitResp = Invoke-RestMethod -Uri $commitUrl -Headers $headers -Method Get
            if ($commitResp.value -and $commitResp.value.Count -gt 0) {
                $lastCommitDate = $commitResp.value[0].committer.date
            }
        }
    }
    catch {
        Write-Warning "  Could not fetch last commit for $($repo.name): $_"
    }

    # Check for .gitattributes LFS markers
    try {
        $gitattrsUrl = "$adoOrg/$adoProj/_apis/git/repositories/$($repo.id)/items?path=.gitattributes&api-version=7.1"
        $gitattrs = Invoke-RestMethod -Uri $gitattrsUrl -Headers $headers -Method Get -ErrorAction SilentlyContinue
        if ($gitattrs -match 'filter=lfs') { $hasLfs = $true }
    }
    catch {
        # No .gitattributes — fine
    }

    $sizeBytes = $repo.size  # ADO returns size in bytes
    $sizeMB    = [math]::Round($sizeBytes / 1MB, 2)
    $sizeGB    = [math]::Round($sizeBytes / 1GB, 2)

    # GEI limit flags
    $exceedsGeiLimit  = $sizeGB -gt 40
    $exceedsFileLimit = $false  # Would need per-file check — flagged in audit-repo-sizes.ps1

    [PSCustomObject]@{
        Name              = $repo.name
        Id                = $repo.id
        DefaultBranch     = if ($repo.PSObject.Properties['defaultBranch']) { $repo.defaultBranch -replace '^refs/heads/', '' } else { $null }
        SizeBytes         = $sizeBytes
        SizeMB            = $sizeMB
        SizeGB            = $sizeGB
        LastCommitDate    = $lastCommitDate
        IsDisabled        = $repo.isDisabled
        HasLFS            = $hasLfs
        ExceedsGEI40GB    = $exceedsGeiLimit
        Url               = $repo.webUrl
        RemoteUrl         = $repo.remoteUrl
    }
})

# ── Exclusion filter ─────────────────────────────────────────────────────────
$exclusions = @()
if ($config.exclusions -and $config.exclusions.repos) {
    $exclusions = $config.exclusions.repos
}
$included = @($repos | Where-Object { $_.Name -notin $exclusions })
$excluded = @($repos | Where-Object { $_.Name -in $exclusions })

# ── Summary ──────────────────────────────────────────────────────────────────
Write-Host "`n=== Discovery Summary ===" -ForegroundColor Green
Write-Host "  Total repos found   : $($repos.Count)"
Write-Host "  Excluded by config  : $($excluded.Count)"
Write-Host "  Repos to migrate    : $($included.Count)"
Write-Host "  Total size          : $([math]::Round(($included | Measure-Object -Property SizeMB -Sum).Sum, 2)) MB"
Write-Host "  Repos with LFS      : $(@($included | Where-Object HasLFS).Count)"
Write-Host "  Repos > 40 GB (GEI) : $(@($included | Where-Object ExceedsGEI40GB).Count)"

$oversize = @($included | Where-Object { $_.ExceedsGEI40GB })
if ($oversize) {
    Write-Warning "The following repos exceed GEI's 40 GB limit and need manual migration:"
    $oversize | Format-Table Name, SizeGB -AutoSize
}

$lfsRepos = @($included | Where-Object { $_.HasLFS })
if ($lfsRepos) {
    Write-Warning "The following repos use Git LFS — LFS objects are NOT migrated by GEI:"
    $lfsRepos | Format-Table Name, SizeGB -AutoSize
}

# ── Output ───────────────────────────────────────────────────────────────────
$jsonOut = Join-Path $reportDir "repo-inventory.json"
$csvOut  = Join-Path $reportDir "repo-inventory.csv"

$included | ConvertTo-Json -Depth 5 | Out-File $jsonOut -Encoding utf8
$included | Export-Csv $csvOut -NoTypeInformation -Encoding utf8

Write-Host "`nReports saved:" -ForegroundColor Cyan
Write-Host "  JSON : $jsonOut"
Write-Host "  CSV  : $csvOut"
Write-Host "`nNext step: Run 01-discover\audit-repo-sizes.ps1 for detailed per-file size analysis."
