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

# Run Python script block to parse config and output environment setup
echo -e "${GRAY}Resolving configuration...${NC}"
config_exports=$(python3 -c "
import json, os, sys
config_file = '$ConfigFile'
config = {}
if config_file and os.path.exists(config_file):
    try:
        with open(config_file, 'r', encoding='utf-8') as f:
            config = json.load(f)
    except Exception as e:
        print(f'# Error reading config: {e}', file=sys.stderr)

def get_val(key, env_keys, default=''):
    val = config
    for k in key.split('.'):
        if isinstance(val, dict):
            val = val.get(k)
        else:
            val = None
            break
    if val is None or (isinstance(val, str) and val.startswith('\$(')):
        val = None
        for ek in env_keys:
            if os.environ.get(ek):
                val = os.environ.get(ek)
                break
    return val if val is not None else default

ado_org = get_val('source.organization', ['ADO_ORG', 'ADO_Org', 'ADOORG'])
gh_org = get_val('target.organization', ['GH_ORG', 'GH_Org', 'GHORG'])
ado_pat = get_val('source.pat', ['ADO_PAT', 'AZDO_PAT'])
gh_pat = get_val('target.pat', ['GH_PAT', 'GITHUB_PAT'])
ado_project = get_val('source.project', ['ADO_PROJECT', 'ADO_Project'])

pipeline_ids = config.get('PIPELINE_IDS')
if not pipeline_ids or (isinstance(pipeline_ids, str) and pipeline_ids.startswith('\$(')):
    pipeline_ids = os.environ.get('PIPELINE_IDS', '')
if isinstance(pipeline_ids, list):
    pipeline_ids = ','.join(map(str, pipeline_ids))

pipeline_type = get_val('PIPELINE_TYPE', ['PIPELINE_TYPE'], 'build')
migrate_mode = get_val('MIGRATE_MODE', ['MIGRATE_MODE', 'MODE'], 'dry-run')

repo_map = config.get('PIPELINE_REPO_MAP')
if not repo_map or (isinstance(repo_map, str) and repo_map.startswith('\$(')):
    repo_map = os.environ.get('PIPELINE_REPO_MAP', '')
if isinstance(repo_map, dict):
    repo_map_str = ','.join(f'{k}={v}' for k, v in repo_map.items())
elif isinstance(repo_map, list):
    repo_map_str = ','.join(repo_map)
else:
    repo_map_str = str(repo_map)

reusable_ids = config.get('REUSABLE_PIPELINE_IDS')
if not reusable_ids or (isinstance(reusable_ids, str) and reusable_ids.startswith('\$(')):
    reusable_ids = os.environ.get('REUSABLE_PIPELINE_IDS', '')
if isinstance(reusable_ids, list):
    reusable_ids = ','.join(map(str, reusable_ids))

gh_repo = get_val('GH_REPO', ['GH_REPO', 'GHRepo'])

print(f'export CONF_ADO_ORG=\"{ado_org}\"')
print(f'export CONF_GH_ORG=\"{gh_org}\"')
print(f'export CONF_ADO_PAT=\"{ado_pat}\"')
print(f'export CONF_GH_PAT=\"{gh_pat}\"')
print(f'export CONF_ADO_PROJECT=\"{ado_project}\"')
print(f'export CONF_PIPELINE_IDS=\"{pipeline_ids}\"')
print(f'export CONF_PIPELINE_TYPE=\"{pipeline_type}\"')
print(f'export CONF_MIGRATE_MODE=\"{migrate_mode}\"')
print(f'export CONF_PIPELINE_REPO_MAP=\"{repo_map_str}\"')
print(f'export CONF_REUSABLE_PIPELINE_IDS=\"{reusable_ids}\"')
print(f'export CONF_GH_REPO=\"{gh_repo}\"')
")

eval "$config_exports"

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

    python3 -c "
import json, os, re
try:
    with open('$OutputDir/tmp_build_pipelines.json', 'r', encoding='utf-8') as f:
        build_data = json.load(f)
except Exception as e:
    build_data = {'value':[]}
    print('Error loading build definitions:', e)

try:
    with open('$OutputDir/tmp_release_pipelines.json', 'r', encoding='utf-8') as f:
        release_data = json.load(f)
except Exception as e:
    release_data = {'value':[]}
    print('Error loading release definitions:', e)

print('\n=== Available Pipelines ===')
print(f'%-8s %-45s %-12s %s' % ('ID', 'Name', 'Type', 'Path'))
print('-' * 90)

build_list = sorted(build_data.get('value', []), key=lambda x: x.get('id', 0))
for p in build_list:
    p_type = 'YAML' if p.get('process', {}).get('type') == 2 else 'Classic Build'
    print(f'%-8s %-45s %-12s %s' % (p.get('id'), p.get('name')[:44], p_type, p.get('path')))

release_list = sorted(release_data.get('value', []), key=lambda x: x.get('id', 0))
for r in release_list:
    print(f'%-8s %-45s %-12s %s' % (r.get('id'), r.get('name')[:44], 'Release', r.get('path')))
"
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
        python3 "$(dirname "$0")/generate_migration_dashboard.py" rewrite-config "$ConfigFilePath" "$ReusablesTargetRepo" "$ReusablesRef"
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
        # Only process if in allowed reusable IDs list
        if [ -n "$CONF_REUSABLE_PIPELINE_IDS" ] && [ -z "${reusable_ids_dict[$pid]}" ]; then
            echo -e "${YELLOW}  Pipeline $pid not in REUSABLE_PIPELINE_IDS -- SKIPPING.${NC}"
            continue
        fi

        # Find consumer repo mapping
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

# Fetch pipelines list
if [ "$CONF_PIPELINE_TYPE" = "release" ]; then
    pipelinesUrl="https://vsrm.dev.azure.com/$CONF_ADO_ORG/$CONF_ADO_PROJECT/_apis/release/definitions?api-version=7.1"
else
    pipelinesUrl="$adoOrgUrl/$CONF_ADO_PROJECT/_apis/build/definitions?api-version=7.1&includeAllProperties=true"
fi

echo -e "${YELLOW}Fetching pipeline configurations from ADO...${NC}"
curl -s -k -H "Authorization: Basic $base64Auth" "$pipelinesUrl" > "$OutputDir/tmp_pipelines.json" || echo '{"value":[]}' > "$OutputDir/tmp_pipelines.json"

# Process definitions and filter in Python, writing results directly toresults_list.json
resultsFile="$OutputDir/results.json"
echo "[]" > "$resultsFile"

results_list_file="$OutputDir/results_list.json"

python3 -c "
import json, os
try:
    with open('$OutputDir/tmp_pipelines.json', 'r', encoding='utf-8') as f:
        data = json.load(f)
except Exception as e:
    data = {'value':[]}
    print('Error loading configurations:', e)

pids = [int(x) for x in '$CONF_PIPELINE_IDS'.split(',')] if '$CONF_PIPELINE_IDS' else []

filtered = []
for p in data.get('value', []):
    if not pids or int(p.get('id')) in pids:
        filtered.append({
            'id': p.get('id'),
            'name': p.get('name'),
            'repo': p.get('repository', {}).get('name') if p.get('repository') else ''
        })

with open('$results_list_file', 'w', encoding='utf-8') as f:
    json.dump(filtered, f)

print(f'Found {len(filtered)} pipeline(s) to process')
"

rm -f "$OutputDir/tmp_pipelines.json"

# Read selected from json list
len_selected=$(python3 -c "import json; print(len(json.load(open('$results_list_file'))))")

for ((i=0; i<len_selected; i++)); do
    pipeline_id=$(python3 -c "import json; print(json.load(open('$results_list_file'))[$i]['id'])")
    pipeline_name=$(python3 -c "import json; print(json.load(open('$results_list_file'))[$i]['name'])")
    pipeline_repo=$(python3 -c "import json; print(json.load(open('$results_list_file'))[$i]['repo'])")

    echo -e "\n  Processing: $pipeline_name (ID: $pipeline_id)"

    # Check if this pipeline is in REUSABLE_PIPELINE_IDS (skip if migrating to avoid duplicates)
    if [ "$CONF_MIGRATE_MODE" = "migrate" ] && [ -n "${reusable_ids_dict[$pipeline_id]}" ]; then
        echo -e "${YELLOW}    Pipeline $pipeline_id is in REUSABLE_PIPELINE_IDS -- already handled by MigrateReusables job. Skipping.${NC}"
        
        # Append skip result
        python3 -c "
import json
try:
    with open('$resultsFile', 'r', encoding='utf-8') as f:
        res = json.load(f)
except Exception:
    res = []
res.append({
    'Pipeline': '$pipeline_name',
    'Id': $pipeline_id,
    'TargetRepo': '${repo_map_dict[$pipeline_id]:-$CONF_GH_REPO}',
    'Mode': '$CONF_MIGRATE_MODE',
    'Status': 'SKIPPED',
    'OutputDir': ''
})
with open('$resultsFile', 'w', encoding='utf-8') as f:
    json.dump(res, f)
"
        continue
    fi

    # Determine target repo
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

    # Set output dir
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

    # Check for config path
    if [ -n "$ConfigFilePath" ] && [ -f "$ConfigFilePath" ]; then
        importerArgs+=("--config-file-path" "$ConfigFilePath")
    elif [ -n "$ImporterConfigFile" ] && [ -f "$ImporterConfigFile" ]; then
        importerArgs+=("--config-file-path" "$ImporterConfigFile")
    fi

    echo -e "    Command: gh ${importerArgs[*]}"
    
    # Run
    set +e
    gh "${importerArgs[@]}" > "$outputSubDir/importer_exec.log" 2>&1
    exitCode=$?
    set -e

    outputStr=$(cat "$outputSubDir/importer_exec.log")
    echo "    --- actions-importer output ---"
    cat "$outputSubDir/importer_exec.log"
    echo "    --- end output ---"

    # Evaluate status
    status="SUCCESS"
    if [ $exitCode -ne 0 ]; then
        status="FAILED"
    elif [[ "$outputStr" =~ "error" ]] || [[ "$outputStr" =~ "failed" ]]; then
        status="FAILED"
    elif [[ "$outputStr" =~ "partially" ]]; then
        status="PARTIAL"
    fi

    # Check if yaml generated
    yamlFiles=$(find "$outputSubDir" -name "*.yml" -o -name "*.yaml" 2>/dev/null || echo "")
    if [ "$CONF_MIGRATE_MODE" = "dry-run" ] && [ -z "$yamlFiles" ] && [ "$status" = "SUCCESS" ]; then
        status="NO_OUTPUT"
    fi

    color="${RED}"
    if [ "$status" = "SUCCESS" ]; then color="${GREEN}"; fi
    if [ "$status" = "PARTIAL" ] || [ "$status" = "NO_OUTPUT" ]; then color="${YELLOW}"; fi
    echo -e "    ${color}$status${NC}"

    python3 -c "
import json
try:
    with open('$resultsFile', 'r', encoding='utf-8') as f:
        res = json.load(f)
except Exception:
    res = []
res.append({
    'Pipeline': '$pipeline_name',
    'Id': $pipeline_id,
    'TargetRepo': '$targetRepo',
    'Mode': '$CONF_MIGRATE_MODE',
    'Status': '$status',
    'OutputDir': '$outputSubDir'
})
with open('$resultsFile', 'w', encoding='utf-8') as f:
    json.dump(res, f)
"
done

# Cleanup temp files
rm -f "$results_list_file"

# Generate CSV summary
csvFile="$OutputDir/pipeline-migration-$(date +%Y%m%d-%H%M%S).csv"
python3 -c "
import json, csv
with open('$resultsFile', 'r') as f:
    data = json.load(f)
if data:
    keys = data[0].keys()
    with open('$csvFile', 'w', newline='') as f:
        dict_writer = csv.DictWriter(f, keys)
        dict_writer.writeheader()
        dict_writer.writerows(data)
" || true

# Generate HTML Dashboard
python3 "$(dirname "$0")/generate_migration_dashboard.py" generate-dashboard "$OutputDir" "$CONF_ADO_ORG" "$CONF_ADO_PROJECT" "$CONF_GH_ORG" "$resultsFile"

# Cleanup token environment variables
unset GITHUB_ACCESS_TOKEN
unset AZURE_DEVOPS_ACCESS_TOKEN

echo -e "\n${GREEN}Migration complete.${NC}"
