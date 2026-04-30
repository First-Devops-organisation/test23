<#
.SYNOPSIS
    Scrubs secrets from Git history and replaces them with GitHub Secret references.
.DESCRIPTION
    Reads secret-scan-findings.json from scan-secrets.ps1, then for each repo:
      1. Clones the repo (full mirror clone — all branches, all history)
      2. Builds a git-filter-repo expressions file that maps:
           secret_value ==> ${{ secrets.SECRET_NAME }}
      3. Runs git-filter-repo --replace-text to rewrite ALL history
      4. Saves secret-values.json for downstream GitHub Secret provisioning
      5. Leaves the scrubbed clone ready for migration

    The scrubbed clone is NOT pushed back to ADO. It stays local for
    the migration wrapper (migrate-single-secure.ps1) to push to GitHub.

    SECRET VALUE HANDLING:
      - Strips leading/trailing whitespace, quotes, commas, semicolons
      - But preserves internal whitespace so full multi-word values are captured
      - Sorts replacement expressions longest-first to prevent partial matches
      - Skips placeholder/false-positive values
.PARAMETER ConfigPath
    Path to repo-migration-config.json
.PARAMETER DryRun
    If set, shows what would be scrubbed without modifying anything
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "$PSScriptRoot\..\config\repo-migration-config.json",
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$config    = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$reportDir = $config.output.reportDir
$logDir    = $config.output.logDir
$cloneDir  = $config.migration.cloneTempDir
$scrubbedDir = Join-Path (Split-Path $cloneDir) "scrubbed"

