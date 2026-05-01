<#
.SYNOPSIS
    Scans repos for exposed secrets using gitleaks + keyword pattern matching.
.DESCRIPTION
    For each repo in repo-inventory.json:
      1. Full clone (all branches, complete history)
      2. Run gitleaks detect across all branches/history
      3. Run keyword-based regex scan for common secret patterns
         (key, password, token, secret, id, credential, etc.)
      4. Consolidate into a detailed JSON with:
         - SecretName, SecretValue, File, LineNumber, Branch, CommitID, RuleID
      5. Publish JSON artifact for downstream scrubbing.
.PARAMETER ConfigPath
    Path to repo-migration-config.json
.PARAMETER ThrottleLimit
    Max parallel repo scans (default: 5)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "$PSScriptRoot\..\config\repo-migration-config.json",

    [Parameter(Mandatory = $false)]
    [int]$ThrottleLimit = 5,

    [Parameter(Mandatory = $false)]
    [string]$RepoName = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Fallback for RepoName from environment if not passed or passed as token
if ([string]::IsNullOrWhiteSpace($RepoName) -or $RepoName -eq '$(ADO_Repo)') {
    if (-not [string]::IsNullOrWhiteSpace($env:ADO_Repo)) {
        $RepoName = $env:ADO_Repo
    }
}

$config    = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$reportDir = $config.output.reportDir
$logDir    = $config.output.logDir
$cloneDir  = $config.migration.cloneTempDir

# --- Expand tokens if still present (fallback) ---
foreach ($var in @('reportDir', 'logDir', 'cloneDir')) {
    $val = Get-Variable $var -ValueOnly
    if ($val -match '\$\(([^)]+)\)') {
        $varName = $Matches[1]
        $envVal = Get-Item -Path "Env:$varName" -ErrorAction SilentlyContinue
        if ($envVal) {
            Set-Variable -Name $var -Value ($val -replace '\$\([^)]+\)', $envVal.Value)
        }
    }
}

# If they are still tokens or empty, provide defaults
if ($reportDir -match '\$\(' -or [string]::IsNullOrWhiteSpace($reportDir)) { $reportDir = "output\reports" }
if ($logDir    -match '\$\(' -or [string]::IsNullOrWhiteSpace($logDir))    { $logDir    = "output\logs" }
if ($cloneDir  -match '\$\(' -or [string]::IsNullOrWhiteSpace($cloneDir))  { $cloneDir  = "output\tmp\clones" }

