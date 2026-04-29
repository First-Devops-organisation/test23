<#
.SYNOPSIS
    Scrubs secrets from Git history and saves values for post-migration GitHub Secret creation.
.DESCRIPTION
    Reads gitleaks scan reports, redacts secrets from Git history using git-filter-repo,
    and saves the original secret values to a protected JSON file.

    SAFETY: Works on a FRESH CLONE. The original ADO repo is NEVER modified.
.PARAMETER SecretScanDir
    Directory containing gitleaks JSON reports from scan-secrets.ps1
.PARAMETER Pat
    ADO PAT for cloning (read-only, original repo NOT modified)
.PARAMETER GitHubOrg
    GitHub organization name (used for mapping in the report)
.PARAMETER OutputDir
    Directory for scrubbed repo clones and reports
.PARAMETER DryRun
    If set, shows what would happen without modifying repos
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SecretScanDir,

    [Parameter(Mandatory = $true)]
    [string]$Pat,

    [Parameter(Mandatory = $true)]
    [string]$GitHubOrg,

    [string]$OutputDir = "./output/scrubbed",
    [string]$TempDir = "./tmp/scrub",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# --- Verify tools ---
$filterRepo = Get-Command git-filter-repo -ErrorAction SilentlyContinue
if (-not $filterRepo) {
    Write-Error "git-filter-repo not found. Install: pip install git-filter-repo"
    exit 1
}

# --- Setup ---
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
if (-not (Test-Path $TempDir)) { New-Item -ItemType Directory -Path $TempDir -Force | Out-Null }

Write-Host "=== Secret Scrubbing $(if ($DryRun) {'(DRY RUN)'} else {'(LIVE)'}) ===" -ForegroundColor Cyan
Write-Host "GitHub Org: $GitHubOrg" -ForegroundColor Gray
Write-Host "NOTE: Original ADO repos are NOT modified." -ForegroundColor Green

# --- Find all secret report files ---
$reportFiles = Get-ChildItem -Path $SecretScanDir -Filter "*_secrets.json" | Where-Object { $_.Length -gt 2 }

if ($reportFiles.Count -eq 0) {
    Write-Host "`nNo secret reports with findings found. All repos are clean." -ForegroundColor Green
    @() | ConvertTo-Json | Out-File -FilePath (Join-Path $OutputDir "secret-values.json") -Encoding utf8
    exit 0
}

Write-Host "Found $($reportFiles.Count) repos with secrets to process.`n" -ForegroundColor Yellow

# --- Collections ---
$migrationReport = @()
$secretValues = @()
$totalSecrets = 0

