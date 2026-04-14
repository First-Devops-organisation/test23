<#
.SYNOPSIS
    Validates migrated repos — compares ADO source vs GitHub target.
    Works for both Single repo and Batch (reads from batch-migration-summary.json
    or a supplied repo list).
.DESCRIPTION
    Per-repo checks:
      1.  Repo exists on GitHub
      2.  Branch count matches ADO
      3.  Missing branches listed
      4.  Default branch matches
      5.  Tag count matches
      6.  PR count within tolerance (±2)
      7.  Repo visibility = expected value
      8.  Latest commit hash reachable on GitHub
      9.  Branch protection rules exist on default branch
    Generates:
      - validation-results.json  (machine-readable)
      - validation-results.csv
      - validation-report.html   (HTML dashboard)
      - validation-summary.md    (ADO pipeline summary tab)
.PARAMETER ADOOrg
    Azure DevOps organisation name
.PARAMETER ADOProject
    Azure DevOps project name
.PARAMETER GHOrg
    Target GitHub organisation name
.PARAMETER GHRepo
    Single repo to validate (omit to validate ALL repos from batch summary)
.PARAMETER ADORepo
    ADO source repo name when validating single repo (defaults to GHRepo)
.PARAMETER OutputDir
    Directory containing audit data and where reports are saved (default: ./output)
.PARAMETER ExpectedVisibility
    Expected GitHub repo visibility: internal | private | public  (default: internal)
.PARAMETER BatchSummaryJson
    Path to batch-migration-summary.json — used when GHRepo is not specified
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]  [string]$ADOOrg,
    [Parameter(Mandatory = $true)]  [string]$ADOProject,
    [Parameter(Mandatory = $true)]  [string]$GHOrg,
    [Parameter(Mandatory = $false)] [string]$GHRepo,
    [Parameter(Mandatory = $false)] [string]$ADORepo,
    [Parameter(Mandatory = $false)] [string]$OutputDir         = "$PSScriptRoot\..\output",
    [Parameter(Mandatory = $false)] [string]$ExpectedVisibility = "internal",
    [Parameter(Mandatory = $false)] [string]$BatchSummaryJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Normalize ADOOrg — strip full URL if passed as https://dev.azure.com/<org> ──
if ($ADOOrg -match '^https?://dev\.azure\.com/([^/]+)/?$') {
    Write-Host "  Normalising ADOOrg: stripping URL prefix → '$($Matches[1])'"
    $ADOOrg = $Matches[1]
}

# ── Validate PATs ────────────────────────────────────────────────────────────
$adoPat = $env:ADO_PAT
$ghPat  = $env:GH_PAT
if ([string]::IsNullOrWhiteSpace($adoPat)) { Write-Error "Set ADO_PAT environment variable" }
if ([string]::IsNullOrWhiteSpace($ghPat))  { Write-Error "Set GH_PAT environment variable" }

$adoBase64  = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$adoPat"))
$adoHeaders = @{ Authorization = "Basic $adoBase64" }
$ghHeaders  = @{ Authorization = "Bearer $ghPat"; Accept = "application/vnd.github+json" }

# Set GH_TOKEN for gh CLI — more reliable than Invoke-RestMethod on PS 5.1/7
$env:GH_TOKEN = $ghPat

$reportDir = "$OutputDir\reports"
New-Item -ItemType Directory -Path $reportDir -Force | Out-Null

# ── Build repo list to validate ───────────────────────────────────────────────
$repoList = @()   # array of @{ ADORepo; GHRepo }

# Trim whitespace — pipeline parameters may pass " " (space default)
if ($GHRepo)  { $GHRepo  = $GHRepo.Trim() }
if ($ADORepo) { $ADORepo = $ADORepo.Trim() }
if ([string]::IsNullOrWhiteSpace($GHRepo) -and -not [string]::IsNullOrWhiteSpace($ADORepo)) {
    Write-Host "  GHRepo was empty — defaulting to ADORepo: '$ADORepo'"
    $GHRepo = $ADORepo
}

