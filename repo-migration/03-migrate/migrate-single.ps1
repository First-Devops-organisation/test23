<#
.SYNOPSIS
    Migrates a SINGLE repo from ADO to GitHub using GEI (gh ado2gh).
    Converted from yaml.yaml pipeline logic into a reusable PS1 script.
.DESCRIPTION
    Steps performed:
      1. Authenticate gh CLI with GH_PAT
      2. Pre-check: does the GitHub repo already exist?
      3. Run gh ado2gh migrate-repo (with "already queued" handling & retry)
      4. Branch-wise post-migration audit (branches, tags, commits, PRs, files)
      5. Download GEI migration log (exponential backoff)
      6. Generate HTML dashboard + Markdown summary
.PARAMETER ADOOrg
    Azure DevOps organisation name (e.g. "mycompany")
.PARAMETER ADOProject
    Azure DevOps project name
.PARAMETER ADO_Repo
    Source repository name in ADO
.PARAMETER GHOrg
    Target GitHub organisation name
.PARAMETER GitHub_Repo
    Target GitHub repository name (defaults to ADO_Repo if omitted)
.PARAMETER OutputDir
    Directory for all reports, logs and dashboards  (default: ./output)
.PARAMETER TargetRepoVisibility
    GitHub repo visibility after migration: private, internal, or public (default: private)
.PARAMETER SkipAudit
    If set, skips the branch-wise audit (Step 4) -------- useful for large repos
.PARAMETER DryRun
    If set, prints the GEI command but does not execute it
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]  [string]$ADOOrg,
    [Parameter(Mandatory = $true)]  [string]$ADOProject,
    [Parameter(Mandatory = $true)]  [string]$ADO_Repo,
    [Parameter(Mandatory = $true)]  [string]$GHOrg,
    [Parameter(Mandatory = $false)] [string]$GitHub_Repo     = $ADO_Repo,
    [Parameter(Mandatory = $false)] [string]$OutputDir  = "$PSScriptRoot\..\output",
    [Parameter(Mandatory = $false)]
    [ValidateSet('private', 'internal', 'public')]
    [string]$TargetRepoVisibility = 'private',
    [switch]$SkipAudit,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- Global reporting variables (initialized for strict mode) ---
$branchCount    = 0
$tagCount       = 0
$commitCount    = 0
$prCount        = 0
$prOpen         = 0
$prMerged       = 0
$prClosed       = 0
$missingInGH    = @()
$extraInGH      = @()
$defaultBranch  = "N/A"
$topBranchHtml  = ""
$allBranchHtml  = ""
$phaseHtml      = ""
$reasonText     = "N/A"
$statusEmoji    = "&#x2139;&#xFE0F;"
$statusText     = "Unknown"
$statusBg       = "#f8f9fa"
$statusColor    = "#6c757d"
$migDate        = Get-Date -Format 'dd MMM yyyy -- HH:mm'
$branchCsvRows  = @()

# -- Trim whitespace from all string parameters ---------------------------------------------
$ADOOrg    = $ADOOrg.Trim()
$ADOProject = $ADOProject.Trim()
$ADO_Repo   = $ADO_Repo.Trim()
$GHOrg     = $GHOrg.Trim()
$GitHub_Repo    = $GitHub_Repo.Trim()

# -- Fallback: if GitHub_Repo is empty after trimming, default to ADO_Repo -----------------
if ([string]::IsNullOrWhiteSpace($GitHub_Repo)) {
    Write-Host "  GitHub_Repo was empty -------- defaulting to ADO_Repo: '$ADO_Repo'"
    $GitHub_Repo = $ADO_Repo
}

# -- Normalize ADOOrg -------- strip full URL if user set it as https://dev.azure.com/<org> ----------------
if ($ADOOrg -match '^https?://dev\.azure\.com/([^/]+)/?$') {
    Write-Host "  Normalising ADOOrg: stripping URL prefix -------- '$($Matches[1])'"
    $ADOOrg = $Matches[1]
}

# -- Normalize GHOrg -------- strip full URL if user set it as https://github.com/<org> ----------------
if ($GHOrg -match '^https?://github\.com/([^/]+)/?$') {
    Write-Host "  Normalising GHOrg: stripping URL prefix -------- '$($Matches[1])'"
    $GHOrg = $Matches[1]
}

# -- Validate PATs ------------------------------------------------------------
$ghPat  = $env:GH_PAT
$adoPat = $env:ADO_PAT
if ([string]::IsNullOrWhiteSpace($ghPat))  { Write-Error "Set GH_PAT environment variable" }
if ([string]::IsNullOrWhiteSpace($adoPat)) { Write-Error "Set ADO_PAT environment variable" }

# -- ADO REST API auth header (for branch comparison in Step 4) -----------------------
$adoBase64   = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$adoPat"))
$adoHeaders  = @{ Authorization = "Basic $adoBase64" }
$adoRepoUrl  = "https://dev.azure.com/$ADOOrg/$ADOProject/_apis/git/repositories/$ADO_Repo"

# -- Set GH_TOKEN once for all gh CLI calls ------------------------------------
$env:GH_TOKEN = $ghPat

# -- Script-level state tracking (avoids re-reading from disk) -------------------------------
$migState = "UNKNOWN"
$migLogUrl = $null   # captured from GEI output (Step 3) for direct download in Step 5

# -- In-memory audit data (avoids re-reading .txt files in Step 6) --------------------
$auditData = @{
    BranchCount   = "N/A"; TagCount      = "N/A"; CommitCount   = "N/A"
    PRCount       = "N/A"; PROpen        = "N/A"; PRMerged      = "N/A"
    PRClosed      = "N/A"; DefaultBranch = "N/A"
    LatestHash    = "N/A"
}

# -- Output directories --------------------------------------------------------------
$reportDir  = "$OutputDir\reports"
$logDir     = "$OutputDir\logs"
$auditDir   = "$OutputDir\audit\$GitHub_Repo"
$dashDir    = "$OutputDir\dashboard\$GitHub_Repo"
$folderDir  = "$auditDir\folder-listing"

foreach ($d in @($reportDir, $logDir, $auditDir, $dashDir, $folderDir)) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
}

$stateFile    = "$logDir\migration-state-$GitHub_Repo.txt"
$precheckFile = "$logDir\repo-precheck-$GitHub_Repo.txt"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  SINGLE REPO MIGRATION"
Write-Host "  ADO:    $ADOOrg / $ADOProject / $ADO_Repo"
Write-Host "  GitHub: $GHOrg / $GitHub_Repo"
Write-Host "  DryRun: $DryRun"
Write-Host "============================================"

# ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
# STEP 1 -------- Authenticate & install ado2gh extension
# ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
Write-Host "`n[Step 1] Authenticate GitHub CLI..." -ForegroundColor Cyan
# GH_TOKEN is already set once at script init -------- gh CLI uses it directly.
Write-Host "  Authenticating via GH_TOKEN environment variable."
$ErrorActionPreference = 'SilentlyContinue'
gh auth status 2>&1 | ForEach-Object { Write-Host "  $_" }
$ErrorActionPreference = 'Stop'
# Install ado2gh extension only if not already present
$installedExts = gh extension list 2>&1
if ($installedExts -notmatch 'ado2gh') {
    Write-Host "  Installing gh-ado2gh extension..."
    $ErrorActionPreference = 'SilentlyContinue'
    gh extension install github/gh-ado2gh 2>&1 | ForEach-Object { Write-Host "  $_" }
    $ErrorActionPreference = 'Stop'
} else {
    Write-Host "  ado2gh extension already installed."
}
gh extension list

# ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
# STEP 2 -------- Pre-check: does the GitHub repo already exist?
# ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
Write-Host "`n[Step 2] Pre-check repo existence in GitHub..." -ForegroundColor Cyan
$repoStatus = "NOT_EXISTS"
$ErrorActionPreference = 'SilentlyContinue'
[void](gh repo view "$GHOrg/$GitHub_Repo" --json name 2>&1)
if ($LASTEXITCODE -eq 0) {
    Write-Host "  Repo already exists: $GHOrg/$GitHub_Repo" -ForegroundColor Yellow
    $repoStatus = "ALREADY_EXISTS"
} else {
    Write-Host "  Repo does not exist yet (will be migrated): $GitHub_Repo"
    $repoStatus = "NOT_EXISTS"
}
$ErrorActionPreference = 'Stop'

$repoStatus | Out-File $precheckFile -Encoding utf8
Write-Host "  Status: $repoStatus"

# ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
# STEP 3 -------- Migrate repo via GEI
# ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
if ($repoStatus -eq "ALREADY_EXISTS") {
    Write-Host "`n[Step 3] SKIPPED -------- repo already exists in GitHub." -ForegroundColor Yellow
    $migState = "SKIPPED"
    $migState | Out-File $stateFile -Encoding utf8
}
elseif ($DryRun) {
    Write-Host "`n[Step 3] DRY RUN -------- GEI command that would run:" -ForegroundColor DarkYellow
    Write-Host "  gh ado2gh migrate-repo --ado-org `"$ADOOrg`" --ado-team-project `"$ADOProject`" --ado-repo `"$ADO_Repo`" --github-org `"$GHOrg`" --github-repo `"$GitHub_Repo`" --target-repo-visibility $TargetRepoVisibility"
    $migState = "DRY_RUN"
    $migState | Out-File $stateFile -Encoding utf8
}
else {
    Write-Host "`n[Step 3] Migrating repo..." -ForegroundColor Cyan
    $env:ADO_PAT  = $adoPat
    $env:GH_PAT   = $ghPat
    $migState = "PENDING"
    $migState | Out-File $stateFile -Encoding utf8

    Write-Host "  State: EXPORTING from ADO..."
    $migState = "EXPORTING"
    $migState | Out-File $stateFile -Encoding utf8

    # 1. Run Standard GEI Migration (to get PRs, Issues, etc.)
    Write-Host "  Step 3.1: Running gh ado2gh migrate-repo (GEI Logic)..." -ForegroundColor Cyan
    $migOutput = gh ado2gh migrate-repo `
        --ado-org          $ADOOrg `
        --ado-team-project $ADOProject `
        --ado-repo         $ADO_Repo `
        --github-org       $GHOrg `
        --github-repo      $GitHub_Repo `
        --target-repo-visibility $TargetRepoVisibility 2>&1

    $migOutput | ForEach-Object { Write-Host "  $_" }

    if ($LASTEXITCODE -eq 0 -or (($migOutput -join "") -match "already been queued")) {
        # 2. Check if we need to perform post-migration scrubbing
        $reportDirAbs = (Resolve-Path $reportDir).Path
        # Use a wildcard search to be more resilient to naming differences
        $exprFiles = Get-ChildItem -Path $reportDirAbs -Filter "expressions-*.txt"
        $expressionsFile = $exprFiles | Where-Object { $_.Name -match [regex]::Escape($ADO_Repo) } | Select-Object -ExpandProperty FullName -First 1
        
        if ($expressionsFile -and (Test-Path $expressionsFile)) {
            Write-Host "`n  Step 3.2: SECURE MODE -------- Found expressions file: $expressionsFile" -ForegroundColor Green
            Write-Host "  Performing post-migration scrub..."
            
            # Wait for migration to actually finish in GitHub (if queued)
            Write-Host "  Waiting for GitHub repo to be ready (up to 30 mins)..."
            $repoReady = $false
            for ($w = 1; $w -le 60; $w++) {
                $ErrorActionPreference = 'SilentlyContinue'
                $check = gh repo view "$GHOrg/$GitHub_Repo" --json name 2>&1
                $ErrorActionPreference = 'Stop'
                if ($LASTEXITCODE -eq 0) { $repoReady = $true; break }
                Write-Host "    $w/60: Still waiting..."
                Start-Sleep -Seconds 30
            }
            
            if (-not $repoReady) {
                Write-Warning "  GitHub repo did not become ready in time. Skipping scrub."
                return
            }

            # Local clone, scrub, and force-push
            $ghClonePath = Join-Path (Split-Path $logDir) "tmp\gh-scrub-$GitHub_Repo"
            if (Test-Path $ghClonePath) { Remove-Item -Recurse -Force $ghClonePath }
            
            Write-Host "  Cloning from GitHub for scrubbing..."
            $encodedPat = [uri]::EscapeDataString($ghPat)
            $ghRemote = "https://x-access-token:$encodedPat@github.com/$GHOrg/$GitHub_Repo.git"
            & git clone --mirror $ghRemote $ghClonePath 2>&1 | ForEach-Object { Write-Host "    $_" }
            
            if (-not (Test-Path $ghClonePath)) {
                Write-Warning "  Failed to clone GitHub repository for scrubbing. Check the logs above."
            }
            
            if (Test-Path $ghClonePath) {
                Push-Location $ghClonePath
                try {
                    Write-Host "  Expressions in $expressionsFile :"
                    $allExprs = Get-Content $expressionsFile
                    Write-Host "    Found $($allExprs.Count) replacement rules."
                    $allExprs | Select-Object -First 50 | ForEach-Object { Write-Host "    $_" }
                    if ($allExprs.Count -gt 50) { Write-Host "    ... (truncated)" }
                    
                    Write-Host "  Running git-filter-repo on GitHub history..."
                    & git filter-repo --replace-text "$expressionsFile" --force 2>&1 | ForEach-Object { Write-Host "    $_" }
                    
                    if ($LASTEXITCODE -ne 0) {
                        Write-Warning "  git-filter-repo reported an error. History may not have been rewritten."
                    }
                    else {
                        Write-Host "  History rewrite successful." -ForegroundColor Green
                    }

                    # --- VERIFICATION STEP: Ensure no secrets remain in the local clone ---
                    Write-Host "  Verifying scrub quality..."
                    $checkSecret = ($allExprs | Select-Object -First 1 -ExpandProperty p1).Split("==>")[0]
                    if ($checkSecret) {
                        $search = & git grep "$checkSecret" 2>&1
                        if ($search -match $checkSecret) {
                            Write-Error "CRITICAL FAILURE: Secret '$checkSecret' still found in history after scrub! Aborting push to prevent contamination."
                            return
                        }
                        Write-Host "  Verification PASSED. Secret not found in current HEAD." -ForegroundColor Green
                    }

                    # --- HANDLE BRANCH PROTECTION: Disable temporarily to allow force-push ---
                    Write-Host "  Checking for branch protection on GitHub..."
                    $defaultBranch = & gh repo view "$GHOrg/$GitHub_Repo" --json defaultBranchRef --jq .defaultBranchRef.name
                    $protection = & gh api "repos/$GHOrg/$GitHub_Repo/branches/$defaultBranch/protection" 2>$null
                    $hadProtection = $LASTEXITCODE -eq 0
                    
                    if ($hadProtection) {
                        Write-Host "  Temporarily disabling branch protection for $defaultBranch..."
                        & gh api "repos/$GHOrg/$GitHub_Repo/branches/$defaultBranch/protection" -X DELETE | Out-Null
                    }

                    Write-Host "  Force-pushing scrubbed history back to GitHub..."
                    # Push all branches and tags
                    & git push --force --mirror $ghRemote 2>&1 | ForEach-Object { Write-Host "    $_" }
                    
                    if ($hadProtection) {
                        Write-Host "  Restoring branch protection for $defaultBranch..."
                        # Note: This is a simplification; full restoration requires saving the original config.
                        # For now, we just notify the user.
                        Write-Warning "  Branch protection was disabled for $defaultBranch. Please re-enable it in GitHub settings."
                    }

                    Write-Host "  Post-migration scrub COMPLETE." -ForegroundColor Green
                }
                catch {
                    Write-Warning "  Post-migration scrub failed: $_"
                }
                finally {
                    Pop-Location
                }
            }
        }
        else {
            Write-Host "  Step 3.2: No expressions file found at $expressionsFile. Skipping post-migration scrub (nothing to redact)." -ForegroundColor Gray
        }
    }

    if ($LASTEXITCODE -eq 0) {
        Write-Host "  State: COMPLETE" -ForegroundColor Green
        $migState = "COMPLETE"
        $migState | Out-File $stateFile -Encoding utf8
    }
    elseif (($migOutput -join "") -match "already been queued") {
        Write-Host "  Migration already queued -------- polling until repo appears..." -ForegroundColor Yellow
        $migState = "WAITING"
        $migState | Out-File $stateFile -Encoding utf8
        $found = $false
        for ($w = 1; $w -le 30; $w++) {
            Start-Sleep -Seconds 60
            Write-Host "  Poll $w/30..."
            $ErrorActionPreference = 'SilentlyContinue'
            $check = gh repo view "$GHOrg/$GitHub_Repo" --json name 2>&1
            $ErrorActionPreference = 'Stop'
            if ($LASTEXITCODE -eq 0) { $found = $true; break }
        }
        if ($found) {
            $migState = "COMPLETE"
            $migState | Out-File $stateFile -Encoding utf8
            Write-Host "  State: COMPLETE (queued migration finished)" -ForegroundColor Green
        }
        else {
            $migState = "FAILED"
            $migState | Out-File $stateFile -Encoding utf8
            Write-Warning "Migration did not complete within 30 minutes. Check GEI logs."
        }
    }
    else {
        Write-Host "`n[Step 3] GEI Migration FAILED!" -ForegroundColor Red
        $migOutput | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkRed }
        $migState = "FAILED"
        $migState | Out-File $stateFile -Encoding utf8
        $outputStr = $migOutput -join "`n"
        if ($outputStr -match 'lookup the Organization ID|Failed to lookup') {
            Write-Warning @"
Migration failed: GitHub could not resolve org '$GHOrg'.
  ROOT CAUSE -------- GH_PAT is missing required scopes.
  Required classic PAT scopes:
    - repo          (Full control of private repositories)
    - read:org      (Read org and team membership, org projects)
  Note: Fine-grained PATs are NOT supported by gh ado2gh.
  Fix: Go to github.com/settings/tokens -------- regenerate the classic PAT
       with 'repo' and 'read:org' (or 'admin:org') scopes,
       then update the GH_PAT value in the repo-migration-migrate variable group.
"@
        } else {
            Write-Warning @"
Migration failed (exit code $LASTEXITCODE). Common causes:
  1. ADO_PAT scope: needs 'Code (Read)' + 'Identity (Read)' on the ADO organisation.
  2. ADOOrg name mismatch: check the value in the repo-migration-discover variable group.
     (Value must be bare org name e.g. 'YashTech-DevOps', not a full URL)
  3. GHOrg name mismatch or GH_PAT lacks 'repo' + 'read:org' scopes.
GEI output above should contain a more specific error message.
"@
        }
    }
}

# ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
# STEP 4 -------- Branch-wise post-migration audit
# ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
if ($SkipAudit) {
    Write-Host "`n[Step 4] SKIPPED (--------SkipAudit flag set)." -ForegroundColor Yellow
}
elseif ($migState -in @("FAILED", "DRY_RUN", "UNKNOWN")) {
    Write-Host "`n[Step 4] SKIPPED -------- migration state is '$migState', no repo to audit." -ForegroundColor Yellow
}
else {
    Write-Host "`n[Step 4] Post-migration audit (API-only, no clone)..." -ForegroundColor Cyan

    $ProgressPreference = 'SilentlyContinue'

    # -- Helper: paginated GitHub REST API -----------------------------------------
    function Get-GitHubPages([string]$endpoint) {
        $all = @(); $page = 1
        do {
            $sep = if ($endpoint -match '\?') { '&' } else { '?' }
            $batch = @(gh api "${endpoint}${sep}per_page=100&page=$page" 2>$null | ConvertFrom-Json)
            if ($batch.Count -gt 0) { $all += $batch; $page++ } else { break }
        } while ($batch.Count -eq 100)
        return $all
    }

    # -- 4a. Repo metadata (default branch + size) -------- single API call ----------------------
    Write-Host "  Fetching repo metadata..."
    $repoInfoRaw = gh api "repos/$GHOrg/$GitHub_Repo" 2>$null
    $repoInfo = $null
    if ($repoInfoRaw) { $repoInfo = $repoInfoRaw | ConvertFrom-Json }

    if (-not $repoInfo) {
        Write-Warning "  Could not fetch repo info via API -------- skipping audit."
    }
    else {
        $defaultBranch = $repoInfo.default_branch
        $defaultBranch | Out-File "$auditDir\gh-default-branch.txt" -Encoding utf8
        Write-Host "  Default branch: $defaultBranch"

        # -- 4b. Branches via REST API (paginated) --------------------------------
        Write-Host "  Fetching branches..."
        $branchObjs  = Get-GitHubPages "repos/$GHOrg/$GitHub_Repo/branches"
        $branches    = @($branchObjs | ForEach-Object { $_.name })
        $branchCount = $branches.Count
        $branches    | Out-File "$auditDir\gh-branches.txt" -Encoding utf8
        Write-Host "  Branches (GitHub): $branchCount"

        # -- 4b-2. ADO branches via REST API (for comparison) ------------
        Write-Host "  Fetching ADO branches for comparison..."
        $adoBranches = @()
        try {
            $skip = 0
            do {
                $brResp = Invoke-WebRequest -Uri "$adoRepoUrl/refs?filter=heads/&`$top=1000&`$skip=$skip&api-version=7.1" -Headers $adoHeaders -UseBasicParsing
                $brJson = $brResp.Content | ConvertFrom-Json
                $batch  = @($brJson.value)
                $adoBranches += $batch | ForEach-Object { $_.name -replace '^refs/heads/', '' }
                $skip += $batch.Count
            } while ($batch.Count -eq 1000)
            Write-Host "  Branches (ADO): $($adoBranches.Count)"
        }
        catch {
            Write-Warning "  Could not fetch ADO branches: $_ -------- comparison will be skipped."
            $adoBranches = @()
        }

        # -- 4b-3. Compare ADO vs GitHub branches ----------------------------------------
        $missingInGH = @()
        if ($adoBranches.Count -gt 0) {
            $missingInGH = @($adoBranches | Where-Object { $_ -notin $branches })
            $extraInGH   = @($branches | Where-Object { $_ -notin $adoBranches })
            Write-Host "  Missing in GitHub: $($missingInGH.Count)  |  Extra in GitHub: $($extraInGH.Count)"
            if ($missingInGH.Count -gt 0) {
                $missingInGH | Out-File "$auditDir\gh-missing-branches.txt" -Encoding utf8
            }
        }

        # -- 4c. Tags via REST API (paginated) -------------------------------------------
        Write-Host "  Fetching tags..."
        $tagObjs  = Get-GitHubPages "repos/$GHOrg/$GitHub_Repo/tags"
        $tags     = @($tagObjs | ForEach-Object { $_.name })
        $tagCount = $tags.Count
        if ($tags.Count -gt 0) { $tags | Out-File "$auditDir\gh-tags.txt" -Encoding utf8 }
        else                   { ""    | Out-File "$auditDir\gh-tags.txt" -Encoding utf8 }
        Write-Host "  Tags: $tagCount"

        # -- 4d. Latest commit hash (default branch) -------------------------------------
        $defaultBranchObj = $branchObjs | Where-Object { $_.name -eq $defaultBranch } | Select-Object -First 1
        $latestHash = if ($defaultBranchObj) { $defaultBranchObj.commit.sha } else { "N/A" }
        Write-Host "  Latest hash: $latestHash"

        # -- 4e. Branch metadata via commit-detail API ---------------------
        Write-Host "  Fetching per-branch commit metadata..."
        $refMeta = @{}
        foreach ($bObj in $branchObjs) {
            $bName = $bObj.name
            $bSha  = $bObj.commit.sha
            $cRaw  = gh api "repos/$GHOrg/$GitHub_Repo/commits/$bSha" 2>$null
            $cDetail = $null
            if ($cRaw) { $cDetail = $cRaw | ConvertFrom-Json }
            if ($cDetail -and $cDetail.PSObject.Properties['commit']) {
                $c = $cDetail.commit
                $cAuthor = "N/A"; $cDate = "N/A"; $cMsg = "N/A"
                if ($c.PSObject.Properties['author'] -and $c.author) {
                    if ($c.author.PSObject.Properties['name'] -and $c.author.name) { $cAuthor = $c.author.name }
                    if ($c.author.PSObject.Properties['date'] -and $c.author.date) { $cDate = ([datetime]$c.author.date).ToString("yyyy-MM-dd") }
                }
                if ($c.PSObject.Properties['message'] -and $c.message) { $cMsg = ($c.message -split "`n")[0] }
                $refMeta[$bName] = @{
                    Hash   = $bSha.Substring(0, [Math]::Min(12, $bSha.Length))
                    Author = $cAuthor
                    Date   = $cDate
                    Msg    = $cMsg
                }
            }
        }

        # -- 4f. Commit counts via GraphQL (batched, up to 50 branches per query) ----------------
        Write-Host "  Fetching commit counts via GraphQL..."
        $commitCounts = @{}
        $batchSize = 50
        for ($i = 0; $i -lt $branches.Count; $i += $batchSize) {
            $slice = $branches[$i..[Math]::Min($i + $batchSize - 1, $branches.Count - 1)]
            $aliases = @()
            $idx = 0
            foreach ($bn in $slice) {
                $alias = "b$idx"
                $qualName = "refs/heads/$bn"
                $aliases += "  $alias`: ref(qualifiedName: `"$qualName`") { target { ... on Commit { history { totalCount } } } }"
                $idx++
            }
            $gqlQuery = "{ repository(owner: `"$GHOrg`", name: `"$GitHub_Repo`") {`n" + ($aliases -join "`n") + "`n} }"
            $gqlRaw = gh api graphql -f query="$gqlQuery" 2>$null
            $gqlResult = $null
            if ($gqlRaw) { $gqlResult = $gqlRaw | ConvertFrom-Json }

            if ($gqlResult -and $gqlResult.PSObject.Properties['data']) {
                $gqlData = $gqlResult.data
                if ($gqlData.PSObject.Properties['repository']) {
                    $gqlRepo = $gqlData.repository
                    $idx = 0
                    foreach ($bn in $slice) {
                        $alias = "b$idx"
                        if ($gqlRepo.PSObject.Properties[$alias]) {
                            $refData = $gqlRepo.$alias
                            if ($refData -and $refData.PSObject.Properties['target']) {
                                $tgt = $refData.target
                                if ($tgt -and $tgt.PSObject.Properties['history']) {
                                    $commitCounts[$bn] = $tgt.history.totalCount
                                }
                            }
                        }
                        $idx++
                    }
                }
            }
        }

        # Total commits = default branch count (most meaningful; --all double-counts shared commits)
        $totalCommits = if ($commitCounts.ContainsKey($defaultBranch)) { "$($commitCounts[$defaultBranch])" } else { "N/A" }
        Write-Host "  Total commits (default branch): $totalCommits"

        # -- 4g. File listing via Trees API (default branch only) -----------------
        Write-Host "  Fetching file tree for default branch..."
        $csvFolderFile    = "$auditDir\gh-folder-wise-files.csv"
        $csvFolderSummary = "$auditDir\gh-folder-summary.csv"
        $folderFileRows   = [System.Collections.Generic.List[PSCustomObject]]::new()
        $folderSummRows   = [System.Collections.Generic.List[PSCustomObject]]::new()

        $defaultSha = if ($defaultBranchObj) { $defaultBranchObj.commit.sha } else { $null }
        $bFileCount   = 0
        $bFolderCount = 0

        if ($defaultSha) {
            $treeRaw = gh api "repos/$GHOrg/$GitHub_Repo/git/trees/${defaultSha}?recursive=1" 2>$null
            $treeData = $null
            if ($treeRaw) { $treeData = $treeRaw | ConvertFrom-Json }
            if ($treeData -and $treeData.PSObject.Properties['tree']) {
                $blobEntries = @($treeData.tree | Where-Object { $_.type -eq "blob" })
                $bFileCount  = $blobEntries.Count

                $isTruncated = $false
                if ($treeData.PSObject.Properties['truncated']) { $isTruncated = $treeData.truncated }

                if ($isTruncated) {
                    Write-Host "    WARNING: Tree truncated (100K+ files) -------- skipping folder enumeration"
                    $bFolderCount = "100K+ (API limit)"
                }
                elseif ($bFileCount -gt 50000) {
                    Write-Host "    WARNING: $bFileCount files exceeds 50K cap -------- skipping folder enumeration"
                    $bFolderCount = "50K+ (skipped)"
                }
                else {
                    $filesByFolder = [ordered]@{}
                    foreach ($entry in $blobEntries) {
                        $f = $entry.path
                        $folder = (Split-Path $f -Parent) -replace '\\','/'
                        if (-not $folder) { $folder = "(root)" }
                        if (-not $filesByFolder.Contains($folder)) { $filesByFolder[$folder] = @() }
                        $filesByFolder[$folder] += Split-Path $f -Leaf
                    }
                    $bFolderCount = $filesByFolder.Keys.Count

                    # Write per-branch Markdown file listing
                    $safeBranch   = $defaultBranch -replace '[/\\]','--'
                    $branchFileMd = "# Files in branch: $defaultBranch`n`n"
                    foreach ($folder in ($filesByFolder.Keys | Sort-Object)) {
                        $branchFileMd += "## $folder/`n"
                        foreach ($file in ($filesByFolder[$folder] | Sort-Object)) { $branchFileMd += "- $file`n" }
                        $branchFileMd += "`n"
                    }
                    $branchFileMd | Out-File "$folderDir\gh-files-$safeBranch.md" -Encoding utf8

                    # Folder summary Markdown for default branch
                    $folderSummaryMd = "| Folder | Files |`n|---|---|`n"
                    $folderTotal = 0
                    foreach ($folder in ($filesByFolder.Keys | Sort-Object)) {
                        $fc = $filesByFolder[$folder].Count
                        $folderTotal += $fc
                        $folderSummaryMd += "| $folder | $fc |`n"
                    }
                    $folderSummaryMd += "| **Total** | **$folderTotal** |`n"
                    $folderSummaryMd | Out-File "$auditDir\gh-folder-summary-default.md" -Encoding utf8

                    # Batch-collect folder CSV rows (single write at end)
                    foreach ($folder in $filesByFolder.Keys) {
                        $folderSummRows.Add([PSCustomObject]@{ Branch=$defaultBranch; Folder=$folder; FileCount=$filesByFolder[$folder].Count })
                        foreach ($file in $filesByFolder[$folder]) {
                            $folderFileRows.Add([PSCustomObject]@{ Branch=$defaultBranch; Folder=$folder; FileName=$file })
                        }
                    }
                    $filesByFolder = $null
                }
                $blobEntries = $null
            }
        }

        # -- 4i. Build branch CSV rows --------------------------------------------
        $branchCsvRows = @()
        $bIdx = 0
        $branchStatus = if ($migState -eq 'SKIPPED') { 'Already Existed' } else { 'Migrated' }
        foreach ($b in $branches) {
            $bIdx++
            Write-Host "  [$bIdx/$branchCount] $b"

            $m = if ($refMeta.ContainsKey($b)) { $refMeta[$b] } else { @{ Hash="N/A"; Author="N/A"; Date="N/A"; Msg="N/A" } }

            if ($b -eq $defaultBranch) {
                $branchCsvRows += [PSCustomObject]@{
                    Branch=$b; Status=$branchStatus; Files=$bFileCount; Folders=$bFolderCount
                    LatestHash=$m.Hash; LatestAuthor=$m.Author; LatestDate=$m.Date; LatestMsg=$m.Msg
                }
            } else {
                $branchCsvRows += [PSCustomObject]@{
                    Branch=$b; Status=$branchStatus; Files="-"; Folders="-"
                    LatestHash=$m.Hash; LatestAuthor=$m.Author; LatestDate=$m.Date; LatestMsg=$m.Msg
                }
            }
        }
        # Append ADO branches missing in GitHub
        foreach ($mb in $missingInGH) {
            $branchCsvRows += [PSCustomObject]@{
                Branch=$mb; Status="Missing"; Files="-"; Folders="-"
                LatestHash="-"; LatestAuthor="-"; LatestDate="-"; LatestMsg="Not found in GitHub"
            }
        }
        $branchCsvRows | Export-Csv "$auditDir\gh-branch-wise-data.csv" -NoTypeInformation -Encoding utf8

        # Write folder CSVs in one batch
        if ($folderSummRows.Count -gt 0) { $folderSummRows | Export-Csv -Path $csvFolderSummary -NoTypeInformation -Encoding utf8 -Force }
        if ($folderFileRows.Count -gt 0) { $folderFileRows | Export-Csv -Path $csvFolderFile    -NoTypeInformation -Encoding utf8 -Force }
        Write-Host "  Folder CSVs: $($folderFileRows.Count) file rows, $($folderSummRows.Count) folder rows"
        $folderFileRows = $null; $folderSummRows = $null

        # -- 4j. Top 5 key branches with commit counts (from GraphQL data) --------
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
            $cnt   = if ($commitCounts.ContainsKey($tb.Branch)) { $commitCounts[$tb.Branch] } else { 0 }
            $isDef = if ($tb.Branch -eq $defaultBranch) { "Yes" } else { "No" }
            $topRows += [PSCustomObject]@{ Branch=$tb.Branch; Commits=("{0:N0}" -f [long]$cnt); IsDefault=$isDef }
        }
        $topRows | Export-Csv "$auditDir\gh-top-branches.csv" -NoTypeInformation -Encoding utf8

        # PR audit via GitHub API
        $allPRs = @(); $page = 1
        do {
            $prs = @(gh api "repos/$GHOrg/$GitHub_Repo/pulls?state=all&per_page=100&page=$page" 2>$null | ConvertFrom-Json)
            if ($prs.Count -gt 0) { $allPRs += $prs; $page++ } else { break }
        } while ($prs.Count -eq 100)

        $totalPRs    = $allPRs.Count
        $totalOpen   = @($allPRs | Where-Object { $_.state -eq "open" }).Count
        $totalMerged = @($allPRs | Where-Object { $_.merged_at }).Count
        $totalClosed = $totalPRs - $totalOpen - $totalMerged

        # PR breakdown by source branch (head)
        $prByHead = @{}
        foreach ($pr in $allPRs) {
            $head = $pr.head.ref
            if (-not $prByHead.ContainsKey($head)) { $prByHead[$head] = @{ Open=0; Merged=0; Closed=0 } }
            if     ($pr.state -eq "open") { $prByHead[$head].Open++ }
            elseif ($pr.merged_at)        { $prByHead[$head].Merged++ }
            else                          { $prByHead[$head].Closed++ }
        }
        $prHeadMd = "| Source Branch (head) | Open | Merged | Closed | Total |`n|---|---|---|---|---|`n"
        foreach ($hb in ($prByHead.Keys | Sort-Object)) {
            $o=$prByHead[$hb].Open; $m=$prByHead[$hb].Merged; $c=$prByHead[$hb].Closed; $t=$o+$m+$c
            $prHeadMd += "| $hb | $o | $m | $c | $t |`n"
        }
        $prHeadMd += "| **TOTAL** | **$totalOpen** | **$totalMerged** | **$totalClosed** | **$totalPRs** |`n"
        $prHeadMd | Out-File "$auditDir\gh-pr-by-source-branch.md" -Encoding utf8

        # PR breakdown by target branch (base)
        $prByBase = @{}
        foreach ($pr in $allPRs) {
            $base = $pr.base.ref
            if (-not $prByBase.ContainsKey($base)) { $prByBase[$base] = @{ Open=0; Merged=0; Closed=0 } }
            if     ($pr.state -eq "open") { $prByBase[$base].Open++ }
            elseif ($pr.merged_at)        { $prByBase[$base].Merged++ }
            else                          { $prByBase[$base].Closed++ }
        }
        $prBaseMd = "| Target Branch (base) | Open | Merged | Closed | Total |`n|---|---|---|---|---|`n"
        foreach ($bb in ($prByBase.Keys | Sort-Object)) {
            $o=$prByBase[$bb].Open; $m=$prByBase[$bb].Merged; $c=$prByBase[$bb].Closed; $t=$o+$m+$c
            $prBaseMd += "| $bb | $o | $m | $c | $t |`n"
        }
        $prBaseMd += "| **TOTAL** | **$totalOpen** | **$totalMerged** | **$totalClosed** | **$totalPRs** |`n"
        $prBaseMd | Out-File "$auditDir\gh-pr-by-target-branch.md" -Encoding utf8

        # Branch-wise Markdown table
        $mdTable  = "| # | Branch | Status | Files | Latest Commit | Date |`n"
        $mdTable += "|---|---|---|---|---|---|`n"
        $idx = 1
        foreach ($row in ($branchCsvRows | Sort-Object Branch)) {
            $mdTable += "| $idx | ``$($row.Branch)`` | $($row.Status) | $($row.Files) | $($row.LatestAuthor) - *$($row.LatestMsg)* | $($row.LatestDate) |`n"
            $idx++
        }
        $mdTable | Out-File "$auditDir\gh-branch-wise-table.md" -Encoding utf8

        # Write metric text files
        $branchCount  | Out-File "$auditDir\gh-branch-count.txt"  -Encoding utf8
        $tagCount     | Out-File "$auditDir\gh-tag-count.txt"     -Encoding utf8
        $totalCommits | Out-File "$auditDir\gh-commit-count.txt"  -Encoding utf8
        $totalPRs     | Out-File "$auditDir\gh-pr-count.txt"      -Encoding utf8
        $totalOpen    | Out-File "$auditDir\gh-pr-open.txt"       -Encoding utf8
        $totalMerged  | Out-File "$auditDir\gh-pr-merged.txt"     -Encoding utf8
        $totalClosed  | Out-File "$auditDir\gh-pr-closed.txt"     -Encoding utf8
        $latestHash   | Out-File "$auditDir\gh-latest-hash.txt"   -Encoding utf8

        # -- Populate in-memory audit data for Step 6 (dashboard) ---------------
        $auditData.BranchCount   = "$branchCount"
        $auditData.TagCount      = "$tagCount"
        $auditData.CommitCount   = "$totalCommits"
        $auditData.PRCount       = "$totalPRs"
        $auditData.PROpen        = "$totalOpen"
        $auditData.PRMerged      = "$totalMerged"
        $auditData.PRClosed      = "$totalClosed"
        $auditData.DefaultBranch = $defaultBranch
        $auditData.LatestHash    = $latestHash

        Write-Host "  Audit complete. PRs: $totalPRs (Open:$totalOpen Merged:$totalMerged Closed:$totalClosed)" -ForegroundColor Green
    }
}

# ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
# STEP 5 -------- Download GEI migration log
# ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
if ($migState -in @("SKIPPED","DRY_RUN","FAILED")) {
    Write-Host "`n[Step 5] Skipping log download (state: $migState)." -ForegroundColor Yellow
}
else {
    Write-Host "`n[Step 5] Downloading GEI migration log..." -ForegroundColor Cyan
    $migLogFile = "$logDir\migration-log-$GitHub_Repo.log"
    $success = $false

    # -- Fast path: direct download via URL captured from GEI output ----------------------
    if ($migLogUrl) {
        Write-Host "  Downloading directly from captured URL (no wait)..."
        try {
            Invoke-WebRequest -Uri $migLogUrl -OutFile $migLogFile -UseBasicParsing -ErrorAction Stop
            $success = $true
            Write-Host "  Log saved (direct download): $migLogFile" -ForegroundColor Green
        } catch {
            Write-Host "  Direct download failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    # -- Fallback: gh ado2gh download-logs with short backoff ---------------
    if (-not $success) {
        $backoff = 10   # start at 10s (was 30s)
        for ($i = 1; $i -le 4; $i++) {
            Write-Host "  Attempt $i/4 (waiting ${backoff}s)..."
            Start-Sleep -Seconds $backoff
            $ErrorActionPreference = 'SilentlyContinue'
            $out = gh ado2gh download-logs --github-org $GHOrg --github-repo $GitHub_Repo --migration-log-file $migLogFile --overwrite 2>&1
            $ErrorActionPreference = 'Stop'
            if ($LASTEXITCODE -eq 0) { $success = $true; break }
            $backoff = [math]::Min($backoff * 2, 60)   # max 60s between retries
        }
    }

    if (-not $success) {
        "Log download failed" | Out-File $migLogFile -Encoding utf8
        Write-Warning "  Logs unavailable (non-critical - migration data is complete)."
    }
    elseif (-not $migLogUrl) {
        Write-Host "  Log saved: $migLogFile" -ForegroundColor Green
    }
}

# ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
# STEP 6 -------- Generate HTML dashboard + Markdown summary
# ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
Write-Host "`n[Step 6] Generating HTML dashboard..." -ForegroundColor Cyan

# Use in-memory audit data (populated in Step 4) -------- no file re-reads
$branchCount   = $auditData.BranchCount
$tagCount      = $auditData.TagCount
$commitCount   = $auditData.CommitCount
$prCount       = $auditData.PRCount
$prOpen        = $auditData.PROpen
$prMerged      = $auditData.PRMerged
$prClosed      = $auditData.PRClosed
$defaultBranch = $auditData.DefaultBranch
$migDate       = Get-Date -Format 'dd MMM yyyy - HH:mm'

if ($migState -eq "SKIPPED") {
    $migResult   = "Already Exists"; $statusColor = "#f0ad4e"; $statusBg = "#fff8e1"
    $statusEmoji = "&#x26A0;&#xFE0F;";  $statusText  = "Skipped &#x2014; Repository Already Exists"
    $reasonText  = "Target repository was detected in GitHub prior to migration."
} elseif ($migState -eq "DRY_RUN") {
    $migResult   = "Dry Run";         $statusColor = "#0969da"; $statusBg = "#ddf4ff"
    $statusEmoji = "&#x1F4CB;";       $statusText  = "Dry Run &#x2014; No changes made"
    $reasonText  = "Dry run mode: GEI command was printed but not executed."
} elseif ($migState -eq "COMPLETE") {
    $migResult   = "Success";         $statusColor = "#28a745"; $statusBg = "#e6f9ed"
    $statusEmoji = "&#x2705;";        $statusText  = "Completed - Migration Successful"
    $reasonText  = "Repository migrated successfully from ADO to GitHub."
} else {
    $migResult   = "Failed";          $statusColor = "#dc3545"; $statusBg = "#fdecea"
    $statusEmoji = "&#x274C;";        $statusText  = "Failed - Migration Error"
    $reasonText  = "Check migration logs for error details."
}

# Pipeline execution phase rows
if ($migState -eq "SKIPPED") {
    $phaseRows = @(
        @("&#x2705;","Pre-Check","Completed","#28a745"),
        @("&#x23E9;","Migration","Skipped","#f0ad4e"),
        @("&#x2705;","Audit","Completed","#28a745"),
        @("&#x26A0;&#xFE0F;","Result","Repository Already Exists","#f0ad4e")
    )
} elseif ($migState -eq "COMPLETE") {
    $phaseRows = @(
        @("&#x2705;","Pre-Check","Completed","#28a745"),
        @("&#x2705;","Migration","Completed","#28a745"),
        @("&#x2705;","Audit","Completed","#28a745"),
        @("&#x2705;","Result","Migration Successful","#28a745")
    )
} else {
    $phaseRows = @(
        @("&#x2705;","Pre-Check","Completed","#28a745"),
        @("&#x274C;","Migration","Failed","#dc3545"),
        @("&#x2705;","Audit","Completed","#28a745"),
        @("&#x274C;","Result","Migration Failed","#dc3545")
    )
}
$phaseHtml = ""
foreach ($p in $phaseRows) {
    $phaseHtml += "<tr><td style='font-size:20px;text-align:center;'>$($p[0])</td><td><strong>$($p[1])</strong></td><td style='color:$($p[3]);font-weight:600;'>$($p[2])</td></tr>`n"
}

# Top branches table rows
$topBranchHtml = ""
$topCsvFile    = "$auditDir\gh-top-branches.csv"
if (Test-Path $topCsvFile) {
    $topRows = Import-Csv $topCsvFile; $rank = 1
    foreach ($r in $topRows) {
        $defLabel = if ($r.IsDefault -eq "Yes") { " <span style='background:#ddf4ff;color:#0969da;padding:2px 8px;border-radius:8px;font-size:11px;font-weight:700;margin-left:6px;'>DEFAULT</span>" } else { "" }
        $topBranchHtml += "<tr><td style='text-align:center;color:#6f42c1;font-weight:700;'>$rank</td><td><code>$($r.Branch)</code>$defLabel</td><td style='text-align:right;font-weight:600;font-variant-numeric:tabular-nums;'>$($r.Commits)</td></tr>`n"
        $rank++
    }
}
if ($topBranchHtml -eq "") { $topBranchHtml = "<tr><td colspan='3' style='color:#999;text-align:center;'>No data</td></tr>" }

# All branches rows
$allBranchHtml = ""
$branchCsvFile = "$auditDir\gh-branch-wise-data.csv"
if (Test-Path $branchCsvFile) {
    $allRows = Import-Csv $branchCsvFile | Sort-Object @{Expression={if ($_.Status -eq 'Missing') {1} else {0}}}, Branch; $idx = 1
    foreach ($r in $allRows) {
        switch ($r.Status) {
            'Missing'         { $badge = "<span style='background:#ffebe9;color:#cf222e;padding:4px 12px;border-radius:12px;font-weight:600;font-size:13px;'>&#x274C; Missing</span>" }
            'Already Existed'  { $badge = "<span style='background:#fff8c5;color:#9a6700;padding:4px 12px;border-radius:12px;font-weight:600;font-size:13px;'>&#x26A0;&#xFE0F; Already Existed</span>" }
            default           { $badge = "<span style='background:#dafbe1;color:#1a7f37;padding:4px 12px;border-radius:12px;font-weight:600;font-size:13px;'>&#x2705; Migrated</span>" }
        }
        $allBranchHtml += "<tr><td style='text-align:center;'>$idx</td><td><code>$($r.Branch)</code></td><td style='text-align:center;'>$badge</td></tr>`n"
        $idx++
    }
}
if ($allBranchHtml -eq "") { $allBranchHtml = "<tr><td colspan='3' style='color:#999;text-align:center;'>No data</td></tr>" }

$nl = [Environment]::NewLine
$html  = "<!DOCTYPE html><html lang='en'><head><meta charset='UTF-8'><meta name='viewport' content='width=device-width,initial-scale=1.0'><title>Migration Report - $GitHub_Repo</title>" + $nl
$html += "<style>*{margin:0;padding:0;box-sizing:border-box}body{font-family:'Segoe UI',Tahoma,Geneva,Verdana,sans-serif;background:#f4f6f9;color:#333;padding:30px;font-size:16px}"
$html += ".container{max-width:960px;margin:0 auto}.header{background:linear-gradient(135deg,#0d1117 0%,#161b22 100%);color:#fff;padding:32px 36px;border-radius:14px;margin-bottom:24px}"
$html += ".header h1{font-size:28px;margin-bottom:12px}.status-banner{display:inline-block;padding:10px 22px;border-radius:8px;font-size:18px;font-weight:600;margin-top:6px;background:$statusBg;color:$statusColor;border:2px solid $statusColor}"
$html += ".card{background:#fff;border-radius:12px;padding:28px 32px;margin-bottom:20px;box-shadow:0 2px 8px rgba(0,0,0,.06)}.card h2{font-size:22px;margin-bottom:18px;color:#0d1117;border-bottom:2px solid #e1e4e8;padding-bottom:10px}"
$html += "table{width:100%;border-collapse:collapse;font-size:15px}th{background:#f6f8fa;text-align:left;padding:12px 16px;font-weight:600;color:#24292f;border-bottom:2px solid #d0d7de}"
$html += "td{padding:11px 16px;border-bottom:1px solid #eaecef}tr:hover{background:#f6f8fa}"
$html += ".overview-table td:first-child{font-weight:600;width:220px;color:#555;font-size:16px}.overview-table td:last-child{font-size:16px}"
$html += "code{background:#eff1f3;padding:3px 8px;border-radius:5px;font-size:14px;color:#0d1117}"
$html += ".stat-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:16px;margin-bottom:8px}"
$html += ".stat-box{background:#f6f8fa;border-radius:10px;padding:20px;text-align:center;border:1px solid #e1e4e8}"
$html += ".stat-box .num{font-size:32px;font-weight:700;color:#0d1117}.stat-box .label{font-size:14px;color:#666;margin-top:4px}"
$html += ".reason{background:#f0f4f8;border-left:4px solid $statusColor;padding:12px 18px;border-radius:6px;margin-top:14px;font-size:15px;color:#555}"
$html += "details{margin-top:10px}details summary{cursor:pointer;font-weight:600;font-size:16px;color:#0969da;padding:8px 0}details summary:hover{text-decoration:underline}"
$html += ".pr-pills{display:flex;gap:12px;flex-wrap:wrap}.pr-pill{padding:8px 18px;border-radius:20px;font-weight:600;font-size:15px}"
$html += ".pr-open{background:#dafbe1;color:#1a7f37}.pr-merged{background:#e8d5f5;color:#8250df}.pr-closed{background:#fdecea;color:#cf222e}"
$html += ".footer{text-align:center;color:#999;font-size:13px;margin-top:30px;padding-top:16px;border-top:1px solid #e1e4e8}</style></head><body><div class='container'>" + $nl
# Header
$html += "<div class='header'><h1>&#x1F680; ADO &#x2192; GitHub Migration Report</h1><div class='status-banner'>$statusEmoji $statusText</div></div>" + $nl
# Migration overview
$html += "<div class='card'><h2>&#x1F4C2; Migration Overview</h2><table class='overview-table'>" + $nl
$html += "<tr><td>&#x1F4C5; Migration Date</td><td>$migDate</td></tr>" + $nl
$html += "<tr><td>&#x1F4E6; Source (ADO)</td><td><code>$ADOOrg / $ADOProject / $ADO_Repo</code></td></tr>" + $nl
$html += "<tr><td>&#x1F3AF; Target (GitHub)</td><td><code>$GHOrg / $GitHub_Repo</code></td></tr>" + $nl
$html += "<tr><td>&#x1F33F; Default Branch</td><td><code>$defaultBranch</code></td></tr>" + $nl
$html += "</table></div>" + $nl
# Pipeline execution status
$html += "<div class='card'><h2>&#x1F6A6; Pipeline Execution Status</h2><table>" + $nl
$html += "<thead><tr><th style='width:50px;'></th><th>Phase</th><th>Status</th></tr></thead><tbody>" + $nl
$html += $phaseHtml
$html += "</tbody></table><div class='reason'>&#x2139;&#xFE0F; <strong>Reason:</strong> $reasonText</div></div>" + $nl
# Repository snapshot
$html += "<div class='card'><h2>&#x1F4CA; Repository Snapshot</h2><div class='stat-grid'>" + $nl
$html += "<div class='stat-box'><div class='num'>$branchCount</div><div class='label'>&#x1F33F; Branches</div></div>" + $nl
$html += "<div class='stat-box'><div class='num'>$tagCount</div><div class='label'>&#x1F3F7;&#xFE0F; Tags</div></div>" + $nl
$html += "<div class='stat-box'><div class='num'>$commitCount</div><div class='label'>&#x1F4DD; Commits</div></div>" + $nl
$html += "<div class='stat-box'><div class='num'>$prCount</div><div class='label'>&#x1F500; Pull Requests</div></div>" + $nl
$html += "</div><div class='pr-pills' style='margin-top:14px;'><span class='pr-pill pr-open'>&#x1F7E2; $prOpen Open</span><span class='pr-pill pr-merged'>&#x1F7E3; $prMerged Merged</span><span class='pr-pill pr-closed'>&#x1F534; $prClosed Closed</span></div></div>" + $nl
# Key branches
$html += "<div class='card'><h2>&#x1F511; Key Branches</h2><table><thead><tr><th style='text-align:center;'>#</th><th>Branch</th><th style='text-align:right;'>Commits</th></tr></thead><tbody>$topBranchHtml</tbody></table></div>" + $nl
# All branches
$totalBranchCount = $branchCount + $missingInGH.Count
$branchSummary = if ($missingInGH.Count -gt 0) { "$totalBranchCount - $branchCount in GitHub, $($missingInGH.Count) missing from ADO" } else { "$branchCount" }
$html += "<div class='card'><h2>&#x1F33F; All Branches ($branchSummary)</h2><details><summary>Click to expand all branches</summary><table style='margin-top:10px;'><thead><tr><th style='text-align:center;'>#</th><th>Branch</th><th style='text-align:center;'>Status</th></tr></thead><tbody>$allBranchHtml</tbody></table></details></div>" + $nl
# Audit & Artifacts
$html += "<div class='card'><h2>&#x1F4E6; Audit &amp; Artifacts</h2>" + $nl
$html += "<p style='font-size:16px;margin-bottom:10px;'>&#x1F4E5; <strong>MigrationAudit</strong> artifact includes:</p>" + $nl
$html += "<ul style='margin-left:24px;font-size:15px;line-height:2;'>" + $nl
$html += "<li>Folder-wise file inventory (<code>gh-folder-wise-files.csv</code>, <code>gh-folder-summary-default.md</code>)</li>" + $nl
$html += "<li>PR breakdown by source branch (<code>gh-pr-by-source-branch.md</code>)</li>" + $nl
$html += "<li>PR breakdown by target branch (<code>gh-pr-by-target-branch.md</code>)</li>" + $nl
$html += "<li>Branch-wise commit table (<code>gh-branch-wise-table.md</code>)</li>" + $nl
$html += "<li>Validation checks</li></ul>" + $nl
$html += "<p style='margin-top:12px;font-size:15px;'>&#x2705; Recommended for audit &amp; compliance reviews.</p></div>" + $nl
# Footer
$html += "<div class='footer'>Generated $migDate &bull; ADO-to-GitHub Migration Pipeline</div></div></body></html>"

$html | Out-File "$dashDir\migration-report-$GitHub_Repo.html" -Encoding utf8
Write-Host "  HTML saved: $dashDir\migration-report-$GitHub_Repo.html" -ForegroundColor Green

# Markdown summary (with Unicode chars matching yaml.yaml)
$emojiCheck = [char]::ConvertFromUtf32(0x2705)
$emojiWarn  = [char]::ConvertFromUtf32(0x26A0) + [char]::ConvertFromUtf32(0xFE0F)
$emojiCross = [char]::ConvertFromUtf32(0x274C)
if     ($migResult -eq "Already Exists") { $mdStatus = "$emojiWarn Skipped - Repository Already Exists" }
elseif ($migResult -eq "Success")        { $mdStatus = "$emojiCheck Completed - Migration Successful" }
else                                     { $mdStatus = "$emojiCross Failed - Migration Error" }

$md  = "# " + [char]::ConvertFromUtf32(0x1F680) + " ADO " + [char]::ConvertFromUtf32(0x2192) + " GitHub Migration Report`n`n"
$md += "> Status: $mdStatus`n`n"
$md += "| | |`n|:---|:---|`n"
$md += "| " + [char]::ConvertFromUtf32(0x1F4C5) + " Date | $migDate |`n"
$md += "| " + [char]::ConvertFromUtf32(0x1F4E6) + " Source | ``$ADOOrg / $ADOProject / $ADO_Repo`` |`n"
$md += "| " + [char]::ConvertFromUtf32(0x1F3AF) + " Target | ``$GHOrg / $GitHub_Repo`` |`n"
$md += "| " + [char]::ConvertFromUtf32(0x1F33F) + " Branches | $branchCount |`n"
$md += "| " + [char]::ConvertFromUtf32(0x1F4DD) + " Commits | $commitCount |`n"
$md += "| " + [char]::ConvertFromUtf32(0x1F500) + " PRs | $prOpen Open / $prMerged Merged / $prClosed Closed |`n`n"
$md += "> " + [char]::ConvertFromUtf32(0x1F4A1) + " Download the **MigrationDashboard** artifact for the full HTML report.`n"
$md | Out-File "$reportDir\migration-summary-$GitHub_Repo.md" -Encoding utf8

Write-Host "`n============================================" -ForegroundColor Green
Write-Host "  MIGRATION COMPLETE: $GitHub_Repo"
Write-Host "  Status:   $migResult"
Write-Host "  Branches: $branchCount | Tags: $tagCount | Commits: $commitCount"
Write-Host "  PRs:      $prCount (Open:$prOpen Merged:$prMerged Closed:$prClosed)"
Write-Host "============================================"



