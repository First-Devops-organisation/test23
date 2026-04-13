<#
.SYNOPSIS
    Migrates a SINGLE repo from ADO to GitHub using GEI (gh ado2gh).
    Converted from yaml.yaml pipeline logic into a reusable PS1 script.
.DESCRIPTION
    Steps performed (mirrors yaml.yaml Steps 1-5):
      1. Authenticate gh CLI with GH_PAT
      2. Pre-check: does the GitHub repo already exist?
      3. Run gh ado2gh migrate-repo (with "already queued" handling & retry)
      4. Branch-wise post-migration audit (branches, tags, commits, PRs, files)
      5. Download GEI migration log
      6. Generate HTML dashboard + Markdown summary
.PARAMETER ADOOrg
    Azure DevOps organisation name (e.g. "mycompany")
.PARAMETER ADOProject
    Azure DevOps project name
.PARAMETER ADORepo
    Source repository name in ADO
.PARAMETER GHOrg
    Target GitHub organisation name
.PARAMETER GHRepo
    Target GitHub repository name (defaults to ADORepo if omitted)
.PARAMETER OutputDir
    Directory for all reports, logs and dashboards  (default: ./output)
.PARAMETER SkipAudit
    If set, skips the branch-wise audit (Step 4) — useful for large repos
.PARAMETER DryRun
    If set, prints the GEI command but does not execute it
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]  [string]$ADOOrg,
    [Parameter(Mandatory = $true)]  [string]$ADOProject,
    [Parameter(Mandatory = $true)]  [string]$ADORepo,
    [Parameter(Mandatory = $true)]  [string]$GHOrg,
    [Parameter(Mandatory = $false)] [string]$GHRepo     = $ADORepo,
    [Parameter(Mandatory = $false)] [string]$OutputDir  = "$PSScriptRoot\..\output",
    [switch]$SkipAudit,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Normalize ADOOrg — strip full URL if user set it as https://dev.azure.com/<org> ──
if ($ADOOrg -match '^https?://dev\.azure\.com/([^/]+)/?$') {
    Write-Host "  Normalising ADOOrg: stripping URL prefix → '$($Matches[1])'"
    $ADOOrg = $Matches[1]
}

# ── Validate PATs ────────────────────────────────────────────────────────────
$ghPat  = $env:GH_PAT
$adoPat = $env:ADO_PAT
if ([string]::IsNullOrWhiteSpace($ghPat))  { Write-Error "Set GH_PAT environment variable" }
if ([string]::IsNullOrWhiteSpace($adoPat)) { Write-Error "Set ADO_PAT environment variable" }

# ── Output directories ───────────────────────────────────────────────────────
$reportDir  = "$OutputDir\reports"
$logDir     = "$OutputDir\logs"
$auditDir   = "$OutputDir\audit\$GHRepo"
$dashDir    = "$OutputDir\dashboard\$GHRepo"
$folderDir  = "$auditDir\folder-listing"

foreach ($d in @($reportDir, $logDir, $auditDir, $dashDir, $folderDir)) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
}

$stateFile    = "$logDir\migration-state-$GHRepo.txt"
$precheckFile = "$logDir\repo-precheck-$GHRepo.txt"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  SINGLE REPO MIGRATION"
Write-Host "  ADO:    $ADOOrg / $ADOProject / $ADORepo"
Write-Host "  GitHub: $GHOrg / $GHRepo"
Write-Host "  DryRun: $DryRun"
Write-Host "============================================"

# ════════════════════════════════════════════════════════════════════════════
# STEP 1 – Authenticate & install ado2gh extension
# ════════════════════════════════════════════════════════════════════════════
Write-Host "`n[Step 1] Authenticate GitHub CLI..." -ForegroundColor Cyan
$env:GH_TOKEN = $ghPat
# When GH_TOKEN is set the CLI uses it directly — gh auth login is not needed
# and returns exit code 1 (polluting the job error stream). Skip it.
Write-Host "  Authenticating via GH_TOKEN environment variable."
gh auth status 2>&1 | ForEach-Object { Write-Host "  $_" }
gh extension install github/gh-ado2gh 2>&1 | Where-Object { $_ -notmatch 'already installed' }
gh extension list

