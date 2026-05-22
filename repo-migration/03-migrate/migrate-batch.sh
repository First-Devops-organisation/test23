#!/usr/bin/env bash

set -euo pipefail

# SYNOPSIS
#     Migrates MULTIPLE repos from ADO to GitHub in batch using GEI (gh ado2gh).
#     Calls migrate-single.sh for each repo - same audit + dashboard per repo.
#     Converted from PowerShell to native Linux Bash.

ADOOrg=""
ADOProject=""
GHOrg=""
ConfigPath=""
BatchName=""
RepoListCsv=""
OutputDir=""
MaxParallel=3
SkipAudit=false
DryRun=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG_PATH="${SCRIPT_DIR}/../config/repo-migration-config.json"
DEFAULT_OUTPUT_DIR="${SCRIPT_DIR}/../output"

while [[ $# -gt 0 ]]; do
  case $1 in
    --ado-org|-ADOOrg) ADOOrg="$2"; shift 2 ;;
    --ado-project|-ADOProject) ADOProject="$2"; shift 2 ;;
    --github-org|-GHOrg) GHOrg="$2"; shift 2 ;;
    --config-path|-ConfigPath) ConfigPath="$2"; shift 2 ;;
    --batch-name|-BatchName) BatchName="$2"; shift 2 ;;
    --repo-list-csv|-RepoListCsv) RepoListCsv="$2"; shift 2 ;;
    --output-dir|-OutputDir) OutputDir="$2"; shift 2 ;;
    --max-parallel|-MaxParallel) MaxParallel="$2"; shift 2 ;;
    --skip-audit|-SkipAudit) SkipAudit=true; shift ;;
    --dry-run|-DryRun) DryRun=true; shift ;;
    *) echo "Error: Unknown parameter: $1" >&2; exit 1 ;;
  esac
done

ConfigPath="${ConfigPath:-$DEFAULT_CONFIG_PATH}"
OutputDir="${OutputDir:-$DEFAULT_OUTPUT_DIR}"

# Trim whitespace
ADOOrg=$(echo "$ADOOrg" | xargs || true)
ADOProject=$(echo "$ADOProject" | xargs || true)
GHOrg=$(echo "$GHOrg" | xargs || true)
BatchName=$(echo "$BatchName" | xargs || true)
RepoListCsv=$(echo "$RepoListCsv" | xargs || true)

# Validate PATs
ghPat="${GH_PAT:-}"
adoPat="${ADO_PAT:-}"
if [ -z "$ghPat" ]; then  echo "Error: Set GH_PAT environment variable" >&2; exit 1; fi
if [ -z "$adoPat" ]; then echo "Error: Set ADO_PAT environment variable" >&2; exit 1; fi
export GH_TOKEN="$ghPat"

singleScript="${SCRIPT_DIR}/migrate-single.sh"
if [ ! -f "$singleScript" ]; then
  echo "Error: migrate-single.sh not found at: $singleScript" >&2
  exit 1
fi
chmod +x "$singleScript"

# Build repo list
adoRepos=()
ghRepos=()
declare -A seen

if [ -n "$RepoListCsv" ]; then
  if [ ! -f "$RepoListCsv" ]; then
    echo "Error: CSV not found: $RepoListCsv" >&2
    exit 1
  fi
  first_line=true
  while IFS=',' read -r ado gh || [ -n "$ado" ]; do
    if [ "$first_line" = true ]; then
      first_line=false
      continue
    fi
    # Trim Windows newlines / spaces
    ado=$(echo "$ado" | tr -d '\r' | xargs || true)
    gh=$(echo "$gh" | tr -d '\r' | xargs || true)
    
    if [ -z "$ado" ]; then
      continue
    fi
    if [ -z "$gh" ]; then
      gh="$ado"
    fi
    
    if [ -z "${seen[$ado]:-}" ]; then
      seen[$ado]=1
      adoRepos+=("$ado")
      ghRepos+=("$gh")
    fi
  done < "$RepoListCsv"
  echo "Loaded ${#adoRepos[@]} repos from CSV: $RepoListCsv"
