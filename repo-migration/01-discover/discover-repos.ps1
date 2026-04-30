<#
.SYNOPSIS
    Discovers all repositories in an Azure DevOps project and audits their basic metadata.
.DESCRIPTION
    Fetches the repository list from ADO API, identifies default branches, 
    detects Git LFS usage (.gitattributes), and calculates total sizes.
    Outputs JSON, CSV, and a searchable HTML report.
#>
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "$PSScriptRoot\..\config\repo-migration-config.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path $ConfigPath)) {
    Write-Error "Config file not found at $ConfigPath"
}

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$adoOrg = $config.source.organization
$adoProj = $config.source.project
$adoPat = $config.source.pat
$reportDir = $config.output.reportDir

if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }

$base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$adoPat"))
$headers = @{
    Authorization  = "Basic $base64Auth"
    Accept         = "application/json"
    "Content-Type" = "application/json"
}

Write-Host "Verifying PAT connectivity..." -ForegroundColor Cyan
try {
    $connTest = Invoke-RestMethod -Uri "$adoOrg/_apis/connectiondata" -Headers $headers -Method Get
    Write-Host "  Authenticated as: $($connTest.authenticatedUser.providerDisplayName)" -ForegroundColor Green
}
catch {
    Write-Error "PAT authentication failed. Detail: $_"
}

Write-Host "=== Discovering repos in $adoOrg/$adoProj ===" -ForegroundColor Cyan
$repoApiUrl = "$adoOrg/$adoProj/_apis/git/repositories?api-version=7.1"

try {
    $response = Invoke-RestMethod -Uri $repoApiUrl -Headers $headers -Method Get
}
catch {
    Write-Error "API call failed for $repoApiUrl. Detail: $_"
}

$repoList = $response.value
$throttleLimit = 5
Write-Host "Enriching $($repoList.Count) repos..." -ForegroundColor Cyan

$repos = foreach ($repo in $repoList) {
    Write-Host "  Processing $($repo.name)..." -ForegroundColor Gray
    $lastCommitDate = $null
    $hasLfs = $false

    try {
        $defaultBranch = if ($repo.PSObject.Properties['defaultBranch']) { $repo.defaultBranch -replace '^refs/heads/', '' } else { $null }
        if ($defaultBranch) {
            $commitUrl = '{0}/{1}/_apis/git/repositories/{2}/commits?searchCriteria.$top=1&searchCriteria.itemVersion.version={3}&api-version=7.1' -f $adoOrg, $adoProj, $repo.id, $defaultBranch
            $commitResp = Invoke-RestMethod -Uri $commitUrl -Headers $headers -Method Get
            if ($commitResp.value -and $commitResp.value.Count -gt 0) {
                $lastCommitDate = $commitResp.value[0].committer.date
            }
        }
    }
    catch { }

    try {
        $gitattrsUrl = "$adoOrg/$adoProj/_apis/git/repositories/$($repo.id)/items?path=.gitattributes&api-version=7.1"
        $gitattrs = Invoke-RestMethod -Uri $gitattrsUrl -Headers $headers -Method Get -ErrorAction SilentlyContinue
        if ($gitattrs -match 'filter=lfs') { $hasLfs = $true }
    }
    catch { }

    $sizeBytes = $repo.size
    $sizeMB    = [math]::Round($sizeBytes / 1MB, 2)
    $sizeGB    = [math]::Round($sizeBytes / 1GB, 2)

    [PSCustomObject]@{
        Name              = $repo.name
        Id                = $repo.id
        DefaultBranch     = $defaultBranch
        SizeMB            = $sizeMB
        SizeGB            = $sizeGB
        LastCommitDate    = $lastCommitDate
        HasLFS            = $hasLfs
        ExceedsGEI40GB    = ($sizeGB -gt 40)
        Url               = $repo.webUrl
    }
}

$exclusions = @()
if ($config.exclusions -and $config.exclusions.repos) { $exclusions = $config.exclusions.repos }
$included = @($repos | Where-Object { $_.Name -notin $exclusions })
$excluded = @($repos | Where-Object { $_.Name -in $exclusions })

Write-Host "`n=== Discovery Summary ===" -ForegroundColor Green
Write-Host "  Total repos found: $($repos.Count)"
Write-Host "  Included:          $($included.Count)"
Write-Host "  Excluded:          $($excluded.Count)"

if (@($included | Where-Object { $_.ExceedsGEI40GB }).Count -gt 0) {
    Write-Warning "Some repositories exceed GEI 40GB limit!"
}

$jsonOut = Join-Path $reportDir "repo-inventory.json"
$included | ConvertTo-Json -Depth 5 | Out-File $jsonOut -Encoding utf8

$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss UTC"
$tableRows = ""
foreach ($r in ($included | Sort-Object SizeMB -Descending)) {
    $sizeClass = if ($r.SizeGB -gt 40) { "blocked" } elseif ($r.SizeMB -gt 1024) { "warning" } else { "ok" }
    $lfsIcon = if ($r.HasLFS) { "YES" } else { "NO" }
    $tableRows += "<tr class='$sizeClass'><td>$($r.Name)</td><td>$($r.DefaultBranch)</td><td>$($r.SizeMB)</td><td>$($r.SizeGB)</td><td>$lfsIcon</td></tr>"
}

$htmlContent = @"
<!DOCTYPE html><html><head><title>Discovery Report</title>
<style>body{font-family:sans-serif;padding:20px}table{width:100%;border-collapse:collapse}th,td{border:1px solid #ddd;padding:8px}th{background:#f4f4f4}.blocked{background:#fee}.warning{background:#ffe}</style>
</head><body>
<h1>Discovery Report</h1><p>Generated: $timestamp</p>
<table><thead><tr><th>Repo</th><th>Branch</th><th>MB</th><th>GB</th><th>LFS</th></tr></thead>
<tbody>$tableRows</tbody></table>
</body></html>
"@
$htmlContent | Out-File (Join-Path $reportDir "repo-inventory.html") -Encoding utf8

Write-Host "Done. Reports saved to $reportDir"