if (-not [string]::IsNullOrWhiteSpace($GHRepo)) {
    $adoName = if ($ADORepo) { $ADORepo } else { $GHRepo }
    $repoList += @{ ADORepo = $adoName; GHRepo = $GHRepo }
}
else {
    # Load from batch summary
    $summaryPath = if ($BatchSummaryJson) { $BatchSummaryJson } else { "$reportDir\batch-migration-summary.json" }
    if (-not (Test-Path $summaryPath)) { Write-Error "Batch summary not found: $summaryPath. Specify –GHRepo for single-repo validation." }
    $summary = Get-Content $summaryPath -Raw | ConvertFrom-Json
    foreach ($entry in $summary) {
        $repoList += @{ ADORepo = $entry.ADORepo; GHRepo = $entry.GHRepo }
    }
}

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  MIGRATION VALIDATION"
Write-Host "  ADO:   $ADOOrg / $ADOProject"
Write-Host "  GitHub: $GHOrg"
Write-Host "  Repos: $($repoList.Count)"
Write-Host "============================================"

# ── Helper functions ──────────────────────────────────────────────────────────
function Get-AuditVal($auditDir, $file) {
    $p = "$auditDir\$file"
    if (Test-Path $p) { return (Get-Content $p -Raw).Trim() }
    return $null
}

# Safe property accessor — iterates properties to avoid PS 5.1 indexer bug
function Get-JsonProp($obj, [string]$name, $default = $null) {
    if ($null -eq $obj) { return $default }
    foreach ($p in $obj.PSObject.Properties) {
        if ($p.Name -eq $name) { return $p.Value }
    }
    return $default
}

$allResults  = @()
$totalPass   = 0
$totalFail   = 0
$totalWarn   = 0