foreach ($d in @($reportDir, $logDir, $cloneDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ------ Verify gitleaks ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
$gl = Get-Command gitleaks -ErrorAction SilentlyContinue
if (-not $gl) {
    Write-Error "gitleaks not found. Install: https://github.com/gitleaks/gitleaks/releases"
}

# ------ Resolve PAT first (needed for both inventory load and API fallback) -----
$adoPat = if ($config.source.pat -eq '$(ADO_PAT)') { $env:ADO_PAT } else { $config.source.pat }
if ([string]::IsNullOrWhiteSpace($adoPat)) { Write-Error "Set ADO_PAT environment variable" }

# ------ Load inventory (or fetch from API if discover-repos was skipped) --------
$inventoryPath = Join-Path $reportDir "repo-inventory.json"
if (Test-Path $inventoryPath) {
    Write-Host "Loading repo inventory from $inventoryPath" -ForegroundColor Cyan
    $repos = @(Get-Content $inventoryPath -Raw | ConvertFrom-Json)
} else {
    Write-Host "repo-inventory.json not found - fetching repos directly from ADO API..." -ForegroundColor Yellow
    $adoOrg  = if ($config.source.organization -eq '$(ADO_Org)') { $env:ADO_Org } else { $config.source.organization }
    $adoProj = if ($config.source.project -eq '$(ADO_Project)') { $env:ADO_Project } else { $config.source.project }
    
    if ([string]::IsNullOrWhiteSpace($adoOrg)) { Write-Error "ADO Organization not found (config or environment)" }
    if ([string]::IsNullOrWhiteSpace($adoProj)) { Write-Error "ADO Project not found (config or environment)" }

    # If org is just the name (e.g. "YashTech-DevOps"), prepend the base URL
    if ($adoOrg -and $adoOrg -notmatch '^https?://') {
        $adoOrg = "https://dev.azure.com/$adoOrg"
    }
    Write-Host "  ADO Org URL: $adoOrg" -ForegroundColor Gray
    Write-Host "  ADO Project: $adoProj" -ForegroundColor Gray
    $base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":${adoPat}"))
    $headers = @{
        Authorization  = "Basic $base64Auth"
        Accept         = "application/json"
        "Content-Type" = "application/json"
    }
    $repoApiUrl = "${adoOrg}/${adoProj}/_apis/git/repositories?api-version=7.1"
    $response = Invoke-RestMethod -Uri $repoApiUrl -Headers $headers -Method Get
    $repos = @($response.value | ForEach-Object {
        [PSCustomObject]@{
            Project   = $adoProj
            Name      = $_.name
            Id        = $_.id
            SizeMB    = [math]::Round($_.size / 1MB, 2)
            SizeGB    = [math]::Round($_.size / 1GB, 2)
            RemoteUrl = $_.remoteUrl
            Url       = $_.webUrl
        }
    })
    Write-Host "  Found $($repos.Count) repos from API" -ForegroundColor Green
    # Save for downstream use
    $repos | ConvertTo-Json -Depth 5 | Out-File $inventoryPath -Encoding utf8
}

# Keep original list for filtering and error reporting
$allRepos = $repos

# Filter by RepoName if provided
if (-not [string]::IsNullOrWhiteSpace($RepoName)) {
    $trimmedRepo = $RepoName.Trim()
    Write-Host "Filtering scan to single repo: $trimmedRepo" -ForegroundColor Cyan
    $repos = @($repos | Where-Object { $_.Name -ieq $trimmedRepo })
    if ($repos.Count -eq 0) {
        $available = ($allRepos | Select-Object -First 5 -ExpandProperty Name) -join ", "
        Write-Error "Repository '$trimmedRepo' not found in ADO project inventory. Available repos (first 5): $available. Please check the name in your variable group."
    }
}

# Keep a reference to original list for error reporting above
# (I need to ensure $allRepos is defined)

# Skip empty repos (but only if we didn't specifically target one)
if ([string]::IsNullOrWhiteSpace($RepoName)) {
    $beforeCount = $repos.Count
    $repos = @($repos | Where-Object { $_.SizeMB -gt 0 })
    $afterCount = $repos.Count
    if ($beforeCount -ne $afterCount) {
        Write-Host "  Skipped $($beforeCount - $afterCount) empty repositories." -ForegroundColor Gray
    }
}

$repos = @($repos | Sort-Object { $_.SizeMB })

Write-Host "=== Scanning $($repos.Count) repos for secrets (ThrottleLimit=$ThrottleLimit) ===" -ForegroundColor Cyan

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# ------ Thread-safe collections ------------------------------------------------------------------------------------------------------------------------------------------------------
$allSecrets  = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()
$repoSummary = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()

