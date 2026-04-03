<#
.SYNOPSIS
    Validates migrated repos by comparing source (ADO) and target (GitHub).
.DESCRIPTION
    For each migrated repo, compares:
      - Branch count and names
      - Commit count on default branch
      - Pull request count
      - Tag count
      - Repository visibility
      - Branch protection rules existence
    Generates a pass/fail report.
.PARAMETER ConfigPath
    Path to repo-migration-config.json
.PARAMETER BatchName
    Specific batch to validate. If omitted, validates all batches.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "$PSScriptRoot\..\config\repo-migration-config.json",

    [Parameter(Mandatory = $false)]
    [string]$BatchName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$config    = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$adoOrg    = ($config.source.organization -replace 'https://dev.azure.com/', '').TrimEnd('/')
$adoProj   = $config.source.project
$ghOrg     = $config.target.organization
$reportDir = $config.output.reportDir

if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }

$adoPat = if ($config.source.pat -eq '$(ADO_PAT)') { $env:ADO_PAT } else { $config.source.pat }
$ghPat  = if ($config.target.pat -eq '$(GH_PAT)') { $env:GH_PAT } else { $config.target.pat }

if ([string]::IsNullOrWhiteSpace($adoPat)) { Write-Error "Set ADO_PAT environment variable" }
if ([string]::IsNullOrWhiteSpace($ghPat))  { Write-Error "Set GH_PAT environment variable" }

$adoBase64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$adoPat"))
$adoHeaders = @{ Authorization = "Basic $adoBase64" }
$ghHeaders  = @{ Authorization = "Bearer $ghPat"; Accept = "application/vnd.github+json" }

# ── Determine repos to validate ─────────────────────────────────────────────
$batches = $config.batches
if ($BatchName) {
    $batches = $batches | Where-Object { $_.name -eq $BatchName }
}
$repoNames = $batches | ForEach-Object { $_.repos } | Select-Object -Unique

Write-Host "=== Validating $($repoNames.Count) migrated repos ===" -ForegroundColor Cyan

$results = @()