else
  if [ ! -f "$ConfigPath" ]; then
    echo "Error: Config not found: $ConfigPath" >&2
    exit 1
  fi
  
  # Read exclusions
  exclusions=$(jq -r '.exclusions.repos[]? // empty' "$ConfigPath" 2>/dev/null | xargs || true)
  declare -A excluded
  for r in $exclusions; do
    excluded[$r]=1
  done
  
  # Find batch repos using jq.
  if [ -n "$BatchName" ]; then
    batches_json=$(jq --arg bn "$BatchName" '.batches[] | select(.name == $bn)' "$ConfigPath" 2>/dev/null || true)
    if [ -z "$batches_json" ]; then
      echo "Error: Batch '$BatchName' not found in config" >&2
      exit 1
    fi
    repos=$(echo "$batches_json" | jq -r '.repos[]? // empty' | tr -d '\r')
  else
    repos=$(jq -r '.batches[].repos[]? // empty' "$ConfigPath" 2>/dev/null | tr -d '\r' || true)
  fi
  
  while read -r name; do
    name=$(echo "$name" | xargs || true)
    if [ -z "$name" ]; then
      continue
    fi
    if [ -n "${excluded[$name]:-}" ]; then
      echo "  [SKIPPING] $name (listed in exclusions)"
      continue
    fi
    if [ -z "${seen[$name]:-}" ]; then
      seen[$name]=1
      adoRepos+=("$name")
      ghRepos+=("$name")
    fi
  done <<< "$repos"
  echo "Loaded ${#adoRepos[@]} repos from config batch(es) (after exclusions)"
fi

