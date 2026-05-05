<#
.SYNOPSIS
    Scrubs secrets from Git history on the GITHUB side after GEI migration.
.DESCRIPTION
    Reads secret-scan-findings.json from scan-secrets.ps1, then for each repo:
      1. Clones the MIGRATED repo from GitHub (full clone — all branches)
      2. Builds git-filter-repo replacement expressions (longest-first)
      3. Replaces secret values with ${{ secrets.SECRET_NAME }} across all history
      4. Force-pushes the cleaned history back to GitHub
      5. Generates secret-values.json for GitHub Secret creation

    WHY POST-MIGRATION: GEI clones directly from ADO → GitHub. It ignores any
    local scrubbed clone. So we must scrub AFTER GEI has migrated the repo.
    The original ADO repo is NEVER modified.

    CAUTION: This rewrites Git history on the GitHub repo. All developers
    must re-clone after scrubbing.
.PARAMETER ConfigPath
    Path to repo-migration-config.json
.PARAMETER GitHubOrg
    GitHub organization name
.PARAMETER GitHubRepo
    GitHub repository name (for single mode)
.PARAMETER DryRun
    If set, shows what would be cleaned without making changes
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "$PSScriptRoot\..\config\repo-migration-config.json",

    [Parameter(Mandatory = $false)]
    [string]$GitHubOrg,

    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$GitHubRepo = '',

    [switch]$DryRun
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

# Resolve to absolute paths — git-filter-repo runs inside clone dir, so relative paths break
$reportDir = (Resolve-Path $reportDir).Path
$logDir    = (Resolve-Path $logDir).Path
$cloneDir  = (Resolve-Path $cloneDir).Path

# ── Resolve GitHub org ───────────────────────────────────────────────────────
if ([string]::IsNullOrWhiteSpace($GitHubOrg)) {
    $GitHubOrg = if ($config.target.organization -match '^\$\(') { $env:GitHub_Org } else { $config.target.organization }
}
if ([string]::IsNullOrWhiteSpace($GitHubOrg)) { Write-Error "GitHubOrg is required. Set via parameter or GitHub_Org env variable." }
# Strip URL prefix if present
if ($GitHubOrg -match 'github\.com/([^/]+)') { $GitHubOrg = $Matches[1] }

# ── GitHub PAT ───────────────────────────────────────────────────────────────
$ghPat = $env:GH_PAT
if ([string]::IsNullOrWhiteSpace($ghPat)) { $ghPat = $env:GH_TOKEN }
if ([string]::IsNullOrWhiteSpace($ghPat)) { Write-Error "Set GH_PAT or GH_TOKEN environment variable" }

# ── Verify git-filter-repo ───────────────────────────────────────────────────
$gfr = Get-Command git-filter-repo -ErrorAction SilentlyContinue
if (-not $gfr) {
    Write-Host "git-filter-repo not found. Attempting pip install..." -ForegroundColor Yellow
    $pipOutput = & pip install git-filter-repo 2>&1
    $gfr = Get-Command git-filter-repo -ErrorAction SilentlyContinue
    if (-not $gfr) {
        Write-Error "git-filter-repo not found. Install: pip install git-filter-repo"
    }
}

# ── Load findings ────────────────────────────────────────────────────────────
$findingsPath = Join-Path $reportDir "secret-scan-findings.json"
if (-not (Test-Path $findingsPath)) {
    Write-Error "secret-scan-findings.json not found at $findingsPath. Run 01-discover\scan-secrets.ps1 first."
}
$findings = Get-Content $findingsPath -Raw | ConvertFrom-Json
if ($findings.Count -eq 0) {
    Write-Host "No secrets found — nothing to scrub." -ForegroundColor Green
    # Still create empty secret-values.json so downstream steps don't fail
    $svPath = Join-Path $reportDir "secret-values.json"
    "[]" | Out-File $svPath -Encoding utf8
    Write-Host "  Created empty secret-values.json at $svPath"
    return
}

