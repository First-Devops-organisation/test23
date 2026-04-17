<#
.SYNOPSIS
    Runs GitHub Actions Importer audit against Azure DevOps pipelines.
.DESCRIPTION
    Wraps 'gh actions-importer audit azure-devops' to produce a conversion readiness report
    showing which pipeline tasks are supported, partially supported, or unsupported.
.PARAMETER AdoOrg
    Azure DevOps organization name (not URL)
.PARAMETER AdoProject
    Optional: specific project to audit. If omitted, audits all projects.
.PARAMETER AdoPat
    ADO PAT
.PARAMETER GitHubPat
    GitHub PAT (needed by actions-importer)
.PARAMETER OutputDir
    Directory for audit output
#>
[CmdletBinding()]
param(
    [string]$AdoOrg,

    [string]$AdoProject,

    [string]$AdoPat,

    [string]$GitHubPat,


    [string]$OutputDir = "./output/pipeline-audit"
)

$AdoOrg = if ($AdoOrg) { $AdoOrg } elseif ($env:ADO_Org) { $env:ADO_Org } elseif ($env:ADO_ORG) { $env:ADO_ORG } elseif ($env:ADOORG) { $env:ADOORG } else { $null }
if ($AdoOrg -match "^https://dev\.azure\.com/(.+)$") {
    $AdoOrg = $matches[1]
}
$AdoPat = if ($AdoPat) { $AdoPat } elseif ($env:ADO_PAT) { $env:ADO_PAT } elseif ($env:AZDO_PAT) { $env:AZDO_PAT } else { $null }
$GitHubPat = if ($GitHubPat) { $GitHubPat } elseif ($env:GH_PAT) { $env:GH_PAT } elseif ($env:GITHUB_PAT) { $env:GITHUB_PAT } else { $null }
$OutputDir = if ($OutputDir -and -not [string]::IsNullOrWhiteSpace($OutputDir)) { $OutputDir } else { "./output/pipeline-audit" }

if (-not $AdoOrg) {
    Write-Host "ERROR: Azure DevOps organization is required. Provide -AdoOrg or set ADO_Org / ADO_ORG." -ForegroundColor Red
    exit 1
}
if (-not $AdoPat) {
    Write-Host "ERROR: Azure DevOps PAT is required. Provide -AdoPat or set ADO_PAT." -ForegroundColor Red
    exit 1
}
if (-not $GitHubPat) {
    Write-Host "ERROR: GitHub PAT is required. Provide -GitHubPat or set GH_PAT / GITHUB_PAT." -ForegroundColor Red
    exit 1
}

$ErrorActionPreference = "Stop"

# --- Verify Prerequisites ---
$gh = Get-Command gh -ErrorAction SilentlyContinue
if (-not $gh) {
    Write-Host "GitHub CLI (gh) not found. Install from: https://cli.github.com" -ForegroundColor Red
    exit 1
}

# Check actions-importer extension
$extensions = gh extension list 2>&1
if ($extensions -notmatch "actions-importer") {
    Write-Host "Installing gh actions-importer extension..." -ForegroundColor Yellow
    gh extension install github/gh-actions-importer
}

if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
$dashboardDir = Join-Path $OutputDir "dashboard"
if (-not (Test-Path $dashboardDir)) { New-Item -ItemType Directory -Path $dashboardDir -Force | Out-Null }

Write-Host "=== Pipeline Audit: $AdoOrg ===" -ForegroundColor Cyan

# --- Set environment variables for actions-importer ---
$env:GITHUB_ACCESS_TOKEN = $GitHubPat
$env:GITHUB_TOKEN = $GitHubPat
$env:GH_TOKEN = $GitHubPat
$env:AZURE_DEVOPS_ACCESS_TOKEN = $AdoPat
$env:ADO_PAT = $AdoPat

# --- Update actions-importer ---
Write-Host "Updating actions-importer..." -ForegroundColor Yellow
gh actions-importer update 2>&1

# --- Run Audit ---
$auditArgs = @(
    "actions-importer", "audit", "azure-devops",
    "--output-dir", $OutputDir,
    "--azure-devops-organization", $AdoOrg
)

if ($AdoProject) {
    $auditArgs += "--azure-devops-project"
    $auditArgs += $AdoProject
}

Write-Host "Running audit (this may take several minutes)..." -ForegroundColor Yellow
gh @auditArgs 2>&1

