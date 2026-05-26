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
nameToIdFile="$OutputDir/name_to_id.json"
echo "{}" > "$nameToIdFile"

if [ -n "$AdoProject" ]; then
    echo -e "${YELLOW}Fetching pipeline IDs from ADO API...${NC}"
    base64Auth=$(echo -n ":$AdoPat" | base64 | tr -d '\n')
    adoOrgUrl="https://dev.azure.com/$AdoOrg"

    # Python helper to call API and parse IDs
    python3 -c "
import urllib.request, json, base64
headers = { 'Authorization': 'Basic ' + '$base64Auth' }
name_to_id = {}
try:
    build_url = '$adoOrgUrl/$AdoProject/_apis/build/definitions?api-version=7.1'
    req = urllib.request.Request(build_url, headers=headers)
    with urllib.request.urlopen(req) as response:
        data = json.loads(response.read().decode())
        for d in data.get('value', []):
            name_to_id[d['name']] = d['id']
except Exception as e:
    print('Could not fetch build definitions:', e)

try:
    release_url = 'https://vsrm.dev.azure.com/$AdoOrg/$AdoProject/_apis/release/definitions?api-version=7.1'
    req = urllib.request.Request(release_url, headers=headers)
    with urllib.request.urlopen(req) as response:
        data = json.loads(response.read().decode())
        for d in data.get('value', []):
            name_to_id[d['name']] = d['id']
except Exception as e:
    print('Could not fetch release definitions:', e)

with open('$nameToIdFile', 'w', encoding='utf-8') as f:
    json.dump(name_to_id, f)
" || echo "Note: Could not fetch pipeline IDs from ADO API"
fi

# Print summary to console
auditSummaryFile="$OutputDir/audit_summary.md"
if [ -f "$auditSummaryFile" ]; then
    echo -e "\n${CYAN}=== Audit Summary ===${NC}"
    successCount=$(grep -i "Successful:" "$auditSummaryFile" | grep -oE '[0-9]+' | head -n 1 || echo "0")
    partialCount=$(grep -i "Partially successful:" "$auditSummaryFile" | grep -oE '[0-9]+' | head -n 1 || echo "0")
    unsupportedCount=$(grep -i "Unsupported:" "$auditSummaryFile" | grep -oE '[0-9]+' | head -n 1 || echo "0")
    failedCount=$(grep -i "Failed:" "$auditSummaryFile" | grep -oE '[0-9]+' | head -n 1 || echo "0")

    echo -e "  Fully Convertible:    ${GREEN}$successCount${NC}"
    echo -e "  Partially Convertible: ${YELLOW}$partialCount${NC}"
    echo -e "  Unsupported:          ${RED}$unsupportedCount${NC}"
    echo -e "  Failed:               ${RED}$failedCount${NC}"

    # Print pipelines list by status if python is available
    python3 -c "
import re, json
with open('$auditSummaryFile', 'r', encoding='utf-8') as f:
    content = f.read()

try:
    with open('$nameToIdFile', 'r', encoding='utf-8') as f:
        name_to_id = json.load(f)
except:
    name_to_id = {}

sections = [
    ('Successful', '\033[32m', r'(?ms)^### Successful\s*\n(.*?)(?=^### |\z)'),
    ('Partially Successful', '\033[33m', r'(?ms)^### Partially successful\s*\n(.*?)(?=^### |\z)'),
    ('Unsupported', '\033[31m', r'(?ms)^### Unsupported\s*\n(.*?)(?=^### |\z)'),
    ('Failed', '\033[31m', r'(?ms)^### Failed\s*\n(.*?)(?=^### |\z)')
]

for title, color, pattern in sections:
    match = re.search(pattern, content)
    if match:
        body = match.group(1)
        pipelines = re.findall(r'(?m)^####\s+(.+)$', body)
        if pipelines:
            print(f'\n=== {title} Pipelines ({len(pipelines)}) ===')
            for p in pipelines:
                p_clean = p.strip()
                name = p_clean.split('/')[-1]
                # Try suffix match too
                name_clean = re.sub(r'_\(\d+\)$', '', name)
                pid = name_to_id.get(name, name_to_id.get(name_clean, ''))
                if pid:
                    print(f'  {color}[{pid}] {name}\033[0m')
                else:
                    print(f'       {color}{name}\033[0m')
" || true
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

# Generate Dashboard and summaries via Python helper
python3 "$(dirname "$0")/generate_audit_dashboard.py" "$OutputDir" "$AdoOrg" "$AdoProject" "$nameToIdFile"

# Cleanup name-to-id mapping temp file
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