foreach ($entry in $repoList) {
    $adoRepoName = $entry['ADORepo']
    $ghRepoName  = $entry['GHRepo']
    $auditDir    = "$OutputDir\audit\$ghRepoName"

    Write-Host "`n── Validating: $adoRepoName → $ghRepoName ──" -ForegroundColor Yellow

    $checks = @()

    function Add-Check($name, $sourcVal, $targVal, $pass, $detail = "") {
        $status = if ($pass) { "PASS" } else { "FAIL" }
        $check  = [PSCustomObject]@{ Check=$name; Source=$sourcVal; Target=$targVal; Status=$status; Detail=$detail }
        $script:checks += $check
        if ($pass) {
            Write-Host "    [PASS] $name" -ForegroundColor Green
            $script:totalPass++
        }
        else {
            Write-Host "    [FAIL] $name  source=[$sourcVal] target=[$targVal] $detail" -ForegroundColor Red
            $script:totalFail++
        }
    }

    function Add-Warn($name, $detail) {
        $check = [PSCustomObject]@{ Check=$name; Source="N/A"; Target="N/A"; Status="WARN"; Detail=$detail }
        $script:checks += $check
        Write-Host "    [WARN] $name — $detail" -ForegroundColor Yellow
        $script:totalWarn++
    }

    # ── 1. Repo exists on GitHub (via gh CLI — avoids PS 5.1 Invoke-RestMethod issues) ──
    $ghRepoCheck = $null
    $ErrorActionPreference = 'SilentlyContinue'
    $ghRepoCheck = gh repo view "$GHOrg/$ghRepoName" --json name --jq .name 2>&1
    $ErrorActionPreference = 'Stop'
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($ghRepoCheck)) {
        Write-Host "      [DEBUG] gh repo view failed: $ghRepoCheck" -ForegroundColor Yellow
        Add-Check "Repo Exists on GitHub" "expected" "NOT FOUND" $false
        $allResults += [PSCustomObject]@{ ADORepo=$adoRepoName; GHRepo=$ghRepoName; Status="FAIL_NOT_FOUND"; Accuracy=0; PassCount=0; FailCount=1; WarnCount=0; Checks=$checks }
        continue
    }
    Add-Check "Repo Exists on GitHub" "yes" "yes" $true

    # Fetch default branch and visibility via gh CLI (returns plain strings)
    $ghDefault    = (gh repo view "$GHOrg/$ghRepoName" --json defaultBranchRef --jq .defaultBranchRef.name 2>$null)
    $ghVisibility = (gh repo view "$GHOrg/$ghRepoName" --json visibility --jq .visibility 2>$null)
    if ($ghVisibility) { $ghVisibility = $ghVisibility.ToLower() }   # gh returns PRIVATE/INTERNAL/PUBLIC
    Write-Host "      [DEBUG] default_branch=$ghDefault  visibility=$ghVisibility" -ForegroundColor DarkGray

    # ── 2. ADO source data ───────────────────────────────────────────────────
    $adoRepoUrl  = "https://dev.azure.com/$ADOOrg/$ADOProject/_apis/git/repositories/$adoRepoName"
    $adoRepo     = $null
    $adoBranches = @()
    $adoPrCount  = 0
    $adoTags     = @()
    $adoDefault  = ""

    try {
        $adoRepo = Invoke-RestMethod -Uri "${adoRepoUrl}?api-version=7.1" -Headers $adoHeaders
        if ($adoRepo -is [string]) {
            try { $adoRepo = $adoRepo | ConvertFrom-Json } catch { $adoRepo = $null }
        }
        if ($adoRepo) {
            $rawDefault = Get-JsonProp $adoRepo 'defaultBranch' $null
            Write-Host "      [DEBUG] ADO defaultBranch raw=[$rawDefault]" -ForegroundColor DarkGray
            if ($rawDefault) {
                $adoDefault = $rawDefault -replace '^refs/heads/', ''
            }
        }
    }
    catch {
        Add-Warn "ADO API Access" "Cannot fetch ADO repo metadata: $_"
    }

    try {
        $brResp      = Invoke-RestMethod -Uri "$adoRepoUrl/refs?filter=heads/&api-version=7.1" -Headers $adoHeaders
        $adoBranches = @($brResp.value | ForEach-Object { $_.name -replace '^refs/heads/', '' })
    }
    catch { Add-Warn "ADO Branch API" "Cannot fetch ADO branches: $_" }

    try {
        $prResp     = Invoke-RestMethod -Uri "$adoRepoUrl/pullrequests?searchCriteria.status=all&api-version=7.1" -Headers $adoHeaders
        $adoPrCount = [int](Get-JsonProp $prResp 'count' 0)
    }
    catch { Add-Warn "ADO PR API" "Cannot fetch ADO PR count: $_" }

    try {
        $tagResp = Invoke-RestMethod -Uri "$adoRepoUrl/refs?filter=tags/&api-version=7.1" -Headers $adoHeaders
        $adoTags = @($tagResp.value)
    }
    catch { Add-Warn "ADO Tag API" "Cannot fetch ADO tags: $_" }

    # ── 3. GitHub branch list (via gh api — paginated) ────────────────────────
    $ghBranches = @()
    try {
        $page = 1
        do {
            $brRaw = gh api "repos/$GHOrg/$ghRepoName/branches?per_page=100&page=$page" 2>$null
            $brList = @()
            if ($brRaw) { $brList = @($brRaw | ConvertFrom-Json) }
            $ghBranches += $brList | ForEach-Object { $_.name }
            $page++
        } while ($brList.Count -eq 100)
    }
    catch { Add-Warn "GitHub Branch API" "Could not fetch branches: $_" }

    # ── 4. Branch count ──────────────────────────────────────────────────────
    $auditBranchCount = Get-AuditVal $auditDir "gh-branch-count.txt"
    $ghBranchCount    = $ghBranches.Count
    $sourceBranchCount = $adoBranches.Count
    if ($sourceBranchCount -eq 0 -and $auditBranchCount) { $sourceBranchCount = [int]$auditBranchCount }
    $branchDetail = ""
    if ($adoBranches.Count -gt 0 -or $ghBranches.Count -gt 0) {
        $branchDetail = "ADO: [$(($adoBranches | Sort-Object) -join ', ')] | GH: [$(($ghBranches | Sort-Object) -join ', ')]"
    }
    Add-Check "Branch Count" $sourceBranchCount $ghBranchCount ($sourceBranchCount -eq $ghBranchCount) $branchDetail

    # ── List branch names ─────────────────────────────────────────────────
    if ($adoBranches.Count -gt 0) {
        $adoBranchList = ($adoBranches | Sort-Object) -join ', '
        Write-Host "      ADO Branches : $adoBranchList" -ForegroundColor DarkGray
    }
    if ($ghBranches.Count -gt 0) {
        $ghBranchList = ($ghBranches | Sort-Object) -join ', '
        Write-Host "      GH  Branches : $ghBranchList" -ForegroundColor DarkGray
    }

    # ── 5. Missing branches ──────────────────────────────────────────────────
    if ($adoBranches.Count -gt 0) {
        $missing = @($adoBranches | Where-Object { $_ -notin $ghBranches })
        $extra   = @($ghBranches  | Where-Object { $_ -notin $adoBranches })
        if ($missing.Count -gt 0) {
            Add-Check "No Missing Branches" $adoBranches.Count "missing: $($missing -join ', ')" $false "Branches in ADO not found in GitHub"
        }
        else {
            Add-Check "No Missing Branches" "all present" "all present" $true
        }
        if ($extra.Count -gt 0) {
            Write-Host "      Extra in GH  : $($extra -join ', ')" -ForegroundColor DarkGray
        }
    }

    # ── 6. Default branch ────────────────────────────────────────────────────
    if ([string]::IsNullOrWhiteSpace($ghDefault)) { $ghDefault = 'N/A' }
    Write-Host "      Default Branch: ADO=[$adoDefault] GH=[$ghDefault]" -ForegroundColor DarkGray
    if ($adoDefault) {
        Add-Check "Default Branch" $adoDefault $ghDefault ($adoDefault -eq $ghDefault)
    }
    else {
        $auditDefault = Get-AuditVal $auditDir "gh-default-branch.txt"
        if ($auditDefault) { Add-Check "Default Branch (audit)" $auditDefault $ghDefault ($auditDefault -eq $ghDefault) }
        else               { Add-Warn  "Default Branch" "ADO default branch not available for comparison" }
    }

    # ── 7. Tag count ─────────────────────────────────────────────────────────
    $ghTags = @()
    $ghTagNames  = @()
    $adoTagNames = @()
    try {
        $tagRaw = gh api "repos/$GHOrg/$ghRepoName/tags?per_page=100" 2>$null
        if ($tagRaw) { $ghTags = @($tagRaw | ConvertFrom-Json) }
        $ghTagNames = @($ghTags | ForEach-Object { $_.name })
    }
    catch { }
    if ($adoTags.Count -gt 0) {
        $adoTagNames = @($adoTags | ForEach-Object { $_.name -replace '^refs/tags/', '' })
    }
    $adoTagCount = $adoTagNames.Count
    $ghTagCount  = $ghTagNames.Count

    # List tag names
    if ($adoTagNames.Count -gt 0) {
        Write-Host "      ADO Tags     : $(($adoTagNames | Sort-Object) -join ', ')" -ForegroundColor DarkGray
    }
    if ($ghTagNames.Count -gt 0) {
        Write-Host "      GH  Tags     : $(($ghTagNames | Sort-Object) -join ', ')" -ForegroundColor DarkGray
    }

    if ($adoTagCount -gt 0) {
        $missingTags = @($adoTagNames | Where-Object { $_ -notin $ghTagNames })
        $tagDetail   = if ($missingTags.Count -gt 0) { "Missing: $($missingTags -join ', ')" } else { "" }
        Add-Check "Tag Count" $adoTagCount $ghTagCount ($adoTagCount -eq $ghTagCount) $tagDetail
    }
    else {
        $auditTagCount = Get-AuditVal $auditDir "gh-tag-count.txt"
        if ($auditTagCount -and $auditTagCount -ne "N/A") {
            Add-Check "Tag Count (audit)" $auditTagCount $ghTagCount ([int]$auditTagCount -eq $ghTagCount)
        }
    }

    # ── 8. PR count ──────────────────────────────────────────────────────────
    $ghPrCount = 0
    try {
        $prSearchRaw = gh api "search/issues?q=repo:$GHOrg/$ghRepoName+type:pr" 2>$null
        if ($prSearchRaw) {
            $prSearch  = $prSearchRaw | ConvertFrom-Json
            $ghPrCount = $prSearch.total_count
        }
    }
    catch { }
    if ($adoPrCount -gt 0) {
        $prDiff = [math]::Abs($adoPrCount - $ghPrCount)
        Add-Check "PR Count (±2 tolerance)" $adoPrCount $ghPrCount ($prDiff -le 2) $(if ($prDiff -gt 2) { "Difference: $prDiff" } else { "" })
    }
    else {
        $auditPrCount = Get-AuditVal $auditDir "gh-pr-count.txt"
        if ($auditPrCount -and $auditPrCount -ne "N/A") {
            Add-Warn "PR Count" "ADO PR count unavailable; GitHub has $ghPrCount (audit: $auditPrCount)"
        }
    }

    # ── 9. Repo visibility ───────────────────────────────────────────────────
    if ([string]::IsNullOrWhiteSpace($ghVisibility)) { $ghVisibility = "unknown" }
    Write-Host "      Visibility   : $ghVisibility" -ForegroundColor DarkGray
    Add-Check "Visibility" $ExpectedVisibility $ghVisibility ($ghVisibility -eq $ExpectedVisibility)

    # ── 10. Latest commit reachable ──────────────────────────────────────────────
    $auditHash = Get-AuditVal $auditDir "gh-latest-hash.txt"
    if ($auditHash -and $auditHash -ne "N/A") {
        $ErrorActionPreference = 'SilentlyContinue'
        $commitRaw = gh api "repos/$GHOrg/$ghRepoName/git/commits/$auditHash" 2>$null
        $ErrorActionPreference = 'Stop'
        if ($LASTEXITCODE -eq 0 -and $commitRaw) {
            Add-Check "Latest Commit Reachable" $auditHash.Substring(0,12) "found" $true
        }
        else {
            Add-Check "Latest Commit Reachable" $auditHash.Substring(0,12) "not found" $false "Commit SHA from audit not found in GitHub"
        }
    }
    else {
        Add-Warn "Latest Commit Check" "No audit hash available (run migrate-single.ps1 first)"
    }

    # ── 12. Branch protection on default branch ──────────────────────────────
    $ErrorActionPreference = 'SilentlyContinue'
    $bpRaw = gh api "repos/$GHOrg/$ghRepoName/branches/$ghDefault/protection" 2>$null
    $ErrorActionPreference = 'Stop'
    if ($LASTEXITCODE -eq 0 -and $bpRaw) {
        Add-Check "Branch Protection" "configured" "configured" $true
    }
    else {
        Add-Warn "Branch Protection" "No branch protection on default branch '$ghDefault' — configure after migration"
    }

    # ── Overall ──────────────────────────────────────────────────────────────
    $failedChecks = @($checks | Where-Object { $_.Status -eq "FAIL" })
    $repoStatus   = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }
    $passCount    = @($checks | Where-Object { $_.Status -eq "PASS" }).Count
    $failCount    = $failedChecks.Count
    $warnCount    = @($checks | Where-Object { $_.Status -eq "WARN" }).Count
    $accuracy     = if (($passCount + $failCount) -gt 0) { [math]::Round(($passCount / ($passCount + $failCount)) * 100, 1) } else { 0 }

    Write-Host "  ─── Result: $repoStatus  Accuracy: $accuracy%  ($passCount PASS / $failCount FAIL / $warnCount WARN) ───" -ForegroundColor $(if ($repoStatus -eq "PASS") {"Green"} else {"Red"})

    $allResults += [PSCustomObject]@{
        ADORepo    = $adoRepoName
        GHRepo     = $ghRepoName
        Status     = $repoStatus
        Accuracy   = $accuracy
        PassCount  = $passCount
        FailCount  = $failCount
        WarnCount  = $warnCount
        Checks     = $checks
    }
}