# ════════════════════════════════════════════════════════════════════════════
# STEP 2 – Pre-check: does the GitHub repo already exist?
# ════════════════════════════════════════════════════════════════════════════
Write-Host "`n[Step 2] Pre-check repo existence in GitHub..." -ForegroundColor Cyan
$repoStatus = "NOT_EXISTS"
try {
    $ErrorActionPreference = 'SilentlyContinue'
    [void](gh repo view "$GHOrg/$GHRepo" --json name 2>&1)
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Repo already exists: $GHOrg/$GHRepo" -ForegroundColor Yellow
        $repoStatus = "ALREADY_EXISTS"
    }
}
catch { }
finally { $ErrorActionPreference = 'Stop' }

$repoStatus | Out-File $precheckFile -Encoding utf8
Write-Host "  Status: $repoStatus"

# ════════════════════════════════════════════════════════════════════════════
# STEP 3 – Migrate repo via GEI
# ════════════════════════════════════════════════════════════════════════════
if ($repoStatus -eq "ALREADY_EXISTS") {
    Write-Host "`n[Step 3] SKIPPED — repo already exists in GitHub." -ForegroundColor Yellow
    "SKIPPED" | Out-File $stateFile -Encoding utf8
}
elseif ($DryRun) {
    Write-Host "`n[Step 3] DRY RUN — GEI command that would run:" -ForegroundColor DarkYellow
    Write-Host "  gh ado2gh migrate-repo --ado-org `"$ADOOrg`" --ado-team-project `"$ADOProject`" --ado-repo `"$ADORepo`" --github-org `"$GHOrg`" --github-repo `"$GHRepo`""
    "DRY_RUN" | Out-File $stateFile -Encoding utf8
}
else {
    Write-Host "`n[Step 3] Migrating repo..." -ForegroundColor Cyan
    $env:ADO_PAT = $adoPat
    $env:GH_PAT  = $ghPat
    "PENDING" | Out-File $stateFile -Encoding utf8

    $migOutput = gh ado2gh migrate-repo `
        --ado-org       $ADOOrg `
        --ado-team-project $ADOProject `
        --ado-repo      $ADORepo `
        --github-org    $GHOrg `
        --github-repo   $GHRepo 2>&1

    $migOutput | ForEach-Object { Write-Host "  $_" }

    if ($LASTEXITCODE -eq 0) {
        Write-Host "  State: COMPLETE" -ForegroundColor Green
        "COMPLETE" | Out-File $stateFile -Encoding utf8
    }
    elseif (($migOutput -join "") -match "already been queued") {
        Write-Host "  Migration already queued — polling until repo appears..." -ForegroundColor Yellow
        "WAITING" | Out-File $stateFile -Encoding utf8
        $env:GH_TOKEN = $ghPat
        $found = $false
        for ($w = 1; $w -le 30; $w++) {
            Start-Sleep -Seconds 60
            Write-Host "  Poll $w/30..."
            $ErrorActionPreference = 'SilentlyContinue'
            $check = gh repo view "$GHOrg/$GHRepo" --json name 2>&1
            $ErrorActionPreference = 'Stop'
            if ($LASTEXITCODE -eq 0) { $found = $true; break }
        }
        if ($found) {
            "COMPLETE" | Out-File $stateFile -Encoding utf8
            Write-Host "  State: COMPLETE (queued migration finished)" -ForegroundColor Green
        }
        else {
            "FAILED" | Out-File $stateFile -Encoding utf8
            Write-Warning "Migration did not complete within 30 minutes. Check GEI logs."
        }
    }
    else {
        "FAILED" | Out-File $stateFile -Encoding utf8
        Write-Warning @"
Migration failed (exit code $LASTEXITCODE). Common causes:
  1. ADO_PAT scope: needs 'Code (Read)' + 'Identity (Read)' on the ADO organisation.
  2. ADOOrg name mismatch: check the value in the repo-migration-discover variable group.
  3. GHOrg name mismatch or GH_PAT lacks 'repo' + 'admin:org' scopes.
GEI output above should contain a more specific error message.
"@
    }
}

# ════════════════════════════════════════════════════════════════════════════
# STEP 4 – Branch-wise post-migration audit
# ════════════════════════════════════════════════════════════════════════════
if ($SkipAudit) {
    Write-Host "`n[Step 4] SKIPPED (–SkipAudit flag set)." -ForegroundColor Yellow
}
else {
    Write-Host "`n[Step 4] Post-migration audit (branch-wise)..." -ForegroundColor Cyan

    $ProgressPreference = 'SilentlyContinue'
    $env:GH_TOKEN = $ghPat

    $cloneDir = "$OutputDir\tmp\$GHRepo-mirror"
    if (Test-Path $cloneDir) { Remove-Item $cloneDir -Recurse -Force }

    Write-Host "  Cloning GitHub repo (blobless mirror)..."
    $ErrorActionPreference = 'SilentlyContinue'
    git clone --filter=blob:none --mirror "https://$ghPat@github.com/$GHOrg/$GHRepo.git" $cloneDir 2>&1 | ForEach-Object { Write-Host "  $_" }
    $ErrorActionPreference = 'Stop'

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $cloneDir)) {
        Write-Warning "  Could not clone GitHub repo — skipping audit."
    }
    else {
        Push-Location $cloneDir

        # Branches
        $branches     = @(git branch | ForEach-Object { $_.Trim().TrimStart("* ") } | Where-Object { $_ -ne "" })
        $branchCount  = $branches.Count
        $branches     | Out-File "$auditDir\gh-branches.txt" -Encoding utf8
        Write-Host "  Branches: $branchCount"

        # Default branch
        $defaultRef   = git symbolic-ref HEAD 2>$null
        $defaultBranch = if ($defaultRef) { $defaultRef.Trim() -replace '^refs/heads/','' }
                         elseif ($branchCount -gt 0) { $branches[0].Trim() }
                         else { "" }
        $defaultBranch | Out-File "$auditDir\gh-default-branch.txt" -Encoding utf8
        Write-Host "  Default branch: $defaultBranch"

        # Tags
        $tags      = git tag -l
        $tagCount  = if ($tags) { ($tags | Measure-Object).Count } else { 0 }
        if ($tags) { $tags | Out-File "$auditDir\gh-tags.txt" -Encoding utf8 }
        else       { ""    | Out-File "$auditDir\gh-tags.txt" -Encoding utf8 }
        Write-Host "  Tags: $tagCount"

        # Total commits
        $totalCommits = (git rev-list --count --all).Trim()
        $latestHash   = (git log -1 --format="%H").Trim()
        Write-Host "  Total commits: $totalCommits"

        # Repo size metadata
        $repoSize = git count-objects -vH
        $repoSize | Out-File "$auditDir\gh-repo-size.txt" -Encoding utf8

        # Batch-fetch branch metadata via for-each-ref (1 call for all branches)
        $refMeta  = @{}
        $refLines = git for-each-ref --format='%(refname:short)|%(objectname:short=12)|%(authorname)|%(creatordate:short)|%(subject)' refs/heads/ 2>$null
        if ($refLines) {
            foreach ($line in $refLines) {
                $p = $line -split '\|', 5
                if ($p.Count -ge 5) { $refMeta[$p[0]] = @{ Hash=$p[1]; Author=$p[2]; Date=$p[3]; Msg=$p[4] } }
            }
        }

        $branchCsvRows    = @()
        $csvFolderFile    = "$auditDir\gh-folder-wise-files.csv"
        $csvFolderSummary = "$auditDir\gh-folder-summary.csv"
        $csvHeaderWritten = $false
        $totalFolderFiles = 0
        $bIdx = 0

        foreach ($branch in $branches) {
            $b = $branch.Trim(); if ($b -eq "") { continue }
            $bIdx++
            Write-Host "  [$bIdx/$branchCount] $b"

            if ($b -eq $defaultBranch) {
                $bFiles     = git ls-tree -r --name-only $b 2>$null
                $bFileCount = if ($bFiles) { ($bFiles | Measure-Object).Count } else { 0 }

                if ($bFileCount -gt 50000) {
                    $bFolderCount = "50K+ (skipped)"
                }
                else {
                    $filesByFolder = [ordered]@{}
                    if ($bFiles) {
                        foreach ($f in $bFiles) {
                            $folder = (Split-Path $f -Parent) -replace '\\','/'
                            if (-not $folder) { $folder = "(root)" }
                            if (-not $filesByFolder.Contains($folder)) { $filesByFolder[$folder] = @() }
                            $filesByFolder[$folder] += Split-Path $f -Leaf
                        }
                    }
                    $bFolderCount = $filesByFolder.Keys.Count

                    # Write per-branch Markdown file listing
                    $safeBranch   = $b -replace '[/\\]','--'
                    $branchFileMd = "# Files in branch: $b`n`n"
                    foreach ($folder in ($filesByFolder.Keys | Sort-Object)) {
                        $branchFileMd += "## $folder/`n"
                        foreach ($file in ($filesByFolder[$folder] | Sort-Object)) { $branchFileMd += "- $file`n" }
                        $branchFileMd += "`n"
                    }
                    $branchFileMd | Out-File "$folderDir\gh-files-$safeBranch.md" -Encoding utf8

                    # Stream folder CSVs
                    foreach ($folder in $filesByFolder.Keys) {
                        [PSCustomObject]@{ Branch=$b; Folder=$folder; FileCount=$filesByFolder[$folder].Count } |
                            Export-Csv -Path $csvFolderSummary -NoTypeInformation -Encoding utf8 -Append:$csvHeaderWritten -Force
                        foreach ($file in $filesByFolder[$folder]) {
                            [PSCustomObject]@{ Branch=$b; Folder=$folder; FileName=$file } |
                                Export-Csv -Path $csvFolderFile -NoTypeInformation -Encoding utf8 -Append:$csvHeaderWritten -Force
                            $totalFolderFiles++
                        }
                        if (-not $csvHeaderWritten) { $csvHeaderWritten = $true }
                    }
                    $bFiles = $null; $filesByFolder = $null
                }
            }
            else { $bFileCount = "-"; $bFolderCount = "-" }

            $m = if ($refMeta.ContainsKey($b)) { $refMeta[$b] } else { @{ Hash="N/A"; Author="N/A"; Date="N/A"; Msg="N/A" } }
            $branchCsvRows += [PSCustomObject]@{
                Branch       = $b
                Status       = "Migrated"
                Files        = $bFileCount
                Folders      = $bFolderCount
                LatestHash   = $m.Hash
                LatestAuthor = $m.Author
                LatestDate   = $m.Date
                LatestMsg    = $m.Msg
            }
        }
        $branchCsvRows | Export-Csv "$auditDir\gh-branch-wise-data.csv" -NoTypeInformation -Encoding utf8

        # Top 5 key branches with commit counts
        $topBranches = $branchCsvRows | Sort-Object {
            $bn = $_.Branch
            if     ($bn -eq $defaultBranch)          { 0 }
            elseif ($bn -match '^(main|master)$')    { 1 }
            elseif ($bn -match '^(develop|dev)$')    { 2 }
            elseif ($bn -match '^(release|hotfix)')  { 3 }
            else                                     { 99 }
        }, Branch | Select-Object -First 5

        $topRows = @()
        foreach ($tb in $topBranches) {
            $cnt   = (git rev-list --count $tb.Branch 2>$null); if ($cnt) { $cnt = $cnt.Trim() } else { $cnt = "0" }
            $isDef = if ($tb.Branch -eq $defaultBranch) { "Yes" } else { "No" }
            $topRows += [PSCustomObject]@{ Branch=$tb.Branch; Commits=("{0:N0}" -f [long]$cnt); IsDefault=$isDef }
        }
        $topRows | Export-Csv "$auditDir\gh-top-branches.csv" -NoTypeInformation -Encoding utf8

        Pop-Location
        Remove-Item $cloneDir -Recurse -Force -ErrorAction SilentlyContinue

        # PR audit via GitHub API
        $allPRs = @(); $page = 1
        do {
            $prs = @(gh api "repos/$GHOrg/$GHRepo/pulls?state=all&per_page=100&page=$page" 2>$null | ConvertFrom-Json)
            if ($prs.Count -gt 0) { $allPRs += $prs; $page++ } else { break }
        } while ($prs.Count -eq 100)

        $totalPRs    = $allPRs.Count
        $totalOpen   = @($allPRs | Where-Object { $_.state -eq "open" }).Count
        $totalMerged = @($allPRs | Where-Object { $_.merged_at }).Count
        $totalClosed = $totalPRs - $totalOpen - $totalMerged

        # Write metric text files
        $branchCount  | Out-File "$auditDir\gh-branch-count.txt"  -Encoding utf8
        $tagCount     | Out-File "$auditDir\gh-tag-count.txt"     -Encoding utf8
        $totalCommits | Out-File "$auditDir\gh-commit-count.txt"  -Encoding utf8
        $totalPRs     | Out-File "$auditDir\gh-pr-count.txt"      -Encoding utf8
        $totalOpen    | Out-File "$auditDir\gh-pr-open.txt"       -Encoding utf8
        $totalMerged  | Out-File "$auditDir\gh-pr-merged.txt"     -Encoding utf8
        $totalClosed  | Out-File "$auditDir\gh-pr-closed.txt"     -Encoding utf8
        $latestHash   | Out-File "$auditDir\gh-latest-hash.txt"   -Encoding utf8

        Write-Host "  Audit complete. PRs: $totalPRs (Open:$totalOpen Merged:$totalMerged Closed:$totalClosed)" -ForegroundColor Green
    }
}