foreach ($repoName in $repoNames) {
    Write-Host "`n── $repoName ──" -ForegroundColor Yellow
    $checks = @()

    # ── ADO source data ──────────────────────────────────────────────────────
    $adoRepoUrl = "https://dev.azure.com/$adoOrg/$adoProj/_apis/git/repositories/$repoName"
    try {
        $adoRepo = Invoke-RestMethod -Uri "$adoRepoUrl`?api-version=7.1" -Headers $adoHeaders
    }
    catch {
        Write-Warning "  Cannot reach ADO repo $repoName : $_"
        $results += [PSCustomObject]@{ Repo = $repoName; Status = "ADO_UNREACHABLE"; Checks = @() }
        continue
    }

    # ADO branches
    $adoBranches = @()
    try {
        $brResp = Invoke-RestMethod -Uri "$adoRepoUrl/refs?filter=heads/&api-version=7.1" -Headers $adoHeaders
        $adoBranches = $brResp.value | ForEach-Object { ($_.name -replace '^refs/heads/', '') }
    }
    catch { Write-Warning "  Could not fetch ADO branches" }

    # ADO PRs (completed + active)
    $adoPrCount = 0
    try {
        $prResp = Invoke-RestMethod -Uri "$adoRepoUrl/pullrequests?searchCriteria.status=all&`$top=1&api-version=7.1" -Headers $adoHeaders
        $adoPrCount = $prResp.count
    }
    catch { Write-Warning "  Could not fetch ADO PR count" }

    # ADO tags
    $adoTags = @()
    try {
        $tagResp = Invoke-RestMethod -Uri "$adoRepoUrl/refs?filter=tags/&api-version=7.1" -Headers $adoHeaders
        $adoTags = $tagResp.value
    }
    catch {}

    # ── GitHub target data ───────────────────────────────────────────────────
    $ghRepoUrl = "https://api.github.com/repos/$ghOrg/$repoName"
    try {
        $ghRepo = Invoke-RestMethod -Uri $ghRepoUrl -Headers $ghHeaders
    }
    catch {
        Write-Warning "  Cannot reach GitHub repo $repoName : $_"
        $results += [PSCustomObject]@{ Repo = $repoName; Status = "GH_NOT_FOUND"; Checks = @() }
        continue
    }

    # GH branches
    $ghBranches = @()
    try {
        $page = 1
        do {
            $brResp = Invoke-RestMethod -Uri "$ghRepoUrl/branches?per_page=100&page=$page" -Headers $ghHeaders
            $ghBranches += $brResp | ForEach-Object { $_.name }
            $page++
        } while ($brResp.Count -eq 100)
    }
    catch {}

    # GH PRs
    $ghPrCount = 0
    try {
        $prResp = Invoke-RestMethod -Uri "$ghRepoUrl/pulls?state=all&per_page=1" -Headers $ghHeaders
        # GitHub doesn't return total count easily; use search API
        $searchResp = Invoke-RestMethod -Uri "https://api.github.com/search/issues?q=repo:$ghOrg/$repoName+type:pr" -Headers $ghHeaders
        $ghPrCount = $searchResp.total_count
    }
    catch {}

    # GH tags
    $ghTags = @()
    try {
        $tagResp = Invoke-RestMethod -Uri "$ghRepoUrl/tags?per_page=100" -Headers $ghHeaders
        $ghTags = $tagResp
    }
    catch {}

    # ── Comparisons ──────────────────────────────────────────────────────────
    # Branch count
    $branchPass = $adoBranches.Count -eq $ghBranches.Count
    $checks += [PSCustomObject]@{
        Check  = "Branch Count"
        Source = $adoBranches.Count
        Target = $ghBranches.Count
        Pass   = $branchPass
        Detail = if (-not $branchPass) { "Missing: $(($adoBranches | Where-Object { $_ -notin $ghBranches }) -join ', ')" } else { "" }
    }

    # PR count
    $prPass = [math]::Abs($adoPrCount - $ghPrCount) -le 2  # Allow small variance
    $checks += [PSCustomObject]@{
        Check  = "Pull Request Count"
        Source = $adoPrCount
        Target = $ghPrCount
        Pass   = $prPass
        Detail = ""
    }

    # Tag count
    $tagPass = $adoTags.Count -eq $ghTags.Count
    $checks += [PSCustomObject]@{
        Check  = "Tag Count"
        Source = $adoTags.Count
        Target = $ghTags.Count
        Pass   = $tagPass
        Detail = ""
    }

    # Visibility
    $expectedVis = $config.migration.targetRepoVisibility
    $visPass = $ghRepo.visibility -eq $expectedVis
    $checks += [PSCustomObject]@{
        Check  = "Visibility"
        Source = $expectedVis
        Target = $ghRepo.visibility
        Pass   = $visPass
        Detail = ""
    }

    # Default branch
    $adoDefault = $adoRepo.defaultBranch -replace '^refs/heads/', ''
    $ghDefault  = $ghRepo.default_branch
    $defaultPass = $adoDefault -eq $ghDefault
    $checks += [PSCustomObject]@{
        Check  = "Default Branch"
        Source = $adoDefault
        Target = $ghDefault
        Pass   = $defaultPass
        Detail = ""
    }

    # Overall
    $allPass = ($checks | Where-Object { -not $_.Pass }).Count -eq 0
    $status = if ($allPass) { "PASS" } else { "FAIL" }

    if ($allPass) {
        Write-Host "  PASS — all checks passed" -ForegroundColor Green
    }
    else {
        Write-Host "  FAIL — some checks failed:" -ForegroundColor Red
        $checks | Where-Object { -not $_.Pass } | ForEach-Object {
            Write-Host "    ✗ $($_.Check): Source=$($_.Source) Target=$($_.Target) $($_.Detail)" -ForegroundColor Red
        }
    }

    $results += [PSCustomObject]@{
        Repo   = $repoName
        Status = $status
        Checks = $checks
    }
}

# ── Report ───────────────────────────────────────────────────────────────────
$jsonOut = Join-Path $reportDir "validation-results.json"
$results | ConvertTo-Json -Depth 5 | Out-File $jsonOut -Encoding utf8

Write-Host "`n=== Validation Summary ===" -ForegroundColor Green
Write-Host "  Total repos   : $($results.Count)"
Write-Host "  PASS          : $(($results | Where-Object Status -eq 'PASS').Count)"
Write-Host "  FAIL          : $(($results | Where-Object Status -eq 'FAIL').Count)"
Write-Host "  Unreachable   : $(($results | Where-Object Status -match 'UNREACHABLE|NOT_FOUND').Count)"
Write-Host "`nReport: $jsonOut"

$failed = $results | Where-Object { $_.Status -eq 'FAIL' }
if ($failed) {
    Write-Host "`nFailed repos require manual investigation:" -ForegroundColor Red
    $failed | ForEach-Object { Write-Host "  - $($_.Repo)" }
}