# ------ Keyword patterns for additional scanning ---------------------------------------------------------------------------------------------------
# These catch secrets that gitleaks might miss --- simple key=value assignments
# with common secret-related keywords.
$keywordPatternsRaw = @(
    # Pattern: KEYWORD = "value" or KEYWORD: "value" or KEYWORD = 'value'
    '(?i)(password|passwd|pwd)\s*[=:]\s*["\u0027]([^"\u0027\s]{4,})["\u0027]'
    '(?i)(api[_-]?key|apikey)\s*[=:]\s*["\u0027]([^"\u0027\s]{4,})["\u0027]'
    '(?i)(secret[_-]?key|secretkey)\s*[=:]\s*["\u0027]([^"\u0027\s]{4,})["\u0027]'
    '(?i)(access[_-]?key|accesskey)\s*[=:]\s*["\u0027]([^"\u0027\s]{4,})["\u0027]'
    '(?i)(auth[_-]?token|authtoken)\s*[=:]\s*["\u0027]([^"\u0027\s]{4,})["\u0027]'
    '(?i)(token)\s*[=:]\s*["\u0027]([^"\u0027\s]{8,})["\u0027]'
    '(?i)(private[_-]?key|privatekey)\s*[=:]\s*["\u0027]([^"\u0027\s]{4,})["\u0027]'
    '(?i)(client[_-]?secret|clientsecret)\s*[=:]\s*["\u0027]([^"\u0027\s]{4,})["\u0027]'
    '(?i)(connection[_-]?string|connectionstring)\s*[=:]\s*["\u0027]([^"\u0027\s]{8,})["\u0027]'
    '(?i)(credential|cred)\s*[=:]\s*["\u0027]([^"\u0027\s]{4,})["\u0027]'
    '(?i)(signing[_-]?key|signingkey)\s*[=:]\s*["\u0027]([^"\u0027\s]{4,})["\u0027]'
    '(?i)(encryption[_-]?key|encryptionkey)\s*[=:]\s*["\u0027]([^"\u0027\s]{4,})["\u0027]'
    '(?i)(db[_-]?password|dbpassword)\s*[=:]\s*["\u0027]([^"\u0027\s]{4,})["\u0027]'
    '(?i)(smtp[_-]?password|smtppassword)\s*[=:]\s*["\u0027]([^"\u0027\s]{4,})["\u0027]'
    '(?i)(bearer)\s+([A-Za-z0-9\-_\.]{20,})'
)