# ════════════════════════════════════════════════════════════════════════════
# STEP 5 – Download GEI migration log
# ════════════════════════════════════════════════════════════════════════════
$migState = if (Test-Path $stateFile) { (Get-Content $stateFile -Raw).Trim() } else { "UNKNOWN" }

if ($migState -in @("SKIPPED","DRY_RUN","FAILED")) {
    Write-Host "`n[Step 5] Skipping log download (state: $migState)." -ForegroundColor Yellow
}
else {
    Write-Host "`n[Step 5] Downloading GEI migration log (waiting 300s for large repos)..." -ForegroundColor Cyan
    Start-Sleep -Seconds 300
    $migLogFile = "$logDir\migration-log-$GHRepo.log"
    $env:GH_TOKEN = $ghPat
    $success = $false
    for ($i = 1; $i -le 15; $i++) {
        Write-Host "  Attempt $i/15..."
        $ErrorActionPreference = 'SilentlyContinue'
        $out = gh ado2gh download-logs --github-org $GHOrg --github-repo $GHRepo --migration-log-file $migLogFile --overwrite 2>&1
        $ErrorActionPreference = 'Stop'
        if ($LASTEXITCODE -eq 0) { $success = $true; break }
        Start-Sleep -Seconds 60
    }
    if (-not $success) {
        "Log download failed after 15 retries" | Out-File $migLogFile -Encoding utf8
        Write-Warning "  Logs unavailable after 15 retries (normal for large repos)."
    }
    else {
        Write-Host "  Log saved: $migLogFile" -ForegroundColor Green
    }
}