foreach ($reportFile in $reportFiles) {
    $repoIdentifier = $reportFile.BaseName -replace "_secrets$", ""
    Write-Host "  ==========================================" -ForegroundColor Cyan
    Write-Host "  Processing: $repoIdentifier" -ForegroundColor Yellow

    $findings = Get-Content $reportFile.FullName -Raw | ConvertFrom-Json
    if ($findings.Count -eq 0) { continue }

    # Filter out empty secrets but keep ALL findings for reporting
    $allFindings = @()
    foreach ($f in $findings) {
        if (-not [string]::IsNullOrWhiteSpace($f.Secret)) {
            $allFindings += $f
        }
    }
    $findings = $allFindings

    # Track unique secret values for deduplication (expressions + secret-values.json)
    $seenSecrets = @{}        # secret value ΓåÆ resolved secret name
    $seenSecretNames = @{}    # secret name ΓåÆ secret value (detect name collisions)

    Write-Host "    $($findings.Count) total secret findings" -ForegroundColor Red

    # Determine names
    $parts = $repoIdentifier -split "_", 2
    $project = $parts[0]
    $repoName = $parts[1]
    $ghRepoName = $repoName.ToLower() -replace " ", "-"
    $ghFullRepo = "$GitHubOrg/$ghRepoName"

    Write-Host "    Target GitHub repo: $ghFullRepo" -ForegroundColor Gray

    # Build replacement expressions for git-filter-repo
    $expressionsFile = Join-Path (Resolve-Path $TempDir).Path "$repoIdentifier-expressions.txt"
    $expressions = @()
    $secretCounter = 0

    foreach ($finding in $findings) {
        # Trim leading/trailing whitespace, quotes, commas, and semicolons
        $secret = $finding.Secret.Trim()
        $secret = $secret -replace '^["'']+|["'',;]+$', ''
        $secret = $secret.Trim()
        
        $match = $finding.Match
        if ([string]::IsNullOrWhiteSpace($secret)) { continue }

        # --- Filter out values that are NOT real secrets ---
        # Skip multi-line or values with control characters (GitHub API rejects these)
        if ($secret -match '[\r\n\x00-\x1f]') {
            Write-Host "    Γèÿ Skipped (contains control chars): [$($finding.RuleID)] $($finding.File):$($finding.StartLine)" -ForegroundColor DarkGray
            continue
        }

        # Skip common false-positive values
        $falsePositives = @(
            'changeme', 'password', 'secret', 'example', 'placeholder',
            'your-secret-here', 'your-password-here', 'your-token-here',
            'xxxxxxxx', 'test1234', 'abcdefgh', 'changeit', 'replace_me',
            'todo_replace', 'CHANGE_ME', 'INSERT_HERE', 'none', 'null',
            'undefined', 'default', 'required', 'optional'
        )
        if ($falsePositives -contains $secret.ToLower()) {
            Write-Host "    Γèÿ Skipped (placeholder value): [$secret] $($finding.File)" -ForegroundColor DarkGray
            continue
        }

        # Skip values that look like file paths or URLs (not secrets)
        if ($secret -match '^(https?://|/|\\|\./)' -or $secret -match '\.(js|ts|css|html|json|xml|yaml|yml|md|txt|png|jpg|svg)$') {
            Write-Host "    Γèÿ Skipped (path/URL): [$secret]" -ForegroundColor DarkGray
            continue
        }

        $secretCounter++
        $totalSecrets++

        # --- Extract key name from match (e.g. ENV_KEY from ENV_KEY=xyz123) ---
        $keyName = ""
        if ($match -match '(?i)([A-Z_][A-Z0-9_]*)\s*[=:]') {
            $keyName = $Matches[1]
        } else {
            $keyName = $finding.RuleID
        }

        # --- Use actual key name as GitHub Secret name ---
        $secretName = $keyName.ToUpper() -replace "[^A-Z0-9_]", "_"
        if ([string]::IsNullOrWhiteSpace($secretName)) {
            $secretName = ($finding.RuleID -replace "[^a-zA-Z0-9]", "_").ToUpper()
        }
        if ($secretName -match "^\d") { $secretName = "S_$secretName" }
        # GitHub reserves the GITHUB_ prefix for system secrets ΓÇö rename to GH_
        if ($secretName -match "^GITHUB_") {
            $secretName = $secretName -replace "^GITHUB_", "GH_"
            Write-Host "      ΓÜá Renamed to $secretName (GITHUB_ prefix is reserved by GitHub)" -ForegroundColor Yellow
        }
        if ($secretName.Length -gt 100) { $secretName = $secretName.Substring(0, 100) }

        # --- Resolve name collisions (same key name, different secret values) ---
        # e.g. DB_PASSWORD=abc in dev ΓåÆ DB_PASSWORD
        #      DB_PASSWORD=xyz in prod ΓåÆ DB_PASSWORD_2
        if ($seenSecrets.ContainsKey($secret)) {
            # Same secret value seen before ΓÇö reuse the already-assigned name
            $secretName = $seenSecrets[$secret]
        } elseif ($seenSecretNames.ContainsKey($secretName)) {
            # Different value but same name ΓÇö append suffix to make unique
            $baseName = $secretName
            $suffix = 2
            while ($seenSecretNames.ContainsKey("${baseName}_${suffix}")) {
                $suffix++
            }
            $secretName = "${baseName}_${suffix}"
            Write-Host "      ΓÜá Name collision: renamed to $secretName (same key, different value)" -ForegroundColor Yellow
        }

        # --- Log what was found ---
        Write-Host "    ΓåÆ KEY: $keyName | File: $($finding.File):$($finding.StartLine) | Rule: $($finding.RuleID)" -ForegroundColor Yellow
        Write-Host "      Match:  [$match]" -ForegroundColor DarkGray
        Write-Host "      Secret: [$secret]" -ForegroundColor DarkGray
        Write-Host "      GitHub Secret Name: $secretName" -ForegroundColor Gray

        # --- Preview (masked) ---
        $secretPreview = if ($secret.Length -le 8) {
            "***"
        } else {
            $secret.Substring(0, 3) + ("*" * ($secret.Length - 6)) + $secret.Substring($secret.Length - 3)
        }

        # --- Only add unique secrets to expressions file and secret-values.json ---
        if (-not $seenSecrets.ContainsKey($secret)) {
            $seenSecrets[$secret] = $secretName
            $seenSecretNames[$secretName] = $secret

            # --- Save for post-migration (one entry per unique secret value) ---
            $secretValues += [PSCustomObject]@{
                GitHubRepo       = $ghFullRepo
                SecretName       = $secretName
                SecretValue      = $secret
                MatchString      = $match
                KeyName          = $keyName
                RuleID           = $finding.RuleID
                SourceFile       = $finding.File
                SourceLine       = $finding.StartLine
                Description      = $finding.Description
            }

            # --- Build redaction expression (one per unique secret value) ---
            $placeholder = "`${{ secrets.$secretName }}"
            $expressions += "$secret==>$placeholder"
        }

        # --- Add ALL findings to migration report (not deduplicated) ---
        $migrationReport += [PSCustomObject]@{
            Repo              = $repoIdentifier
            GitHubRepo        = $ghFullRepo
            File              = $finding.File
            Line              = $finding.StartLine
            KeyName           = $keyName
            SecretType        = $finding.RuleID
            Description       = $finding.Description
            SecretPreview     = $secretPreview
            GitHubSecretName  = $secretName
            HowToUse          = "`${{ secrets.$secretName }}"
            Action            = "Update code to read from env var"
        }
    }

    $uniqueCount = $seenSecrets.Count
    Write-Host "    $uniqueCount unique secrets (deduped for scrubbing), $secretCounter total occurrences reported" -ForegroundColor Cyan

    # Sort expressions by secret length (longest first) so longer matches
    # are processed before shorter ones ΓÇö prevents partial replacements
    # e.g. "AKIAIOSFODNN7EXAMPLE" must be replaced before "AKIA" alone
    $sortedExpressions = $expressions | Sort-Object { ($_ -split "==>")[0].Length } -Descending
    $sortedExpressions | Out-File -FilePath $expressionsFile -Encoding utf8 -NoNewline:$false

    if ($DryRun) {
        Write-Host "    [DRY RUN] Would redact $($expressions.Count) secrets" -ForegroundColor Gray
        continue
    }

    # --- Clone repo (read-only, ADO untouched) ---
    $cloneDir = Join-Path (Resolve-Path $TempDir).Path $repoIdentifier
    if (Test-Path $cloneDir) { Remove-Item -Recurse -Force $cloneDir }

    Write-Host "    Cloning repo (read-only)..." -ForegroundColor Gray
    $adoOrg = $env:ADO_ORG
    $cloneUrl = "https://$Pat@dev.azure.com/$adoOrg/$project/_git/$repoName"
    git clone --mirror $cloneUrl $cloneDir 2>&1 | Out-Null

    if (-not (Test-Path $cloneDir)) {
        Write-Warning "    Failed to clone repo ΓÇö skipping"
        continue
    }

    # --- Redact secrets from Git history ---
    Write-Host "    Running git-filter-repo (redacting $($expressions.Count) secrets)..." -ForegroundColor Gray
    $absExpressionsFile = (Resolve-Path $expressionsFile).Path
    Push-Location $cloneDir
    try {
        git filter-repo --replace-text "$absExpressionsFile" --force 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "    git-filter-repo returned exit code $LASTEXITCODE"
        } else {
            Write-Host "    Γ£ô Secrets redacted from history" -ForegroundColor Green
        }
    }
    catch {
        Write-Warning "    git-filter-repo error: $_"
    }
    finally {
        Pop-Location
    }

    Write-Host "    Γ£ô Original ADO repo was NOT modified" -ForegroundColor Green

    # Move to output
    $outputRepoDir = Join-Path $OutputDir $repoIdentifier
    if (Test-Path $outputRepoDir) { Remove-Item -Recurse -Force $outputRepoDir }
    Move-Item -Path $cloneDir -Destination $outputRepoDir
}

