#!/usr/bin/env bash
###############################################################################
# inventory-assets.sh
#
# Inventories Azure DevOps assets for a specific project:
#   repos, build pipelines, release definitions, teams, work items,
#   service connections, variable groups, environments.
#
# Produces: JSON inventory, CSV summaries, HTML dashboard.
#
# Prerequisites: curl, jq, base64
#
# Usage:
#   ./inventory-assets.sh \
#       -o "https://dev.azure.com/myorg" \
#       -t "MY_PAT" \
#       -p "MyProject" \
#       [-d "./output/inventory"]
###############################################################################
set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
ORG_URL=""
PAT=""
PROJECT_NAME=""
OUTPUT_DIR="./output/inventory"

# ── Parse arguments ──────────────────────────────────────────────────────────
usage() {
  echo "Usage: $0 -o <OrgUrl> -t <PAT> -p <ProjectName> [-d <OutputDir>]"
  echo ""
  echo "  -o  Azure DevOps organization URL (e.g., https://dev.azure.com/myorg)"
  echo "  -t  Personal Access Token"
  echo "  -p  Project name to inventory"
  echo "  -d  Output directory (default: ./output/inventory)"
  exit 1
}

while getopts "o:t:p:d:h" opt; do
  case $opt in
    o) ORG_URL="${OPTARG}" ;;
    t) PAT="${OPTARG}" ;;
    p) PROJECT_NAME="${OPTARG}" ;;
    d) OUTPUT_DIR="${OPTARG}" ;;
    h) usage ;;
    *) usage ;;
  esac
done

[[ -z "$ORG_URL" ]]      && { echo "ERROR: -o OrgUrl is required"; usage; }
[[ -z "$PAT" ]]           && { echo "ERROR: -t PAT is required"; usage; }
[[ -z "$PROJECT_NAME" ]]  && { echo "ERROR: -p ProjectName is required"; usage; }

# ── Auth ─────────────────────────────────────────────────────────────────────
AUTH_HEADER="Authorization: Basic $(printf ":%s" "$PAT" | base64 -w0 2>/dev/null || printf ":%s" "$PAT" | base64)"

# ── Helper: call ADO REST API ────────────────────────────────────────────────
ado_api() {
  local uri="$1"
  local api_version="${2:-7.1}"
  if [[ "$uri" == *"?"* ]]; then
    uri="${uri}&api-version=${api_version}"
  else
    uri="${uri}?api-version=${api_version}"
  fi
  curl -sS --fail-with-body \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json" \
    "$uri" 2>/dev/null || echo ""
}

# POST helper (for WIQL)
ado_post() {
  local uri="$1"
  local body="$2"
  local api_version="${3:-7.1}"
  if [[ "$uri" == *"?"* ]]; then
    uri="${uri}&api-version=${api_version}"
  else
    uri="${uri}?api-version=${api_version}"
  fi
  curl -sS --fail-with-body \
    -X POST \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "$uri" 2>/dev/null || echo ""
}

# HTML-encode helper
html_enc() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  printf '%s' "$s"
}

# Safe jq read — returns fallback if jq fails or input is empty
jq_val() {
  local json="$1" path="$2" fallback="${3:-}"
  local val
  val=$(echo "$json" | jq -r "$path" 2>/dev/null) || val=""
  [[ -z "$val" || "$val" == "null" ]] && val="$fallback"
  printf '%s' "$val"
}

# ── Setup ────────────────────────────────────────────────────────────────────
mkdir -p "$OUTPUT_DIR"

ORG_NAME="${ORG_URL#https://dev.azure.com/}"
ORG_NAME="${ORG_NAME%/}"

echo -e "\e[36m=== ADO Inventory: $ORG_NAME / $PROJECT_NAME ===\e[0m"

SCAN_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ── Fetch project ───────────────────────────────────────────────────────────
PROJECT_JSON=$(ado_api "${ORG_URL}/_apis/projects/${PROJECT_NAME}")
if [[ -z "$PROJECT_JSON" ]]; then
  echo "ERROR: Failed to find project '$PROJECT_NAME'. Check PAT, org URL, and project name." >&2
  exit 1
fi

PROJ_ID=$(jq_val "$PROJECT_JSON" '.id')
PROJ_STATE=$(jq_val "$PROJECT_JSON" '.state')
PROJ_VIS=$(jq_val "$PROJECT_JSON" '.visibility')

echo -e "\e[32mFound project: $PROJECT_NAME (id: $PROJ_ID)\e[0m"
echo -e "\e[33m  Scanning project: $PROJECT_NAME\e[0m"

# ── Repos ────────────────────────────────────────────────────────────────────
REPOS_JSON=$(ado_api "${ORG_URL}/${PROJECT_NAME}/_apis/git/repositories")
REPO_COUNT=$(echo "$REPOS_JSON" | jq '.count // 0' 2>/dev/null || echo 0)
echo -e "\e[90m    Repos: $REPO_COUNT\e[0m"