# ════════════════════════════════════════════════════════════════════════════
# STEP 6 – Repo size from GitHub API
# ════════════════════════════════════════════════════════════════════════════
Write-Host "`n[Step 6] Getting repo size from GitHub API..." -ForegroundColor Cyan
$env:GH_TOKEN = $ghPat
$actualSize = "N/A"
$sizeKB = 0
for ($i = 1; $i -le 5; $i++) {
    $ErrorActionPreference = 'SilentlyContinue'
    $rawSize = gh api "repos/$GHOrg/$GHRepo" --jq '.size' 2>$null
    $ErrorActionPreference = 'Stop'
    if ($rawSize -and $rawSize -match '^\d+$' -and [long]$rawSize -gt 0) { $sizeKB = [long]$rawSize; break }
    if ($i -lt 5) { Start-Sleep -Seconds 20 }
}
if ($sizeKB -gt 0) {
    if     ($sizeKB -ge 1048576) { $actualSize = "{0:N2} GB" -f ($sizeKB / 1048576) }
    elseif ($sizeKB -ge 1024)    { $actualSize = "{0:N2} MB" -f ($sizeKB / 1024) }
    else                         { $actualSize = "$sizeKB KB" }
}
$actualSize | Out-File "$auditDir\gh-repo-size-actual.txt" -Encoding utf8
Write-Host "  Repo size: $actualSize"

