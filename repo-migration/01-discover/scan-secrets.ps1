<#
.SYNOPSIS
    Scans repos for exposed secrets using gitleaks + keyword pattern matching.
.DESCRIPTION
    For each repo identified from config:
      1. Full mirror clone (all branches, complete history)
      2. Run gitleaks detect across all branches/history
      3. Keyword-based regex scan on every branch for common secret patterns
      4. Consolidate into secret-scan-findings.json with full details
    Repos with findings MUST go through scrub-secrets.ps1 before migration.
.PARAMETER ConfigPath
    Path to repo-migration-config.json
.PARAMETER SizeFilter
    Filter repos by size: All (default), Small (< threshold), Large (>= threshold)
.PARAMETER SizeThresholdMB
    Size threshold in MB for Small/Large split (default: 1024 = 1 GB)
.PARAMETER ThrottleLimit
    Max parallel repo scans per agent (default: 5)
.PARAMETER BatchIndex
    Which batch this agent handles (0-based). Default: 0
.PARAMETER BatchTotal
    Total number of batches. Default: 1
.PARAMETER MigrationMode
    Single or Batch mode
.PARAMETER SingleRepoName
    Repo name for Single mode
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "$PSScriptRoot\..\config\repo-migration-config.json",

    [Parameter(Mandatory = $false)]
    [ValidateSet('All', 'Small', 'Large')]
    [string]$SizeFilter = 'All',

    [Parameter(Mandatory = $false)]
    [int]$SizeThresholdMB = 1024,

    [Parameter(Mandatory = $false)]
    [int]$ThrottleLimit = 5,

    [Parameter(Mandatory = $false)]
    [int]$BatchIndex = 0,

    [Parameter(Mandatory = $false)]
    [int]$BatchTotal = 1,

    [Parameter(Mandatory = $false)]
    [string]$MigrationMode = 'Batch',

    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$SingleRepoName = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$config    = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$reportDir = $config.output.reportDir
$logDir    = $config.output.logDir
$cloneDir  = $config.migration.cloneTempDir

