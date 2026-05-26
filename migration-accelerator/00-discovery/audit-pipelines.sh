#!/usr/bin/env bash

# SYNOPSIS
#     Runs GitHub Actions Importer audit against Azure DevOps pipelines.
# DESCRIPTION
#     Wraps 'gh actions-importer audit azure-devops' to produce a conversion readiness report.

set -e

# ANSI escape codes for colors
CYAN='\e[36m'
GREEN='\e[32m'
YELLOW='\e[33m'
RED='\e[31m'
GRAY='\e[90m'
NC='\e[0m' # No Color

# Default values
AdoOrg=""
AdoProject=""
AdoPat=""
GitHubPat=""
OutputDir="./output/pipeline-audit"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --ado-org)
            AdoOrg="$2"
            shift 2
            ;;
        --ado-project)
            AdoProject="$2"
            shift 2
            ;;
        --ado-pat)
            AdoPat="$2"
            shift 2
            ;;
        --github-pat)
            GitHubPat="$2"
            shift 2
            ;;
        --output-dir)
            OutputDir="$2"
            shift 2
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

# Fallbacks to env vars
if [ -z "$AdoOrg" ]; then AdoOrg="${ADO_Org:-${ADO_ORG:-$ADOORG}}"; fi
if [ -z "$AdoPat" ]; then AdoPat="${ADO_PAT:-$AZDO_PAT}"; fi
if [ -z "$GitHubPat" ]; then GitHubPat="${GH_PAT:-$GITHUB_PAT}"; fi