# ════════════════════════════════════════════════════════════════════════════
# STEP 7 – Generate HTML dashboard + Markdown summary
# ════════════════════════════════════════════════════════════════════════════
Write-Host "`n[Step 7] Generating HTML dashboard..." -ForegroundColor Cyan

function Get-AuditVal($file) {
    $p = "$auditDir\$file"
    if (Test-Path $p) { return (Get-Content $p -Raw).Trim() }
    return "N/A"
}

$branchCount  = Get-AuditVal "gh-branch-count.txt"
$tagCount     = Get-AuditVal "gh-tag-count.txt"
$commitCount  = Get-AuditVal "gh-commit-count.txt"
$prCount      = Get-AuditVal "gh-pr-count.txt"
$prOpen       = Get-AuditVal "gh-pr-open.txt"
$prMerged     = Get-AuditVal "gh-pr-merged.txt"
$prClosed     = Get-AuditVal "gh-pr-closed.txt"
$repoSize     = Get-AuditVal "gh-repo-size-actual.txt"
$defaultBranch = Get-AuditVal "gh-default-branch.txt"
$migDate      = Get-Date -Format 'dd MMM yyyy · HH:mm'

# Determine final migration result
$migState = if (Test-Path $stateFile) { (Get-Content $stateFile -Raw).Trim() } else { "UNKNOWN" }
if     ($migState -eq "SKIPPED")   { $migResult = "Skipped (Already Exists)"; $statusColor = "#f0ad4e"; $statusBg = "#fff8e1"; $statusEmoji = "&#x26A0;" }
elseif ($migState -eq "DRY_RUN")   { $migResult = "Dry Run";                  $statusColor = "#0969da"; $statusBg = "#ddf4ff"; $statusEmoji = "&#x1F4CB;" }
elseif ($migState -eq "COMPLETE")  { $migResult = "Success";                  $statusColor = "#28a745"; $statusBg = "#e6f9ed"; $statusEmoji = "&#x2705;" }
else                               { $migResult = "Failed";                   $statusColor = "#dc3545"; $statusBg = "#fdecea"; $statusEmoji = "&#x274C;" }

