#!/usr/bin/env bash

# SYNOPSIS
#     Migrates Azure DevOps pipeline definitions to GitHub Actions workflows.
# DESCRIPTION
#     Uses GitHub Actions Importer to convert ADO YAML and Classic pipelines
#     to GitHub Actions workflows. Handles dry-run, migration, and custom transformer support.

set -e

# ANSI escape codes for colors
CYAN='\e[36m'
GREEN='\e[32m'
YELLOW='\e[33m'
RED='\e[31m'
GRAY='\e[90m'
NC='\e[0m' # No Color

# Function to fix file ownership of docker-generated files on exit
fix_permissions() {
    if [ -x "$(command -v docker)" ]; then
        local target_dir=""
        if [ -n "$OutputDir" ] && [ -d "$OutputDir" ]; then
            target_dir="$OutputDir"
        elif [ -d "output" ]; then
            target_dir="output"
        fi
        if [ -n "$target_dir" ]; then
            echo -e "${YELLOW}Fixing ownership of generated files in $target_dir...${NC}"
            local abs_target=$(realpath "$target_dir")
            docker run --rm -v "$abs_target":/data ghcr.io/actions-importer/cli:latest chown -R "$(id -u):$(id -g)" /data 2>/dev/null || true
        fi
    fi
}
trap fix_permissions EXIT

# Parameter variables
ConfigFile=""
AdoProject=""
PipelineIds=()
Mode="dry-run"
PipelineType="build"
CustomTransformersDir=""
ImporterConfigFile=""
ConfigFilePath=""
ReusablesTargetRepo=""
ReusablesRef="main"
OutputDir="./output/pipelines"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --config-file)
            ConfigFile="$2"
            shift 2
            ;;
        --ado-project)
            AdoProject="$2"
            shift 2
            ;;
        --pipeline-id)
            IFS=',' read -ra ADDR <<< "$2"
            for i in "${ADDR[@]}"; do
                PipelineIds+=("$i")
            done
            shift 2
            ;;
        --mode)
            Mode="$2"
            shift 2
            ;;
        --pipeline-type)
            PipelineType="$2"
            shift 2
            ;;
        --custom-transformers-dir)
            CustomTransformersDir="$2"
            shift 2
            ;;
        --importer-config-file)
            ImporterConfigFile="$2"
            shift 2
            ;;
        --config-file-path)
            ConfigFilePath="$2"
            shift 2
            ;;
        --reusables-target-repo)
            ReusablesTargetRepo="$2"
            shift 2
            ;;
        --reusables-ref)
            ReusablesRef="$2"
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

echo -e "${GRAY}Resolving configuration...${NC}"

get_val() {
    local key="$1"
    local default="$2"
    shift 2
    local env_keys=("$@")
    
    local val=""
    if [ -f "$ConfigFile" ]; then
        val=$(jq -r ".${key} // empty" "$ConfigFile" 2>/dev/null || echo "")
    fi
    
    if [ -z "$val" ] || [[ "$val" == \$* ]]; then
        val=""
        for ek in "${env_keys[@]}"; do
            local eval_val="${!ek}"
            if [ -n "$eval_val" ]; then
                val="$eval_val"
                break
            fi
        done
    fi
    
    if [ -z "$val" ]; then
        echo "$default"
    else
        echo "$val"
    fi
}

CONF_ADO_ORG=$(get_val "source.organization" "" "ADO_ORG" "ADO_Org" "ADOORG")
CONF_GH_ORG=$(get_val "target.organization" "" "GH_ORG" "GH_Org" "GHORG")
CONF_ADO_PAT=$(get_val "source.pat" "" "ADO_PAT" "AZDO_PAT")
CONF_GH_PAT=$(get_val "target.pat" "" "GH_PAT" "GITHUB_PAT")
CONF_ADO_PROJECT=$(get_val "source.project" "" "ADO_PROJECT" "ADO_Project")

# Handle PIPELINE_IDS from config
pipeline_ids=""
if [ -f "$ConfigFile" ]; then
    pipeline_ids=$(jq -r 'if .PIPELINE_IDS == null then "" elif .PIPELINE_IDS | type == "array" then .PIPELINE_IDS | join(",") else .PIPELINE_IDS | tostring end' "$ConfigFile" 2>/dev/null || echo "")
fi
if [ -z "$pipeline_ids" ] || [[ "$pipeline_ids" == \$* ]]; then
    pipeline_ids="${PIPELINE_IDS:-}"
fi
CONF_PIPELINE_IDS="$pipeline_ids"

CONF_PIPELINE_TYPE=$(get_val "PIPELINE_TYPE" "build" "PIPELINE_TYPE")
CONF_MIGRATE_MODE=$(get_val "MIGRATE_MODE" "dry-run" "MIGRATE_MODE" "MODE")