# Normalize AdoOrg (if it is a URL, extract the org name)
if [[ "$AdoOrg" =~ ^https://dev\.azure\.com/([^/]+) ]]; then
    AdoOrg="${BASH_REMATCH[1]}"
fi

if [ -z "$AdoOrg" ]; then
    echo -e "${RED}ERROR: Azure DevOps organization is required. Provide --ado-org or set ADO_ORG env var.${NC}"
    exit 1
fi
if [ -z "$AdoPat" ]; then
    echo -e "${RED}ERROR: Azure DevOps PAT is required. Provide --ado-pat or set ADO_PAT env var.${NC}"
    exit 1
fi
if [ -z "$GitHubPat" ]; then
    echo -e "${RED}ERROR: GitHub PAT is required. Provide --github-pat or set GH_PAT env var.${NC}"
    exit 1
fi

# Verify prerequisites
if ! command -v gh >/dev/null 2>&1; then
    echo -e "${RED}GitHub CLI (gh) not found. Install from: https://cli.github.com${NC}"
    exit 1
fi

# Check actions-importer extension
extensions=$(gh extension list 2>&1 || echo "")
if [[ ! "$extensions" =~ "actions-importer" ]]; then
    echo -e "${YELLOW}Installing gh actions-importer extension...${NC}"
    gh extension install github/gh-actions-importer
fi

mkdir -p "$OutputDir"
dashboardDir="$OutputDir/dashboard"
mkdir -p "$dashboardDir"

echo -e "${CYAN}=== Pipeline Audit: $AdoOrg ===${NC}"

# Set environment variables for actions-importer
export GITHUB_ACCESS_TOKEN="$GitHubPat"
export GITHUB_TOKEN="$GitHubPat"
export GH_TOKEN="$GitHubPat"
export AZURE_DEVOPS_ACCESS_TOKEN="$AdoPat"
export ADO_PAT="$AdoPat"

# Update actions-importer
echo -e "${YELLOW}Updating actions-importer...${NC}"
gh actions-importer update 2>&1 || true

# Run Audit
auditArgs=("actions-importer" "audit" "azure-devops" "--output-dir" "$OutputDir" "--azure-devops-organization" "$AdoOrg")
if [ -n "$AdoProject" ]; then
    auditArgs+=("--azure-devops-project" "$AdoProject")
fi

echo -e "${YELLOW}Running audit (this may take several minutes)...${NC}"
gh "${auditArgs[@]}" 2>&1

# Build name-to-id lookup from ADO API
nameToIdFile="$OutputDir/name_to_id.txt"
echo -n "" > "$nameToIdFile"

if [ -n "$AdoProject" ] && command -v jq >/dev/null 2>&1; then
    echo -e "${YELLOW}Fetching pipeline IDs from ADO API...${NC}"
    base64Auth=$(echo -n ":$AdoPat" | base64 | tr -d '\n')
    adoOrgUrl="https://dev.azure.com/$AdoOrg"

    # Fetch build definitions
    buildUrl="$adoOrgUrl/$AdoProject/_apis/build/definitions?api-version=7.1"
    set +e
    buildDefs=$(curl -s -k -H "Authorization: Basic $base64Auth" "$buildUrl")
    if [ -n "$buildDefs" ]; then
        echo "$buildDefs" | jq -r '.value[] | "\(.name)\t\(.id)"' >> "$nameToIdFile" 2>/dev/null || true
    fi

    # Fetch release definitions
    releaseUrl="https://vsrm.dev.azure.com/$AdoOrg/$AdoProject/_apis/release/definitions?api-version=7.1"
    releaseDefs=$(curl -s -k -H "Authorization: Basic $base64Auth" "$releaseUrl")
    if [ -n "$releaseDefs" ]; then
        echo "$releaseDefs" | jq -r '.value[] | "\(.name)\t\(.id)"' >> "$nameToIdFile" 2>/dev/null || true
    fi
    set -e
fi

# Print summary to console
auditSummaryFile="$OutputDir/audit_summary.md"
successCount=0
partialCount=0
unsupportedCount=0
failedCount=0
totalCount=0

if [ -f "$auditSummaryFile" ]; then
    echo -e "\n${CYAN}=== Audit Summary ===${NC}"
    successCount=$(grep -i "Successful:" "$auditSummaryFile" | tr -d '*' | grep -oE '[0-9]+' | head -n 1 || echo "0")
    partialCount=$(grep -i "Partially successful:" "$auditSummaryFile" | tr -d '*' | grep -oE '[0-9]+' | head -n 1 || echo "0")
    unsupportedCount=$(grep -i "Unsupported:" "$auditSummaryFile" | tr -d '*' | grep -oE '[0-9]+' | head -n 1 || echo "0")
    failedCount=$(grep -i "Failed:" "$auditSummaryFile" | tr -d '*' | grep -oE '[0-9]+' | head -n 1 || echo "0")

    echo -e "  Fully Convertible:    ${GREEN}$successCount${NC}"
    echo -e "  Partially Convertible: ${YELLOW}$partialCount${NC}"
    echo -e "  Unsupported:          ${RED}$unsupportedCount${NC}"
    echo -e "  Failed:               ${RED}$failedCount${NC}"

    # Print pipelines list by status using pure Bash
    echo -e "\n=== Audit Status Breakdown ==="
    current_section=""
    while IFS= read -line || [ -n "$line" ]; do
        if [[ "$line" =~ ^###\ (.*) ]]; then
            current_section="${BASH_REMATCH[1]}"
            echo -e "\n--- $current_section Pipelines ---"
        elif [[ "$line" =~ ^####\ (.*) ]]; then
            full_path="${BASH_REMATCH[1]}"
            # Strip trailing spaces
            full_path=$(echo "$full_path" | xargs)
            pipe_name=$(basename "$full_path")
            pipe_name_clean=${pipe_name%_\([0-9]*\)}
            
            # Lookup ID
            pid=""
            if [ -f "$nameToIdFile" ]; then
                pid=$(grep "^$pipe_name	" "$nameToIdFile" | cut -f2 | head -n 1 || grep "^$pipe_name_clean	" "$nameToIdFile" | cut -f2 | head -n 1 || echo "")
            fi
            
            color="${RED}"
            if [ "$current_section" = "Successful" ]; then color="${GREEN}"; fi
            if [ "$current_section" = "Partially successful" ]; then color="${YELLOW}"; fi
            
            if [ -n "$pid" ]; then
                echo -e "  ${color}[$pid] $pipe_name${NC}"
            else
                echo -e "       ${color}$pipe_name${NC}"
            fi
        fi
    done < "$auditSummaryFile"
fi

# Generate manual tasks guide
cat << 'EOF' > "$OutputDir/manual-tasks-summary.md"
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
EOF

echo -e "Manual tasks guide saved to: ${GREEN}$OutputDir/manual-tasks-summary.md${NC}"

# Dashboard Calculations
totalCount=$((successCount + partialCount + unsupportedCount + failedCount))
totalDivisor=$((totalCount > 0 ? totalCount : 1))
pctSuccess=$((successCount * 100 / totalDivisor))
pctPartial=$((partialCount * 100 / totalDivisor))
pctUnsupported=$((unsupportedCount * 100 / totalDivisor))
pctFailed=$((failedCount * 100 / totalDivisor))
pctReady=$((pctSuccess + pctPartial))

scanDate=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
projLabel="${AdoProject:-All Projects}"

# Conic segments
donutSeg1=$pctSuccess
donutSeg2=$((pctSuccess + pctPartial))
donutSeg3=$((pctSuccess + pctPartial + pctUnsupported))

# Build converted files table rows
pipelineRows=""
while read -r yf; do
    if [ -n "$yf" ]; then
        relPath=${yf#"$OutputDir/"}
        name=$(basename "$yf" | cut -f1 -d'.')
        dir=$(dirname "$relPath")
        sizeBytes=$(stat -c%s "$yf" 2>/dev/null || stat -f%z "$yf" 2>/dev/null || echo "0")
        sizeKb=$((sizeBytes / 1024))
        pipelineRows+="    <tr><td>$dir</td><td>$name</td><td class='num'>${sizeKb} KB</td><td class='center'>&#9989; Converted</td></tr>\n"
    fi
done < <(find "$OutputDir" -name "*.yml" -o -name "*.yaml" | grep -v "dashboard" || echo "")

convertedSection=""
if [ -n "$pipelineRows" ]; then
    convertedSection="<table>
        <thead><tr><th>Directory</th><th>Pipeline</th><th>Size</th><th>Status</th></tr></thead>
        <tbody>
$pipelineRows
        </tbody>
      </table>"
else
    convertedSection="<p class='empty-state'><span class='empty-icon'>&#128194;</span>No converted YAML files found in audit output.</p>"
fi

# Build manual tasks list
manualSection=""
if [ -f "$OutputDir/manual-tasks-summary.md" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^#+\ (.*) ]]; then
            manualSection+="<h4>${BASH_REMATCH[1]}</h4>\n"
        elif [[ "$line" =~ ^-\ \[\ \]\ (.*) ]]; then
            manualSection+="<label class='checklist-item'><input type='checkbox'/><span>${BASH_REMATCH[1]}</span></label>\n"
        elif [[ "$line" =~ ^-\ (.*) ]]; then
            manualSection+="<div class='task-note'>&#8226; ${BASH_REMATCH[1]}</div>\n"
        fi
    done < "$OutputDir/manual-tasks-summary.md"
else
    manualSection="<p class='empty-state'><span class='empty-icon'>&#9989;</span>No manual tasks file found.</p>"
fi

rawSummaryText="audit_summary.md not available."
if [ -f "$auditSummaryFile" ]; then
    rawSummaryText=$(cat "$auditSummaryFile")
fi

# Build HTML report
cat << EOF > "$dashboardDir/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Pipeline Audit Report &mdash; $AdoOrg</title>
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
      var(--green) 0% $donutSeg1%,
      var(--yellow) $donutSeg1% $donutSeg2%,
      var(--red) $donutSeg2% $donutSeg3%,
      var(--gray) $donutSeg3% 100%
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
  details summary::before { content:'▶'; font-size:.7rem; transition:transform .2s; display:inline-block; }
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
  <h1><span class="icon">⚡</span>ADO Pipeline Audit Report</h1>
  <div class="meta">
    <span>🏢 <strong>$AdoOrg</strong></span>
    <span>📁 <strong>$projLabel</strong></span>
    <span>📅 $scanDate</span>
  </div>
  <div class="badge">🚀 Migration Readiness: $pctReady% Convertible</div>
</div>

<div class="container">

  <!-- ===== KPI CARDS ===== -->
  <div class="kpi-row">
    <div class="kpi total">
      <div class="kpi-icon">📊</div>
      <div class="kpi-val">$totalCount</div>
      <div class="kpi-label">Total Pipelines</div>
    </div>
    <div class="kpi success">
      <div class="kpi-icon">✅</div>
      <div class="kpi-val">$successCount</div>
      <div class="kpi-label">Fully Convertible</div>
    </div>
    <div class="kpi partial">
      <div class="kpi-icon">⚠️</div>
      <div class="kpi-val">$partialCount</div>
      <div class="kpi-label">Partially Convertible</div>
    </div>
    <div class="kpi unsupported">
      <div class="kpi-icon">❌</div>
      <div class="kpi-val">$unsupportedCount</div>
      <div class="kpi-label">Unsupported</div>
    </div>
    <div class="kpi failed">
      <div class="kpi-icon">🚫</div>
      <div class="kpi-val">$failedCount</div>
      <div class="kpi-label">Failed</div>
    </div>
  </div>

  <!-- ===== READINESS CHART ===== -->
  <div class="panel">
    <h2><span class="sec-icon">🌐</span>Readiness Breakdown</h2>
    <div class="chart-grid">
      <div class="donut-wrap">
        <div class="donut"></div>
        <div class="donut-center">
          <div class="big">$pctReady%</div>
          <div class="sub">Ready</div>
        </div>
      </div>
      <div>
        <table class="breakdown">
          $breakdownRows
        </table>
        <div class="stacked-bar">
          <div class="seg" style="width:$pctSuccess%;background:var(--green)"></div>
          <div class="seg" style="width:$pctPartial%;background:var(--yellow)"></div>
          <div class="seg" style="width:$pctUnsupported%;background:var(--red)"></div>
          <div class="seg" style="width:$pctFailed%;background:var(--gray)"></div>
        </div>
      </div>
    </div>
  </div>

  <!-- ===== CONVERTED PIPELINES ===== -->
  <div class="panel">
    <h2><span class="sec-icon">📄</span>Converted Pipeline Files</h2>
    $convertedSection
  </div>

  <!-- ===== MANUAL TASKS ===== -->
  <div class="panel">
    <h2><span class="sec-icon">✍️</span>Manual Tasks Required Post-Migration</h2>
    $manualSection
  </div>

  <!-- ===== RAW AUDIT ===== -->
  <div class="panel">
    <h2><span class="sec-icon">📜</span>Raw Audit Summary</h2>
    <details>
      <summary>View full audit_summary.md output</summary>
      <div><pre class="raw-block">$rawSummaryText</pre></div>
    </details>
  </div>

  <div class="footer">
    Generated by <strong>ADO-to-GitHub Migration Accelerator</strong> &mdash; Pipeline Audit Module &bull; $scanDate
  </div>
</div>

</body>
</html>
EOF

echo -e "HTML report saved to: ${GREEN}$dashboardDir/index.html${NC}"

# Generate pipeline-audit-summary.md
cat << EOF > "$OutputDir/pipeline-audit-summary.md"
## Pipeline Audit Results

| Metric | Count | % |
|---|---:|---:|
| **Total Pipelines** | **$totalCount** | 100% |
| Fully Convertible | $successCount | $pctSuccess% |
| Partially Convertible | $partialCount | $pctPartial% |
| Unsupported | $unsupportedCount | $pctUnsupported% |
| Failed | $failedCount | $pctFailed% |

**Migration Readiness: $pctReady% convertible**

---
*Organization:* \`$AdoOrg\` | *Project:* \`$projLabel\` | *Scanned:* $scanDate
EOF

echo -e "Summary MD saved to: ${GREEN}$OutputDir/pipeline-audit-summary.md${NC}"

# Cleanup temp name-to-id mapping file
rm -f "$nameToIdFile"

# Clean env vars
unset GITHUB_ACCESS_TOKEN
unset GITHUB_TOKEN
unset GH_TOKEN
unset AZURE_DEVOPS_ACCESS_TOKEN

# Upload Build Summary to ADO pipeline summary tab if running in ADO agent
if [ -n "$BUILD_SOURCESDIRECTORY" ]; then
    absSummaryPath=$(realpath "$OutputDir/pipeline-audit-summary.md")
    if [ -f "$absSummaryPath" ]; then
        echo "##vso[task.uploadsummary]$absSummaryPath"
        echo "##vso[task.addattachment type=Distributedtask.Core.Summary;name=Pipeline Audit Results;]$absSummaryPath"
    else
        echo -e "${YELLOW}WARNING: Summary file not found at $absSummaryPath${NC}"
    fi
fi

echo -e "\n${GREEN}Reports saved:${NC}"
echo "  Audit output : $(realpath "$OutputDir")"
echo "  Manual tasks : $(realpath "$OutputDir/manual-tasks-summary.md")"
echo "  HTML report  : $(realpath "$OutputDir/dashboard/index.html")"
echo "  Build summary: $(realpath "$OutputDir/pipeline-audit-summary.md")"
echo -e "\n${CYAN}Pipeline audit complete.${NC}"