# --- Parse Results ---
$auditSummaryFile = Join-Path $OutputDir "audit_summary.md"
if (Test-Path $auditSummaryFile) {
    Write-Host "`n=== Audit Summary ===" -ForegroundColor Cyan
    $content = Get-Content $auditSummaryFile -Raw

    # Extract key metrics
    $successMatch = [regex]::Match($content, "Successful:\s*(\d+)")
    $partialMatch = [regex]::Match($content, "Partially successful:\s*(\d+)")
    $unsupportedMatch = [regex]::Match($content, "Unsupported:\s*(\d+)")
    $failedMatch = [regex]::Match($content, "Failed:\s*(\d+)")

    if ($successMatch.Success) { Write-Host "  Fully Convertible:    $($successMatch.Groups[1].Value)" -ForegroundColor Green }
    if ($partialMatch.Success) { Write-Host "  Partially Convertible: $($partialMatch.Groups[1].Value)" -ForegroundColor Yellow }
    if ($unsupportedMatch.Success) { Write-Host "  Unsupported:          $($unsupportedMatch.Groups[1].Value)" -ForegroundColor Red }
    if ($failedMatch.Success) { Write-Host "  Failed:               $($failedMatch.Groups[1].Value)" -ForegroundColor Red }

    Write-Host "`nFull audit report: $auditSummaryFile" -ForegroundColor Green
}

# --- Manual Tasks Summary ---
$manualTasksFile = Join-Path $OutputDir "manual-tasks-summary.md"
$manualTasks = @"
# Manual Tasks Required Post-Pipeline Migration

## Per Pipeline
- [ ] Create GitHub Actions secrets (from ADO variable groups / key vault references)
- [ ] Configure self-hosted runners (if using ADO self-hosted agents)
- [ ] Set up GitHub Environments with protection rules (replaces ADO stages/gates)
- [ ] Update any hard-coded ADO URLs in scripts
- [ ] Configure OIDC for cloud deployments (replaces ADO service connections)

## Classic Release Pipelines
- [ ] Deployment gates → GitHub Environment protection rules + required reviewers
- [ ] Pre/post-deployment approvals → GitHub Environment required reviewers
- [ ] Variable scoping per stage → GitHub Environment secrets
- [ ] Artifact triggers → workflow_run triggers or composite actions

## Common Unsupported Tasks (require custom actions or scripts)
- AzureRmWebAppDeployment → azure/webapps-deploy
- AzureKeyVault → azure/login + az keyvault commands
- SonarQubePrepare/Analyze → SonarSource/sonarqube-scan-action
- VSBuild → microsoft/setup-msbuild + msbuild command
- NuGetCommand → nuget/setup-nuget + nuget commands

## NOT Migrated (stays in ADO)
- Pipeline run history and logs
- Build artifacts
- Test results
- Deployment history
"@
$manualTasks | Out-File -FilePath $manualTasksFile -Encoding utf8
Write-Host "Manual tasks guide saved to: $manualTasksFile" -ForegroundColor Green

# --- Cleanup env vars ---
Remove-Item Env:\GITHUB_ACCESS_TOKEN -ErrorAction SilentlyContinue
Remove-Item Env:\AZURE_DEVOPS_ACCESS_TOKEN -ErrorAction SilentlyContinue

# --- HTML Dashboard Report ------------------------------------------------
Add-Type -AssemblyName System.Web

$scanDate  = Get-Date -Format "yyyy-MM-dd HH:mm:ss UTC"
$projLabel = if ($AdoProject) { $AdoProject } else { "All Projects" }

# Metrics
$auditMetrics = @{ Successful="0"; Partial="0"; Unsupported="0"; Failed="0"; Total="0" }
if (Test-Path $auditSummaryFile) {
    $raw = Get-Content $auditSummaryFile -Raw
    $s=[regex]::Match($raw,"Successful:\s*(\d+)");           if($s.Success){$auditMetrics.Successful=$s.Groups[1].Value}
    $p=[regex]::Match($raw,"Partially successful:\s*(\d+)"); if($p.Success){$auditMetrics.Partial=$p.Groups[1].Value}
    $u=[regex]::Match($raw,"Unsupported:\s*(\d+)");          if($u.Success){$auditMetrics.Unsupported=$u.Groups[1].Value}
    $f=[regex]::Match($raw,"Failed:\s*(\d+)");               if($f.Success){$auditMetrics.Failed=$f.Groups[1].Value}
    $auditMetrics.Total = [int]$auditMetrics.Successful + [int]$auditMetrics.Partial + [int]$auditMetrics.Unsupported + [int]$auditMetrics.Failed
}

