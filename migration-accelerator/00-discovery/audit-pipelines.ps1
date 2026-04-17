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

    # Extract key metrics (handles **N** markdown bold and optional percentages)
    $successMatch = [regex]::Match($content, "Successful:\s*\*{0,2}(\d+)\*{0,2}")
    $partialMatch = [regex]::Match($content, "Partially successful:\s*\*{0,2}(\d+)\*{0,2}")
    $unsupportedMatch = [regex]::Match($content, "Unsupported:\s*\*{0,2}(\d+)\*{0,2}")
    $failedMatch = [regex]::Match($content, "Failed:\s*\*{0,2}(\d+)\*{0,2}")

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
    Write-Host "DEBUG audit_summary.md content:" -ForegroundColor Magenta
    Write-Host $raw
    $s=[regex]::Match($raw,"Successful:\s*\*{0,2}(\d+)\*{0,2}");           if($s.Success){$auditMetrics.Successful=$s.Groups[1].Value}
    $p=[regex]::Match($raw,"Partially successful:\s*\*{0,2}(\d+)\*{0,2}"); if($p.Success){$auditMetrics.Partial=$p.Groups[1].Value}
    $u=[regex]::Match($raw,"Unsupported:\s*\*{0,2}(\d+)\*{0,2}");          if($u.Success){$auditMetrics.Unsupported=$u.Groups[1].Value}
    $f=[regex]::Match($raw,"Failed:\s*\*{0,2}(\d+)\*{0,2}");               if($f.Success){$auditMetrics.Failed=$f.Groups[1].Value}
    $auditMetrics.Total = [int]$auditMetrics.Successful + [int]$auditMetrics.Partial + [int]$auditMetrics.Unsupported + [int]$auditMetrics.Failed
    Write-Host "DEBUG parsed metrics: Total=$($auditMetrics.Total) Success=$($auditMetrics.Successful) Partial=$($auditMetrics.Partial) Unsupported=$($auditMetrics.Unsupported) Failed=$($auditMetrics.Failed)" -ForegroundColor Magenta
} else {
    Write-Host "WARNING: audit_summary.md not found at $auditSummaryFile" -ForegroundColor Yellow
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
$pctReady       = $pctSuccess + $pctPartial

$encOrg  = [System.Web.HttpUtility]::HtmlEncode($AdoOrg)
$encProj = [System.Web.HttpUtility]::HtmlEncode($projLabel)

# Donut chart SVG conic-gradient segments (CSS-based)
$donutSeg1 = $pctSuccess
$donutSeg2 = $donutSeg1 + $pctPartial
$donutSeg3 = $donutSeg2 + $pctUnsupported

# Converted pipelines table rows
$convertedSection = if ($pipelineRows) {
    @"
      <table>
        <thead><tr><th>Directory</th><th>Pipeline</th><th>Size</th><th>Status</th></tr></thead>
        <tbody>
$pipelineRows
        </tbody>
      </table>
"@
} else { "      <p class='empty-state'><span class='empty-icon'>&#128194;</span>No converted YAML files found in audit output.</p>" }

# Manual tasks — parse markdown into HTML checklist
$manualSection = ""
if (Test-Path $manualTasksFile) {
    $mtLines = Get-Content $manualTasksFile
    foreach ($line in $mtLines) {
        if ($line -match "^#+\s+(.+)") {
            $manualSection += "<h4>$($matches[1])</h4>`n"
        } elseif ($line -match "^- \[ \]\s+(.+)") {
            $escaped = [System.Web.HttpUtility]::HtmlEncode($matches[1])
            $manualSection += "<label class='checklist-item'><input type='checkbox'/><span>$escaped</span></label>`n"
        } elseif ($line -match "^- (.+)") {
            $escaped = [System.Web.HttpUtility]::HtmlEncode($matches[1])
            $manualSection += "<div class='task-note'>&#8226; $escaped</div>`n"
        }
    }
}
if (-not $manualSection) { $manualSection = "<p class='empty-state'><span class='empty-icon'>&#9989;</span>No manual tasks file found.</p>" }

# Raw summary
$rawSection = if (Test-Path $auditSummaryFile) {
    $escaped = [System.Web.HttpUtility]::HtmlEncode((Get-Content $auditSummaryFile -Raw))
    "<pre class='raw-block'>$escaped</pre>"
} else { "<p class='empty-state'>audit_summary.md not available.</p>" }

# Build the pipeline detail rows for the breakdown table
$breakdownRows = @"
        <tr><td><span class='dot' style='background:#10b981'></span> Fully Convertible</td>
            <td class='num'>$($auditMetrics.Successful)</td>
            <td><div class='mini-bar'><div class='mini-fill' style='width:${pctSuccess}%;background:#10b981'></div></div></td>
            <td class='num'>${pctSuccess}%</td></tr>
        <tr><td><span class='dot' style='background:#f59e0b'></span> Partially Convertible</td>
            <td class='num'>$($auditMetrics.Partial)</td>
            <td><div class='mini-bar'><div class='mini-fill' style='width:${pctPartial}%;background:#f59e0b'></div></div></td>
            <td class='num'>${pctPartial}%</td></tr>
        <tr><td><span class='dot' style='background:#ef4444'></span> Unsupported</td>
            <td class='num'>$($auditMetrics.Unsupported)</td>
            <td><div class='mini-bar'><div class='mini-fill' style='width:${pctUnsupported}%;background:#ef4444'></div></div></td>
            <td class='num'>${pctUnsupported}%</td></tr>
        <tr><td><span class='dot' style='background:#6b7280'></span> Failed</td>
            <td class='num'>$($auditMetrics.Failed)</td>
            <td><div class='mini-bar'><div class='mini-fill' style='width:${pctFailed}%;background:#6b7280'></div></div></td>
            <td class='num'>${pctFailed}%</td></tr>
"@

$htmlContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Pipeline Audit Report &mdash; $encOrg</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap');
  :root {
    --green: #10b981; --yellow: #f59e0b; --red: #ef4444; --gray: #6b7280;
    --bg: #0f172a; --surface: #1e293b; --surface2: #334155;
    --text: #f1f5f9; --text2: #94a3b8; --accent: #38bdf8; --accent2: #818cf8;
    --border: rgba(148,163,184,.15); --radius: 16px;
  }
  * { margin:0; padding:0; box-sizing:border-box; }
  body { font-family:'Inter',system-ui,sans-serif; background:var(--bg); color:var(--text); min-height:100vh; }

  /* --- Header banner --- */
  .header { background: linear-gradient(135deg, #0ea5e9 0%, #8b5cf6 50%, #ec4899 100%);
    padding: 40px 48px 32px; position: relative; overflow: hidden; }
  .header::before { content:''; position:absolute; top:-50%; right:-20%; width:600px; height:600px;
    background: radial-gradient(circle, rgba(255,255,255,.08) 0%, transparent 70%); }
  .header::after { content:''; position:absolute; bottom:-40%; left:-10%; width:500px; height:500px;
    background: radial-gradient(circle, rgba(255,255,255,.05) 0%, transparent 70%); }
  .header h1 { font-size:2.2rem; font-weight:800; letter-spacing:-.02em; position:relative; z-index:1; }
  .header h1 .icon { font-size:1.6rem; margin-right:10px; }
  .header .meta { margin-top:8px; font-size:.9rem; opacity:.85; position:relative; z-index:1; }
  .header .meta span { margin-right:24px; }
  .header .badge { display:inline-block; background:rgba(255,255,255,.2); backdrop-filter:blur(8px);
    padding:4px 14px; border-radius:20px; font-size:.8rem; font-weight:600; margin-top:12px; position:relative; z-index:1; }

  .container { max-width:1440px; margin:0 auto; padding: 0 32px 40px; }

  /* --- KPI Cards --- */
  .kpi-row { display:grid; grid-template-columns:repeat(5,1fr); gap:16px; margin: -40px 0 32px; position:relative; z-index:2; }
  .kpi { background:var(--surface); border:1px solid var(--border); border-radius:var(--radius); padding:24px 20px;
    text-align:center; transition: transform .2s, box-shadow .2s; }
  .kpi:hover { transform:translateY(-4px); box-shadow: 0 12px 40px rgba(0,0,0,.3); }
  .kpi .kpi-icon { font-size:1.6rem; margin-bottom:8px; }
  .kpi .kpi-val { font-size:2.4rem; font-weight:800; font-variant-numeric:tabular-nums; }
  .kpi .kpi-label { font-size:.78rem; color:var(--text2); margin-top:4px; text-transform:uppercase; letter-spacing:.06em; }
  .kpi.total .kpi-val { color:var(--accent); }
  .kpi.success .kpi-val { color:var(--green); }
  .kpi.partial .kpi-val { color:var(--yellow); }
  .kpi.unsupported .kpi-val { color:var(--red); }
  .kpi.failed .kpi-val { color:var(--gray); }

  /* --- Sections --- */
  .panel { background:var(--surface); border:1px solid var(--border); border-radius:var(--radius);
    padding:28px; margin-bottom:20px; }
  .panel h2 { font-size:1.15rem; font-weight:700; margin-bottom:20px; display:flex; align-items:center; gap:10px; }
  .panel h2 .sec-icon { font-size:1.2rem; }

  /* --- Donut + Breakdown side-by-side --- */
  .chart-grid { display:grid; grid-template-columns: 280px 1fr; gap:32px; align-items:center; }
  @media (max-width:768px) { .chart-grid { grid-template-columns:1fr; } }
  .donut-wrap { position:relative; width:220px; height:220px; margin:0 auto; }
  .donut { width:220px; height:220px; border-radius:50%;
    background: conic-gradient(
      var(--green) 0% ${donutSeg1}%,
      var(--yellow) ${donutSeg1}% ${donutSeg2}%,
      var(--red) ${donutSeg2}% ${donutSeg3}%,
      var(--gray) ${donutSeg3}% 100%
    );
    -webkit-mask: radial-gradient(circle, transparent 60%, black 61%);
            mask: radial-gradient(circle, transparent 60%, black 61%);
  }
  .donut-center { position:absolute; top:50%; left:50%; transform:translate(-50%,-50%); text-align:center; }
  .donut-center .big { font-size:2.6rem; font-weight:800; color:var(--accent); }
  .donut-center .sub { font-size:.8rem; color:var(--text2); }

  /* Breakdown table */
  .breakdown { width:100%; border-collapse:collapse; }
  .breakdown td { padding:12px 10px; border-bottom:1px solid var(--border); font-size:.9rem; }
  .breakdown tr:last-child td { border-bottom:none; }
  .dot { display:inline-block; width:10px; height:10px; border-radius:50%; margin-right:8px; vertical-align:middle; }
  .num { text-align:right; font-variant-numeric:tabular-nums; font-weight:600; }
  .mini-bar { width:100%; height:8px; background:var(--surface2); border-radius:4px; overflow:hidden; }
  .mini-fill { height:100%; border-radius:4px; transition: width .8s ease; }

  /* --- Stacked bar --- */
  .stacked-bar { display:flex; height:14px; border-radius:7px; overflow:hidden; margin-top:16px; }
  .stacked-bar .seg { transition: width .8s ease; }

  /* --- Table --- */
  table:not(.breakdown) { width:100%; border-collapse:collapse; }
  table:not(.breakdown) th { background: linear-gradient(135deg,#0ea5e9,#8b5cf6); color:#fff;
    padding:14px 12px; text-align:left; font-size:.8rem; text-transform:uppercase; letter-spacing:.06em; font-weight:600; }
  table:not(.breakdown) td { padding:12px; border-bottom:1px solid var(--border); font-size:.85rem; }
  table:not(.breakdown) tr:hover { background:rgba(56,189,248,.06); }
  .center { text-align:center; }
  .badge-ok { background:rgba(16,185,129,.15); color:var(--green); padding:3px 12px; border-radius:12px; font-size:.78rem; font-weight:600; }

  /* --- Checklist --- */
  .checklist-item { display:flex; align-items:flex-start; gap:10px; padding:8px 0; font-size:.88rem; cursor:pointer; }
  .checklist-item input[type=checkbox] { accent-color:var(--accent); margin-top:3px; width:16px; height:16px; }
  .checklist-item span { flex:1; }
  h4 { color:var(--accent); font-size:.95rem; margin:18px 0 6px; font-weight:600; }
  h4:first-child { margin-top:0; }
  .task-note { padding:4px 0 4px 26px; font-size:.85rem; color:var(--text2); }

  /* --- Raw block --- */
  .raw-block { background:var(--bg); border:1px solid var(--border); border-radius:12px; padding:20px;
    font-family:'Cascadia Code','Fira Code',Consolas,monospace; font-size:.82rem; color:var(--text2);
    white-space:pre-wrap; max-height:400px; overflow-y:auto; line-height:1.6; }

  /* Collapsible */
  details { margin-bottom:4px; }
  details summary { cursor:pointer; font-weight:600; font-size:.95rem; padding:8px 0; color:var(--text);
    list-style:none; display:flex; align-items:center; gap:8px; }
  details summary::before { content:'&#9654;'; font-size:.7rem; transition:transform .2s; display:inline-block; }
  details[open] summary::before { transform:rotate(90deg); }
  details > div { padding: 8px 0 0 20px; }

  .empty-state { text-align:center; padding:32px; color:var(--text2); }
  .empty-icon { font-size:2rem; display:block; margin-bottom:8px; }

  .footer { text-align:center; color:var(--text2); font-size:.78rem; margin-top:32px; padding:20px;
    border-top:1px solid var(--border); }
  .footer a { color:var(--accent); text-decoration:none; }

  /* Animate on load */
  @keyframes fadeUp { from { opacity:0; transform:translateY(20px); } to { opacity:1; transform:translateY(0); } }
  .kpi, .panel { animation: fadeUp .5s ease both; }
  .kpi:nth-child(2) { animation-delay:.05s; }
  .kpi:nth-child(3) { animation-delay:.1s; }
  .kpi:nth-child(4) { animation-delay:.15s; }
  .kpi:nth-child(5) { animation-delay:.2s; }
  .panel:nth-of-type(1) { animation-delay:.25s; }
  .panel:nth-of-type(2) { animation-delay:.3s; }
  .panel:nth-of-type(3) { animation-delay:.35s; }
  .panel:nth-of-type(4) { animation-delay:.4s; }
</style>
</head>
<body>

<!-- ===== HEADER ===== -->
<div class="header">
  <h1><span class="icon">&#9889;</span>ADO Pipeline Audit Report</h1>
  <div class="meta">
    <span>&#127970; <strong>$encOrg</strong></span>
    <span>&#128193; <strong>$encProj</strong></span>
    <span>&#128197; $scanDate</span>
  </div>
  <div class="badge">&#128640; Migration Readiness: ${pctReady}% Convertible</div>
</div>

<div class="container">

  <!-- ===== KPI CARDS ===== -->
  <div class="kpi-row">
    <div class="kpi total">
      <div class="kpi-icon">&#128202;</div>
      <div class="kpi-val">$($auditMetrics.Total)</div>
      <div class="kpi-label">Total Pipelines</div>
    </div>
    <div class="kpi success">
      <div class="kpi-icon">&#9989;</div>
      <div class="kpi-val">$($auditMetrics.Successful)</div>
      <div class="kpi-label">Fully Convertible</div>
    </div>
    <div class="kpi partial">
      <div class="kpi-icon">&#9888;&#65039;</div>
      <div class="kpi-val">$($auditMetrics.Partial)</div>
      <div class="kpi-label">Partially Convertible</div>
    </div>
    <div class="kpi unsupported">
      <div class="kpi-icon">&#10060;</div>
      <div class="kpi-val">$($auditMetrics.Unsupported)</div>
      <div class="kpi-label">Unsupported</div>
    </div>
    <div class="kpi failed">
      <div class="kpi-icon">&#128683;</div>
      <div class="kpi-val">$($auditMetrics.Failed)</div>
      <div class="kpi-label">Failed</div>
    </div>
  </div>

  <!-- ===== READINESS CHART ===== -->
  <div class="panel">
    <h2><span class="sec-icon">&#127760;</span>Readiness Breakdown</h2>
    <div class="chart-grid">
      <div class="donut-wrap">
        <div class="donut"></div>
        <div class="donut-center">
          <div class="big">${pctReady}%</div>
          <div class="sub">Ready</div>
        </div>
      </div>
      <div>
        <table class="breakdown">
$breakdownRows
        </table>
        <div class="stacked-bar">
          <div class="seg" style="width:${pctSuccess}%;background:var(--green)"></div>
          <div class="seg" style="width:${pctPartial}%;background:var(--yellow)"></div>
          <div class="seg" style="width:${pctUnsupported}%;background:var(--red)"></div>
          <div class="seg" style="width:${pctFailed}%;background:var(--gray)"></div>
        </div>
      </div>
    </div>
  </div>

  <!-- ===== CONVERTED PIPELINES ===== -->
  <div class="panel">
    <h2><span class="sec-icon">&#128196;</span>Converted Pipeline Files</h2>
$convertedSection
  </div>

  <!-- ===== MANUAL TASKS ===== -->
  <div class="panel">
    <h2><span class="sec-icon">&#9997;&#65039;</span>Manual Tasks Required Post-Migration</h2>
    $manualSection
  </div>

  <!-- ===== RAW AUDIT ===== -->
  <div class="panel">
    <h2><span class="sec-icon">&#128220;</span>Raw Audit Summary</h2>
    <details>
      <summary>View full audit_summary.md output</summary>
      <div>$rawSection</div>
    </details>
  </div>

  <div class="footer">
    Generated by <strong>ADO-to-GitHub Migration Accelerator</strong> &mdash; Pipeline Audit Module &bull; $scanDate
  </div>
</div>

</body>
</html>
"@

$htmlOut = Join-Path $dashboardDir "index.html"
$htmlContent | Out-File -FilePath $htmlOut -Encoding utf8

# --- Build Summary Markdown (shows on pipeline Extensions tab) ---
$summaryMd = @"
## Pipeline Audit Results

| Metric | Count | % |
|--------|------:|---:|
| **Total Pipelines** | **$($auditMetrics.Total)** | 100% |
| Fully Convertible | $($auditMetrics.Successful) | ${pctSuccess}% |
| Partially Convertible | $($auditMetrics.Partial) | ${pctPartial}% |
| Unsupported | $($auditMetrics.Unsupported) | ${pctUnsupported}% |
| Failed | $($auditMetrics.Failed) | ${pctFailed}% |

**Migration Readiness: ${pctReady}% convertible**

---
*Organization:* ``$AdoOrg`` | *Project:* ``$projLabel`` | *Scanned:* $scanDate
"@
$summaryMdPath = Join-Path $OutputDir "pipeline-audit-summary.md"
$summaryMd | Out-File -FilePath $summaryMdPath -Encoding utf8

# --- Upload Build Summary to ADO pipeline summary tab ---
if ($env:BUILD_SOURCESDIRECTORY) {
    # ##vso commands require absolute paths — resolve them
    $absOutputDir   = (Resolve-Path $OutputDir).Path
    $absSummaryPath = Join-Path $absOutputDir "pipeline-audit-summary.md"
    if (Test-Path $absSummaryPath) {
        Write-Host "##vso[task.uploadsummary]$absSummaryPath"
        Write-Host "##vso[task.addattachment type=Distributedtask.Core.Summary;name=Pipeline Audit Results;]$absSummaryPath"
    } else {
        Write-Host "WARNING: Summary file not found at $absSummaryPath" -ForegroundColor Yellow
    }
}

Write-Host "`nReports saved:" -ForegroundColor Cyan
$absOut = (Resolve-Path $OutputDir -ErrorAction SilentlyContinue).Path
if (-not $absOut) { $absOut = $OutputDir }
Write-Host "  Audit output : $absOut"
Write-Host "  Manual tasks : $(Join-Path $absOut 'manual-tasks-summary.md')"
Write-Host "  HTML report  : $(Join-Path $absOut 'dashboard/index.html')"
Write-Host "  Build summary: $(Join-Path $absOut 'pipeline-audit-summary.md')"
Write-Host "`nPipeline audit complete." -ForegroundColor Cyan