# ── Filter findings by repo if specified ─────────────────────────────────────
if (-not [string]::IsNullOrWhiteSpace($GitHubRepo)) {
    $findings = @($findings | Where-Object { $_.Repo -eq $GitHubRepo.Trim() })
    Write-Host "Filtered findings for repo: $GitHubRepo ($($findings.Count) findings)" -ForegroundColor Cyan
}

if ($findings.Count -eq 0) {
    Write-Host "No findings for selected repo(s) — nothing to scrub." -ForegroundColor Green
    $svPath = Join-Path $reportDir "secret-values.json"
    "[]" | Out-File $svPath -Encoding utf8
    Write-Host "  Created empty secret-values.json at $svPath"
    return
}

# ── Values that are likely placeholders ───────────────────────────────────────
# Only exact-match for short values; long values are never filtered
$placeholderExact = @(
    'changeme', 'password', 'example', 'your-password-here', 'xxx', 'TODO',
    'CHANGE_ME', 'replace_me', 'insert_here', 'none', 'null', 'empty',
    'test', 'dummy', 'sample', 'placeholder', 'default', 'admin', 'root',
    'xxxxxx', '******'
)

# Group findings by repo
$byRepo = $findings | Group-Object -Property Repo

Write-Host "=== Post-Migration Secret Scrubbing ($($byRepo.Count) repos, DryRun=$DryRun) ===" -ForegroundColor Cyan
Write-Host "  Target: GitHub org '$GitHubOrg'" -ForegroundColor Cyan
Write-Host "  NOTE: ADO repos are NOT affected. Only GitHub copies are scrubbed." -ForegroundColor Yellow

$allSecretValues = @()
$migrationReport = @()
$rotationChecklist = @()