foreach ($d in @($reportDir, $logDir, $cloneDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ── Verify TruffleHog ────────────────────────────────────────────────────────
$th = Get-Command trufflehog -ErrorAction SilentlyContinue
if (-not $th) {
    Write-Error "trufflehog not found. Install: https://github.com/trufflesecurity/trufflehog/releases"
}

# ── Keyword patterns for Phase 2 PowerShell scan ─────────────────────────────
$keywordRegex = '(?i)[a-zA-Z_]?[a-zA-Z0-9_]*(?:key|secret|password|passwd|pwd|token|cred(?:ential)?|auth)[a-zA-Z0-9_]*[''"]*\s*[:=]\s*[''"]*([^''"\s,;]+)[''"]*'


# Values that are likely placeholders, not real secrets
# Only exact-match for short values; long values are never filtered as placeholders
$placeholderExact = @(
    'changeme', 'password', 'example', 'your-password-here', 'xxx', 'TODO',
    'CHANGE_ME', 'replace_me', 'insert_here', 'none', 'null', 'empty',
    'test', 'dummy', 'sample', 'placeholder', 'default', 'admin', 'root',
    'xxxxxx', '******'
)

# ── Identify repos to scan ───────────────────────────────────────────────────
$reposToScan = @()
if ($MigrationMode -ieq 'Single') {
    if ([string]::IsNullOrWhiteSpace($SingleRepoName) -and $config.migration -and $config.migration.singleRepo) {
        $SingleRepoName = $config.migration.singleRepo
        Write-Host "Filter: SingleRepoName was blank — using default from config: $SingleRepoName" -ForegroundColor Gray
    }
    if (-not [string]::IsNullOrWhiteSpace($SingleRepoName)) {
        $reposToScan += $SingleRepoName.Trim()
    }
}
else {
    $targetBatches = $config.batches
    $batchFilter = $SingleRepoName.Trim()
    if (-not [string]::IsNullOrWhiteSpace($batchFilter)) {
        $targetBatches = @($config.batches | Where-Object { $_.name -eq $batchFilter })
    }
    foreach ($batch in $targetBatches) {
        if ($null -ne $batch.repos) {
            $reposToScan += @($batch.repos)
        }
    }
}

if ($reposToScan.Count -eq 0) {
    Write-Error "No repositories identified for scanning. Check config.json or pipeline parameters."
}

# ── Fetch repo metadata from ADO ─────────────────────────────────────────────
$adoPat  = if ($config.source.pat -eq '$(ADO_PAT)') { $env:ADO_PAT } else { $config.source.pat }
$adoOrg  = if ($config.source.organization -match '^\$\(') { $env:ADO_Org } else { $config.source.organization }
$adoProj = if ($config.source.project -match '^\$\(') { $env:ADO_Project } else { $config.source.project }

if ([string]::IsNullOrWhiteSpace($adoPat)) { Write-Error "Set ADO_PAT environment variable" }
if ([string]::IsNullOrWhiteSpace($adoOrg)) { Write-Error "Set ADO_Org environment variable" }
if ([string]::IsNullOrWhiteSpace($adoProj)) { Write-Error "Set ADO_Project environment variable" }

# Normalize ADO org to full URL
if ($adoOrg -notmatch '^https?://') { $adoOrg = "https://dev.azure.com/$adoOrg" }
$adoOrg = $adoOrg.TrimEnd('/')

Write-Host "Fetching metadata for $($reposToScan.Count) repos from Azure DevOps..." -ForegroundColor Cyan
$base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$adoPat"))
$headers = @{ Authorization = "Basic $base64Auth"; Accept = "application/json" }
$repos = @()

foreach ($repoName in $reposToScan) {
    try {
        $apiUrl = "$adoOrg/$adoProj/_apis/git/repositories/$($repoName.Trim())?api-version=7.1"
        $repoData = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method Get
        $sizeMB = [math]::Round($repoData.size / 1MB, 2)
        $repos += [PSCustomObject]@{
            Name      = $repoData.name
            SizeMB    = $sizeMB
            Url       = $repoData.webUrl
            RemoteUrl = $repoData.remoteUrl
            SizeBytes = $repoData.size
        }
    }
    catch {
        Write-Warning "  Could not fetch metadata for '$repoName'. Skipping."
    }
}

Write-Host "  Found $($repos.Count) valid repositories to scan." -ForegroundColor Green

# Filter exclusions
$excludeList = if ($config.exclusions -and $config.exclusions.repos) { $config.exclusions.repos } else { @() }
$repos = @($repos | Where-Object { $_.Name -notin $excludeList })

# Identify empty repos
$emptyRepos = @($repos | Where-Object { $_.SizeBytes -eq 0 })
if ($emptyRepos.Count -gt 0) {
    Write-Host "  Found $($emptyRepos.Count) empty repo(s). They will be marked as CLEAN." -ForegroundColor Yellow
}

# Size filter
$totalCount = ($repos | Measure-Object).Count
if ($SizeFilter -eq 'Small') {
    $repos = @($repos | Where-Object { $_.SizeMB -lt $SizeThresholdMB })
    Write-Host "Filter: Small repos only (< ${SizeThresholdMB} MB) — $($repos.Count) of $totalCount" -ForegroundColor Gray
} elseif ($SizeFilter -eq 'Large') {
    $repos = @($repos | Where-Object { $_.SizeMB -ge $SizeThresholdMB })
    Write-Host "Filter: Large repos only (>= ${SizeThresholdMB} MB) — $($repos.Count) of $totalCount" -ForegroundColor Gray
}

$repos = @($repos | Sort-Object { $_.SizeMB })

# Batch splitting
if ($BatchTotal -gt 1) {
    $batchedRepos = @()
    for ($i = 0; $i -lt $repos.Count; $i++) {
        if ($i % $BatchTotal -eq $BatchIndex) { $batchedRepos += $repos[$i] }
    }
    $repos = $batchedRepos
    Write-Host "Batch $($BatchIndex + 1) of ${BatchTotal}: scanning $($repos.Count) repos" -ForegroundColor Cyan
}

$batchSuffix = if ($BatchTotal -gt 1) { "-batch$BatchIndex" } else { '' }
$fileSuffix = if ($SizeFilter -ne 'All') { "-$($SizeFilter.ToLower())${batchSuffix}" } else { $batchSuffix }

Write-Host "=== Scanning $($repos.Count) repos for secrets [$SizeFilter] (ThrottleLimit=$ThrottleLimit) ===" -ForegroundColor Cyan

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# ── Thread-safe collections ──────────────────────────────────────────────────
$allFindings = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()
$repoSummary = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()

# ── Parallel scan ────────────────────────────────────────────────────────────
$repos | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
    $repo           = $_
    $cloneDir       = $using:cloneDir
    $logDir         = $using:logDir
    $adoPat         = $using:adoPat
    $findings       = $using:allFindings
    $summary        = $using:repoSummary
    $phValues       = $using:placeholderExact

    $repoLabel  = $repo.Name
    $clonePath  = Join-Path $cloneDir "$($repo.Name)-$([guid]::NewGuid().ToString('N').Substring(0,8)).git"
    $reportFile = Join-Path $logDir "trufflehog-$($repo.Name).jsonl"

    # Skip empty repos
    if ($repo.SizeBytes -eq 0) {
        Write-Host "  CLEAN (Empty) — $repoLabel" -ForegroundColor Green
        $summary.Add([PSCustomObject]@{ Name = $repo.Name; SizeMB = $repo.SizeMB; TruffleHogFindings = 0; KeywordFindings = 0; TotalFindings = 0; Status = "CLEAN" })
        return
    }

    # Clone — mirror clone for all branches/history
    $cloneUrl   = $repo.RemoteUrl -replace '://[^@]+@', '://'
    $base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("pat:${adoPat}"))

    try {
        $env:GIT_LFS_SKIP_SMUDGE = '1'
        Write-Host "  Cloning $repoLabel — mirror ($($repo.SizeMB) MB)" -ForegroundColor Gray
        $cloneArgs = @('-c', "http.extraHeader=Authorization: Basic $base64Auth",
                       '-c', 'lfs.fetchexclude=*',
                       'clone', '--mirror', '--quiet', $cloneUrl, $clonePath)
        $cloneOutput = & git @cloneArgs 2>&1
        if ($LASTEXITCODE -ne 0) { throw ($cloneOutput | Out-String) }
    }
    catch {
        Write-Warning "  Clone failed for ${repoLabel}: $_"
        $summary.Add([PSCustomObject]@{ Name = $repo.Name; SizeMB = $repo.SizeMB; TruffleHogFindings = -1; KeywordFindings = 0; TotalFindings = -1; Status = "CLONE_FAILED" })
        return
    }

    $thCount = 0; $kwCount = 0

    # ── Phase 1: TruffleHog scan (entire history, 800+ detectors) ─────────
    try {
        Write-Host "  Phase 1: TruffleHog scan — $repoLabel" -ForegroundColor Gray
        & trufflehog git "file://$clonePath" --json --no-update 2>$null | Out-File -FilePath $reportFile -Encoding utf8
    }
    catch {
        Write-Warning "  TruffleHog scan error for ${repoLabel}: $_"
    }

    if (Test-Path $reportFile) {
        $lines = Get-Content $reportFile -ErrorAction SilentlyContinue
        foreach ($line in $lines) {
            $line = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $f = $line | ConvertFrom-Json } catch { continue }

            $secretVal = $f.Raw
            if ([string]::IsNullOrWhiteSpace($secretVal) -and $f.PSObject.Properties['RawV2']) { $secretVal = $f.RawV2 }
            if ([string]::IsNullOrWhiteSpace($secretVal)) { continue }

            # Trim outer quotes/delimiters but preserve internal whitespace
            $secretVal = $secretVal.Trim()
            $secretVal = $secretVal -replace '[,;\s]+$', ''
            $secretVal = $secretVal -replace '^[''"`]+', '' -replace '[''"`]+$', ''
            $secretVal = $secretVal.Trim()

            if ($secretVal.Length -lt 4) { continue }

            # Check if placeholder — only exact match for short values
            $isPlaceholder = $false
            $valLower = $secretVal.ToLower().Trim()
            if ($valLower.Length -le 20) {
                foreach ($ph in $phValues) {
                    if ($valLower -eq $ph.ToLower()) { $isPlaceholder = $true; break }
                }
            }
            if ($isPlaceholder) { continue }

            # Extract metadata from TruffleHog JSONL
            $gitMeta = $null
            if ($f.PSObject.Properties['SourceMetadata'] -and $f.SourceMetadata.PSObject.Properties['Data'] -and $f.SourceMetadata.Data.PSObject.Properties['Git']) {
                $gitMeta = $f.SourceMetadata.Data.Git
            }
            $filePath   = if ($gitMeta -and $gitMeta.file)   { $gitMeta.file }   else { 'N/A' }
            $commitHash = if ($gitMeta -and $gitMeta.commit)  { $gitMeta.commit.Substring(0, [Math]::Min(12, $gitMeta.commit.Length)) } else { 'N/A' }
            $lineNum    = if ($gitMeta -and $gitMeta.PSObject.Properties['line']) { $gitMeta.line } else { 0 }
            $author     = if ($gitMeta -and $gitMeta.email)   { $gitMeta.email }  else { 'N/A' }
            $dateVal    = if ($gitMeta -and $gitMeta.PSObject.Properties['timestamp']) { $gitMeta.timestamp } else { 'N/A' }

            # Derive secret name from DetectorName
            $secretName = if ($f.PSObject.Properties['DetectorName'] -and -not [string]::IsNullOrWhiteSpace($f.DetectorName)) {
                ($f.DetectorName -replace '[^a-zA-Z0-9]', '_').ToUpper()
            } else { 'DETECTED_SECRET' }

            $thCount++
            $findings.Add([PSCustomObject]@{
                Repo        = $repo.Name
                SecretName  = $secretName
                SecretValue = $secretVal
                File        = $filePath
                LineNumber  = $lineNum
                Branch      = 'HISTORY'
                CommitHash  = $commitHash
                Source      = 'trufflehog'
                RuleID      = $secretName
                Author      = $author
                Date        = $dateVal
            })
        }
    }

    # ── Phase 2: PowerShell Keyword Scan (All History) ─────────────────────
    # Catches custom/internal secrets that TruffleHog's built-in detectors miss
    try {
        Write-Host "  Phase 2: Keyword scan — $repoLabel" -ForegroundColor Gray
        $kwRegex = $using:keywordRegex

        # Get all commits in the repo
        $commits = & git -C $clonePath rev-list --all 2>$null
        if ($commits) {
            foreach ($commitSha in $commits) {
                # Get all files changed in this commit
                $diffFiles = & git -C $clonePath diff-tree --no-commit-id --name-only -r $commitSha 2>$null
                if (-not $diffFiles) { continue }

                foreach ($filePath in $diffFiles) {
                    $filePath = $filePath.Trim()
                    if ([string]::IsNullOrWhiteSpace($filePath)) { continue }
                    # Skip binary files and common non-secret files
                    if ($filePath -match '\.(png|jpg|jpeg|gif|ico|svg|woff|ttf|eot|pdf|zip|tar|gz|exe|dll|so|dylib)$') { continue }

                    try {
                        $content = & git -C $clonePath show "${commitSha}:${filePath}" 2>$null
                    } catch { continue }
                    if (-not $content) { continue }

                    $lineNum = 0
                    foreach ($line in $content) {
                        $lineNum++
                        if ($line -match $kwRegex) {
                            $val = $Matches[1]
                            if ([string]::IsNullOrWhiteSpace($val)) { continue }
                            $val = $val.Trim()
                            $val = $val -replace '[,;\s]+$', ''
                            $val = $val -replace '^[''"` ]+', '' -replace '[''"` ]+$', ''
                            $val = $val.Trim()
                            if ($val.Length -lt 4) { continue }

                            # Check placeholder
                            $skip = $false
                            $valLower = $val.ToLower().Trim()
                            if ($valLower.Length -le 20) {
                                foreach ($ph in $phValues) {
                                    if ($valLower -eq $ph.ToLower()) { $skip = $true; break }
                                }
                            }
                            if ($skip) { continue }
                            # Skip template variables like ${{ }}, ${}, %%, <% %>
                            if ($val -match '^\$\{\{|^\$\{|^%%|^\<\%|^\{\{') { continue }

                            # Extract variable name from line
                            $secretName = 'DETECTED_SECRET'
                            if ($line -match '^\s*[''"]*([A-Za-z_][A-Za-z0-9_]*)[''"]*\s*[:=]') {
                                $secretName = $Matches[1].ToUpper()
                            }

                            # Get commit metadata
                            $commitAuthor = & git -C $clonePath log -1 --format='%ae' $commitSha 2>$null
                            $commitDate   = & git -C $clonePath log -1 --format='%aI' $commitSha 2>$null

                            $kwCount++
                            $findings.Add([PSCustomObject]@{
                                Repo        = $repo.Name
                                SecretName  = $secretName
                                SecretValue = $val
                                File        = $filePath
                                LineNumber  = $lineNum
                                Branch      = 'HISTORY'
                                CommitHash  = $commitSha.Substring(0, [Math]::Min(12, $commitSha.Length))
                                Source      = 'keyword'
                                RuleID      = 'KEYWORD_SCAN'
                                Author      = $commitAuthor
                                Date        = $commitDate
                            })
                        }
                    }
                }
            }
        }
    }
    catch {
        Write-Warning "  Keyword scan failed for ${repoLabel}: $_"
    }

    $total = $thCount + $kwCount
    if ($total -gt 0) {
        Write-Warning "  SECRETS FOUND: $total finding(s) in $repoLabel (trufflehog: $thCount, keywords: $kwCount)"
        $summary.Add([PSCustomObject]@{ Name = $repo.Name; SizeMB = $repo.SizeMB; TruffleHogFindings = $thCount; KeywordFindings = $kwCount; TotalFindings = $total; Status = "SECRETS_FOUND" })
    }
    else {
        Write-Host "  CLEAN — $repoLabel" -ForegroundColor Green
        $summary.Add([PSCustomObject]@{ Name = $repo.Name; SizeMB = $repo.SizeMB; TruffleHogFindings = 0; KeywordFindings = 0; TotalFindings = 0; Status = "CLEAN" })
    }

    # Cleanup clone
    if (Test-Path $clonePath) {
        Remove-Item $clonePath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$stopwatch.Stop()

# ── Final cleanup ────────────────────────────────────────────────────────────
if (Test-Path $cloneDir) { Remove-Item $cloneDir -Recurse -Force -ErrorAction SilentlyContinue }

# ── Convert to arrays ────────────────────────────────────────────────────────
$repoSummaryArr = @($repoSummary.ToArray())
$allFindingsArr = @($allFindings.ToArray())

# ── Reports ──────────────────────────────────────────────────────────────────
$summaryJson  = Join-Path $reportDir "secret-scan-summary${fileSuffix}.json"
$findingsJson = Join-Path $reportDir "secret-scan-findings${fileSuffix}.json"

if ($repoSummaryArr.Count -gt 0) { $repoSummaryArr | ConvertTo-Json -Depth 3 | Out-File $summaryJson -Encoding utf8 } else { "[]" | Out-File $summaryJson -Encoding utf8 }
if ($allFindingsArr.Count -gt 0) { $allFindingsArr | ConvertTo-Json -Depth 5 | Out-File $findingsJson -Encoding utf8 } else { "[]" | Out-File $findingsJson -Encoding utf8 }

# ── HTML Report ──────────────────────────────────────────────────────────────
$htmlPath     = Join-Path $reportDir "secret-scan-report${fileSuffix}.html"
$cleanCount   = @($repoSummaryArr | Where-Object Status -eq 'CLEAN').Count
$secretsCount = @($repoSummaryArr | Where-Object Status -eq 'SECRETS_FOUND').Count
$errorCount   = @($repoSummaryArr | Where-Object Status -eq 'SCAN_ERROR').Count
$failedCount  = @($repoSummaryArr | Where-Object Status -eq 'CLONE_FAILED').Count

$tableRows = ($repoSummaryArr | Sort-Object Status, Name | ForEach-Object {
    $statusColor = switch ($_.Status) {
        'CLEAN'         { '#27ae60' }
        'SECRETS_FOUND' { '#e74c3c' }
        'SCAN_ERROR'    { '#f39c12' }
        'CLONE_FAILED'  { '#95a5a6' }
        default         { '#333' }
    }
    "<tr><td>$([System.Net.WebUtility]::HtmlEncode($_.Name))</td><td>$($_.SizeMB)</td><td>$($_.TruffleHogFindings)</td><td>$($_.KeywordFindings)</td><td>$($_.TotalFindings)</td><td style='color:$statusColor;font-weight:bold'>$($_.Status)</td></tr>"
}) -join "`n"

$html = @"
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Secret Scan Report [$SizeFilter]</title>
<style>
  body { font-family: 'Segoe UI', sans-serif; margin: 20px; background: #f5f5f5; }
  h1 { color: #2c3e50; } h2 { color: #34495e; }
  .summary { display: flex; gap: 15px; margin: 15px 0; flex-wrap: wrap; }
  .card { padding: 15px 25px; border-radius: 8px; color: #fff; font-size: 1.1em; min-width: 120px; }
  .card .num { font-size: 2em; font-weight: bold; }
  table { border-collapse: collapse; width: 100%; background: #fff; margin-top: 10px; }
  th, td { border: 1px solid #ddd; padding: 8px 12px; text-align: left; }
  th { background: #2c3e50; color: #fff; }
  tr:nth-child(even) { background: #f9f9f9; }
  .elapsed { color: #7f8c8d; font-size: 0.9em; margin-top: 5px; }
</style></head><body>
<h1>Secret Scan Report [$SizeFilter]</h1>
<p class="elapsed">Scanned $($repoSummaryArr.Count) repos in $($stopwatch.Elapsed.ToString('hh\:mm\:ss')) | ThrottleLimit=$ThrottleLimit | Mirror clone (all branches + history)</p>
<div class="summary">
  <div class="card" style="background:#27ae60"><div class="num">$cleanCount</div>Clean</div>
  <div class="card" style="background:#e74c3c"><div class="num">$secretsCount</div>Secrets Found</div>
  <div class="card" style="background:#f39c12"><div class="num">$errorCount</div>Errors</div>
  <div class="card" style="background:#95a5a6"><div class="num">$failedCount</div>Clone Failed</div>
</div>
<h2>Repo Details</h2>
<table><tr><th>Repo</th><th>Size (MB)</th><th>TruffleHog</th><th>Keywords</th><th>Total</th><th>Status</th></tr>
$tableRows
</table>
</body></html>
"@
$html | Out-File $htmlPath -Encoding utf8

Write-Host "`n=== Secret Scan Summary [$SizeFilter] ===" -ForegroundColor Green
Write-Host "  Elapsed time        : $($stopwatch.Elapsed.ToString('hh\:mm\:ss'))"
Write-Host "  Total repos scanned : $($repoSummaryArr.Count)"
Write-Host "  Clean               : $cleanCount"
Write-Host "  Secrets found       : $secretsCount"
Write-Host "  Scan errors         : $errorCount"
Write-Host "  Clone failed        : $failedCount"
Write-Host "  Total findings      : $($allFindingsArr.Count)"

$dirty = @($repoSummaryArr | Where-Object { $_.Status -eq 'SECRETS_FOUND' })
if ($dirty) {
    Write-Host "`nRepos requiring secret scrubbing BEFORE migration:" -ForegroundColor Red
    $dirty | Format-Table Name, TruffleHogFindings, KeywordFindings, TotalFindings -AutoSize
    Write-Host "Run 02-prep\scrub-secrets.ps1 to clean these repos."
}

Write-Host "`nReports saved:"
Write-Host "  Summary  : $summaryJson"
Write-Host "  Findings : $findingsJson"
Write-Host "  HTML     : $htmlPath"
Write-Host "`nNext step: Run 02-prep\install-tools.ps1, then 02-prep\scrub-secrets.ps1"