# Top branches table rows
$topBranchHtml = ""
$topCsvFile = "$auditDir\gh-top-branches.csv"
if (Test-Path $topCsvFile) {
    $topRows = Import-Csv $topCsvFile
    $rank = 1
    foreach ($r in $topRows) {
        $defLabel = if ($r.IsDefault -eq "Yes") { " <span style='background:#ddf4ff;color:#0969da;padding:2px 7px;border-radius:8px;font-size:11px;font-weight:700;'>DEFAULT</span>" } else { "" }
        $topBranchHtml += "<tr><td style='text-align:center;color:#6f42c1;font-weight:700;'>$rank</td><td><code>$($r.Branch)</code>$defLabel</td><td style='text-align:right;font-variant-numeric:tabular-nums;font-weight:600;'>$($r.Commits)</td></tr>`n"
        $rank++
    }
}
if ($topBranchHtml -eq "") { $topBranchHtml = "<tr><td colspan='3' style='color:#999;text-align:center;'>No data</td></tr>" }

# All branches rows
$allBranchHtml = ""
$branchCsvFile = "$auditDir\gh-branch-wise-data.csv"
if (Test-Path $branchCsvFile) {
    $allRows = Import-Csv $branchCsvFile | Sort-Object Branch
    $idx = 1
    foreach ($r in $allRows) {
        $allBranchHtml += "<tr><td style='text-align:center;'>$idx</td><td><code>$($r.Branch)</code></td><td style='text-align:center;'><span style='background:#dafbe1;color:#1a7f37;padding:3px 12px;border-radius:12px;font-weight:600;'>&#x2705; Migrated</span></td></tr>`n"
        $idx++
    }
}
if ($allBranchHtml -eq "") { $allBranchHtml = "<tr><td colspan='3' style='color:#999;text-align:center;'>No data</td></tr>" }