# ── Write JSON + CSV ──────────────────────────────────────────────────────────
$jsonPath = "$reportDir\validation-results.json"
$csvPath  = "$reportDir\validation-results.csv"
$allResults | ConvertTo-Json -Depth 5 | Out-File $jsonPath -Encoding utf8

# Flat CSV — one row per check per repo
$flatRows = @()
foreach ($r in $allResults) {
    foreach ($c in $r.Checks) {
        $flatRows += [PSCustomObject]@{
            ADORepo = $r.ADORepo; GHRepo  = $r.GHRepo; RepoStatus = $r.Status
            Check   = $c.Check;  Source  = $c.Source;  Target     = $c.Target
            Status  = $c.Status; Detail  = $c.Detail
        }
    }
}
$flatRows | Export-Csv $csvPath -NoTypeInformation -Encoding utf8

# ── HTML report ───────────────────────────────────────────────────────────────
$migDate    = Get-Date -Format 'dd MMM yyyy · HH:mm'
$totalRepos = $allResults.Count
$passRepos  = @($allResults | Where-Object { $_.Status -eq "PASS" }).Count
$failRepos  = @($allResults | Where-Object { $_.Status -ne "PASS" }).Count
$overallAccuracy = if (($totalPass + $totalFail) -gt 0) { [math]::Round(($totalPass / ($totalPass + $totalFail)) * 100, 1) } else { 0 }
$accuracyColor   = if ($overallAccuracy -ge 90) { "#28a745" } elseif ($overallAccuracy -ge 70) { "#f0ad4e" } else { "#dc3545" }