# --- Save secret values JSON ---
$secretValuesFile = Join-Path $OutputDir "secret-values.json"
$secretValues | ConvertTo-Json -Depth 10 | Out-File -FilePath $secretValuesFile -Encoding utf8

# --- Save Migration Report CSV ---
$reportCsvFile = Join-Path $OutputDir "secret-migration-report.csv"
if ($migrationReport.Count -gt 0) {
    $migrationReport | Export-Csv -Path $reportCsvFile -NoTypeInformation
}

# --- Generate HTML Dashboard ---
$dashboardDir = Join-Path $OutputDir "dashboard"
if (-not (Test-Path $dashboardDir)) { New-Item -ItemType Directory -Path $dashboardDir -Force | Out-Null }

$htmlFile = Join-Path $dashboardDir "index.html"
$repoGroups = $migrationReport | Group-Object -Property GitHubRepo

$tableRows = ""
foreach ($entry in $migrationReport) {
    $typeColor = switch -Wildcard ($entry.SecretType) {
        "*password*" { "#e74c3c" }
        "*api*"      { "#e67e22" }
        "*token*"    { "#f39c12" }
        "*aws*"      { "#ff6b6b" }
        "*key*"      { "#e74c3c" }
        "*private*"  { "#c0392b" }
        default      { "#e67e22" }
    }
    $tableRows += @"
        <tr>
            <td><span class="repo-badge">$($entry.GitHubRepo)</span></td>
            <td><code>$($entry.File)</code></td>
            <td class="center">$($entry.Line)</td>
            <td><span class="type-badge" style="background:$typeColor">$($entry.SecretType)</span></td>
            <td>$($entry.Description)</td>
            <td><code>$($entry.SecretPreview)</code></td>
            <td><code>$($entry.GitHubSecretName)</code></td>
            <td><code>$($entry.HowToUse)</code></td>
        </tr>

"@
}

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Secret Migration Dashboard</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #0d1117; color: #c9d1d9; }
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
        th { background: #1f2937; color: #58a6ff; text-align: left; padding: 12px 16px; font-size: 13px; text-transform: uppercase; letter-spacing: 0.5px; border-bottom: 2px solid #30363d; }
        td { padding: 10px 16px; border-bottom: 1px solid #21262d; font-size: 14px; }
        tr:hover { background: #1c2128; }
        code { background: #1f2937; padding: 2px 6px; border-radius: 4px; font-size: 13px; color: #79c0ff; }
        .repo-badge { background: #1f6feb; color: white; padding: 3px 8px; border-radius: 12px; font-size: 12px; white-space: nowrap; }
        .type-badge { color: white; padding: 3px 8px; border-radius: 4px; font-size: 12px; font-weight: 600; }
        .center { text-align: center; }
        .legend { background: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 16px 24px; margin-top: 24px; }
        .legend h3 { color: #58a6ff; margin-bottom: 8px; }
        .legend p { color: #8b949e; font-size: 14px; line-height: 1.8; }
        .footer { text-align: center; padding: 24px; color: #484f58; font-size: 12px; }
    </style>
</head>
<body>
    <div class="header">
        <h1>≡ƒöÆ Secret Migration Dashboard</h1>
        <p>Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC')</p>
    </div>

    <div class="stats">
        <div class="stat-card warning">
            <div class="number">$totalSecrets</div>
            <div class="label">Secrets Found</div>
        </div>
        <div class="stat-card">
            <div class="number">$($reportFiles.Count)</div>
            <div class="label">Repos Scanned</div>
        </div>
        <div class="stat-card">
            <div class="number">$($repoGroups.Count)</div>
            <div class="label">Repos with Secrets</div>
        </div>
        <div class="stat-card">
            <div class="number">$($migrationReport | Select-Object -ExpandProperty File -Unique | Measure-Object | Select-Object -ExpandProperty Count)</div>
            <div class="label">Files Affected</div>
        </div>
    </div>

    <div class="content">
        <h2 style="color:#c9d1d9; margin-bottom:8px;">Secret Details</h2>
        <p style="color:#8b949e; margin-bottom:16px;">Each secret has been redacted from Git history and stored as a GitHub Secret. Teams must update code to use environment variables.</p>

        <table>
            <thead>
                <tr>
                    <th>GitHub Repo</th>
                    <th>File</th>
                    <th>Line</th>
                    <th>Type</th>
                    <th>Description</th>
                    <th>Preview</th>
                    <th>GitHub Secret Name</th>
                    <th>How to Use</th>
                </tr>
            </thead>
            <tbody>
$tableRows
            </tbody>
        </table>

        <div class="legend">
            <h3>≡ƒôï What Teams Need To Do</h3>
            <p>1. Find the <strong>GitHub Secret Name</strong> for each entry in the table above</p>
            <p>2. Go to GitHub repo ΓåÆ Settings ΓåÆ Secrets ΓåÆ verify the secret exists</p>
            <p>3. Update code to read from environment variable instead of hardcoded value</p>
            <p>4. In GitHub Actions workflows, use <code>`${{ secrets.SECRET_NAME }}</code> to inject the value</p>
            <p>5. <strong style="color:#f85149;">ROTATE all credentials</strong> ΓÇö the original values may have been exposed in ADO history</p>
        </div>
    </div>

    <div class="footer">
        Generated by ADO-to-GitHub Migration Accelerator | Secret values are NOT shown in this dashboard
    </div>
</body>
</html>
"@

$html | Out-File -FilePath $htmlFile -Encoding utf8
Write-Host "`n=== Dashboard generated: $htmlFile ===" -ForegroundColor Green

# --- Print summary table ---
Write-Host "`n=== SECRET MIGRATION REPORT ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "  ΓöîΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓö¼ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓö¼ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓö¼ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÉ" -ForegroundColor White
Write-Host "  Γöé Repo               Γöé File:Line              Γöé Secret Type                      Γöé GitHub Secret Name              Γöé" -ForegroundColor White
Write-Host "  Γö£ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓö╝ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓö╝ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓö╝ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöñ" -ForegroundColor White
foreach ($entry in $migrationReport) {
    $repoCol = $entry.GitHubRepo.PadRight(18).Substring(0, 18)
    $fileCol = "$($entry.File):$($entry.Line)".PadRight(22).Substring(0, 22)
    $typeCol = $entry.SecretType.PadRight(32).Substring(0, 32)
    $secretCol = $entry.GitHubSecretName.PadRight(31).Substring(0, 31)
    Write-Host "  Γöé $repoCol Γöé $fileCol Γöé $typeCol Γöé $secretCol Γöé" -ForegroundColor White
}
Write-Host "  ΓööΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓö┤ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓö┤ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓö┤ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÿ" -ForegroundColor White

# --- Summary ---
Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "Repos processed:     $($reportFiles.Count)" -ForegroundColor Gray
Write-Host "Total secrets:       $totalSecrets" -ForegroundColor Yellow
Write-Host "Secret values file:  $secretValuesFile" -ForegroundColor Gray
Write-Host "Migration report:    $reportCsvFile" -ForegroundColor Gray
Write-Host "HTML Dashboard:      $htmlFile" -ForegroundColor Gray
Write-Host "Scrubbed repos:      $OutputDir" -ForegroundColor Green
Write-Host "Original ADO repos:  UNTOUCHED" -ForegroundColor Green

exit 0