foreach ($d in @($reportDir, $logDir, $cloneDir, $scrubbedDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ── Verify git-filter-repo ───────────────────────────────────────────────────
$filterRepo = Get-Command git-filter-repo -ErrorAction SilentlyContinue
if (-not $filterRepo) {
    Write-Error "git-filter-repo not found. Install: pip install git-filter-repo"
}

# ── Load findings ────────────────────────────────────────────────────────────
$findingsPath = Join-Path $reportDir "secret-scan-findings.json"
if (-not (Test-Path $findingsPath)) {
    Write-Error "secret-scan-findings.json not found. Run 01-discover\scan-secrets.ps1 first."
}
$findings = @(Get-Content $findingsPath -Raw | ConvertFrom-Json)
if ($findings.Count -eq 0) {
    Write-Host "No secrets found — nothing to scrub." -ForegroundColor Green
    # Write empty secret-values.json so downstream scripts don't fail
    @() | ConvertTo-Json | Out-File (Join-Path $reportDir "secret-values.json") -Encoding utf8
    return
}

$inventoryPath = Join-Path $reportDir "repo-inventory.json"
$repos = @(Get-Content $inventoryPath -Raw | ConvertFrom-Json)

$adoPat = if ($config.source.pat -eq '$(ADO_PAT)') { $env:ADO_PAT } else { $config.source.pat }
if ([string]::IsNullOrWhiteSpace($adoPat)) { Write-Error "Set ADO_PAT environment variable" }

# ── Group findings by repo ───────────────────────────────────────────────────
$byRepo = $findings | Group-Object -Property Repo

Write-Host "=== Secret Scrubbing ($($byRepo.Count) repos, DryRun=$DryRun) ===" -ForegroundColor Cyan
Write-Host "NOTE: Original ADO repos are NOT modified. Scrubbed clones stay local." -ForegroundColor Green

# ── Collections ──────────────────────────────────────────────────────────────
$allSecretValues    = @()    # For secret-values.json (GitHub Secret provisioning)
$migrationReport    = @()    # Full report of all findings
$rotationChecklist  = @()    # Credential rotation tracker

# ── Common false-positive values to skip ─────────────────────────────────────
$falsePositives = @(
    'changeme', 'password', 'secret', 'example', 'placeholder',
    'your-secret-here', 'your-password-here', 'your-token-here',
    'xxxxxxxx', 'test1234', 'abcdefgh', 'changeit', 'replace_me',
    'todo_replace', 'change_me', 'none', 'null', 'undefined',
    'default', 'required', 'optional', 'insert_here', 'xxx',
    'yyy', 'zzz', 'true', 'false', 'yes', 'no'
)

foreach ($group in $byRepo) {
    $repoName     = $group.Name
    $repoFindings = @($group.Group)
    $repoInfo     = $repos | Where-Object { $_.Name -eq $repoName }

    Write-Host "`n  ==========================================" -ForegroundColor Cyan
    Write-Host "  Processing: $repoName ($($repoFindings.Count) findings)" -ForegroundColor Yellow

    # ── Track unique secrets for dedup ────────────────────────────────────
    $seenSecrets     = @{}   # secret value → resolved secret name
    $seenSecretNames = @{}   # secret name  → secret value (detect collisions)
    $expressions     = @()   # git-filter-repo replacement lines

    foreach ($finding in $repoFindings) {
        # ── Clean the secret value ────────────────────────────────────
        $secret = $finding.SecretValue
        if ([string]::IsNullOrWhiteSpace($secret)) { continue }

        # Trim outer whitespace
        $secret = $secret.Trim()
        # Strip leading/trailing quotes, commas, semicolons
        $secret = $secret -replace '^["'']+|["'',;]+$', ''
        $secret = $secret.Trim()

        if ([string]::IsNullOrWhiteSpace($secret)) { continue }
        if ($secret.Length -lt 4) { continue }

        # ── Skip false positives ──────────────────────────────────────
        if ($falsePositives -contains $secret.ToLower()) {
            Write-Host "    SKIP (placeholder): [$secret]" -ForegroundColor DarkGray
            continue
        }

        # Skip values that look like file paths or URLs
        if ($secret -match '^(https?://|/|\\|\./)' -or $secret -match '\.(js|ts|css|html|json|xml|yaml|yml|md|txt|png|jpg|svg)$') {
            Write-Host "    SKIP (path/URL): [$secret]" -ForegroundColor DarkGray
            continue
        }

        # Skip values with control characters (GitHub API rejects these)
        if ($secret -match '[\x00-\x1f]' -and $secret -notmatch '[\r\n]') {
            Write-Host "    SKIP (control chars): [$($finding.RuleID)] $($finding.File):$($finding.LineNumber)" -ForegroundColor DarkGray
            continue
        }

        # ── Determine secret name ─────────────────────────────────────
        $secretName = $finding.SecretName
        if ([string]::IsNullOrWhiteSpace($secretName)) {
            # Try to extract key name from the match context
            if ($finding.Match -match '(?i)([A-Z_][A-Z0-9_]*)\s*[=:]') {
                $secretName = $Matches[1]
            } else {
                $secretName = $finding.RuleID
            }
        }
        $secretName = $secretName.ToUpper() -replace "[^A-Z0-9_]", "_"
        if ([string]::IsNullOrWhiteSpace($secretName)) { $secretName = "SECRET" }
        if ($secretName -match "^\d") { $secretName = "S_$secretName" }
        # GitHub reserves the GITHUB_ prefix
        if ($secretName -match "^GITHUB_") {
            $secretName = $secretName -replace "^GITHUB_", "GH_"
            Write-Host "      Renamed to $secretName (GITHUB_ prefix reserved)" -ForegroundColor Yellow
        }
        if ($secretName.Length -gt 100) { $secretName = $secretName.Substring(0, 100) }

        # ── Resolve name collisions ───────────────────────────────────
        if ($seenSecrets.ContainsKey($secret)) {
            # Same secret value seen before — reuse assigned name
            $secretName = $seenSecrets[$secret]
        } elseif ($seenSecretNames.ContainsKey($secretName)) {
            # Different value but same name — append suffix
            $baseName = $secretName
            $suffix = 2
            while ($seenSecretNames.ContainsKey("${baseName}_${suffix}")) {
                $suffix++
            }
            $secretName = "${baseName}_${suffix}"
            Write-Host "      Name collision: renamed to $secretName" -ForegroundColor Yellow
        }

        # ── Log finding ───────────────────────────────────────────────
        $secretPreview = if ($secret.Length -le 8) { "***" }
                         else { $secret.Substring(0, 3) + ("*" * ($secret.Length - 6)) + $secret.Substring($secret.Length - 3) }

        Write-Host "    -> KEY: $secretName | File: $($finding.File):$($finding.LineNumber) | Rule: $($finding.RuleID)" -ForegroundColor Yellow
        Write-Host "       Value: [$secretPreview] | Branch: $($finding.Branch)" -ForegroundColor DarkGray

        # ── Build replacement expression (only once per unique secret) ─
        if (-not $seenSecrets.ContainsKey($secret)) {
            $seenSecrets[$secret]          = $secretName
            $seenSecretNames[$secretName]  = $secret

            # The placeholder uses GitHub Actions syntax: ${{ secrets.NAME }}
            $placeholder = "`${{ secrets.$secretName }}"
            $expressions += "$secret==>$placeholder"

            # Save for post-migration GitHub Secret provisioning
            $allSecretValues += [PSCustomObject]@{
                Repo          = $repoName
                SecretName    = $secretName
                SecretValue   = $secret
                RuleID        = $finding.RuleID
                SourceFile    = $finding.File
                SourceLine    = $finding.LineNumber
                Branch        = $finding.Branch
                CommitID      = $finding.CommitID
                Description   = $finding.Description
            }
        }

        # ── Add to migration report (all findings, not deduplicated) ──
        $migrationReport += [PSCustomObject]@{
            Repo             = $repoName
            File             = $finding.File
            Line             = $finding.LineNumber
            Branch           = $finding.Branch
            CommitID         = $finding.CommitID
            KeyName          = $secretName
            SecretType       = $finding.RuleID
            SecretPreview    = $secretPreview
            GitHubSecretName = $secretName
            HowToUse         = "`${{ secrets.$secretName }}"
            Action           = "Update code to use GitHub Secret"
        }

        $rotationChecklist += [PSCustomObject]@{
            Repo     = $repoName
            RuleID   = $finding.RuleID
            File     = $finding.File
            Line     = $finding.LineNumber
            Branch   = $finding.Branch
            SecretName = $secretName
            Action   = "ROTATE_CREDENTIAL"
        }
    }

    $uniqueCount = $seenSecrets.Count
    Write-Host "    $uniqueCount unique secrets (deduped), $($repoFindings.Count) total occurrences" -ForegroundColor Cyan

    if ($uniqueCount -eq 0) {
        Write-Host "    No actionable secrets after filtering — skipping" -ForegroundColor Green
        continue
    }

    # ── Sort expressions longest-first (prevents partial replacements) ────
    $sortedExpressions = $expressions | Sort-Object { ($_ -split "==>")[0].Length } -Descending

    # ── Write expressions file ────────────────────────────────────────────
    $expressionsFile = Join-Path (Resolve-Path $logDir).Path "expressions-$repoName.txt"
    $sortedExpressions | Out-File -FilePath $expressionsFile -Encoding utf8

    Write-Host "    Expressions file: $expressionsFile ($($sortedExpressions.Count) entries)" -ForegroundColor Gray

    if ($DryRun) {
        Write-Host "    [DRY RUN] Would redact $($sortedExpressions.Count) unique secrets" -ForegroundColor Gray
        Write-Host "    [DRY RUN] Expressions:" -ForegroundColor Gray
        foreach ($expr in $sortedExpressions) {
            $parts = $expr -split "==>"
            $val = $parts[0]
            $preview = if ($val.Length -le 8) { "***" }
                       else { $val.Substring(0, 3) + ("*" * ($val.Length - 6)) + $val.Substring($val.Length - 3) }
            Write-Host "      $preview ==> $($parts[1])" -ForegroundColor DarkGray
        }
        continue
    }

    # ── Clone repo (mirror — all branches, all history) ───────────────────
    $clonePath = Join-Path $cloneDir "$repoName-scrub"
    if (Test-Path $clonePath) { Remove-Item -Recurse -Force $clonePath }

    Write-Host "    Cloning $repoName (mirror)..." -ForegroundColor Gray
    $cloneUrl   = $repoInfo.RemoteUrl -replace '://[^@]+@', '://'
    $base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("pat:${adoPat}"))
    $cloneArgs  = @('-c', "http.extraHeader=Authorization: Basic $base64Auth",
                    'clone', '--mirror', '--quiet', $cloneUrl, $clonePath)
    $cloneOutput = & git @cloneArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "    Clone failed for $repoName — skipping"
        continue
    }

    # ── Run git-filter-repo --replace-text ────────────────────────────────
    Write-Host "    Running git-filter-repo (redacting $($sortedExpressions.Count) secrets)..." -ForegroundColor Gray
    $absExpressionsFile = (Resolve-Path $expressionsFile).Path

    Push-Location $clonePath
    try {
        & git filter-repo --replace-text "$absExpressionsFile" --force 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "    git-filter-repo returned exit code $LASTEXITCODE"
        } else {
            Write-Host "    Secrets redacted from ALL history" -ForegroundColor Green
        }
    }
    catch {
        Write-Warning "    git-filter-repo error: $_"
    }
    finally {
        Pop-Location
    }

    # ── Move scrubbed clone to output ─────────────────────────────────────
    $outputRepoDir = Join-Path $scrubbedDir $repoName
    if (Test-Path $outputRepoDir) { Remove-Item -Recurse -Force $outputRepoDir }
    Move-Item -Path $clonePath -Destination $outputRepoDir
    Write-Host "    Scrubbed clone saved: $outputRepoDir" -ForegroundColor Green
    Write-Host "    Original ADO repo was NOT modified" -ForegroundColor Green
}