$tableRows = ""
foreach ($r in $allResults) {
    $color  = if ($r.Status -eq "PASS") { "#28a745" } else { "#dc3545" }
    $badge  = if ($r.Status -eq "PASS") { "<span style='background:#dafbe1;color:#1a7f37;padding:4px 12px;border-radius:12px;font-weight:600;'>&#x2705; PASS</span>" } else { "<span style='background:#fdecea;color:#cf222e;padding:4px 12px;border-radius:12px;font-weight:600;'>&#x274C; FAIL</span>" }
    $details = ""
    foreach ($c in $r.Checks) {
        $cIcon   = switch ($c.Status) { "PASS" { "&#x2705;" } "FAIL" { "&#x274C;" } default { "&#x26A0;" } }
        $cColor  = switch ($c.Status) { "PASS" { "#28a745" } "FAIL" { "#dc3545" } default { "#f0ad4e" } }
        $details += "<tr style='font-size:13px;'><td style='padding:6px 12px;color:$cColor;'>$cIcon $($c.Check)</td><td style='padding:6px 12px;'>$($c.Source)</td><td style='padding:6px 12px;'>$($c.Target)</td><td style='padding:6px 12px;color:#666;font-size:12px;'>$($c.Detail)</td></tr>"
    }
    $repoAccColor = if ($r.Accuracy -ge 90) { "#28a745" } elseif ($r.Accuracy -ge 70) { "#f0ad4e" } else { "#dc3545" }
    $tableRows += "
    <tr>
      <td><code>$($r.ADORepo)</code></td>
      <td><code>$($r.GHRepo)</code></td>
      <td>$badge</td>
      <td style='text-align:center;font-weight:700;color:$repoAccColor;font-size:16px;'>$($r.Accuracy)%</td>
      <td style='text-align:center;color:#28a745;font-weight:600;'>$($r.PassCount)</td>
      <td style='text-align:center;color:#dc3545;font-weight:600;'>$($r.FailCount)</td>
    </tr>
    <tr><td colspan='6' style='padding:0;'>
      <details style='margin:0 8px 8px;'><summary style='cursor:pointer;font-size:13px;color:#0969da;padding:6px;'>View check details</summary>
        <table style='width:100%;font-size:13px;margin-top:4px;'>
          <thead><tr style='background:#f6f8fa;'><th style='padding:6px 12px;'>Check</th><th style='padding:6px 12px;'>Source</th><th style='padding:6px 12px;'>Target</th><th style='padding:6px 12px;'>Notes</th></tr></thead>
          <tbody>$details</tbody>
        </table>
      </details>
    </td></tr>"
}