if [ ${#adoRepos[@]} -eq 0 ]; then
  echo "Error: No repos found to migrate." >&2
  exit 1
fi

# Target repo visibility
targetVisibility="private"
if [ -f "$ConfigPath" ]; then
  cfg_vis=$(jq -r '.migration.targetRepoVisibility // empty' "$ConfigPath" | tr -d '\r')
  if [ -n "$cfg_vis" ]; then
    targetVisibility="$cfg_vis"
  fi
fi
echo "  Repo visibility: $targetVisibility"

# Output folder
reportDir="$OutputDir/reports"
mkdir -p "$reportDir"

echo ""
echo "======================================================"
echo "  BATCH MIGRATION"
echo "  ADO:         $ADOOrg / $ADOProject"
echo "  GitHub:      $GHOrg"
echo "  Repos:       ${#adoRepos[@]}"
echo "  MaxParallel: $MaxParallel"
echo "  DryRun:      $DryRun"
echo "======================================================"

successRepos=()
failedRepos=()
totalRepos=${#adoRepos[@]}

# Loop sequentially through the repos
for ((i=0; i<totalRepos; i++)); do
  repoIndex=$((i + 1))
  adoRepo="${adoRepos[$i]}"
  ghRepo="${ghRepos[$i]}"
  
  echo ""
  echo "[$repoIndex/$totalRepos] Migrating: $adoRepo -> $ghRepo"
  
  # Prepare params
  migParams=(
    --ado-org "$ADOOrg"
    --ado-project "$ADOProject"
    --ado-repo "$adoRepo"
    --github-org "$GHOrg"
    --github-repo "$ghRepo"
    --output-dir "$OutputDir"
    --target-repo-visibility "$targetVisibility"
  )
  if [ "$SkipAudit" = "true" ]; then
    migParams+=(--skip-audit)
  fi
  if [ "$DryRun" = "true" ]; then
    migParams+=(--dry-run)
  fi
  
  set +e
  "$singleScript" "${migParams[@]}"
  exitCode=$?
  set -e
  
  if [ $exitCode -eq 0 ]; then
    echo "  [$adoRepo] Completed successfully."
    successRepos+=("$adoRepo")
  else
    echo "  [$adoRepo] FAILED with exit code $exitCode"
    failedRepos+=("$adoRepo")
  fi
done

echo ""
echo "All $totalRepos repo(s) processed."

# Collect per-repo results into a batch summary
echo ""
echo "Generating batch summary report..."

# Initialize JSON array
json_array="[]"

# Initialize CSV content with headers
csv_content="\"ADORepo\",\"GHRepo\",\"State\",\"Branches\",\"Tags\",\"Commits\",\"PRs\",\"DashboardPath\"\n"

for ((i=0; i<totalRepos; i++)); do
  adoRepo="${adoRepos[$i]}"
  ghRepo="${ghRepos[$i]}"
  stateFile="$OutputDir/logs/migration-state-$ghRepo.txt"
  auditDir="$OutputDir/audit/$ghRepo"
  
  state="UNKNOWN"
  if [ -f "$stateFile" ]; then
    state=$(cat "$stateFile" | xargs || true)
  fi
  
  get_val() {
    local f="$1"
    if [ -f "$auditDir/$f" ]; then
      cat "$auditDir/$f" | xargs || true
    else
      echo "N/A"
    fi
  }
  
  branches=$(get_val "gh-branch-count.txt")
  tags=$(get_val "gh-tag-count.txt")
  commits=$(get_val "gh-commit-count.txt")
  prs=$(get_val "gh-pr-count.txt")
  dashPath="$OutputDir/dashboard/$ghRepo/migration-report-$ghRepo.html"
  
  # Add to JSON
  json_array=$(jq --arg ado "$adoRepo" --arg gh "$ghRepo" --arg st "$state" --arg br "$branches" --arg tg "$tags" --arg cm "$commits" --arg pr "$prs" --arg dp "$dashPath" \
    '. + [{ADORepo: $ado, GHRepo: $gh, State: $st, Branches: $br, Tags: $tg, Commits: $cm, PRs: $pr, DashboardPath: $dp}]' <<< "$json_array")
    
  # Add to CSV
  csv_content+="\"$adoRepo\",\"$ghRepo\",\"$state\",\"$branches\",\"$tags\",\"$commits\",\"$prs\",\"$dashPath\"\n"
done

summaryJson="$reportDir/batch-migration-summary.json"
summaryCsv="$reportDir/batch-migration-summary.csv"

echo "$json_array" | jq . > "$summaryJson"
echo -ne "$csv_content" > "$summaryCsv"

# Print final summary table
echo ""
echo "======================================================"
echo "  BATCH MIGRATION SUMMARY"
echo "======================================================"

printf "%-25s | %-25s | %-12s | %-8s | %-6s | %-8s | %-6s\n" "ADO Repo" "GH Repo" "State" "Branches" "Tags" "Commits" "PRs"
printf -- "--------------------------|---------------------------|--------------|----------|------|----------|------\n"

for ((i=0; i<totalRepos; i++)); do
  adoRepo="${adoRepos[$i]}"
  ghRepo="${ghRepos[$i]}"
  
  state=$(echo "$json_array" | jq -r ".[$i].State")
  branches=$(echo "$json_array" | jq -r ".[$i].Branches")
  tags=$(echo "$json_array" | jq -r ".[$i].Tags")
  commits=$(echo "$json_array" | jq -r ".[$i].Commits")
  prs=$(echo "$json_array" | jq -r ".[$i].PRs")
  
  printf "%-25.25s | %-25.25s | %-12s | %-8s | %-6s | %-8s | %-6s\n" "$adoRepo" "$ghRepo" "$state" "$branches" "$tags" "$commits" "$prs"
done

successCount=$(echo "$json_array" | jq '[.[] | select(.State == "COMPLETE" or .State == "SKIPPED" or .State == "DRY_RUN")] | length')
failCount=$(echo "$json_array" | jq '[.[] | select(.State == "FAILED" or .State == "UNKNOWN")] | length')

echo ""
echo "  Total   : $totalRepos"
echo "  Success : $successCount"
echo "  Failed  : $failCount"
echo ""
echo "  Summary JSON: $summaryJson"
echo "  Summary CSV  : $summaryCsv"

exit 0