# ── Save secret-values.json (for GitHub Secret provisioning) ─────────────────
$secretValuesFile = Join-Path $reportDir "secret-values.json"
$allSecretValues | ConvertTo-Json -Depth 10 | Out-File -FilePath $secretValuesFile -Encoding utf8

# ── Save migration report CSV ────────────────────────────────────────────────
$reportCsvFile = Join-Path $reportDir "secret-migration-report.csv"
if ($migrationReport.Count -gt 0) {
    $migrationReport | Export-Csv -Path $reportCsvFile -NoTypeInformation -Encoding utf8
}

# ── Save rotation checklist ──────────────────────────────────────────────────
$checklistPath = Join-Path $reportDir "credential-rotation-checklist.csv"
$rotationChecklist | Export-Csv $checklistPath -NoTypeInformation -Encoding utf8

# ── HTML Dashboard ───────────────────────────────────────────────────────────
$dashboardDir = Join-Path $reportDir "dashboard"
if (-not (Test-Path $dashboardDir)) { New-Item -ItemType Directory -Path $dashboardDir -Force | Out-Null }

$htmlFile = Join-Path $dashboardDir "scrub-dashboard.html"

$tableRows = ""
foreach ($entry in $migrationReport) {
    $typeColor = switch -Wildcard ($entry.SecretType) {
        "*password*" { "#e74c3c" }
        "*api*"      { "#e67e22" }
        "*token*"    { "#f39c12" }
        "*key*"      { "#e74c3c" }
        "*private*"  { "#c0392b" }
        default      { "#e67e22" }
    }
    $tableRows += @"
<tr>
  <td>$([System.Net.WebUtility]::HtmlEncode($entry.Repo))</td>
  <td><code>$([System.Net.WebUtility]::HtmlEncode($entry.File))</code></td>
  <td>$($entry.Line)</td>
  <td>$([System.Net.WebUtility]::HtmlEncode($entry.Branch))</td>
  <td><span style="color:$typeColor;font-weight:bold">$([System.Net.WebUtility]::HtmlEncode($entry.SecretType))</span></td>
  <td><code>$([System.Net.WebUtility]::HtmlEncode($entry.SecretPreview))</code></td>
  <td><code>$([System.Net.WebUtility]::HtmlEncode($entry.GitHubSecretName))</code></td>
  <td><code>$([System.Net.WebUtility]::HtmlEncode($entry.HowToUse))</code></td>
</tr>

"@
}