$overallColor  = if ($failRepos -eq 0) { "#28a745" } else { "#dc3545" }
$overallBg     = if ($failRepos -eq 0) { "#e6f9ed" } else { "#fdecea" }
$overallStatus = if ($failRepos -eq 0) { "&#x2705; All repos passed validation" } else { "&#x274C; $failRepos repo(s) failed validation" }

$nl   = [Environment]::NewLine
$html = "<!DOCTYPE html><html lang='en'><head><meta charset='UTF-8'><title>Validation Report</title>" + $nl
$html += "<style>*{margin:0;padding:0;box-sizing:border-box}body{font-family:'Segoe UI',sans-serif;background:#f4f6f9;color:#333;padding:30px}"
$html += ".container{max-width:1100px;margin:0 auto}.header{background:linear-gradient(135deg,#0d1117,#161b22);color:#fff;padding:32px;border-radius:14px;margin-bottom:24px}"
$html += ".header h1{font-size:26px;margin-bottom:10px}.status-banner{display:inline-block;padding:10px 22px;border-radius:8px;font-size:17px;font-weight:600;background:$overallBg;color:$overallColor;border:2px solid $overallColor}"
$html += ".card{background:#fff;border-radius:12px;padding:24px;margin-bottom:20px;box-shadow:0 2px 8px rgba(0,0,0,.06)}.card h2{font-size:20px;margin-bottom:16px;border-bottom:2px solid #e1e4e8;padding-bottom:8px}"
$html += ".stat-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(130px,1fr));gap:14px;margin-bottom:16px}"
$html += ".stat-box{background:#f6f8fa;border-radius:10px;padding:18px;text-align:center;border:1px solid #e1e4e8}"
$html += ".stat-box .num{font-size:28px;font-weight:700;color:#0d1117}.stat-box .label{font-size:13px;color:#666;margin-top:4px}"
$html += "table{width:100%;border-collapse:collapse}th{background:#f6f8fa;padding:11px 14px;font-weight:600;border-bottom:2px solid #d0d7de;text-align:left}"
$html += "td{padding:10px 14px;border-bottom:1px solid #eaecef}tr:hover{background:#fafafa}"
$html += "code{background:#eff1f3;padding:2px 7px;border-radius:4px;font-size:13px}"
$html += ".footer{text-align:center;color:#999;font-size:13px;margin-top:24px;padding-top:14px;border-top:1px solid #e1e4e8}</style></head><body><div class='container'>" + $nl
$html += "<div class='header'><h1>&#x1F50D; Migration Validation Report</h1><div class='status-banner'>$overallStatus</div><div class='status-banner' style='margin-left:16px;background:#fff;color:$accuracyColor;border-color:$accuracyColor;font-size:20px;'>&#x1F3AF; $overallAccuracy% Accuracy</div></div>" + $nl
$html += "<div class='card'><h2>&#x1F4CA; Summary</h2><div class='stat-grid'>"
$html += "<div class='stat-box' style='border:2px solid $accuracyColor;'><div class='num' style='color:$accuracyColor;font-size:32px;'>$overallAccuracy%</div><div class='label'>&#x1F3AF; Migration Accuracy</div></div>"
$html += "<div class='stat-box'><div class='num'>$totalRepos</div><div class='label'>Total Repos</div></div>"
$html += "<div class='stat-box'><div class='num' style='color:#28a745;'>$passRepos</div><div class='label'>&#x2705; Passed</div></div>"
$html += "<div class='stat-box'><div class='num' style='color:#dc3545;'>$failRepos</div><div class='label'>&#x274C; Failed</div></div>"
$html += "<div class='stat-box'><div class='num'>$totalPass</div><div class='label'>Total Checks Passed</div></div>"
$html += "<div class='stat-box'><div class='num' style='color:#dc3545;'>$totalFail</div><div class='label'>Total Checks Failed</div></div>"
$html += "</div></div>" + $nl
$html += "<div class='card'><h2>&#x1F4CB; Repo-by-Repo Results</h2><table>"
$html += "<thead><tr><th>ADO Repo</th><th>GitHub Repo</th><th>Status</th><th style='text-align:center;'>Accuracy</th><th style='text-align:center;'>Pass</th><th style='text-align:center;'>Fail</th></tr></thead>"
$html += "<tbody>$tableRows</tbody></table></div>" + $nl
$html += "<div class='footer'>Generated $migDate &bull; ADO-to-GitHub Migration Validation</div></div></body></html>"