# Manual tasks content
$manualHtml = ""
if (Test-Path $manualTasksFile) {
    $mtRaw = Get-Content $manualTasksFile -Raw
    $manualHtml = [System.Web.HttpUtility]::HtmlEncode($mtRaw) -replace "`n","<br/>"
}

# Converted YAML files table rows
$pipelineRows = ""
$yamlFiles = Get-ChildItem -Path $OutputDir -Recurse -Filter "*.yml" -ErrorAction SilentlyContinue
foreach ($yf in $yamlFiles) {
    $relPath = $yf.FullName.Replace($OutputDir,"").TrimStart("\").TrimStart("/")
    $name = [System.Web.HttpUtility]::HtmlEncode($yf.BaseName)
    $dir  = [System.Web.HttpUtility]::HtmlEncode((Split-Path $relPath -Parent))
    $size = "{0:N1} KB" -f ($yf.Length / 1KB)
    $pipelineRows += "    <tr><td>$dir</td><td>$name</td><td class='num'>$size</td><td class='center'>&#9989; Converted</td></tr>`n"
}

# Percentages
$total = [Math]::Max([int]$auditMetrics.Total, 1)
$pctSuccess     = [math]::Round(([int]$auditMetrics.Successful   / $total) * 100)
$pctPartial     = [math]::Round(([int]$auditMetrics.Partial      / $total) * 100)
$pctUnsupported = [math]::Round(([int]$auditMetrics.Unsupported  / $total) * 100)
$pctFailed      = [math]::Round(([int]$auditMetrics.Failed       / $total) * 100)

$lblSuccess     = if ($pctSuccess -ge 8)     { "${pctSuccess}%" }     else { "" }
$lblPartial     = if ($pctPartial -ge 8)     { "${pctPartial}%" }     else { "" }
$lblUnsupported = if ($pctUnsupported -ge 8) { "${pctUnsupported}%" } else { "" }
$lblFailed      = if ($pctFailed -ge 8)      { "${pctFailed}%" }      else { "" }

$encOrg  = [System.Web.HttpUtility]::HtmlEncode($AdoOrg)
$encProj = [System.Web.HttpUtility]::HtmlEncode($projLabel)

# Dynamic sections
$convertedSection = if ($pipelineRows) {
    @"
  <table id="pipelineTable">
    <thead><tr><th>Directory</th><th>Pipeline</th><th>Size</th><th>Status</th></tr></thead>
    <tbody>
$pipelineRows
    </tbody>
  </table>
"@
} else { "  <p class='muted'>No converted YAML files found in audit output.</p>" }

$manualSection = if ($manualHtml) {
    "  <div class='pre-block'>$manualHtml</div>"
} else { "  <p class='muted'>No manual tasks file found.</p>" }

$rawSection = if (Test-Path $auditSummaryFile) {
    $escaped = [System.Web.HttpUtility]::HtmlEncode((Get-Content $auditSummaryFile -Raw)) -replace "`n","<br/>"
    "  <div class='pre-block'>$escaped</div>"
} else { "  <p class='muted'>audit_summary.md not available.</p>" }

$htmlContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Pipeline Audit Report - $encOrg</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { font-family: 'Segoe UI', Tahoma, sans-serif; background: #f0f2f5; color: #24292f; padding: 20px; }
  .container { max-width: 1400px; margin: 0 auto; }
  h1 { font-size: 1.8rem; margin-bottom: 5px; color: #0078d4; }
  h2 { font-size: 1.3rem; margin: 30px 0 12px; color: #24292f; border-bottom: 2px solid #e1e4e8; padding-bottom: 6px; }
  .subtitle { color: #586069; margin-bottom: 20px; font-size: 0.9rem; }
  .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 15px; margin-bottom: 25px; }
  .card { background: #fff; border-radius: 8px; padding: 18px; box-shadow: 0 1px 3px rgba(0,0,0,0.12); text-align: center; }
  .card .value { font-size: 2rem; font-weight: 700; color: #0078d4; }
  .card .label { font-size: 0.85rem; color: #586069; margin-top: 4px; }
  .card.green .value { color: #1a7f37; }
  .card.yellow .value { color: #d29922; }
  .card.red .value { color: #cf222e; }
  table { width: 100%; border-collapse: collapse; background: #fff; border-radius: 8px; overflow: hidden; box-shadow: 0 1px 3px rgba(0,0,0,0.12); margin-bottom: 20px; }
  th { background: #0078d4; color: #fff; padding: 12px 10px; text-align: left; font-size: 0.85rem; position: sticky; top: 0; }
  td { padding: 10px; border-bottom: 1px solid #e1e4e8; font-size: 0.85rem; }
  tr:hover { background: #f6f8fa; }
  .num { text-align: right; font-variant-numeric: tabular-nums; }
  .center { text-align: center; }
  .bar-chart { display: flex; height: 32px; border-radius: 6px; overflow: hidden; margin: 12px 0; box-shadow: 0 1px 3px rgba(0,0,0,0.12); }
  .bar-chart .seg { display: flex; align-items: center; justify-content: center; font-size: .75rem; font-weight: 600; color: #fff; min-width: 2px; }
  .seg-success { background: #1a7f37; }
  .seg-partial { background: #d29922; }
  .seg-unsupported { background: #cf222e; }
  .seg-failed { background: #6e7681; }
  .legend { display: flex; gap: 20px; flex-wrap: wrap; margin-bottom: 20px; font-size: .85rem; }
  .legend-item { display: flex; align-items: center; gap: 6px; }
  .legend-dot { width: 12px; height: 12px; border-radius: 3px; }
  .pre-block { background: #fff; border: 1px solid #e1e4e8; border-radius: 6px; padding: 16px; font-family: 'Cascadia Code', Consolas, monospace; font-size: .85rem; white-space: pre-wrap; overflow-x: auto; max-height: 400px; overflow-y: auto; box-shadow: 0 1px 3px rgba(0,0,0,0.12); }
  .muted { color: #586069; }
  section { margin-bottom: 20px; }
  .footer { margin-top: 30px; color: #586069; font-size: 0.8rem; text-align: center; }
</style>
</head>
<body>
<div class="container">
  <h1>&#128269; ADO Pipeline Audit Report</h1>
  <p class="subtitle">Organization: <strong>$encOrg</strong> | Project: <strong>$encProj</strong> | Scanned: $scanDate</p>

  <section id="summary">
  <h2>Conversion Summary</h2>
  <div class="cards">
    <div class="card"><div class="value">$($auditMetrics.Total)</div><div class="label">Total Pipelines</div></div>
    <div class="card green"><div class="value">$($auditMetrics.Successful)</div><div class="label">Fully Convertible</div></div>
    <div class="card yellow"><div class="value">$($auditMetrics.Partial)</div><div class="label">Partially Convertible</div></div>
    <div class="card red"><div class="value">$($auditMetrics.Unsupported)</div><div class="label">Unsupported</div></div>
    <div class="card red"><div class="value">$($auditMetrics.Failed)</div><div class="label">Failed</div></div>
  </div>
  </section>

  <section id="chart">
  <h2>Readiness Breakdown</h2>
  <div class="bar-chart">
    <div class="seg seg-success" style="width:${pctSuccess}%">$lblSuccess</div>
    <div class="seg seg-partial" style="width:${pctPartial}%">$lblPartial</div>
    <div class="seg seg-unsupported" style="width:${pctUnsupported}%">$lblUnsupported</div>
    <div class="seg seg-failed" style="width:${pctFailed}%">$lblFailed</div>
  </div>
  <div class="legend">
    <div class="legend-item"><div class="legend-dot" style="background:#1a7f37"></div>Fully Convertible ($pctSuccess%)</div>
    <div class="legend-item"><div class="legend-dot" style="background:#d29922"></div>Partially Convertible ($pctPartial%)</div>
    <div class="legend-item"><div class="legend-dot" style="background:#cf222e"></div>Unsupported ($pctUnsupported%)</div>
    <div class="legend-item"><div class="legend-dot" style="background:#6e7681"></div>Failed ($pctFailed%)</div>
  </div>
  </section>

  <section id="converted">
  <h2>Converted Pipeline Files</h2>
$convertedSection
  </section>

  <section id="manual">
  <h2>Manual Tasks Required Post-Migration</h2>
$manualSection
  </section>

  <section id="raw">
  <h2>Raw Audit Summary</h2>
$rawSection
  </section>

  <p class="footer">Generated by ADO-to-GitHub Migration Accelerator &mdash; Pipeline Audit | $scanDate</p>
</div>
</body>
</html>
"@

$htmlOut = Join-Path $dashboardDir "pipeline-audit-report.html"
$htmlContent | Out-File -FilePath $htmlOut -Encoding utf8

Write-Host "`nReports saved:" -ForegroundColor Cyan
Write-Host "  Audit output : $OutputDir"
Write-Host "  Manual tasks : $manualTasksFile"
Write-Host "  HTML report  : $htmlOut"
Write-Host "`nPipeline audit complete." -ForegroundColor Cyan