$repoGroups = $migrationReport | Group-Object -Property Repo

$html = @"
<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8">
<title>Secret Scrubbing Dashboard</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: #0d1117; color: #c9d1d9; }
  .header { background: linear-gradient(135deg, #161b22, #1f2937); padding: 32px; border-bottom: 1px solid #30363d; }
  .header h1 { font-size: 24px; color: #58a6ff; }
  .header p { color: #8b949e; margin-top: 8px; }
  .stats { display: flex; gap: 16px; padding: 24px 32px; flex-wrap: wrap; }
  .stat-card { background: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 16px 24px; min-width: 180px; }
  .stat-card .number { font-size: 32px; font-weight: bold; color: #58a6ff; }
  .stat-card .label { color: #8b949e; font-size: 14px; margin-top: 4px; }
  .stat-card.warning .number { color: #f85149; }
  .content { padding: 0 32px 32px; }
  table { width: 100%; border-collapse: collapse; margin-top: 16px; background: #161b22; border-radius: 8px; overflow: hidden; }
  th { background: #1f2937; color: #58a6ff; text-align: left; padding: 12px 16px; font-size: 13px; }
  td { padding: 10px 16px; border-bottom: 1px solid #21262d; font-size: 14px; }
  tr:hover { background: #1c2128; }
  code { background: #1f2937; padding: 2px 6px; border-radius: 4px; font-size: 13px; color: #79c0ff; }
  .legend { background: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 16px 24px; margin-top: 24px; }
  .legend h3 { color: #58a6ff; margin-bottom: 8px; }
  .legend p { color: #8b949e; font-size: 14px; line-height: 1.8; }
  .footer { text-align: center; padding: 24px; color: #484f58; font-size: 12px; }
</style></head><body>
<div class="header">
  <h1>Secret Scrubbing Dashboard</h1>
  <p>Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') | Mode: $(if ($DryRun) {'DRY RUN'} else {'LIVE'})</p>
</div>
<div class="stats">
  <div class="stat-card warning"><div class="number">$($allSecretValues.Count)</div><div class="label">Unique Secrets</div></div>
  <div class="stat-card"><div class="number">$($byRepo.Count)</div><div class="label">Repos Processed</div></div>
  <div class="stat-card"><div class="number">$($repoGroups.Count)</div><div class="label">Repos with Secrets</div></div>
  <div class="stat-card"><div class="number">$($migrationReport.Count)</div><div class="label">Total Findings</div></div>
</div>
<div class="content">
  <h2 style="color:#c9d1d9;margin-bottom:16px">Secret Details</h2>
  <table>
    <thead><tr><th>Repo</th><th>File</th><th>Line</th><th>Branch</th><th>Type</th><th>Preview</th><th>GitHub Secret</th><th>Usage</th></tr></thead>
    <tbody>$tableRows</tbody>
  </table>
  <div class="legend">
    <h3>What Teams Need To Do</h3>
    <p>1. Check GitHub repo Settings > Secrets > verify each secret exists</p>
    <p>2. Update code to use <code>`${{ secrets.SECRET_NAME }}</code> syntax</p>
    <p>3. <strong style="color:#f85149">ROTATE all credentials</strong> — original values may have been in ADO history</p>
  </div>
</div>
<div class="footer">Generated by ADO-to-GitHub Migration Accelerator</div>
</body></html>
"@
$html | Out-File -FilePath $htmlFile -Encoding utf8

# ── Console Summary ──────────────────────────────────────────────────────────
Write-Host "`n=== Scrub Summary ===" -ForegroundColor Cyan
Write-Host "  Repos processed       : $($byRepo.Count)"
Write-Host "  Unique secrets        : $($allSecretValues.Count)"
Write-Host "  Total findings        : $($migrationReport.Count)"
Write-Host "  Credentials to rotate : $($rotationChecklist.Count)"
Write-Host ""
Write-Host "  Secret values file    : $secretValuesFile" -ForegroundColor Gray
Write-Host "  Migration report      : $reportCsvFile" -ForegroundColor Gray
Write-Host "  Rotation checklist    : $checklistPath" -ForegroundColor Gray
Write-Host "  HTML Dashboard        : $htmlFile" -ForegroundColor Gray
Write-Host "  Scrubbed clones       : $scrubbedDir" -ForegroundColor Green
Write-Host "  Original ADO repos    : UNTOUCHED" -ForegroundColor Green
Write-Host ""
Write-Host "  CRITICAL: Rotate ALL credentials listed in:" -ForegroundColor Red
Write-Host "  $checklistPath"
Write-Host "`nNext step: Run 03-migrate to push scrubbed repos to GitHub."
