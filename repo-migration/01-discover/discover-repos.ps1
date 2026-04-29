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
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "$PSScriptRoot\..\config\repo-migration-config.json",

    [Parameter(Mandatory = $false)]
    [string]$RepoName = "",

    [Parameter(Mandatory = $false)]
    [string]$BatchName = "",

    [Parameter(Mandatory = $false)]
    [string]$MigrationMode = "Batch"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Load config ──────────────────────────────────────────────────────────────
if (-not (Test-Path $ConfigPath)) {
    Write-Error "Config not found at $ConfigPath. Copy repo-migration-config.json and fill in your values."
}
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

# Resolve config values — if they look like ADO pipeline variable references, read from env
$ADO_Org  = if ($config.source.organization -match '^\$\(') { $env:ADO_Org } else { $config.source.organization }
$adoProj = if ($config.source.project      -match '^\$\(') { $env:ADO_Project } else { $config.source.project }
$adoPat  = if ($config.source.pat           -match '^\$\(') { $env:ADO_PAT } else { $config.source.pat }

$ADO_Org = ($ADO_Org ?? '').TrimEnd('/')
if ($ADO_Org -and $ADO_Org -notmatch '^https?://') {
    Write-Host "Normalizing ADO_Org to full URL..." -ForegroundColor Gray
    $ADO_Org = "https://dev.azure.com/$ADO_Org"
}

if ([string]::IsNullOrWhiteSpace($ADO_Org)) {
    Write-Error "Set the ADO_Org environment variable or update config.source.organization"
}
if ([string]::IsNullOrWhiteSpace($adoProj)) {
    Write-Error "Set the ADO_Project environment variable or update config.source.project"
}
if ([string]::IsNullOrWhiteSpace($adoPat)) {
    Write-Error "Set the ADO_PAT environment variable or update config.source.pat"
}

$reportDir = $config.output.reportDir
if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }

# ── Auth header ──────────────────────────────────────────────────────────────
$base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$adoPat"))
$headers = @{
    Authorization  = "Basic $base64Auth"
    Accept         = "application/json"
    "Content-Type" = "application/json"
}

# ── Verify PAT connectivity ─────────────────────────────────────────────────
Write-Host "Verifying PAT connectivity..." -ForegroundColor Cyan
try {
    $connTest = Invoke-RestMethod -Uri "$ADO_Org/_apis/connectiondata" -Headers $headers -Method Get
    Write-Host "  Authenticated as: $($connTest.authenticatedUser.providerDisplayName)" -ForegroundColor Green
}
catch {
    Write-Error "PAT authentication failed against $ADO_Org. Ensure ADO_PAT is valid and not expired. Detail: $_"
}

# ── Fetch all repos ─────────────────────────────────────────────────────────
Write-Host "=== Discovering repos in $ADO_Org/$adoProj ===" -ForegroundColor Cyan
$repoApiUrl = "$ADO_Org/$adoProj/_apis/git/repositories?api-version=7.1"

try {
    $response = Invoke-RestMethod -Uri $repoApiUrl -Headers $headers -Method Get
}
catch {
    $statusCode = if ($_.Exception.Response) { $_.Exception.Response.StatusCode.value__ } else { 'N/A' }
    Write-Error "API call failed (HTTP $statusCode) for $repoApiUrl — verify ADO_PAT has 'Code (Read)' scope for project '$adoProj'. Detail: $_"
}

if ($response -is [string]) {
    Write-Error "API returned non-JSON response (likely a sign-in page). The PAT is not authorized for $repoApiUrl."
}

if (-not $response.PSObject.Properties['value']) {
    Write-Host "API response keys: $($response.PSObject.Properties.Name -join ', ')" -ForegroundColor Yellow
    Write-Error "Unexpected API response — no 'value' property. Response: $($response | ConvertTo-Json -Depth 2 -Compress)"
}

$repoList = $response.value

# ── Filtering logic ──────────────────────────────────────────────────────────
if ($MigrationMode -eq 'Single' -and -not [string]::IsNullOrWhiteSpace($RepoName)) {
    $rName = $RepoName.Trim()
    $repoList = @($repoList | Where-Object { $_.name -eq $rName })
    Write-Host "Filtering for single repo: $rName (Found: $($repoList.Count))" -ForegroundColor Cyan
} elseif ($MigrationMode -eq 'Batch' -and -not [string]::IsNullOrWhiteSpace($BatchName)) {
    $bName = $BatchName.Trim()
    $batch = $config.batches | Where-Object { $_.name -eq $bName }
    if ($batch) {
        $batchRepos = $batch.repos
        $repoList = @($repoList | Where-Object { $_.name -in $batchRepos })
        Write-Host "Filtering for batch: $bName (Found: $($repoList.Count) of $($batchRepos.Count) repos)" -ForegroundColor Cyan
    } else {
        Write-Warning "Batch '$bName' not found in config. Discovering all repos."
    }
}
$throttleLimit = 10
Write-Host "Enriching $($repoList.Count) repos (parallel, throttle=$throttleLimit)..." -ForegroundColor Cyan