# Build repos array as JSON
REPOS_ARRAY=$(echo "$REPOS_JSON" | jq '[
  .value[]? | {
    name: .name,
    id: .id,
    sizeBytes: (.size // 0),
    sizeMB: (((.size // 0) / 1048576) * 100 | round / 100),
    sizeGB: (((.size // 0) / 1073741824) * 10000 | round / 10000),
    defaultBranch: (.defaultBranch // ""),
    isDisabled: (.isDisabled // false),
    url: (.webUrl // "")
  }
]' 2>/dev/null || echo '[]')

# ── Build Pipelines ─────────────────────────────────────────────────────────
PIPELINES_JSON=$(ado_api "${ORG_URL}/${PROJECT_NAME}/_apis/build/definitions")
PIPE_COUNT=$(echo "$PIPELINES_JSON" | jq '.count // 0' 2>/dev/null || echo 0)
echo -e "\e[90m    Build Pipelines: $PIPE_COUNT\e[0m"

PIPELINES_ARRAY=$(echo "$PIPELINES_JSON" | jq '[
  .value[]? | {
    name: .name,
    id: .id,
    type: .type,
    queueStatus: .queueStatus,
    path: .path,
    createdDate: .createdDate,
    url: .url,
    processType: (if .process then .process.type else "unknown" end)
  }
]' 2>/dev/null || echo '[]')

# ── Release Definitions (Classic) ───────────────────────────────────────────
VSRM_URL="${ORG_URL//dev.azure.com/vsrm.dev.azure.com}"
RELEASES_JSON=$(ado_api "${VSRM_URL}/${PROJECT_NAME}/_apis/release/definitions?\$expand=environments")
REL_COUNT=$(echo "$RELEASES_JSON" | jq '.count // 0' 2>/dev/null || echo 0)
echo -e "\e[90m    Release Definitions: $REL_COUNT\e[0m"

RELEASES_ARRAY=$(echo "$RELEASES_JSON" | jq '[
  .value[]? | {
    name: .name,
    id: .id,
    path: .path,
    environmentCount: (if .environments then (.environments | length) else 0 end),
    environmentNames: (if .environments then ([.environments[].name] | join(", ")) else "" end),
    createdBy: (if .createdBy then .createdBy.displayName else "N/A" end),
    modifiedBy: (if .modifiedBy then .modifiedBy.displayName else "N/A" end),
    modifiedOn: .modifiedOn
  }
]' 2>/dev/null || echo '[]')

# ── Teams ────────────────────────────────────────────────────────────────────
TEAMS_JSON=$(ado_api "${ORG_URL}/_apis/projects/${PROJ_ID}/teams")
TEAM_COUNT=$(echo "$TEAMS_JSON" | jq '.count // 0' 2>/dev/null || echo 0)
echo -e "\e[90m    Teams: $TEAM_COUNT\e[0m"

TEAMS_ARRAY="["
FIRST_TEAM=true
for TEAM_ID in $(echo "$TEAMS_JSON" | jq -r '.value[]?.id' 2>/dev/null); do
  TEAM_NAME=$(echo "$TEAMS_JSON" | jq -r ".value[] | select(.id==\"$TEAM_ID\") | .name" 2>/dev/null)
  TEAM_DESC=$(echo "$TEAMS_JSON" | jq -r ".value[] | select(.id==\"$TEAM_ID\") | (.description // \"\")" 2>/dev/null)
  MEMBERS_JSON=$(ado_api "${ORG_URL}/_apis/projects/${PROJ_ID}/teams/${TEAM_ID}/members")
  MEMBER_COUNT=$(echo "$MEMBERS_JSON" | jq '.count // 0' 2>/dev/null || echo 0)
  $FIRST_TEAM || TEAMS_ARRAY+=","
  FIRST_TEAM=false
  TEAMS_ARRAY+=$(jq -n \
    --arg name "$TEAM_NAME" \
    --arg id "$TEAM_ID" \
    --arg desc "$TEAM_DESC" \
    --argjson mc "$MEMBER_COUNT" \
    '{name:$name, id:$id, description:$desc, memberCount:$mc}')
done
TEAMS_ARRAY+="]"

# ── Work Item Count (WIQL) ──────────────────────────────────────────────────
WIQL_BODY=$(jq -n --arg proj "$PROJECT_NAME" '{query: ("SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = \u0027" + $proj + "\u0027")}')
WIQL_RESP=$(ado_post "${ORG_URL}/${PROJECT_NAME}/_apis/wit/wiql" "$WIQL_BODY")
WI_COUNT=$(echo "$WIQL_RESP" | jq '[.workItems[]?] | length' 2>/dev/null || echo 0)
echo -e "\e[90m    Work Items: $WI_COUNT\e[0m"

# ── Service Connections ──────────────────────────────────────────────────────
SC_JSON=$(ado_api "${ORG_URL}/${PROJECT_NAME}/_apis/serviceendpoint/endpoints")
SC_COUNT=$(echo "$SC_JSON" | jq '.count // 0' 2>/dev/null || echo 0)
echo -e "\e[90m    Service Connections: $SC_COUNT\e[0m"

SC_ARRAY=$(echo "$SC_JSON" | jq '[
  .value[]? | {
    name: .name,
    type: .type,
    id: .id,
    url: (.url // ""),
    description: (.description // ""),
    authScheme: (if .authorization then .authorization.scheme else "N/A" end),
    isReady: (.isReady // false),
    createdBy: (if .createdBy then .createdBy.displayName else "N/A" end)
  }
]' 2>/dev/null || echo '[]')

# ── Variable Groups ──────────────────────────────────────────────────────────
VG_JSON=$(ado_api "${ORG_URL}/${PROJECT_NAME}/_apis/distributedtask/variablegroups")
VG_COUNT=$(echo "$VG_JSON" | jq '.count // 0' 2>/dev/null || echo 0)
echo -e "\e[90m    Variable Groups: $VG_COUNT\e[0m"

VG_ARRAY=$(echo "$VG_JSON" | jq '[
  .value[]? | {
    name: .name,
    id: .id,
    type: (.type // ""),
    description: (.description // ""),
    variableCount: (if .variables then (.variables | keys | length) else 0 end),
    secretCount: (if .variables then ([.variables | to_entries[] | select(.value.isSecret == true)] | length) else 0 end),
    variableNames: (if .variables then (.variables | keys | join(", ")) else "" end),
    providerData: (if .providerData then .providerData.vault else null end),
    createdBy: (if .createdBy then .createdBy.displayName else "N/A" end),
    modifiedBy: (if .modifiedBy then .modifiedBy.displayName else "N/A" end),
    modifiedOn: .modifiedOn
  }
]' 2>/dev/null || echo '[]')

# ── Environments ─────────────────────────────────────────────────────────────
ENV_JSON=$(ado_api "${ORG_URL}/${PROJECT_NAME}/_apis/distributedtask/environments")
ENV_COUNT=$(echo "$ENV_JSON" | jq '.count // 0' 2>/dev/null || echo 0)
echo -e "\e[90m    Environments: $ENV_COUNT\e[0m"

ENV_ARRAY=$(echo "$ENV_JSON" | jq '[.value[]? | {name: .name, id: .id}]' 2>/dev/null || echo '[]')

# ── Assemble inventory JSON ─────────────────────────────────────────────────
INVENTORY=$(jq -n \
  --arg org "$ORG_NAME" \
  --arg proj "$PROJECT_NAME" \
  --arg date "$SCAN_DATE" \
  --arg projId "$PROJ_ID" \
  --arg state "$PROJ_STATE" \
  --arg vis "$PROJ_VIS" \
  --argjson repos "$REPOS_ARRAY" \
  --argjson pipes "$PIPELINES_ARRAY" \
  --argjson rels "$RELEASES_ARRAY" \
  --argjson teams "$TEAMS_ARRAY" \
  --argjson wi "$WI_COUNT" \
  --argjson scs "$SC_ARRAY" \
  --argjson vgs "$VG_ARRAY" \
  --argjson envs "$ENV_ARRAY" \
  --argjson repoCount "$REPO_COUNT" \
  --argjson pipeCount "$PIPE_COUNT" \
  --argjson teamCount "$TEAM_COUNT" \
  --argjson wiCount "$WI_COUNT" \
  '{
    organization: $org,
    projectName: $proj,
    scanDate: $date,
    totalRepos: $repoCount,
    totalPipelines: $pipeCount,
    totalWorkItems: $wiCount,
    totalTeams: $teamCount,
    projects: [{
      name: $proj,
      id: $projId,
      state: $state,
      visibility: $vis,
      repos: $repos,
      pipelines: $pipes,
      releaseDefinitions: $rels,
      teams: $teams,
      workItemCount: $wi,
      serviceConnections: $scs,
      variableGroups: $vgs,
      environments: $envs
    }]
  }')

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo -e "\e[36m=== Inventory Summary for $PROJECT_NAME ===\e[0m"
echo "Project:     $PROJECT_NAME"
echo "Repos:       $REPO_COUNT"
echo "Pipelines:   $PIPE_COUNT"
echo "Work Items:  $WI_COUNT"
echo "Teams:       $TEAM_COUNT"

# ── Large repo warnings ─────────────────────────────────────────────────────
LARGE_REPOS=$(echo "$REPOS_ARRAY" | jq -r '.[] | select(.sizeGB > 1) | "\(.name): \(.sizeGB) GB"' 2>/dev/null)
if [[ -n "$LARGE_REPOS" ]]; then
  echo ""
  echo -e "\e[31m=== WARNING: Large Repos (>1 GB) ===\e[0m"
  echo "$LARGE_REPOS" | while read -r line; do echo -e "\e[31m  $line\e[0m"; done
fi

OVERSIZED_REPOS=$(echo "$REPOS_ARRAY" | jq -r '.[] | select(.sizeGB > 40) | "\(.name): \(.sizeGB) GB — CANNOT migrate with GEI"' 2>/dev/null)
if [[ -n "$OVERSIZED_REPOS" ]]; then
  echo ""
  echo -e "\e[31m=== BLOCKER: Repos > 40 GB (GEI limit) ===\e[0m"
  echo "$OVERSIZED_REPOS" | while read -r line; do echo -e "\e[31m  $line\e[0m"; done
fi

# ── Export JSON ──────────────────────────────────────────────────────────────
JSON_FILE="${OUTPUT_DIR}/inventory-$(date +%Y%m%d-%H%M%S).json"
echo "$INVENTORY" > "$JSON_FILE"
echo -e "\e[32mInventory saved to: $JSON_FILE\e[0m"

# ── Repo Summary CSV ─────────────────────────────────────────────────────────
CSV_FILE="${OUTPUT_DIR}/repo-summary.csv"
echo '"Project","Repo","SizeMB","SizeGB","DefaultBranch","Disabled","OverGEILimit"' > "$CSV_FILE"
echo "$REPOS_ARRAY" | jq -r --arg proj "$PROJECT_NAME" '.[] |
  [$proj, .name, (.sizeMB|tostring), (.sizeGB|tostring),
   (.defaultBranch // "" | sub("^refs/heads/";"")) ,
   (if .isDisabled then "True" else "False" end),
   (if .sizeGB > 40 then "True" else "False" end)] | @csv' >> "$CSV_FILE"
echo -e "\e[32mRepo summary CSV saved to: $CSV_FILE\e[0m"

# ── Service Connections CSV ──────────────────────────────────────────────────
SC_CSV_FILE="${OUTPUT_DIR}/service-connections.csv"
SC_CSV_COUNT=$(echo "$SC_ARRAY" | jq 'length' 2>/dev/null || echo 0)
if [[ "$SC_CSV_COUNT" -gt 0 ]]; then
  echo '"Project","Name","Type","AuthScheme","URL","IsReady","CreatedBy"' > "$SC_CSV_FILE"
  echo "$SC_ARRAY" | jq -r --arg proj "$PROJECT_NAME" '.[] |
    [$proj, .name, .type, .authScheme, .url,
     (if .isReady then "True" else "False" end), .createdBy] | @csv' >> "$SC_CSV_FILE"
  echo -e "\e[32mService connections CSV saved to: $SC_CSV_FILE\e[0m"
fi

# ── Variable Groups CSV ─────────────────────────────────────────────────────
VG_CSV_FILE="${OUTPUT_DIR}/variable-groups.csv"
VG_CSV_COUNT=$(echo "$VG_ARRAY" | jq 'length' 2>/dev/null || echo 0)
if [[ "$VG_CSV_COUNT" -gt 0 ]]; then
  echo '"Project","Name","Type","VariableCount","SecretCount","VariableNames","KeyVault","ModifiedBy","ModifiedOn"' > "$VG_CSV_FILE"
  echo "$VG_ARRAY" | jq -r --arg proj "$PROJECT_NAME" '.[] |
    [$proj, .name, .type, (.variableCount|tostring), (.secretCount|tostring),
     .variableNames, (.providerData // ""), .modifiedBy, (.modifiedOn // "")] | @csv' >> "$VG_CSV_FILE"
  echo -e "\e[32mVariable groups CSV saved to: $VG_CSV_FILE\e[0m"
fi

# ── Release Definitions CSV ─────────────────────────────────────────────────
REL_CSV_FILE="${OUTPUT_DIR}/release-definitions.csv"
REL_CSV_COUNT=$(echo "$RELEASES_ARRAY" | jq 'length' 2>/dev/null || echo 0)
if [[ "$REL_CSV_COUNT" -gt 0 ]]; then
  echo '"Project","Name","Path","EnvironmentCount","EnvironmentNames","ModifiedBy","ModifiedOn"' > "$REL_CSV_FILE"
  echo "$RELEASES_ARRAY" | jq -r --arg proj "$PROJECT_NAME" '.[] |
    [$proj, .name, .path, (.environmentCount|tostring), .environmentNames,
     .modifiedBy, (.modifiedOn // "")] | @csv' >> "$REL_CSV_FILE"
  echo -e "\e[32mRelease definitions CSV saved to: $REL_CSV_FILE\e[0m"
fi

# ── HTML Dashboard ───────────────────────────────────────────────────────────
HTML_FILE="${OUTPUT_DIR}/inventory-dashboard.html"
TIMESTAMP=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
TOTAL_SIZE_GB=$(echo "$REPOS_ARRAY" | jq '[.[].sizeGB] | add // 0 | . * 100 | round / 100' 2>/dev/null || echo 0)
TOTAL_REL_DEFS=$REL_COUNT
TOTAL_SVC_CONNS=$SC_COUNT
TOTAL_VAR_GROUPS=$VG_COUNT
TOTAL_ENVS=$ENV_COUNT
LARGE_COUNT=$(echo "$REPOS_ARRAY" | jq '[.[] | select(.sizeGB > 1)] | length' 2>/dev/null || echo 0)
GEI_BLOCKED_COUNT=$(echo "$REPOS_ARRAY" | jq '[.[] | select(.sizeGB > 40)] | length' 2>/dev/null || echo 0)

PROJ_SIZE_GB=$(echo "$REPOS_ARRAY" | jq '[.[].sizeGB] | add // 0 | . * 100 | round / 100' 2>/dev/null || echo 0)

# Build summary report row
REPORT_ROWS="<tr><td>$(html_enc "$PROJECT_NAME")</td><td>${PROJ_VIS}</td><td class='num'>${REPO_COUNT}</td><td class='num'>${PROJ_SIZE_GB}</td><td class='num'>${PIPE_COUNT}</td><td class='num'>${REL_COUNT}</td><td class='num'>${TEAM_COUNT}</td><td class='num'>${WI_COUNT}</td><td class='num'>${SC_COUNT}</td><td class='num'>${VG_COUNT}</td><td class='num'>${ENV_COUNT}</td></tr>"

# Build repo table rows
REPO_ROWS=""
while IFS=$'\t' read -r rName rSizeMB rSizeGB rBranch rDisabled rUrl; do
  [[ -z "$rName" ]] && continue
  rBranch="${rBranch#refs/heads/}"
  sizeClass=""
  sizeGBNum=$(echo "$rSizeGB" | awk '{printf "%f", $1}')
  if awk "BEGIN{exit !($sizeGBNum > 40)}"; then sizeClass="blocked"
  elif awk "BEGIN{exit !($sizeGBNum > 1)}"; then sizeClass="warning"
  fi
  rLink="$rName"
  [[ -n "$rUrl" && "$rUrl" != "null" ]] && rLink="<a href='$(html_enc "$rUrl")' target='_blank'>$(html_enc "$rName")</a>"
  disabledStr="No"; [[ "$rDisabled" == "true" ]] && disabledStr="Yes"
  REPO_ROWS+="<tr class='${sizeClass}'><td>${rLink}</td><td class='num'>${rSizeMB}</td><td class='num'>${rSizeGB}</td><td>$(html_enc "$rBranch")</td><td>${disabledStr}</td></tr>"
done < <(echo "$REPOS_ARRAY" | jq -r 'sort_by(-.sizeMB)[] | [.name, (.sizeMB|tostring), (.sizeGB|tostring), (.defaultBranch // ""), (.isDisabled|tostring), (.url // "")] | @tsv' 2>/dev/null)

# Build pipeline table rows
PIPE_ROWS=""
while IFS=$'\t' read -r pName pType pQueue pPath; do
  [[ -z "$pName" ]] && continue
  PIPE_ROWS+="<tr><td>$(html_enc "$pName")</td><td>${pType}</td><td>${pQueue}</td><td>$(html_enc "$pPath")</td></tr>"
done < <(echo "$PIPELINES_ARRAY" | jq -r '.[] | [.name, (.type // ""), (.queueStatus // ""), (.path // "")] | @tsv' 2>/dev/null)

# Build release table rows
RELEASE_ROWS=""
while IFS=$'\t' read -r rdName rdPath rdEnvCount rdEnvNames rdModBy rdModOn; do
  [[ -z "$rdName" ]] && continue
  [[ -z "$rdModOn" || "$rdModOn" == "null" ]] && rdModOn="-"
  [[ "$rdModOn" != "-" ]] && rdModOn="${rdModOn:0:10}"
  RELEASE_ROWS+="<tr><td>$(html_enc "$rdName")</td><td>$(html_enc "$rdPath")</td><td class='num'>${rdEnvCount}</td><td>$(html_enc "$rdEnvNames")</td><td>$(html_enc "$rdModBy")</td><td>${rdModOn}</td></tr>"
done < <(echo "$RELEASES_ARRAY" | jq -r '.[] | [.name, (.path // ""), (.environmentCount|tostring), (.environmentNames // ""), (.modifiedBy // ""), (.modifiedOn // "")] | @tsv' 2>/dev/null)

# Build team table rows
TEAM_ROWS=""
while IFS=$'\t' read -r tName tMembers tDesc; do
  [[ -z "$tName" ]] && continue
  TEAM_ROWS+="<tr><td>$(html_enc "$tName")</td><td class='num'>${tMembers}</td><td>$(html_enc "$tDesc")</td></tr>"
done < <(echo "$TEAMS_ARRAY" | jq -r '.[] | [.name, (.memberCount|tostring), (.description // "")] | @tsv' 2>/dev/null)

# Build service connection table rows
SC_ROWS=""
while IFS=$'\t' read -r scName scType scAuth scUrl scDesc scCreated scReady; do
  [[ -z "$scName" ]] && continue
  readyClass=""; [[ "$scReady" == "false" ]] && readyClass="warning"
  readyStr="Yes"; [[ "$scReady" == "false" ]] && readyStr="No"
  SC_ROWS+="<tr class='${readyClass}'><td>$(html_enc "$scName")</td><td>$(html_enc "$scType")</td><td>$(html_enc "$scAuth")</td><td>$(html_enc "$scUrl")</td><td>$(html_enc "$scDesc")</td><td>$(html_enc "$scCreated")</td><td>${readyStr}</td></tr>"
done < <(echo "$SC_ARRAY" | jq -r '.[] | [.name, .type, .authScheme, (.url // "-"), (.description // "-"), .createdBy, (.isReady|tostring)] | @tsv' 2>/dev/null)

# Build variable groups table rows
VG_ROWS=""
while IFS=$'\t' read -r vgName vgType vgVarCnt vgSecCnt vgVarNames vgVault vgDesc vgModBy vgModOn; do
  [[ -z "$vgName" ]] && continue
  [[ -z "$vgModOn" || "$vgModOn" == "null" ]] && vgModOn="-"
  [[ "$vgModOn" != "-" ]] && vgModOn="${vgModOn:0:10}"
  [[ -z "$vgVault" || "$vgVault" == "null" ]] && vgVault="-"
  [[ -z "$vgDesc" || "$vgDesc" == "null" ]] && vgDesc="-"
  vgVarDisp="-"
  [[ -n "$vgVarNames" && "$vgVarNames" != "null" ]] && vgVarDisp="<span class='var-list' title='$(html_enc "$vgVarNames")'>$(html_enc "$vgVarNames")</span>"
  VG_ROWS+="<tr><td>$(html_enc "$vgName")</td><td>$(html_enc "$vgType")</td><td class='num'>${vgVarCnt}</td><td class='num'>${vgSecCnt}</td><td class='var-cell'>${vgVarDisp}</td><td>$(html_enc "$vgVault")</td><td>$(html_enc "$vgDesc")</td><td>$(html_enc "$vgModBy")</td><td>${vgModOn}</td></tr>"
done < <(echo "$VG_ARRAY" | jq -r '.[] | [.name, (.type // ""), (.variableCount|tostring), (.secretCount|tostring), (.variableNames // ""), (.providerData // ""), (.description // ""), (.modifiedBy // ""), (.modifiedOn // "")] | @tsv' 2>/dev/null)

# Build environment table rows
ENV_ROWS=""
while IFS=$'\t' read -r eName; do
  [[ -z "$eName" ]] && continue
  ENV_ROWS+="<tr><td>$(html_enc "$eName")</td></tr>"
done < <(echo "$ENV_ARRAY" | jq -r '.[].name' 2>/dev/null)

# Helper for conditional table/empty rendering
section_or_empty() {
  local count="$1" header="$2" rows="$3" emptyMsg="$4"
  if [[ "$count" -gt 0 ]]; then
    echo "${header}${rows}</tbody></table>"
  else
    echo "<p class='empty'>${emptyMsg}</p>"
  fi
}

REPOS_HTML=$(section_or_empty "$REPO_COUNT" \
  "<table><colgroup><col style='width:40%'><col style='width:15%'><col style='width:15%'><col style='width:20%'><col style='width:10%'></colgroup><thead><tr><th>Name</th><th>Size (MB)</th><th>Size (GB)</th><th>Default Branch</th><th>Disabled</th></tr></thead><tbody>" \
  "$REPO_ROWS" "No repositories")

PIPES_HTML=$(section_or_empty "$PIPE_COUNT" \
  "<table><thead><tr><th>Name</th><th>Type</th><th>Queue Status</th><th>Path</th></tr></thead><tbody>" \
  "$PIPE_ROWS" "No build pipelines")

RELEASES_HTML=$(section_or_empty "$REL_COUNT" \
  "<table><thead><tr><th>Name</th><th>Path</th><th>Environments</th><th>Environment Names</th><th>Modified By</th><th>Modified</th></tr></thead><tbody>" \
  "$RELEASE_ROWS" "No release definitions")

TEAMS_HTML=$(section_or_empty "$TEAM_COUNT" \
  "<table><thead><tr><th>Name</th><th>Members</th><th>Description</th></tr></thead><tbody>" \
  "$TEAM_ROWS" "No teams")

SC_HTML=$(section_or_empty "$SC_COUNT" \
  "<table><colgroup><col style='width:20%'><col style='width:12%'><col style='width:12%'><col style='width:20%'><col style='width:16%'><col style='width:12%'><col style='width:8%'></colgroup><thead><tr><th>Name</th><th>Type</th><th>Auth Scheme</th><th>URL</th><th>Description</th><th>Created By</th><th>Ready</th></tr></thead><tbody>" \
  "$SC_ROWS" "No service connections")

VG_HTML=$(section_or_empty "$VG_COUNT" \
  "<table><colgroup><col style='width:15%'><col style='width:10%'><col style='width:7%'><col style='width:7%'><col style='width:20%'><col style='width:10%'><col style='width:13%'><col style='width:10%'><col style='width:8%'></colgroup><thead><tr><th>Name</th><th>Type</th><th>Variables</th><th>Secrets</th><th>Variable Names</th><th>Key Vault</th><th>Description</th><th>Modified By</th><th>Modified</th></tr></thead><tbody>" \
  "$VG_ROWS" "No variable groups")

ENV_HTML=$(section_or_empty "$ENV_COUNT" \
  "<table><thead><tr><th>Name</th></tr></thead><tbody>" \
  "$ENV_ROWS" "No environments")

# Card warn classes
LARGE_CARD_CLASS=""; [[ "$LARGE_COUNT" -gt 0 ]] && LARGE_CARD_CLASS=" warn"
GEI_CARD_CLASS=""; [[ "$GEI_BLOCKED_COUNT" -gt 0 ]] && GEI_CARD_CLASS=" error"

cat > "$HTML_FILE" <<HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>ADO Inventory Dashboard — $(html_enc "$ORG_NAME") / $(html_enc "$PROJECT_NAME")</title>
<style>
  *{margin:0;padding:0;box-sizing:border-box}
  body{font-family:'Segoe UI',Tahoma,sans-serif;background:#f0f2f5;color:#24292f;padding:20px}
  .container{max-width:1400px;margin:0 auto}
  h1{font-size:1.8rem;margin-bottom:5px;color:#0078d4}
  .subtitle{color:#586069;margin-bottom:20px;font-size:.9rem}
  .cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin-bottom:25px}
  .card{background:#fff;border-radius:8px;padding:16px;box-shadow:0 1px 3px rgba(0,0,0,.12);text-align:center}
  .card .value{font-size:1.8rem;font-weight:700;color:#0078d4}
  .card .label{font-size:.8rem;color:#586069;margin-top:4px}
  .card.warn .value{color:#d29922}
  .card.error .value{color:#cf222e}
  .search-box{margin-bottom:15px}
  .search-box input{width:100%;max-width:400px;padding:10px 14px;border:1px solid #d0d7de;border-radius:6px;font-size:.9rem}
  .search-box input:focus{outline:none;border-color:#0078d4;box-shadow:0 0 0 3px rgba(0,120,212,.15)}
  .project-card{background:#fff;border-radius:8px;margin-bottom:12px;box-shadow:0 1px 3px rgba(0,0,0,.12);overflow:hidden}
  .project-header{padding:16px 20px;cursor:pointer;border-left:4px solid #0078d4;transition:background .2s}
  .project-header:hover{background:#f6f8fa}
  .project-header h2{font-size:1.1rem;color:#24292f;margin-bottom:6px}
  .project-stats{display:flex;gap:18px;flex-wrap:wrap;font-size:.85rem;color:#586069}
  .project-body{padding:0 20px 20px}
  .project-body h3{font-size:.95rem;color:#0078d4;margin:16px 0 8px;border-bottom:1px solid #e1e4e8;padding-bottom:4px}
  table{width:100%;border-collapse:collapse;margin-bottom:10px;font-size:.83rem;table-layout:fixed}
  th{background:#f6f8fa;padding:8px 10px;text-align:left;font-weight:600;border-bottom:2px solid #e1e4e8;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  td{padding:7px 10px;border-bottom:1px solid #e1e4e8;word-wrap:break-word;overflow:hidden;text-overflow:ellipsis}
  tr:hover{background:#f6f8fa}
  tr.blocked{background:#fff0f0}
  tr.warning{background:#fff8e1}
  .num{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
  .badge-vis{font-size:.7rem;padding:2px 8px;border-radius:10px;background:#dafbe1;color:#1a7f37;margin-left:8px}
  .badge-state{font-size:.7rem;padding:2px 8px;border-radius:10px;background:#ddf4ff;color:#0969da;margin-left:4px}
  .empty{color:#8b949e;font-style:italic;font-size:.85rem;padding:4px 0}
  a{color:#0078d4;text-decoration:none}
  a:hover{text-decoration:underline}
  .footer{margin-top:20px;color:#586069;font-size:.8rem;text-align:center}
  .expand-all{margin-bottom:15px}
  .expand-all button{padding:8px 16px;border:1px solid #d0d7de;border-radius:6px;background:#fff;cursor:pointer;font-size:.85rem}
  .expand-all button:hover{background:#f6f8fa}
  .var-cell{max-width:250px}
  .var-list{display:inline-block;max-width:250px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;vertical-align:middle;cursor:help}
  .report-section{background:#fff;border-radius:8px;padding:20px;margin-bottom:20px;box-shadow:0 1px 3px rgba(0,0,0,.12)}
  .report-section h2{font-size:1.1rem;color:#0078d4;margin-bottom:12px;border-bottom:2px solid #e1e4e8;padding-bottom:6px}
  .report-table{width:100%;border-collapse:collapse;font-size:.83rem}
  .report-table th{background:#f6f8fa;padding:8px 10px;text-align:left;font-weight:600;border-bottom:2px solid #e1e4e8;position:sticky;top:0}
  .report-table td{padding:7px 10px;border-bottom:1px solid #e1e4e8}
  .report-table tr:hover{background:#f6f8fa}
  .report-table .total-row{background:#f0f2f5;font-weight:700}
</style>
</head>
<body>
<div class="container">
  <h1>&#128202; ADO Inventory Dashboard</h1>
  <p class="subtitle">Organization: <b>$(html_enc "$ORG_NAME")</b> &mdash; Project: <b>$(html_enc "$PROJECT_NAME")</b> &mdash; Generated: ${TIMESTAMP}</p>

  <div class="cards">
    <div class="card"><div class="value">1</div><div class="label">Projects</div></div>
    <div class="card"><div class="value">${REPO_COUNT}</div><div class="label">Repositories</div></div>
    <div class="card"><div class="value">${TOTAL_SIZE_GB} GB</div><div class="label">Total Repo Size</div></div>
    <div class="card"><div class="value">${PIPE_COUNT}</div><div class="label">Build Pipelines</div></div>
    <div class="card"><div class="value">${TOTAL_REL_DEFS}</div><div class="label">Release Defs</div></div>
    <div class="card"><div class="value">${TEAM_COUNT}</div><div class="label">Teams</div></div>
    <div class="card"><div class="value">${WI_COUNT}</div><div class="label">Work Items</div></div>
    <div class="card"><div class="value">${TOTAL_SVC_CONNS}</div><div class="label">Service Connections</div></div>
    <div class="card"><div class="value">${TOTAL_VAR_GROUPS}</div><div class="label">Variable Groups</div></div>
    <div class="card"><div class="value">${TOTAL_ENVS}</div><div class="label">Environments</div></div>
    <div class="card${LARGE_CARD_CLASS}"><div class="value">${LARGE_COUNT}</div><div class="label">Repos &gt; 1 GB</div></div>
    <div class="card${GEI_CARD_CLASS}"><div class="value">${GEI_BLOCKED_COUNT}</div><div class="label">GEI Blocked (&gt;40 GB)</div></div>
  </div>

  <div class="report-section">
    <h2>Project Summary Report</h2>
    <table class="report-table">
      <thead>
        <tr><th>Project</th><th>Visibility</th><th>Repos</th><th>Size (GB)</th><th>Pipelines</th><th>Releases</th><th>Teams</th><th>Work Items</th><th>Svc Conns</th><th>Var Groups</th><th>Environments</th></tr>
      </thead>
      <tbody>
${REPORT_ROWS}
      </tbody>
    </table>
  </div>

  <div class="expand-all">
    <button onclick="expandAll()">Expand All</button>
    <button onclick="collapseAll()">Collapse All</button>
  </div>

<div class="project-card" id="proj-${PROJ_ID}">
  <div class="project-header" onclick="toggleProject('${PROJ_ID}')">
    <h2>$(html_enc "$PROJECT_NAME") <span class="badge-vis">${PROJ_VIS}</span> <span class="badge-state">${PROJ_STATE}</span></h2>
    <div class="project-stats">
      <span>Repos: <b>${REPO_COUNT}</b></span>
      <span>Pipelines: <b>${PIPE_COUNT}</b></span>
      <span>Releases: <b>${REL_COUNT}</b></span>
      <span>Teams: <b>${TEAM_COUNT}</b></span>
      <span>Work Items: <b>${WI_COUNT}</b></span>
      <span>Svc Conns: <b>${SC_COUNT}</b></span>
      <span>Var Groups: <b>${VG_COUNT}</b></span>
      <span>Size: <b>${PROJ_SIZE_GB} GB</b></span>
    </div>
  </div>
  <div class="project-body" id="body-${PROJ_ID}" style="display:none;">
    <h3>Repositories (${REPO_COUNT})</h3>
    ${REPOS_HTML}

    <h3>Build Pipelines (${PIPE_COUNT})</h3>
    ${PIPES_HTML}

    <h3>Release Definitions (${REL_COUNT})</h3>
    ${RELEASES_HTML}

    <h3>Teams (${TEAM_COUNT})</h3>
    ${TEAMS_HTML}

    <h3>Service Connections (${SC_COUNT})</h3>
    ${SC_HTML}

    <h3>Variable Groups (${VG_COUNT})</h3>
    ${VG_HTML}

    <h3>Environments (${ENV_COUNT})</h3>
    ${ENV_HTML}
  </div>
</div>

  <p class="footer">ADO Inventory &mdash; $(html_enc "$ORG_NAME") / $(html_enc "$PROJECT_NAME") &mdash; ${TIMESTAMP}</p>
</div>
<script>
function toggleProject(id){
  var el=document.getElementById('body-'+id);
  el.style.display=el.style.display==='none'?'block':'none';
}
function expandAll(){
  document.querySelectorAll('.project-body').forEach(function(el){el.style.display='block';});
}
function collapseAll(){
  document.querySelectorAll('.project-body').forEach(function(el){el.style.display='none';});
}
</script>
</body>
</html>
HTMLEOF

echo -e "\e[32mHTML dashboard saved to: $HTML_FILE\e[0m"