# ------ Parallel scan ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
$repos | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
    $repo     = $_
    $cloneDir = $using:cloneDir
    $logDir   = $using:logDir
    $adoPat   = $using:adoPat
    $secrets  = $using:allSecrets
    $summary  = $using:repoSummary
    $kwPatterns = $using:keywordPatternsRaw

    $repoLabel = "[$($repo.Project)] $($repo.Name)"
    $clonePath = Join-Path $cloneDir "$($repo.Name)-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $gitleaksReport = Join-Path $logDir "gitleaks-$($repo.Name).json"

    # ------ 1. Full clone (all branches, all history) ------------------------------------------------------------------------
    $cloneUrl   = $repo.RemoteUrl -replace '://[^@]+@', '://'
    $base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("pat:${adoPat}"))

    try {
        $env:GIT_LFS_SKIP_SMUDGE = '1'
        Write-Host "  Cloning $repoLabel --- full history ($($repo.SizeMB) MB)" -ForegroundColor Gray
        $cloneArgs = @('-c', "http.extraHeader=Authorization: Basic $base64Auth",
                       '-c', 'lfs.fetchexclude=*',
                       'clone', '--mirror', '--quiet', $cloneUrl, $clonePath)
        $cloneOutput = & git @cloneArgs 2>&1
        if ($LASTEXITCODE -ne 0) { throw ($cloneOutput | Out-String) }
    }
    catch {
        Write-Warning "  Clone failed for ${repoLabel}: $_"
        $summary.Add([PSCustomObject]@{
            Project = $repo.Project; Name = $repo.Name; SizeMB = $repo.SizeMB
            GitleaksFindings = 0; KeywordFindings = 0; TotalFindings = 0; Status = "CLONE_FAILED"
        })
        return
    }

    # ------ 2. Get all branches ------------------------------------------------------------------------------------------------------------------------------------------
    $branches = @()
    try {
        Push-Location $clonePath
        $branchLines = & git branch -a 2>&1 | ForEach-Object { $_.Trim() -replace '^\*\s*', '' -replace '^remotes/origin/', '' }
        $branches = @($branchLines | Where-Object { $_ -and $_ -notmatch 'HEAD' } | Select-Object -Unique)
        Pop-Location
    }
    catch {
        $branches = @("main", "master")
        if (Test-Path (Join-Path $clonePath "HEAD")) { Pop-Location }
    }

    Write-Host "  ${repoLabel}: Found $($branches.Count) branches" -ForegroundColor Gray

    # ------ 3. Run gitleaks (scans entire history across all refs) ------------------------------------
    $gitleaksCount = 0
    $gitleaksExitCode = 0
    try {
        $output = & gitleaks detect --source $clonePath --report-path $gitleaksReport --report-format json --no-banner 2>&1
        $gitleaksExitCode = $LASTEXITCODE
    }
    catch {
        $gitleaksExitCode = $LASTEXITCODE
    }

    if ($gitleaksExitCode -eq 1 -and (Test-Path $gitleaksReport)) {
        $gitleaksFindings = @(Get-Content $gitleaksReport -Raw | ConvertFrom-Json)
        $gitleaksCount = $gitleaksFindings.Count

        foreach ($f in $gitleaksFindings) {
            # Extract key name from the match context
            $keyName = ""
            if ($f.Match -match '(?i)([A-Z_][A-Z0-9_]*)\s*[=:]') {
                $keyName = $Matches[1]
            } else {
                $keyName = $f.RuleID
            }
            $secretName = $keyName.ToUpper() -replace "[^A-Z0-9_]", "_"
            if ([string]::IsNullOrWhiteSpace($secretName)) { $secretName = "SECRET" }
            if ($secretName -match "^\d") { $secretName = "S_$secretName" }

            # Determine branch from commit
            $branchName = "unknown"
            try {
                Push-Location $clonePath
                $brOut = & git branch --contains $f.Commit 2>&1 | Select-Object -First 1
                if ($brOut) { $branchName = ($brOut.Trim() -replace '^\*\s*', '').Trim() }
                Pop-Location
            }
            catch {
                if (Test-Path (Join-Path $clonePath "HEAD")) { Pop-Location }
            }

            $secrets.Add([PSCustomObject]@{
                Source       = "gitleaks"
                Project      = $repo.Project
                Repo         = $repo.Name
                SecretName   = $secretName
                SecretValue  = $f.Secret
                RuleID       = $f.RuleID
                File         = $f.File
                LineNumber   = $f.StartLine
                Branch       = $branchName
                CommitID     = $f.Commit
                Author       = $f.Author
                Date         = $f.Date
                Match        = $f.Match
                Description  = $f.Description
            })
        }
    }
    elseif ($gitleaksExitCode -eq 0) {
        Write-Host "  gitleaks CLEAN --- $repoLabel" -ForegroundColor Green
    }
    else {
        Write-Warning "  gitleaks error (exit=$gitleaksExitCode) for $repoLabel"
    }

    # ------ 4. Keyword-based regex scan (per branch, per file) ---------------------------------------------
    $keywordCount = 0

    foreach ($branch in $branches) {
        try {
            Push-Location $clonePath
            # List all tracked files on this branch
            $fileList = & git ls-tree -r --name-only $branch 2>&1
            if ($LASTEXITCODE -ne 0) { Pop-Location; continue }

            foreach ($filePath in $fileList) {
                # Skip binary-looking extensions
                if ($filePath -match '\.(png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot|zip|tar|gz|dll|exe|bin|pdf|mp4|mp3|wav)$') {
                    continue
                }

                # Get file content from git
                $fileContent = & git show "${branch}:${filePath}" 2>&1
                if ($LASTEXITCODE -ne 0) { continue }

                $lineNum = 0
                foreach ($line in ($fileContent -split "`n")) {
                    $lineNum++
                    foreach ($pattern in $kwPatterns) {
                        if ($line -match $pattern) {
                            $keyName  = $Matches[1]
                            $secretVal = $Matches[2]

                            # Skip placeholders and short values
                            $lowerVal = $secretVal.ToLower()
                            $placeholders = @('changeme','password','secret','example','placeholder',
                                'your-secret-here','your-password-here','your-token-here',
                                'xxxxxxxx','test1234','abcdefgh','changeit','replace_me',
                                'todo_replace','none','null','undefined','default','required',
                                'optional','insert_here','change_me','xxx','yyy','zzz')
                            if ($placeholders -contains $lowerVal) { continue }

                            # Get the commit that last touched this line
                            $commitId = "HEAD"
                            try {
                                $blameLine = & git blame -L "${lineNum},${lineNum}" "${branch}" -- $filePath 2>&1 | Select-Object -First 1
                                if ($blameLine -match '^([0-9a-f]+)') {
                                    $commitId = $Matches[1]
                                }
                            }
                            catch { }

                            $secretName = $keyName.ToUpper() -replace "[^A-Z0-9_]", "_"
                            if ([string]::IsNullOrWhiteSpace($secretName)) { $secretName = "SECRET" }
                            if ($secretName -match "^\d") { $secretName = "S_$secretName" }

                            $keywordCount++
                            $secrets.Add([PSCustomObject]@{
                                Source       = "keyword-scan"
                                Project      = $repo.Project
                                Repo         = $repo.Name
                                SecretName   = $secretName
                                SecretValue  = $secretVal
                                RuleID       = "keyword-$($keyName.ToLower())"
                                File         = $filePath
                                LineNumber   = $lineNum
                                Branch       = $branch
                                CommitID     = $commitId
                                Author       = ""
                                Date         = ""
                                Match        = $line.Trim()
                                Description  = "Keyword pattern match: $keyName"
                            })
                        }
                    }
                }
            }
            Pop-Location
        }
        catch {
            Write-Warning "  Keyword scan failed for branch $branch in ${repoLabel}: $_"
            if (Test-Path (Join-Path $clonePath "HEAD")) { Pop-Location }
        }
    }

    # ------ 5. Summary ---------------------------------------------------------------------------------------------------------------------------------------------------------------------
    $totalFindings = $gitleaksCount + $keywordCount
    $status = if ($totalFindings -gt 0) { "SECRETS_FOUND" } else { "CLEAN" }

    if ($totalFindings -gt 0) {
        Write-Warning "  SECRETS FOUND: $totalFindings ($gitleaksCount gitleaks + $keywordCount keyword) in $repoLabel"
    }

    $summary.Add([PSCustomObject]@{
        Project = $repo.Project; Name = $repo.Name; SizeMB = $repo.SizeMB
        GitleaksFindings = $gitleaksCount; KeywordFindings = $keywordCount
        TotalFindings = $totalFindings; Status = $status
    })

    # Cleanup clone
    if (Test-Path $clonePath) {
        Remove-Item $clonePath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$stopwatch.Stop()

# ------ Final cleanup ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
if (Test-Path $cloneDir) { Remove-Item $cloneDir -Recurse -Force -ErrorAction SilentlyContinue }

# ------ Convert to arrays ------------------------------------------------------------------------------------------------------------------------------------------------------------------------
$repoSummaryArr = @($repoSummary.ToArray())
$allSecretsArr  = @($allSecrets.ToArray())

# ------ Deduplicate secrets (same value in same file = keep one) ---------------------------------------------------
$uniqueSecrets = @()
$seenKeys = @{}
foreach ($s in $allSecretsArr) {
    $dedupKey = "$($s.Repo)|$($s.File)|$($s.LineNumber)|$($s.SecretValue)"
    if (-not $seenKeys.ContainsKey($dedupKey)) {
        $seenKeys[$dedupKey] = $true
        $uniqueSecrets += $s
    }
}

# ------ Auto-increment duplicate secret names ------------------------------------------------------------------------------------------------------------
$nameCounter = @{}
foreach ($s in $uniqueSecrets) {
    $baseName = $s.SecretName
    if ($nameCounter.ContainsKey($baseName)) {
        $nameCounter[$baseName]++
        $s.SecretName = "${baseName}_$($nameCounter[$baseName])"
    } else {
        $nameCounter[$baseName] = 1
    }
}

# ------ Save JSON reports ------------------------------------------------------------------------------------------------------------------------------------------------------------------------
$summaryJson  = Join-Path $reportDir "secret-scan-summary.json"
$findingsJson = Join-Path $reportDir "secret-scan-findings.json"

$repoSummaryArr | ConvertTo-Json -Depth 3 | Out-File $summaryJson  -Encoding utf8
$uniqueSecrets  | ConvertTo-Json -Depth 5 | Out-File $findingsJson -Encoding utf8

# ------ HTML Report ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
$htmlPath     = Join-Path $reportDir "secret-scan-report.html"
$cleanCount   = @($repoSummaryArr | Where-Object Status -eq 'CLEAN').Count
$secretsCount = @($repoSummaryArr | Where-Object Status -eq 'SECRETS_FOUND').Count
$errorCount   = @($repoSummaryArr | Where-Object Status -eq 'SCAN_ERROR').Count
$failedCount  = @($repoSummaryArr | Where-Object Status -eq 'CLONE_FAILED').Count

$findingsTableRows = ""
foreach ($s in ($uniqueSecrets | Sort-Object Repo, File, LineNumber)) {
    $maskedVal = if ($s.SecretValue.Length -le 8) { "***" }
                 else { $s.SecretValue.Substring(0, 3) + ("*" * [Math]::Max(1, $s.SecretValue.Length - 6)) + $s.SecretValue.Substring($s.SecretValue.Length - 3) }
    $findingsTableRows += "<tr>"
    $findingsTableRows += "<td>$([System.Net.WebUtility]::HtmlEncode($s.Repo))</td>"
    $findingsTableRows += "<td>$([System.Net.WebUtility]::HtmlEncode($s.SecretName))</td>"
    $findingsTableRows += "<td><code>$([System.Net.WebUtility]::HtmlEncode($maskedVal))</code></td>"
    $findingsTableRows += "<td>$([System.Net.WebUtility]::HtmlEncode($s.File))</td>"
    $findingsTableRows += "<td>$($s.LineNumber)</td>"
    $findingsTableRows += "<td>$([System.Net.WebUtility]::HtmlEncode($s.Branch))</td>"
    $findingsTableRows += "<td><code>$($s.CommitID.Substring(0, [Math]::Min(8, $s.CommitID.Length)))</code></td>"
    $findingsTableRows += "<td>$([System.Net.WebUtility]::HtmlEncode($s.Source))</td>"
    $findingsTableRows += "<td>$([System.Net.WebUtility]::HtmlEncode($s.RuleID))</td>"
    $findingsTableRows += "</tr>`n"
}

$summaryTableRows = ($repoSummaryArr | Sort-Object Status, Name | ForEach-Object {
    $statusColor = switch ($_.Status) {
        'CLEAN'         { '#27ae60' }
        'SECRETS_FOUND' { '#e74c3c' }
        'SCAN_ERROR'    { '#f39c12' }
        'CLONE_FAILED'  { '#95a5a6' }
        default         { '#333' }
    }
    "<tr><td>$([System.Net.WebUtility]::HtmlEncode($_.Project))</td><td>$([System.Net.WebUtility]::HtmlEncode($_.Name))</td><td>$($_.SizeMB)</td><td>$($_.GitleaksFindings)</td><td>$($_.KeywordFindings)</td><td>$($_.TotalFindings)</td><td style='color:$statusColor;font-weight:bold'>$($_.Status)</td></tr>"
}) -join "`n"

$html = @"
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Secret Scan Report</title>
<style>
  body { font-family: 'Segoe UI', sans-serif; margin: 20px; background: #0d1117; color: #c9d1d9; }
  h1 { color: #58a6ff; } h2 { color: #c9d1d9; margin-top: 24px; }
  .summary { display: flex; gap: 15px; margin: 15px 0; flex-wrap: wrap; }
  .card { padding: 15px 25px; border-radius: 8px; color: #fff; font-size: 1.1em; min-width: 140px; }
  .card .num { font-size: 2em; font-weight: bold; }
  table { border-collapse: collapse; width: 100%; background: #161b22; margin-top: 10px; border-radius: 8px; overflow: hidden; }
  th { background: #1f2937; color: #58a6ff; padding: 10px 12px; text-align: left; font-size: 13px; }
  td { border-bottom: 1px solid #21262d; padding: 8px 12px; font-size: 14px; }
  tr:hover { background: #1c2128; }
  code { background: #1f2937; padding: 2px 6px; border-radius: 4px; font-size: 13px; color: #79c0ff; }
  .elapsed { color: #8b949e; font-size: 0.9em; margin-top: 5px; }
  .footer { text-align: center; padding: 20px; color: #484f58; font-size: 12px; }
</style></head><body>
<h1>&#128270; Secret Scan Report</h1>
<p class="elapsed">Scanned $($repoSummaryArr.Count) repos in $($stopwatch.Elapsed.ToString('hh\:mm\:ss')) | ThrottleLimit=$ThrottleLimit | Full clone (all branches, complete history)</p>
<div class="summary">
  <div class="card" style="background:#27ae60"><div class="num">$cleanCount</div>Clean</div>
  <div class="card" style="background:#e74c3c"><div class="num">$secretsCount</div>Secrets Found</div>
  <div class="card" style="background:#f39c12"><div class="num">$errorCount</div>Errors</div>
  <div class="card" style="background:#95a5a6"><div class="num">$failedCount</div>Clone Failed</div>
  <div class="card" style="background:#58a6ff"><div class="num">$($uniqueSecrets.Count)</div>Total Unique Secrets</div>
</div>
<h2>Repo Summary</h2>
<table><tr><th>Project</th><th>Repo</th><th>Size (MB)</th><th>Gitleaks</th><th>Keyword</th><th>Total</th><th>Status</th></tr>
$summaryTableRows
</table>
<h2>Secret Findings Detail</h2>
<table><tr><th>Repo</th><th>Secret Name</th><th>Value (masked)</th><th>File</th><th>Line</th><th>Branch</th><th>Commit</th><th>Source</th><th>Rule</th></tr>
$findingsTableRows
</table>
<div class="footer">Generated by ADO-to-GitHub Migration Accelerator | Secret values are stored in secret-scan-findings.json</div>
</body></html>
"@
$html | Out-File $htmlPath -Encoding utf8

# ------ Console Summary ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
Write-Host "`n=== Secret Scan Summary ===" -ForegroundColor Green
Write-Host "  Elapsed time        : $($stopwatch.Elapsed.ToString('hh\:mm\:ss'))"
Write-Host "  Total repos scanned : $($repoSummaryArr.Count)"
Write-Host "  Clean               : $cleanCount"
Write-Host "  Secrets found       : $secretsCount"
Write-Host "  Scan errors         : $errorCount"
Write-Host "  Clone failed        : $failedCount"
Write-Host "  Total unique secrets: $($uniqueSecrets.Count)"

$dirty = @($repoSummaryArr | Where-Object { $_.Status -eq 'SECRETS_FOUND' })
if ($dirty) {
    Write-Host "`nRepos requiring secret scrubbing BEFORE migration:" -ForegroundColor Red
    $dirty | Format-Table Name, GitleaksFindings, KeywordFindings, TotalFindings -AutoSize
    Write-Host "Run 02-prep\scrub-secrets.ps1 to clean these repos."
}

Write-Host "`nReports saved:"
Write-Host "  Summary  : $summaryJson"
Write-Host "  Findings : $findingsJson"
Write-Host "  HTML     : $htmlPath"
Write-Host "`nNext step: Run 02-prep\scrub-secrets.ps1"