foreach ($group in $byRepo) {
    $repoName = $group.Name
    $repoFindings = $group.Group

    # Determine the GitHub repo name (may differ from ADO name)
    $ghRepoName = $repoName
    if (-not [string]::IsNullOrWhiteSpace($GitHubRepo)) { $ghRepoName = $GitHubRepo }

    Write-Host "`n── $ghRepoName ($($repoFindings.Count) findings) ──" -ForegroundColor Yellow

    # ── Build unique secret name→value map with dedup ────────────────────
    $secretMap = [ordered]@{}  # secretName → secretValue
    $nameCounter = @{}         # base name → count

    foreach ($f in $repoFindings) {
        $val = $f.SecretValue
        if ([string]::IsNullOrWhiteSpace($val)) { continue }

        # Trim outer quotes/delimiters, preserve internal whitespace
        $val = $val.Trim()
        $val = $val -replace '^[''"`]+', '' -replace '[''"`]+$', ''
        $val = $val -replace '[,;]\s*$', ''
        $val = $val.Trim()

        if ($val.Length -lt 4) { continue }

        # Skip placeholders — only exact match for short values
        $isPlaceholder = $false
        $valLower = $val.ToLower().Trim()
        if ($valLower.Length -le 20) {
            foreach ($ph in $placeholderExact) {
                if ($valLower -eq $ph.ToLower()) { $isPlaceholder = $true; break }
            }
        }
        if ($isPlaceholder) { continue }

        # Derive secret name
        $baseName = $f.SecretName
        if ([string]::IsNullOrWhiteSpace($baseName)) { $baseName = "DETECTED_SECRET" }
        $baseName = ($baseName -replace '[^a-zA-Z0-9]', '_').ToUpper()

        # GitHub reserves GITHUB_ prefix
        if ($baseName -match '^GITHUB_') { $baseName = "GH_$($baseName.Substring(7))" }

        # Check if this exact value already exists under any name
        $existingName = $null
        foreach ($k in $secretMap.Keys) {
            if ($secretMap[$k] -ceq $val) { $existingName = $k; break }
        }

        if ($existingName) {
            $migrationReport += [PSCustomObject]@{
                Repo = $ghRepoName; SecretName = $existingName; File = $f.File
                LineNumber = $f.LineNumber; Branch = $f.Branch; Status = "DEDUP_SAME_VALUE"
            }
            continue
        }

        # Check if name already used (with different value)
        $finalName = $baseName
        if ($secretMap.Contains($baseName)) {
            if (-not $nameCounter.Contains($baseName)) { $nameCounter[$baseName] = 1 }
            $nameCounter[$baseName]++
            $finalName = "${baseName}_$($nameCounter[$baseName])"
        }

        $secretMap[$finalName] = $val

        $migrationReport += [PSCustomObject]@{
            Repo = $ghRepoName; SecretName = $finalName; File = $f.File
            LineNumber = $f.LineNumber; Branch = $f.Branch; Status = "WILL_SCRUB"
        }
    }

    if ($secretMap.Count -eq 0) {
        Write-Host "  No actionable secrets after filtering. Skipping." -ForegroundColor Gray
        continue
    }

    Write-Host "  Unique secrets to scrub: $($secretMap.Count)" -ForegroundColor Cyan

    # Save secret values for this repo
    foreach ($k in $secretMap.Keys) {
        $allSecretValues += [PSCustomObject]@{
            Repo        = $ghRepoName
            SecretName  = $k
            SecretValue = $secretMap[$k]
        }
    }

    if ($DryRun) {
        Write-Host "  [DRY RUN] Would scrub $($secretMap.Count) secrets from $ghRepoName on GitHub"
        foreach ($k in $secretMap.Keys) {
            $maskedVal = $secretMap[$k].Substring(0, [Math]::Min(4, $secretMap[$k].Length)) + "***"
            Write-Host "    - $k = $maskedVal -> `${{ secrets.$k }}"
        }
        $rotationChecklist += $repoFindings | ForEach-Object {
            [PSCustomObject]@{ Repo = $ghRepoName; RuleID = $_.RuleID; File = $_.File; Action = "ROTATE_CREDENTIAL" }
        }
        continue
    }

    # ── Clone from GITHUB (the migrated repo) ───────────────────────────
    $clonePath = Join-Path $cloneDir $ghRepoName
    if (Test-Path $clonePath) { Remove-Item $clonePath -Recurse -Force }

    $ghCloneUrl = "https://${ghPat}@github.com/${GitHubOrg}/${ghRepoName}.git"

    Write-Host "  Cloning from GitHub: $GitHubOrg/$ghRepoName ..."
    try {
        & git clone --quiet $ghCloneUrl $clonePath 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Clone from GitHub failed" }
    }
    catch {
        Write-Warning "  Clone failed for $ghRepoName from GitHub: $_"
        continue
    }

    # Fetch all remote branches locally
    Push-Location $clonePath
    try {
        $remoteBranches = & git branch -r 2>$null | Where-Object { $_ -notmatch 'HEAD' }
        foreach ($rb in $remoteBranches) {
            $rb = $rb.Trim()
            $localName = $rb -replace '^origin/', ''
            $existsLocal = & git branch --list $localName 2>$null
            if (-not $existsLocal) {
                & git branch --track $localName $rb 2>$null | Out-Null
            }
        }
    } catch { }
    Pop-Location

    # ── Build replacement expressions file ───────────────────────────────
    $replacementsFile = Join-Path $logDir "replacements-$ghRepoName.txt"

    # Sort by value length descending (longest first to prevent partial replacements)
    $sortedEntries = $secretMap.GetEnumerator() | Sort-Object { $_.Value.Length } -Descending

    $expressions = @()
    foreach ($entry in $sortedEntries) {
        $replacement = "`${{ secrets.$($entry.Key) }}"
        $expressions += "literal:$($entry.Value)==>${replacement}"
    }
    # Write WITHOUT BOM — git-filter-repo (Python) fails with UTF-8 BOM
    [System.IO.File]::WriteAllLines($replacementsFile, $expressions, [System.Text.UTF8Encoding]::new($false))

    Write-Host "  Applying $($expressions.Count) replacements via git-filter-repo..."

    # ── Run git-filter-repo ──────────────────────────────────────────────
    Push-Location $clonePath
    try {
        # Remove internal refs that cause push failures
        $internalRefs = & git for-each-ref --format='%(refname)' 'refs/pull/' 2>$null
        foreach ($ref in $internalRefs) {
            if (-not [string]::IsNullOrWhiteSpace($ref)) {
                & git update-ref -d $ref 2>$null | Out-Null
            }
        }

        $output = & git-filter-repo --replace-text $replacementsFile --force 2>&1
        if ($LASTEXITCODE -ne 0) { throw ($output | Out-String) }

        Write-Host "  git-filter-repo completed successfully" -ForegroundColor Green

        # ── Verify secrets were actually removed from HEAD ────────────────
        $verifyFailed = $false
        foreach ($entry in $sortedEntries) {
            $found = & git log --all -S $entry.Value --oneline 2>$null
            if ($found) {
                Write-Warning "  VERIFICATION FAILED: '$($entry.Key)' still found in history!"
                $verifyFailed = $true
            }
        }
        if ($verifyFailed) {
            Write-Warning "  Some secrets may not have been fully scrubbed. Check replacements file."
        } else {
            Write-Host "  VERIFIED: All secrets removed from Git history" -ForegroundColor Green
        }

        # Re-add GitHub remote and force-push scrubbed history
        Write-Host "  Force-pushing cleaned history to GitHub..."
        & git remote add origin $ghCloneUrl 2>$null
        & git push --force --all origin 2>&1 | Out-Null
        & git push --force --tags origin 2>&1 | Out-Null

        Write-Host "  DONE — GitHub history rewritten for $ghRepoName" -ForegroundColor Green
        Write-Host "  NOTE: ADO repo is untouched. Developers must re-clone from GitHub." -ForegroundColor Yellow
    }
    catch {
        Write-Warning "  Failed to scrub $ghRepoName on GitHub: $_"
    }
    finally {
        Pop-Location
    }

    $rotationChecklist += $repoFindings | ForEach-Object {
        [PSCustomObject]@{ Repo = $ghRepoName; RuleID = $_.RuleID; File = $_.File; Action = "ROTATE_CREDENTIAL" }
    }
}