$nl = [Environment]::NewLine
$html  = "<!DOCTYPE html><html lang='en'><head><meta charset='UTF-8'><title>Migration Report - $GHRepo</title>" + $nl
$html += "<style>*{margin:0;padding:0;box-sizing:border-box}body{font-family:'Segoe UI',sans-serif;background:#f4f6f9;color:#333;padding:30px}"
$html += ".container{max-width:960px;margin:0 auto}.header{background:linear-gradient(135deg,#0d1117,#161b22);color:#fff;padding:32px;border-radius:14px;margin-bottom:24px}"
$html += ".header h1{font-size:26px;margin-bottom:10px}.status-banner{display:inline-block;padding:10px 22px;border-radius:8px;font-size:17px;font-weight:600;background:$statusBg;color:$statusColor;border:2px solid $statusColor}"
$html += ".card{background:#fff;border-radius:12px;padding:28px;margin-bottom:20px;box-shadow:0 2px 8px rgba(0,0,0,.06)}.card h2{font-size:20px;margin-bottom:16px;border-bottom:2px solid #e1e4e8;padding-bottom:8px}"
$html += "table{width:100%;border-collapse:collapse}th{background:#f6f8fa;padding:11px 14px;font-weight:600;border-bottom:2px solid #d0d7de;text-align:left}"
$html += "td{padding:10px 14px;border-bottom:1px solid #eaecef}tr:hover{background:#f6f8fa}"
$html += ".stat-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:14px}"
$html += ".stat-box{background:#f6f8fa;border-radius:10px;padding:18px;text-align:center;border:1px solid #e1e4e8}"
$html += ".stat-box .num{font-size:28px;font-weight:700;color:#0d1117}.stat-box .label{font-size:13px;color:#666;margin-top:4px}"
$html += ".pr-pills{display:flex;gap:10px;flex-wrap:wrap;margin-top:12px}"
$html += ".pr-pill{padding:7px 16px;border-radius:20px;font-weight:600;font-size:14px}"
$html += ".pr-open{background:#dafbe1;color:#1a7f37}.pr-merged{background:#e8d5f5;color:#8250df}.pr-closed{background:#fdecea;color:#cf222e}"
$html += "details summary{cursor:pointer;font-weight:600;color:#0969da;padding:8px 0}code{background:#eff1f3;padding:2px 7px;border-radius:4px;font-size:13px}"
$html += ".footer{text-align:center;color:#999;font-size:13px;margin-top:24px;padding-top:14px;border-top:1px solid #e1e4e8}</style></head><body><div class='container'>" + $nl
$html += "<div class='header'><h1>&#x1F680; ADO &#x2192; GitHub Migration Report</h1><div class='status-banner'>$statusEmoji $migResult</div></div>" + $nl
$html += "<div class='card'><h2>&#x1F4C2; Migration Overview</h2><table>"
$html += "<tr><td><strong>Date</strong></td><td>$migDate</td></tr>"
$html += "<tr><td><strong>Source (ADO)</strong></td><td><code>$ADOOrg / $ADOProject / $ADORepo</code></td></tr>"
$html += "<tr><td><strong>Target (GitHub)</strong></td><td><code>$GHOrg / $GHRepo</code></td></tr>"
$html += "<tr><td><strong>Default Branch</strong></td><td><code>$defaultBranch</code></td></tr>"
$html += "</table></div>" + $nl
$html += "<div class='card'><h2>&#x1F4CA; Repository Snapshot</h2><div class='stat-grid'>"
$html += "<div class='stat-box'><div class='num'>$branchCount</div><div class='label'>&#x1F33F; Branches</div></div>"
$html += "<div class='stat-box'><div class='num'>$tagCount</div><div class='label'>&#x1F3F7; Tags</div></div>"
$html += "<div class='stat-box'><div class='num'>$commitCount</div><div class='label'>&#x1F4DD; Commits</div></div>"
$html += "<div class='stat-box'><div class='num'>$prCount</div><div class='label'>&#x1F500; Pull Requests</div></div>"
$html += "<div class='stat-box'><div class='num'>$repoSize</div><div class='label'>&#x1F4BE; Repo Size</div></div>"
$html += "</div><div class='pr-pills'><span class='pr-pill pr-open'>&#x1F7E2; $prOpen Open</span><span class='pr-pill pr-merged'>&#x1F7E3; $prMerged Merged</span><span class='pr-pill pr-closed'>&#x1F534; $prClosed Closed</span></div></div>" + $nl
$html += "<div class='card'><h2>&#x1F511; Key Branches</h2><table><thead><tr><th style='width:50px;text-align:center;'>#</th><th>Branch</th><th style='text-align:right;'>Commits</th></tr></thead><tbody>$topBranchHtml</tbody></table></div>" + $nl
$html += "<div class='card'><h2>&#x1F33F; All Branches ($branchCount)</h2><details><summary>Click to expand</summary><table style='margin-top:10px;'><thead><tr><th style='width:50px;text-align:center;'>#</th><th>Branch</th><th style='text-align:center;'>Status</th></tr></thead><tbody>$allBranchHtml</tbody></table></details></div>" + $nl
$html += "<div class='footer'>Generated $migDate &bull; ADO-to-GitHub Migration Pipeline</div></div></body></html>"