# Handle PIPELINE_REPO_MAP
repo_map_str=""
if [ -f "$ConfigFile" ]; then
    repo_map_str=$(jq -r '
        if .PIPELINE_REPO_MAP == null then "" 
        elif .PIPELINE_REPO_MAP | type == "object" then 
            [to_entries[] | "\(.key)=\(.value)"] | join(",") 
        elif .PIPELINE_REPO_MAP | type == "array" then 
            .PIPELINE_REPO_MAP | join(",") 
        else 
            .PIPELINE_REPO_MAP | tostring 
        end' "$ConfigFile" 2>/dev/null || echo "")
fi
if [ -z "$repo_map_str" ] || [[ "$repo_map_str" == \$* ]]; then
    repo_map_str="${PIPELINE_REPO_MAP:-}"
fi
CONF_PIPELINE_REPO_MAP="$repo_map_str"

# Handle REUSABLE_PIPELINE_IDS
reusable_ids=""
if [ -f "$ConfigFile" ]; then
    reusable_ids=$(jq -r 'if .REUSABLE_PIPELINE_IDS == null then "" elif .REUSABLE_PIPELINE_IDS | type == "array" then .REUSABLE_PIPELINE_IDS | join(",") else .REUSABLE_PIPELINE_IDS | tostring end' "$ConfigFile" 2>/dev/null || echo "")
fi
if [ -z "$reusable_ids" ] || [[ "$reusable_ids" == \$* ]]; then
    reusable_ids="${REUSABLE_PIPELINE_IDS:-}"
fi
CONF_REUSABLE_PIPELINE_IDS="$reusable_ids"

CONF_GH_REPO=$(get_val "GH_REPO" "" "GH_REPO" "GHRepo")

# Parameter precedence
if [ -n "$AdoProject" ]; then CONF_ADO_PROJECT="$AdoProject"; fi
if [ ${#PipelineIds[@]} -ne 0 ]; then
    CONF_PIPELINE_IDS=$(IFS=,; echo "${PipelineIds[*]}")
fi
if [ -n "$PipelineType" ]; then CONF_PIPELINE_TYPE="$PipelineType"; fi
if [ -n "$Mode" ]; then CONF_MIGRATE_MODE="$Mode"; fi

# Ensure core variables are set
if [ -z "$CONF_ADO_ORG" ]; then echo -e "${RED}ERROR: ADO org not set.${NC}"; exit 1; fi
if [ -z "$CONF_ADO_PAT" ]; then echo -e "${RED}ERROR: ADO PAT not set.${NC}"; exit 1; fi
if [ -z "$CONF_ADO_PROJECT" ]; then echo -e "${RED}ERROR: ADO project not set.${NC}"; exit 1; fi

mkdir -p "$OutputDir"

# Print configuration details matching powershell style
if [ -n "$ConfigFile" ] && [ -f "$ConfigFile" ]; then
    echo "Loaded config from: $ConfigFile"
fi
if [ -n "$CONF_PIPELINE_REPO_MAP" ]; then
    IFS=',' read -ra ADDR <<< "$CONF_PIPELINE_REPO_MAP"
    echo "  Pipeline-to-Repo map: ${#ADDR[@]} entries loaded"
fi
if [ -n "$CONF_REUSABLE_PIPELINE_IDS" ]; then
    formatted_reusables=$(echo "$CONF_REUSABLE_PIPELINE_IDS" | sed 's/,/, /g')
    echo -e "${CYAN}Reusable pipeline allow-list: $formatted_reusables${NC}"
fi
echo -e "${CYAN}=== Pipeline Migration ($CONF_MIGRATE_MODE) ===${NC}"
echo -e "  Organization: https://dev.azure.com/$CONF_ADO_ORG"
echo -e "  Project:      $CONF_ADO_PROJECT"

# Export token vars for actions-importer
export GITHUB_ACCESS_TOKEN="$CONF_GH_PAT"
export AZURE_DEVOPS_ACCESS_TOKEN="$CONF_ADO_PAT"

# Parse repository mapping
declare -A repo_map_dict
if [ -n "$CONF_PIPELINE_REPO_MAP" ]; then
    IFS=',' read -ra ADDR <<< "$CONF_PIPELINE_REPO_MAP"
    for entry in "${ADDR[@]}"; do
        IFS='=' read -ra PARTS <<< "$entry"
        if [ ${#PARTS[@]} -eq 2 ]; then
            repo_map_dict["${PARTS[0]}"]="${PARTS[1]}"
        fi
    done
fi

# Parse reusable pipeline IDs
declare -A reusable_ids_dict
if [ -n "$CONF_REUSABLE_PIPELINE_IDS" ]; then
    IFS=',' read -ra ADDR <<< "$CONF_REUSABLE_PIPELINE_IDS"
    for rid in "${ADDR[@]}"; do
        reusable_ids_dict["$rid"]=1
    done
fi

# Function to rewrite config.yml for reusable templates
rewrite_config() {
    local config_path="$1"
    local central_url="$2"
    local ref="$3"
    
    if [ ! -f "$config_path" ]; then
        echo -e "${RED}Error: Config file not found at $config_path${NC}"
        return 1
    fi
    
    if [[ ! "$central_url" == http://* ]] && [[ ! "$central_url" == https://* ]]; then
        if [[ "$central_url" == */* ]]; then
            central_url="https://github.com/$central_url"
        else
            echo -e "${RED}Error: Invalid central repo format: $central_url${NC}"
            return 1
        fi
    fi
    
    echo -e "${YELLOW}Rewriting $config_path to centralize reusables at $central_url (ref: $ref)...${NC}"
    
    local backup_path="${config_path}.bak"
    cp "$config_path" "$backup_path"
    echo -e "  Backup saved: $backup_path"
    
    local temp_out="${config_path}.tmp"
    rm -f "$temp_out"
    
    local skip=false
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^([[:space:]]*)-[[:space:]]+name:[[:space:]]+([^[:space:]]+) ]]; then
            indent="${BASH_REMATCH[1]}"
            raw_name="${BASH_REMATCH[2]}"
            prop_indent="${indent}  "
            
            folderName=$(echo "$raw_name" | sed -E 's/\.ya?ml$//I' | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]/_/g')
            
            echo "$line" >> "$temp_out"
            echo "${prop_indent}target_url: $central_url" >> "$temp_out"
            echo "${prop_indent}ref: $ref" >> "$temp_out"
            echo "${prop_indent}path: .github/actions/$folderName" >> "$temp_out"
            
            skip=true
            continue
        fi
        
        if [ "$skip" = "true" ]; then
            if [[ "$line" =~ ^[[:space:]]+target_url:[[:space:]]* ]] || \
               [[ "$line" =~ ^[[:space:]]+ref:[[:space:]]* ]] || \
               [[ "$line" =~ ^[[:space:]]+path:[[:space:]]* ]]; then
                continue
            else
                skip=false
            fi
        fi
        
        echo "$line" >> "$temp_out"
    done < "$config_path"
    
    mv "$temp_out" "$config_path"
    local count=$(grep -c '^[[:space:]]*-[[:space:]]\+name:' "$config_path" || echo "0")
    echo -e "${GREEN}  Normalized $count reusable entries (target_url + ref) -> central repo.${NC}"
}

# Function to generate migration dashboard
generate_dashboard() {
    local output_dir="$1"
    local ado_org="$2"
    local ado_project="$3"
    local gh_org="$4"
    local results_json="$5"
    
    local dashboardDir="$output_dir/dashboard"
    mkdir -p "$dashboardDir"
    
    local scanDate=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
    
    local totalCount=$(jq 'length' "$results_json")
    local successCount=$(jq '[.[] | select(.Status == "SUCCESS")] | length' "$results_json")
    local partialCount=$(jq '[.[] | select(.Status == "PARTIAL")] | length' "$results_json")
    local failedCount=$(jq '[.[] | select(.Status == "FAILED" or .Status == "ERROR")] | length' "$results_json")
    local noOutputCount=$(jq '[.[] | select(.Status == "NO_OUTPUT")] | length' "$results_json")
    
    local safeDivisor=$totalCount
    if [ "$safeDivisor" -lt 1 ]; then safeDivisor=1; fi
    
    local pctSuccess=$(( successCount * 100 / safeDivisor ))
    local pctPartial=$(( partialCount * 100 / safeDivisor ))
    local pctFailed=$(( failedCount * 100 / safeDivisor ))
    local pctNoOutput=$(( noOutputCount * 100 / safeDivisor ))
    local pctMigrated=$(( pctSuccess + pctPartial ))
    
    local seg1=$pctSuccess
    local seg2=$(( seg1 + pctPartial ))
    local seg3=$(( seg2 + pctFailed ))
    
    local pipelineTableRows=""
    readarray -t results_array < <(jq -c '. | sort_by(.Status, .Pipeline)[]' "$results_json" 2>/dev/null || true)
    for r_str in "${results_array[@]}"; do
        local pipeName=$(echo "$r_str" | jq -r '.Pipeline')
        local pipeId=$(echo "$r_str" | jq -r '.Id')
        local targetRepo=$(echo "$r_str" | jq -r '.TargetRepo // ""')
        local mode=$(echo "$r_str" | jq -r '.Mode')
        local status=$(echo "$r_str" | jq -r '.Status')
        
        local statusBadge=""
        case "$status" in
            "SUCCESS")   statusBadge="<span class='badge-ok'>&#9989; Success</span>" ;;
            "PARTIAL")   statusBadge="<span class='badge-warn'>&#9888;&#65039; Partial</span>" ;;
            "NO_OUTPUT") statusBadge="<span class='badge-warn'>&#128196; No Output</span>" ;;
            "FAILED")    statusBadge="<span class='badge-fail'>&#10060; Failed</span>" ;;
            "ERROR")     statusBadge="<span class='badge-fail'>&#128683; Error</span>" ;;
            *)           statusBadge="<span class='badge-fail'>$status</span>" ;;
        esac
        
        local ghRepoUrl="https://github.com/$gh_org/$targetRepo"
        pipelineTableRows+="    <tr><td>$pipeId</td><td>$pipeName</td><td><a href='$ghRepoUrl' target='_blank'>$targetRepo</a></td><td class='center'>$mode</td><td class='center'>$statusBadge</td></tr>\n"
    done
    
    local workflowRows=""
    local yamlFiles=()
    while IFS= read -r -d '' yf; do
        yamlFiles+=("$yf")
    done < <(find "$output_dir" -type f \( -name "*.yml" -o -name "*.yaml" \) -print0 2>/dev/null)
    
    for yf in "${yamlFiles[@]}"; do
        local relPath="${yf#$output_dir/}"
        local name=$(basename "$yf" | sed -E 's/\.ya?ml$//I')
        local dir=$(dirname "$relPath")
        
        local sizeBytes=$(wc -c < "$yf" | tr -d ' ')
        local sizeKb=$(( sizeBytes * 10 / 1024 ))
        local sizeKbStr="$(( sizeKb / 10 )).$(( sizeKb % 10 )) KB"
        
        workflowRows+="    <tr><td>$dir</td><td>$name</td><td class='num'>$sizeKbStr</td></tr>\n"
    done
    
    local workflowSection=""
    if [ -n "$workflowRows" ]; then
        workflowSection=$(cat <<EOF
      <table>
        <thead><tr><th>Directory</th><th>Workflow</th><th>Size</th></tr></thead>
        <tbody>
$(echo -e "$workflowRows")
        </tbody>
      </table>
EOF
)
    else
        workflowSection="      <p class='empty-state'><span class='empty-icon'>&#128194;</span>No workflow YAML files generated.</p>"
    fi
    
    local htmlOut="$dashboardDir/index.html"
    cat <<EOF > "$htmlOut"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Pipeline Migration Dashboard</title>
<style>
  body {
    font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, Roboto, Helvetica, Arial, sans-serif;
    background: #f3f4f6;
    color: #1f2937;
    margin: 0;
    padding: 24px;
  }
  .container {
    max-width: 1100px;
    margin: 0 auto;
    background: #fff;
    padding: 32px;
    border-radius: 12px;
    box-shadow: 0 4px 6px -1px rgba(0,0,0,0.1), 0 2px 4px -1px rgba(0,0,0,0.06);
  }
  h1 {
    margin-top: 0;
    color: #111827;
    font-size: 28px;
    border-bottom: 2px solid #e5e7eb;
    padding-bottom: 16px;
    display: flex;
    align-items: center;
  }
  h2 {
    color: #374151;
    font-size: 20px;
    margin-top: 32px;
    border-bottom: 1px solid #f3f4f6;
    padding-bottom: 8px;
  }
  .title-icon { margin-right: 12px; font-size: 32px; }
  .sec-icon { margin-right: 8px; }
  .meta-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
    gap: 16px;
    margin-bottom: 32px;
  }
  .meta-card {
    background: #f9fafb;
    padding: 16px;
    border-radius: 8px;
    border: 1px solid #e5e7eb;
  }
  .meta-label {
    font-size: 12px;
    text-transform: uppercase;
    color: #6b7280;
    font-weight: 600;
  }
  .meta-value {
    font-size: 18px;
    font-weight: bold;
    color: #111827;
    margin-top: 4px;
    word-break: break-all;
  }
  .dashboard-grid {
    display: grid;
    grid-template-columns: 1fr 320px;
    gap: 32px;
  }
  @media (max-width: 768px) {
    .dashboard-grid { grid-template-columns: 1fr; }
  }
  table {
    width: 100%;
    border-collapse: collapse;
    margin-top: 12px;
  }
  th, td {
    padding: 10px 12px;
    text-align: left;
    border-bottom: 1px solid #e5e7eb;
    font-size: 14px;
  }
  th {
    background: #f9fafb;
    color: #4b5563;
    font-weight: 600;
  }
  tr:hover { background: #f9fafb; }
  .center { text-align: center; }
  .num { text-align: right; font-family: monospace; }
  .badge-ok {
    background: #def7ec;
    color: #03543f;
    padding: 2px 8px;
    border-radius: 12px;
    font-size: 12px;
    font-weight: 500;
  }
  .badge-warn {
    background: #fef3c7;
    color: #92400e;
    padding: 2px 8px;
    border-radius: 12px;
    font-size: 12px;
    font-weight: 500;
  }
  .badge-fail {
    background: #fde8e8;
    color: #9b1c1c;
    padding: 2px 8px;
    border-radius: 12px;
    font-size: 12px;
    font-weight: 500;
  }
  /* Donut Chart */
  .chart-box {
    background: #f9fafb;
    border: 1px solid #e5e7eb;
    border-radius: 8px;
    padding: 24px;
    text-align: center;
  }
  .donut-svg {
    transform: rotate(-90deg);
    margin-bottom: 16px;
  }
  .donut-hole { fill: #f9fafb; }
  .donut-ring { fill: none; stroke: #e5e7eb; stroke-width: 3; }
  .donut-segment-1 {
    fill: none;
    stroke: #10b981;
    stroke-width: 4;
    stroke-dasharray: ${seg1} 100;
  }
  .donut-segment-2 {
    fill: none;
    stroke: #f59e0b;
    stroke-width: 4;
    stroke-dashoffset: -${seg1};
    stroke-dasharray: ${pctPartial} 100;
  }
  .donut-segment-3 {
    fill: none;
    stroke: #ef4444;
    stroke-width: 4;
    stroke-dashoffset: -${seg2};
    stroke-dasharray: ${pctFailed} 100;
  }
  .donut-segment-4 {
    fill: none;
    stroke: #6b7280;
    stroke-width: 4;
    stroke-dashoffset: -${seg3};
    stroke-dasharray: ${pctNoOutput} 100;
  }
  .donut-text {
    font-family: monospace;
    fill: #111827;
  }
  .donut-label {
    font-size: 4px;
    font-weight: bold;
    text-anchor: middle;
  }
  .donut-percent {
    font-size: 7px;
    font-weight: bold;
    text-anchor: middle;
  }
  .breakdown-table td {
    padding: 6px 8px;
    border: none;
    font-size: 13px;
  }
  .dot {
    display: inline-block;
    width: 10px;
    height: 10px;
    border-radius: 50%;
    margin-right: 8px;
  }
  .mini-bar {
    width: 60px;
    background: #e5e7eb;
    height: 6px;
    border-radius: 3px;
    overflow: hidden;
  }
  .mini-fill {
    height: 100%;
  }
  .checklist {
    background: #fff8e1;
    border: 1px solid #ffe082;
    border-radius: 8px;
    padding: 20px;
    margin-top: 32px;
  }
  .checklist-item {
    display: flex;
    align-items: flex-start;
    margin-bottom: 12px;
    font-size: 14px;
  }
  .checklist-item input {
    margin-right: 10px;
    margin-top: 3px;
  }
  .empty-state {
    text-align: center;
    padding: 40px;
    color: #6b7280;
    background: #f9fafb;
    border: 1px dashed #d1d5db;
    border-radius: 8px;
  }
  .empty-icon { font-size: 48px; display: block; margin-bottom: 12px; }
  .footer {
    margin-top: 48px;
    border-top: 1px solid #e5e7eb;
    padding-top: 16px;
    font-size: 12px;
    color: #6b7280;
    text-align: center;
  }
</div>

</body>
</html>
EOF
    echo -e "${GREEN}Migration dashboard generated: $htmlOut${NC}"
}

# Ensure actions-importer is up to date
echo -e "${YELLOW}Ensuring actions-importer image is up to date...${NC}"
gh actions-importer update 2>&1 || true

# --- LIST MODE ---
if [ "$CONF_MIGRATE_MODE" = "list" ]; then
    echo -e "\n${YELLOW}Fetching pipelines from ADO...${NC}"
    base64Auth=$(echo -n ":$CONF_ADO_PAT" | base64 | tr -d '\n')
    adoOrgUrl="https://dev.azure.com/$CONF_ADO_ORG"

    # Fetch build definitions
    buildUrl="$adoOrgUrl/$CONF_ADO_PROJECT/_apis/build/definitions?api-version=7.1&includeAllProperties=true"
    curl -s -k -H "Authorization: Basic $base64Auth" "$buildUrl" > "$OutputDir/tmp_build_pipelines.json" || echo '{"value":[]}' > "$OutputDir/tmp_build_pipelines.json"

    # Fetch release definitions
    releaseUrl="https://vsrm.dev.azure.com/$CONF_ADO_ORG/$CONF_ADO_PROJECT/_apis/release/definitions?api-version=7.1"
    curl -s -k -H "Authorization: Basic $base64Auth" "$releaseUrl" > "$OutputDir/tmp_release_pipelines.json" || echo '{"value":[]}' > "$OutputDir/tmp_release_pipelines.json"

    buildCount=$(jq '.value | length // 0' "$OutputDir/tmp_build_pipelines.json" 2>/dev/null || echo "0")
    releaseCount=$(jq '.value | length // 0' "$OutputDir/tmp_release_pipelines.json" 2>/dev/null || echo "0")
    totalCount=$((buildCount + releaseCount))

    echo -e "\n${CYAN}=== Available Pipelines ($totalCount found) ===${NC}"

    # Build pipelines
    echo -e "\n--- Build Pipelines ($buildCount) ---"
    printf "%-8s %-45s %-12s %s\n" "ID" "Name" "Type" "Path"
    printf "%.0s-" {1..90}; echo

    if [ -f "$OutputDir/tmp_build_pipelines.json" ]; then
        readarray -t build_entries < <(jq -c '.value | sort_by(.id)[]' "$OutputDir/tmp_build_pipelines.json" 2>/dev/null || true)
        for entry in "${build_entries[@]}"; do
            id=$(echo "$entry" | jq -r '.id')
            name=$(echo "$entry" | jq -r '.name // ""')
            short_name="${name:0:44}"
            proc_type=$(echo "$entry" | jq -r '.process.type // 0')
            if [ "$proc_type" -eq 2 ]; then
                p_type="YAML"
            else
                p_type="Classic Build"
            fi
            path=$(echo "$entry" | jq -r '.path // ""')
            printf "%-8s %-45s %-12s %s\n" "$id" "$short_name" "$p_type" "$path"
        done
    fi

    # Release pipelines
    if [ "$releaseCount" -gt 0 ]; then
        echo -e "\n--- Classic Release Pipelines ($releaseCount) ---"
        printf "%-8s %-45s %-12s %s\n" "ID" "Name" "Type" "Path"
        printf "%.0s-" {1..90}; echo

        if [ -f "$OutputDir/tmp_release_pipelines.json" ]; then
            readarray -t release_entries < <(jq -c '.value | sort_by(.id)[]' "$OutputDir/tmp_release_pipelines.json" 2>/dev/null || true)
            for entry in "${release_entries[@]}"; do
                id=$(echo "$entry" | jq -r '.id')
                name=$(echo "$entry" | jq -r '.name // ""')
                short_name="${name:0:44}"
                path=$(echo "$entry" | jq -r '.path // ""')
                printf "%-8s %-45s %-12s %s\n" "$id" "$short_name" "Release" "$path"
            done
        fi
    fi

    echo -e "\n${GREEN}To migrate a build pipeline:   --pipeline-id <ID> --pipeline-type build --mode migrate${NC}"
    echo -e "${GREEN}To migrate a release pipeline: --pipeline-id <ID> --pipeline-type release --mode migrate${NC}"

    # --- Show audit status per pipeline if audit_summary.md exists ---
    auditFile="$OutputDir/audit_summary.md"
    if [ ! -f "$auditFile" ]; then
        auditFile="./output/pipeline-audit/audit_summary.md"
    fi

    if [ -f "$auditFile" ]; then
        echo -e "\n${CYAN}=== Audit Results (from $(basename "$auditFile")) ===${NC}"

        # Combine builds and releases into a single lookup JSON
        jq -n \
          --slurpfile builds "$OutputDir/tmp_build_pipelines.json" \
          --slurpfile releases "$OutputDir/tmp_release_pipelines.json" \
          '
          [
            (($builds[0].value // [])[] | {
              id: .id,
              name: .name,
              type: (if .process.type == 2 then "YAML" else "Classic Build" end),
              slug: (.name | ascii_downcase | gsub("[^a-z0-9-]"; "-") | gsub("-+"; "-") | sub("^-"; "") | sub("-$"; ""))
            }),
            (($releases[0].value // [])[] | {
              id: .id,
              name: .name,
              type: "Release",
              slug: (.name | ascii_downcase | gsub("[^a-z0-9-]"; "-") | gsub("-+"; "-") | sub("^-"; "") | sub("-$"; ""))
            })
          ]
          ' > "$OutputDir/pipeline_lookups.json"

        # Function to extract pipelines from a section in audit_summary.md
        get_section_pipelines() {
            local header="$1"
            local file="$2"
            awk -v hdr="$header" '
                BEGIN {
                    hdr_lower = tolower(hdr)
                    in_sec = 0
                }
                /^### / {
                    line_hdr = substr($0, 5)
                    gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", line_hdr)
                    if (index(tolower(line_hdr), hdr_lower) == 1) {
                        in_sec = 1
                    } else {
                        in_sec = 0
                    }
                    next
                }
                /^#### / {
                    if (in_sec) {
                        val = substr($0, 6)
                        gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", val)
                        print val
                    }
                }
            ' "$file"
        }

        # Define the sections to display
        # Format: SectionHeader|ColorCode|SearchTerm
        sections=(
            "Successful|${GREEN}|Successful"
            "Partially Successful|${YELLOW}|Partially successful"
            "Unsupported|${RED}|Unsupported"
            "Failed|${RED}|Failed"
        )

        for sec_info in "${sections[@]}"; do
            IFS='|' read -r sec_header sec_color sec_term <<< "$sec_info"
            
            # Get pipeline names in this section
            readarray -t audit_pipelines < <(get_section_pipelines "$sec_term" "$auditFile")
            
            # Filter out empty entries
            filtered_pipelines=()
            for pipe in "${audit_pipelines[@]}"; do
                if [ -n "$pipe" ]; then
                    filtered_pipelines+=("$pipe")
                fi
            done

            if [ ${#filtered_pipelines[@]} -gt 0 ]; then
                echo -e "\n${sec_color}--- ${sec_header} Pipelines (${#filtered_pipelines[@]}) ---${NC}"
                printf "%-8s %-45s %-15s %s\n" "ID" "Name" "Type" "Migrate With"
                printf "%.0s-" {1..90}; echo

                for fullPath in "${filtered_pipelines[@]}"; do
                    # Resolve details via jq
                    resolved=$(jq -r \
                      --arg fullPath "$fullPath" \
                      '
                      ($fullPath | split("/") | last) as $pipeName |
                      
                      def slugify:
                        ascii_downcase | gsub("[^a-z0-9-]"; "-") | gsub("-+"; "-") | sub("^-"; "") | sub("-$"; "");
                      
                      def clean_slug:
                        sub("-+[0-9]+$"; "");
                        
                      (map(select(.name == $pipeName)) | first) // 
                      (map(select((.name | ascii_downcase) == ($pipeName | ascii_downcase))) | first) //
                      (
                        $pipeName | 
                        (capture("_\\((?<id>[0-9]+)\\)$") // capture("_(?<id>[0-9]+)$") // empty) | .id | tostring as $extId |
                        (map(select((.id | tostring) == $extId)) | first)
                      ) //
                      (
                        ($pipeName | slugify) as $auditSlug |
                        ($auditSlug | clean_slug) as $auditSlugClean |
                        (map(select(.slug == $auditSlug)) | first) // 
                        (map(select(.slug == $auditSlugClean)) | first)
                      ) //
                      {
                        id: null,
                        name: $pipeName,
                        type: "Unknown"
                      }
                      ' "$OutputDir/pipeline_lookups.json")

                    id=$(echo "$resolved" | jq -r '.id // empty')
                    name=$(echo "$resolved" | jq -r '.name')
                    p_type=$(echo "$resolved" | jq -r '.type')
                    short_name="${name:0:44}"

                    if [ -z "$id" ] || [ "$id" = "null" ]; then
                        id="?"
                        migrateWith=""
                    else
                        if [ "$p_type" = "Release" ]; then
                            migrateWith="--pipeline-type release"
                        else
                            migrateWith="--pipeline-type build"
                        fi
                    fi

                    line=$(printf "%-8s %-45s %-15s %s" "$id" "$short_name" "$p_type" "$migrateWith")
                    echo -e "${sec_color}${line}${NC}"
                done
            fi
        done

        # Cleanup lookup database
        rm -f "$OutputDir/pipeline_lookups.json"
    fi

    rm -f "$OutputDir/tmp_build_pipelines.json" "$OutputDir/tmp_release_pipelines.json"
    exit 0
fi

# --- AUDIT MODE ---
if [ "$CONF_MIGRATE_MODE" = "audit" ]; then
    echo -e "\n${YELLOW}Running audit...${NC}"
    auditArgs=("actions-importer" "audit" "azure-devops" "--output-dir" "$OutputDir" "--azure-devops-organization" "$CONF_ADO_ORG" "--azure-devops-project" "$CONF_ADO_PROJECT")
    gh "${auditArgs[@]}" 2>&1
    
    generatedConfig="$OutputDir/config.yml"
    if [ -f "$generatedConfig" ]; then
        echo -e "\n${CYAN}=== Reusable Workflows / Composite Actions Discovered ===${NC}"
        cat "$generatedConfig"
    fi
    exit 0
fi

# --- MIGRATE REUSABLES MODE ---
if [ "$CONF_MIGRATE_MODE" = "migrate-reusables" ]; then
    if [ -z "$ConfigFilePath" ] || [ ! -f "$ConfigFilePath" ]; then
        echo -e "${RED}ERROR: --config-file-path is required and must point to config.yml${NC}"
        exit 1
    fi

    if [ -n "$ReusablesTargetRepo" ]; then
        rewrite_config "$ConfigFilePath" "$ReusablesTargetRepo" "$ReusablesRef"
    fi

    # Retrieve default target URL from central target URL or config
    defaultTargetUrl=""
    if [ -n "$ReusablesTargetRepo" ]; then
        if [[ "$ReusablesTargetRepo" == http* ]]; then
            defaultTargetUrl="$ReusablesTargetRepo"
        elif [[ "$ReusablesTargetRepo" == */* ]]; then
            defaultTargetUrl="https://github.com/$ReusablesTargetRepo"
        else
            defaultTargetUrl="https://github.com/$CONF_GH_ORG/$ReusablesTargetRepo"
        fi
    fi

    if [ -z "$CONF_PIPELINE_IDS" ]; then
        echo -e "${RED}ERROR: --pipeline-id is required for migrate-reusables.${NC}"
        exit 1
    fi

    IFS=',' read -ra PIDS <<< "$CONF_PIPELINE_IDS"
    anyFailure=false

    for pid in "${PIDS[@]}"; do
        if [ -n "$CONF_REUSABLE_PIPELINE_IDS" ] && [ -z "${reusable_ids_dict[$pid]}" ]; then
            echo -e "${YELLOW}  Pipeline $pid not in REUSABLE_PIPELINE_IDS -- SKIPPING.${NC}"
            continue
        fi

        consumerRepo="${repo_map_dict[$pid]:-$CONF_GH_REPO}"
        if [ -z "$consumerRepo" ]; then
            echo -e "${RED}  ERROR: No consumer repo mapped for pipeline $pid. Set PIPELINE_REPO_MAP or GH_REPO.${NC}"
            anyFailure=true
            continue
        fi
        consumerTargetUrl="https://github.com/$CONF_GH_ORG/$consumerRepo"

        echo -e "\n${CYAN}--- Migrating reusables via consumer pipeline ID: $pid ---${NC}"
        reusableArgs=(
            "actions-importer" "migrate" "azure-devops" "pipeline"
            "--output-dir" "$OutputDir/reusables/$pid"
            "--azure-devops-organization" "$CONF_ADO_ORG"
            "--azure-devops-project" "$CONF_ADO_PROJECT"
            "--pipeline-id" "$pid"
            "--config-file-path" "$ConfigFilePath"
            "--target-url" "$consumerTargetUrl"
        )
        if [ -n "$CustomTransformersDir" ] && [ -d "$CustomTransformersDir" ]; then
            reusableArgs+=("--custom-transformers" "$CustomTransformersDir")
        fi

        echo -e "${GRAY}  Command: gh ${reusableArgs[*]}${NC}"
        if gh "${reusableArgs[@]}" 2>&1; then
            echo -e "${GREEN}  Pipeline $pid OK${NC}"
        else
            echo -e "${RED}  Pipeline $pid FAILED${NC}"
            anyFailure=true
        fi
    done

    if [ "$anyFailure" = true ]; then
        exit 1
    fi
    exit 0
fi

# --- DRY-RUN / MIGRATE MODE ---
base64Auth=$(echo -n ":$CONF_ADO_PAT" | base64 | tr -d '\n')
adoOrgUrl="https://dev.azure.com/$CONF_ADO_ORG"

if [ "$CONF_PIPELINE_TYPE" = "release" ]; then
    pipelinesUrl="https://vsrm.dev.azure.com/$CONF_ADO_ORG/$CONF_ADO_PROJECT/_apis/release/definitions?api-version=7.1"
else
    pipelinesUrl="$adoOrgUrl/$CONF_ADO_PROJECT/_apis/build/definitions?api-version=7.1&includeAllProperties=true"
fi

echo -e "${YELLOW}Fetching pipeline configurations from ADO...${NC}"
curl -s -k -H "Authorization: Basic $base64Auth" "$pipelinesUrl" > "$OutputDir/tmp_pipelines.json" || echo '{"value":[]}' > "$OutputDir/tmp_pipelines.json"

resultsFile="$OutputDir/results.json"
echo "[]" > "$resultsFile"
results_list_file="$OutputDir/results_list.json"

# Build filtered list using jq
jq --arg ids_str "$CONF_PIPELINE_IDS" '
  if $ids_str == "" then [] else ($ids_str | split(",") | map(tonumber)) end as $pids |
  [ .value[] | 
    if ($pids | length == 0) or (.id as $id | $pids | contains([$id])) then
      {
        id: .id,
        name: .name,
        repo: (.repository.name // "")
      }
    else
      empty
    end
  ]
' "$OutputDir/tmp_pipelines.json" > "$results_list_file"

rm -f "$OutputDir/tmp_pipelines.json"

len_selected=$(jq 'length' "$results_list_file")
echo -e "Found $len_selected pipeline(s) to process"

for ((i=0; i<len_selected; i++)); do
    pipeline_id=$(jq -r ".[$i].id" "$results_list_file")
    pipeline_name=$(jq -r ".[$i].name" "$results_list_file")
    pipeline_repo=$(jq -r ".[$i].repo" "$results_list_file")

    echo -e "\n  Processing: $pipeline_name (ID: $pipeline_id)"

    if [ "$CONF_MIGRATE_MODE" = "migrate" ] && [ -n "${reusable_ids_dict[$pipeline_id]}" ]; then
        echo -e "${YELLOW}    Pipeline $pipeline_id is in REUSABLE_PIPELINE_IDS -- already handled by MigrateReusables job. Skipping.${NC}"
        
        # Append skip result using jq
        jq --arg name "$pipeline_name" \
           --argjson id "$pipeline_id" \
           --arg repo "${repo_map_dict[$pipeline_id]:-$CONF_GH_REPO}" \
           --arg mode "$CONF_MIGRATE_MODE" \
           '. += [{
               Pipeline: $name,
               Id: $id,
               TargetRepo: $repo,
               Mode: $mode,
               Status: "SKIPPED",
               OutputDir: ""
           }]' "$resultsFile" > "${resultsFile}.tmp" && mv "${resultsFile}.tmp" "$resultsFile"
        continue
    fi

    targetRepo="${repo_map_dict[$pipeline_id]}"
    if [ -z "$targetRepo" ]; then
        if [ -n "$CONF_GH_REPO" ]; then
            targetRepo="$CONF_GH_REPO"
        elif [ -n "$pipeline_repo" ]; then
            targetRepo=$(echo "$pipeline_repo" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
        else
            targetRepo=$(echo "$CONF_ADO_PROJECT" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
        fi
    fi

    echo -e "    Target repo: $CONF_GH_ORG/$targetRepo"

    outputSubDir="$OutputDir/$CONF_MIGRATE_MODE/$pipeline_name"
    mkdir -p "$outputSubDir"

    importerSubCommand="pipeline"
    if [ "$CONF_PIPELINE_TYPE" = "release" ]; then
        importerSubCommand="release"
    fi

    importerArgs=("actions-importer" "$CONF_MIGRATE_MODE" "azure-devops" "$importerSubCommand" "--output-dir" "$outputSubDir" "--azure-devops-organization" "$CONF_ADO_ORG" "--azure-devops-project" "$CONF_ADO_PROJECT" "--pipeline-id" "$pipeline_id")

    if [ "$CONF_MIGRATE_MODE" = "migrate" ]; then
        importerArgs+=("--target-url" "https://github.com/$CONF_GH_ORG/$targetRepo")
    fi

    if [ -n "$CustomTransformersDir" ] && [ -d "$CustomTransformersDir" ]; then
        importerArgs+=("--custom-transformers" "$CustomTransformersDir")
    fi

    if [ -n "$ConfigFilePath" ] && [ -f "$ConfigFilePath" ]; then
        importerArgs+=("--config-file-path" "$ConfigFilePath")
    elif [ -n "$ImporterConfigFile" ] && [ -f "$ImporterConfigFile" ]; then
        importerArgs+=("--config-file-path" "$ImporterConfigFile")
    fi

    echo -e "    Command: gh ${importerArgs[*]}"
    
    set +e
    gh "${importerArgs[@]}" > "$outputSubDir/importer_exec.log" 2>&1
    exitCode=$?
    set -e

    outputStr=$(cat "$outputSubDir/importer_exec.log" 2>/dev/null || echo "")
    echo "    --- actions-importer output ---"
    cat "$outputSubDir/importer_exec.log" 2>/dev/null || true
    echo "    --- end output ---"

    status="SUCCESS"
    if [ $exitCode -ne 0 ]; then
        status="FAILED"
    elif [[ "$outputStr" =~ "error" ]] || [[ "$outputStr" =~ "failed" ]]; then
        status="FAILED"
    elif [[ "$outputStr" =~ "partially" ]]; then
        status="PARTIAL"
    fi

    yamlFiles=$(find "$outputSubDir" -name "*.yml" -o -name "*.yaml" 2>/dev/null || echo "")
    if [ "$CONF_MIGRATE_MODE" = "dry-run" ] && [ -z "$yamlFiles" ] && [ "$status" = "SUCCESS" ]; then
        status="NO_OUTPUT"
    fi

    color="${RED}"
    if [ "$status" = "SUCCESS" ]; then color="${GREEN}"; fi
    if [ "$status" = "PARTIAL" ] || [ "$status" = "NO_OUTPUT" ]; then color="${YELLOW}"; fi
    echo -e "    ${color}$status${NC}"

    jq --arg name "$pipeline_name" \
       --argjson id "$pipeline_id" \
       --arg repo "$targetRepo" \
       --arg mode "$CONF_MIGRATE_MODE" \
       --arg stat "$status" \
       --arg outDir "$outputSubDir" \
       '. += [{
           Pipeline: $name,
           Id: $id,
           TargetRepo: $repo,
           Mode: $mode,
           Status: $stat,
           OutputDir: $outDir
       }]' "$resultsFile" > "${resultsFile}.tmp" && mv "${resultsFile}.tmp" "$resultsFile"
done

rm -f "$results_list_file"

csvFile="$OutputDir/pipeline-migration-$(date +%Y%m%d-%H%M%S).csv"
echo '"Pipeline","Id","TargetRepo","Mode","Status","OutputDir"' > "$csvFile"
jq -r '.[] | [.Pipeline, .Id, .TargetRepo, .Mode, .Status, .OutputDir] | @csv' "$resultsFile" >> "$csvFile"

generate_dashboard "$OutputDir" "$CONF_ADO_ORG" "$CONF_ADO_PROJECT" "$CONF_GH_ORG" "$resultsFile"

unset GITHUB_ACCESS_TOKEN
unset AZURE_DEVOPS_ACCESS_TOKEN

echo -e "\n${GREEN}Migration complete.${NC}"