$repos = @($repoList | ForEach-Object -ThrottleLimit $throttleLimit -Parallel {
    $repo     = $_
    $ADO_Org   = $using:ADO_Org
    $adoProj  = $using:adoProj
    $headers  = $using:headers
    $lastCommitDate = $null
    $hasLfs = $false

    # Get last commit on default branch
    try {
        $defaultBranch = if ($repo.PSObject.Properties['defaultBranch']) { $repo.defaultBranch -replace '^refs/heads/', '' } else { $null }
        if ($defaultBranch) {
            $commitUrl = '{0}/{1}/_apis/git/repositories/{2}/commits?searchCriteria.$top=1&searchCriteria.itemVersion.version={3}&api-version=7.1' -f $ADO_Org, $adoProj, $repo.id, $defaultBranch
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
        $gitattrsUrl = "$ADO_Org/$adoProj/_apis/git/repositories/$($repo.id)/items?path=.gitattributes&api-version=7.1"
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
        Project           = $adoProj
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
$htmlOut = Join-Path $reportDir "repo-inventory.html"

$included | ConvertTo-Json -Depth 5 | Out-File $jsonOut -Encoding utf8
$included | Export-Csv $csvOut -NoTypeInformation -Encoding utf8

# ── HTML Dashboard Report ────────────────────────────────────────────────────
$totalSizeMB = [math]::Round(($included | Measure-Object -Property SizeMB -Sum).Sum, 2)
$totalSizeGB = [math]::Round($totalSizeMB / 1024, 2)
$lfsCount    = @($included | Where-Object HasLFS).Count
$geiCount    = @($included | Where-Object ExceedsGEI40GB).Count
$disabledCount = @($included | Where-Object IsDisabled).Count
$timestamp   = Get-Date -Format "yyyy-MM-dd HH:mm:ss UTC"

$tableRows = ""
$rowIndex = 0
foreach ($r in ($included | Sort-Object { $_.SizeMB } -Descending)) {
    $rowIndex++
    $sizeClass = if ($r.SizeGB -gt 40) { "blocked" } elseif ($r.SizeMB -gt 1024) { "warning" } else { "ok" }
    $lfsIcon   = if ($r.HasLFS) { "&#9989;" } else { "&#10060;" }
    $geiIcon   = if ($r.ExceedsGEI40GB) { "<span class='badge blocked'>BLOCKED</span>" } else { "<span class='badge ok'>OK</span>" }
    $lastCommit = if ($r.LastCommitDate) { try { ([datetime]$r.LastCommitDate).ToString("yyyy-MM-dd") } catch { "$($r.LastCommitDate)" } } else { "N/A" }
    $repoName  = [System.Net.WebUtility]::HtmlEncode($r.Name)
    $repoLink  = if ($r.Url) { "<a href='$([System.Net.WebUtility]::HtmlEncode($r.Url))' target='_blank'>$repoName</a>" } else { $repoName }

    $tableRows += "    <tr class='$sizeClass'>`n"
    $tableRows += "      <td>$rowIndex</td>`n"
    $tableRows += "      <td>$repoLink</td>`n"
    $tableRows += "      <td>$([System.Net.WebUtility]::HtmlEncode($r.DefaultBranch))</td>`n"
    $tableRows += "      <td class='num'>$($r.SizeMB)</td>`n"
    $tableRows += "      <td class='num'>$($r.SizeGB)</td>`n"
    $tableRows += "      <td>$lastCommit</td>`n"
    $tableRows += "      <td class='center'>$lfsIcon</td>`n"
    $tableRows += "      <td class='center'>$geiIcon</td>`n"
    $tableRows += "    </tr>`n"
}

$htmlContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>ADO Repository Discovery Report</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { font-family: 'Segoe UI', Tahoma, sans-serif; background: #f0f2f5; color: #24292f; padding: 20px; }
  .container { max-width: 1400px; margin: 0 auto; }
  h1 { font-size: 1.8rem; margin-bottom: 5px; color: #0078d4; }
  .subtitle { color: #586069; margin-bottom: 20px; font-size: 0.9rem; }
  .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); gap: 15px; margin-bottom: 25px; }
  .card { background: #fff; border-radius: 8px; padding: 18px; box-shadow: 0 1px 3px rgba(0,0,0,0.12); text-align: center; }
  .card .value { font-size: 2rem; font-weight: 700; color: #0078d4; }
  .card .label { font-size: 0.85rem; color: #586069; margin-top: 4px; }
  .card.warn .value { color: #d29922; }
  .card.error .value { color: #cf222e; }
  table { width: 100%; border-collapse: collapse; background: #fff; border-radius: 8px; overflow: hidden; box-shadow: 0 1px 3px rgba(0,0,0,0.12); }
  th { background: #0078d4; color: #fff; padding: 12px 10px; text-align: left; font-size: 0.85rem; position: sticky; top: 0; cursor: pointer; user-select: none; }
  th:hover { background: #106ebe; }
  td { padding: 10px; border-bottom: 1px solid #e1e4e8; font-size: 0.85rem; }
  tr:hover { background: #f6f8fa; }
  tr.blocked { background: #fff0f0; }
  tr.warning { background: #fff8e1; }
  .num { text-align: right; font-variant-numeric: tabular-nums; }
  .center { text-align: center; }
  .badge { padding: 2px 8px; border-radius: 12px; font-size: 0.75rem; font-weight: 600; }
  .badge.ok { background: #dafbe1; color: #1a7f37; }
  .badge.blocked { background: #ffebe9; color: #cf222e; }
  .search-box { margin-bottom: 15px; }
  .search-box input { width: 100%; max-width: 400px; padding: 10px 14px; border: 1px solid #d0d7de; border-radius: 6px; font-size: 0.9rem; }
  .search-box input:focus { outline: none; border-color: #0078d4; box-shadow: 0 0 0 3px rgba(0,120,212,0.15); }
  a { color: #0078d4; text-decoration: none; }
  a:hover { text-decoration: underline; }
  .footer { margin-top: 15px; color: #586069; font-size: 0.8rem; text-align: center; }
</style>
</head>
<body>
<div class="container">
  <h1>&#128269; ADO Repository Discovery Report</h1>
  <p class="subtitle">$([System.Net.WebUtility]::HtmlEncode($ADO_Org)) / $([System.Net.WebUtility]::HtmlEncode($adoProj)) &mdash; Generated: $timestamp</p>
  <div class="cards">
    <div class="card"><div class="value">$($included.Count)</div><div class="label">Repos to Migrate</div></div>
    <div class="card"><div class="value">$($excluded.Count)</div><div class="label">Excluded</div></div>
    <div class="card"><div class="value">$totalSizeGB GB</div><div class="label">Total Size</div></div>
    <div class="card$(if ($lfsCount -gt 0) {' warn'})"><div class="value">$lfsCount</div><div class="label">Repos with LFS</div></div>
    <div class="card$(if ($geiCount -gt 0) {' error'})"><div class="value">$geiCount</div><div class="label">Exceed GEI 40 GB</div></div>
    <div class="card$(if ($disabledCount -gt 0) {' warn'})"><div class="value">$disabledCount</div><div class="label">Disabled</div></div>
  </div>
  <div class="search-box">
    <input type="text" id="searchInput" placeholder="Search repos..." onkeyup="filterTable()">
  </div>
  <table id="repoTable">
    <thead>
      <tr>
        <th onclick="sortTable(0)">#</th>
        <th onclick="sortTable(1)">Repository</th>
        <th onclick="sortTable(2)">Default Branch</th>
        <th onclick="sortTable(3)">Size (MB)</th>
        <th onclick="sortTable(4)">Size (GB)</th>
        <th onclick="sortTable(5)">Last Commit</th>
        <th onclick="sortTable(6)">LFS</th>
        <th onclick="sortTable(7)">GEI Status</th>
      </tr>
    </thead>
    <tbody>
$tableRows
    </tbody>
  </table>
  <p class="footer">Total repos found: $($repos.Count) | Included: $($included.Count) | Excluded: $($excluded.Count)</p>
</div>
<script>
function filterTable() {
  var input = document.getElementById('searchInput').value.toLowerCase();
  var rows = document.querySelectorAll('#repoTable tbody tr');
  for (var i = 0; i < rows.length; i++) {
    rows[i].style.display = rows[i].textContent.toLowerCase().indexOf(input) > -1 ? '' : 'none';
  }
}
var sortDir = {};
function sortTable(col) {
  var tbody = document.getElementById('repoTable').querySelector('tbody');
  var rows = Array.prototype.slice.call(tbody.querySelectorAll('tr'));
  var dir = sortDir[col] = !sortDir[col];
  rows.sort(function(a, b) {
    var aVal = a.cells[col].textContent.trim();
    var bVal = b.cells[col].textContent.trim();
    var aNum = parseFloat(aVal), bNum = parseFloat(bVal);
    if (!isNaN(aNum) && !isNaN(bNum)) return dir ? aNum - bNum : bNum - aNum;
    return dir ? aVal.localeCompare(bVal) : bVal.localeCompare(aVal);
  });
  for (var i = 0; i < rows.length; i++) { tbody.appendChild(rows[i]); }
}
</script>
</body>
</html>
"@

$htmlContent | Out-File $htmlOut -Encoding utf8

Write-Host "`nReports saved:" -ForegroundColor Cyan
Write-Host "  JSON : $jsonOut"
Write-Host "  CSV  : $csvOut"
Write-Host "  HTML : $htmlOut"
Write-Host "`nNext step: Run 01-discover\audit-repo-sizes.ps1 for detailed per-file size analysis."