$htmlPath = "$reportDir\validation-report.html"
$html | Out-File $htmlPath -Encoding utf8

# ── Markdown summary ──────────────────────────────────────────────────────────
$md  = "# Migration Validation Report`n`n"
$md += "> Generated: $migDate`n`n"
$md += "| Metric | Value |`n|:---|---:|`n"
$md += "| Total repos validated | $totalRepos |`n"
$md += "| &#x1F3AF; Migration Accuracy | **$overallAccuracy%** |`n"
$md += "| ✅ PASS | $passRepos |`n"
$md += "| ❌ FAIL | $failRepos |`n`n"
if ($failRepos -gt 0) {
    $md += "## Failed Repos`n`n"
    $allResults | Where-Object { $_.Status -ne "PASS" } | ForEach-Object {
        $md += "### ``$($_.GHRepo)```n`n"
        $_.Checks | Where-Object { $_.Status -eq "FAIL" } | ForEach-Object {
            $md += "- ❌ **$($_.Check)** — Source: ``$($_.Source)`` Target: ``$($_.Target)`` $($_.Detail)`n"
        }
        $md += "`n"
    }
}
$mdPath = "$reportDir\validation-summary.md"
$md | Out-File $mdPath -Encoding utf8

# ── Console summary ───────────────────────────────────────────────────────────
Write-Host ""
Write-Host "============================================" -ForegroundColor $(if ($failRepos -eq 0) {"Green"} else {"Red"})
Write-Host "  VALIDATION SUMMARY"
Write-Host "  Total repos : $totalRepos"
Write-Host "  Accuracy    : $overallAccuracy%" -ForegroundColor $(if ($overallAccuracy -ge 90) {"Green"} elseif ($overallAccuracy -ge 70) {"Yellow"} else {"Red"})
Write-Host "  PASS        : $passRepos" -ForegroundColor Green
Write-Host "  FAIL        : $failRepos" -ForegroundColor $(if ($failRepos -gt 0) {"Red"} else {"Green"})
Write-Host "============================================"
Write-Host ""
Write-Host "  JSON    : $jsonPath"
Write-Host "  CSV     : $csvPath"
Write-Host "  HTML    : $htmlPath"
Write-Host "  Summary : $mdPath"

if ($failRepos -gt 0) {
    Write-Host "`nFailed repos:" -ForegroundColor Red
    $allResults | Where-Object { $_.Status -ne "PASS" } | ForEach-Object {
        Write-Host "  - $($_.GHRepo)" -ForegroundColor Red
    }
    exit 1
}

exit 0