$html | Out-File "$dashDir\migration-report-$GHRepo.html" -Encoding utf8
Write-Host "  HTML saved: $dashDir\migration-report-$GHRepo.html" -ForegroundColor Green

# Markdown summary
$md  = "# ADO to GitHub Migration Report`n`n"
$md += "> **Repo:** ``$ADORepo`` | **Status:** $migResult`n`n"
$md += "| | |`n|:---|:---|`n"
$md += "| Date | $migDate |`n"
$md += "| Source | ``$ADOOrg / $ADOProject / $ADORepo`` |`n"
$md += "| Target | ``$GHOrg / $GHRepo`` |`n"
$md += "| Branches | $branchCount |`n"
$md += "| Tags | $tagCount |`n"
$md += "| Commits | $commitCount |`n"
$md += "| Repo Size | $repoSize |`n"
$md += "| PRs | $prOpen Open / $prMerged Merged / $prClosed Closed |`n"
$md | Out-File "$reportDir\migration-summary-$GHRepo.md" -Encoding utf8

Write-Host "`n============================================" -ForegroundColor Green
Write-Host "  MIGRATION COMPLETE: $GHRepo"
Write-Host "  Status:   $migResult"
Write-Host "  Branches: $branchCount | Tags: $tagCount | Commits: $commitCount"
Write-Host "  PRs:      $prCount (Open:$prOpen Merged:$prMerged Closed:$prClosed)"
Write-Host "  Size:     $repoSize"
Write-Host "============================================"