# ── Save secret values for GitHub Secret creation ────────────────────────────
$secretValuesPath = Join-Path $reportDir "secret-values.json"
if ($allSecretValues.Count -gt 0) {
    $allSecretValues | ConvertTo-Json -Depth 3 | Out-File $secretValuesPath -Encoding utf8
    Write-Host "`n  Secret values saved: $secretValuesPath" -ForegroundColor Cyan
} else {
    "[]" | Out-File $secretValuesPath -Encoding utf8
}

# ── Migration report CSV ─────────────────────────────────────────────────────
$migReportPath = Join-Path $reportDir "secret-migration-report.csv"
if ($migrationReport.Count -gt 0) {
    $migrationReport | Export-Csv $migReportPath -NoTypeInformation -Encoding utf8
}

# ── Cleanup clones ───────────────────────────────────────────────────────────
if (Test-Path $cloneDir) { Remove-Item $cloneDir -Recurse -Force -ErrorAction SilentlyContinue }

# ── Rotation checklist ───────────────────────────────────────────────────────
$checklistPath = Join-Path $reportDir "credential-rotation-checklist.csv"
if ($rotationChecklist.Count -gt 0) {
    $rotationChecklist | Export-Csv $checklistPath -NoTypeInformation -Encoding utf8
}

# ── Console Summary ──────────────────────────────────────────────────────────
Write-Host "`n=== Post-Migration Scrub Summary ===" -ForegroundColor Cyan
Write-Host "  Repos processed         : $($byRepo.Count)"
Write-Host "  Total unique secrets     : $($allSecretValues.Count)"
Write-Host "  Credentials to rotate   : $($rotationChecklist.Count)"
Write-Host "`n  CRITICAL: Rotate ALL credentials listed in:" -ForegroundColor Red
Write-Host "  $checklistPath"
Write-Host "`n  Secret values for GitHub Secret creation saved to:"
Write-Host "  $secretValuesPath"
Write-Host "`nNext step: Run 03-migrate\create-github-secrets.ps1 to provision secrets in GitHub."
