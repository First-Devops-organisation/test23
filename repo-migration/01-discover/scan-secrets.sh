#!/usr/bin/env bash

# SYNOPSIS
#     Scans all repos for exposed secrets using gitleaks (parallel).

set -euo pipefail

# Resolve script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG_PATH="${SCRIPT_DIR}/../config/repo-migration-config.json"

CONFIG_PATH="$DEFAULT_CONFIG_PATH"
SIZE_FILTER="All"
SIZE_THRESHOLD_MB=1024
THROTTLE_LIMIT=5
BATCH_INDEX=0
BATCH_TOTAL=1
MIGRATION_MODE="Batch"
SINGLE_REPO_NAME=""

# Parse parameters
while [ $# -gt 0 ]; do
  case "$1" in
    -ConfigPath)
      CONFIG_PATH="$2"
      shift 2
      ;;
    -SizeFilter)
      SIZE_FILTER="$2"
      shift 2
      ;;
    -SizeThresholdMB)
      SIZE_THRESHOLD_MB="$2"
      shift 2
      ;;
    -ThrottleLimit)
      THROTTLE_LIMIT="$2"
      shift 2
      ;;
    -BatchIndex)
      BATCH_INDEX="$2"
      shift 2
      ;;
    -BatchTotal)
      BATCH_TOTAL="$2"
      shift 2
      ;;
    -MigrationMode)
      MIGRATION_MODE="$2"
      shift 2
      ;;
    -SingleRepoName)
      SINGLE_REPO_NAME=$(echo "$2" | xargs)
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [ ! -f "$CONFIG_PATH" ]; then
  echo "Error: Config not found at $CONFIG_PATH." >&2
  exit 1
fi

# Load config
config_json=$(cat "$CONFIG_PATH")

resolve_config_value() {
  local val="$1"
  if [[ "$val" =~ ^\$\((.*)\)$ ]]; then
    local var_name="${BASH_REMATCH[1]}"
    echo "${!var_name:-}"
  else
    echo "$val"
  fi
}

reportDir_raw=$(echo "$config_json" | jq -r '.output.reportDir // "./output/reports"')
reportDir=$(resolve_config_value "$reportDir_raw")

logDir_raw=$(echo "$config_json" | jq -r '.output.logDir // "./output/logs"')
logDir=$(resolve_config_value "$logDir_raw")

cloneDir_raw=$(echo "$config_json" | jq -r '.migration.cloneTempDir // "./tmp/clones"')
cloneDir=$(resolve_config_value "$cloneDir_raw")

for d in "$reportDir" "$logDir" "$cloneDir"; do
  mkdir -p "$d"
done

# Verify gitleaks
if ! command -v gitleaks >/dev/null 2>&1; then
  echo "Error: gitleaks not found. Install it or run 02-prep/install-tools.sh" >&2
  exit 1
fi

# Identify repos to scan
reposToScan=()
if [ "${MIGRATION_MODE,,}" = "single" ]; then
  if [ -z "$SINGLE_REPO_NAME" ]; then
    SINGLE_REPO_NAME=$(echo "$config_json" | jq -r '.migration.singleRepo // empty' | xargs)
    echo "Filter: SingleRepoName was blank - using default from config: $SINGLE_REPO_NAME"
  fi
  if [ -n "$SINGLE_REPO_NAME" ]; then
    reposToScan+=("$SINGLE_REPO_NAME")
  fi
else
  # Batch mode
  batchFilter="$SINGLE_REPO_NAME"
  if [ -n "$batchFilter" ] && [ "$batchFilter" != " " ]; then
    repos_in_batch=$(echo "$config_json" | jq -r --arg bf "$batchFilter" '.batches[] | select(.name == $bf) | .repos[] // empty')
    while read -r r; do
      if [ -n "$r" ]; then reposToScan+=("$r"); fi
    done <<< "$repos_in_batch"
  else
    all_repos=$(echo "$config_json" | jq -r '.batches[].repos[] // empty')
    while read -r r; do
      if [ -n "$r" ]; then reposToScan+=("$r"); fi
    done <<< "$all_repos"
  fi
fi

if [ ${#reposToScan[@]} -eq 0 ]; then
  echo "Error: No repositories identified for scanning. Check config.json or pipeline parameters." >&2
  exit 1
fi

# Fetch metadata from ADO
adoPat_raw=$(echo "$config_json" | jq -r '.source.pat // empty')
adoPat=$(resolve_config_value "$adoPat_raw")

adoOrg_raw=$(echo "$config_json" | jq -r '.source.organization // empty')
adoOrg=$(resolve_config_value "$adoOrg_raw")
adoOrg="${adoOrg%/}"

adoProj_raw=$(echo "$config_json" | jq -r '.source.project // empty')
adoProj=$(resolve_config_value "$adoProj_raw")

if [ -z "$adoPat" ]; then echo "Error: Set ADO_PAT environment variable" >&2; exit 1; fi
if [ -z "$adoOrg" ]; then echo "Error: Set ADO_ORG environment variable" >&2; exit 1; fi
if [ -z "$adoProj" ]; then echo "Error: Set ADO_PROJECT environment variable" >&2; exit 1; fi

echo "Fetching metadata for ${#reposToScan[@]} repos from Azure DevOps..."
valid_repos="[]"
for rName in "${reposToScan[@]}"; do
  encodedName=$(jq -rn --arg val "$rName" '$val|@uri')
  apiUrl="${adoOrg}/${adoProj}/_apis/git/repositories/${encodedName}?api-version=7.1"
  repoData=$(curl -s -f -u ":$adoPat" -H "Accept: application/json" "$apiUrl" || true)
  if [ -n "$repoData" ]; then
    size_bytes=$(echo "$repoData" | jq -r '.size // 0')
    size_mb=$(awk -v size="$size_bytes" 'BEGIN { printf "%.2f", size / 1048576 }')
    repo_name=$(echo "$repoData" | jq -r '.name')
    web_url=$(echo "$repoData" | jq -r '.webUrl // empty')
    remote_url=$(echo "$repoData" | jq -r '.remoteUrl // empty')
    
    valid_repos=$(echo "$valid_repos" | jq \
      --arg proj "$adoProj" \
      --arg name "$repo_name" \
      --argjson sb "$size_bytes" \
      --argjson smb "$size_mb" \
      --arg url "$web_url" \
      --arg rurl "$remote_url" \
      '. + [{
        Project: $proj,
        Name: $name,
        SizeMB: $smb,
        Url: $url,
        RemoteUrl: $rurl,
        SizeBytes: $sb
      }]')
  else
    echo "  [WARN] Could not fetch metadata for '$rName' (repo might not exist or PAT has no access). Skipping." >&2
  fi
done

# Filter out exclusions
exclusions_json=$(echo "$config_json" | jq -c '.exclusions.repos // []')
repos_filtered=$(echo "$valid_repos" | jq --argjson excl "$exclusions_json" 'map(select(.Name as $n | ($excl | index($n)) == null))')

# Filter repos by size if requested
total_count=$(echo "$repos_filtered" | jq '. | length')
if [ "${SIZE_FILTER,,}" = "small" ]; then
  repos_filtered=$(echo "$repos_filtered" | jq --argjson thresh "$SIZE_THRESHOLD_MB" 'map(select(.SizeMB < $thresh))')
  echo "Filter: Small repos only (< ${SIZE_THRESHOLD_MB} MB) - $(echo "$repos_filtered" | jq '. | length') of $total_count repos"
elif [ "${SIZE_FILTER,,}" = "large" ]; then
  repos_filtered=$(echo "$repos_filtered" | jq --argjson thresh "$SIZE_THRESHOLD_MB" 'map(select(.SizeMB >= $thresh))')
  echo "Filter: Large repos only (>= ${SIZE_THRESHOLD_MB} MB) - $(echo "$repos_filtered" | jq '. | length') of $total_count repos"
fi

# Sort repos smallest-first
repos_sorted=$(echo "$repos_filtered" | jq 'sort_by(.SizeMB)')

# Batch splitting for matrix strategy
if [ "$BATCH_TOTAL" -gt 1 ]; then
  repos_sorted=$(echo "$repos_sorted" | jq --argjson bi "$BATCH_INDEX" --argjson bt "$BATCH_TOTAL" '
    to_entries | map(select(.key % $bt == $bi)) | map(.value)
  ')
  echo "Batch $((BATCH_INDEX + 1)) of ${BATCH_TOTAL}: scanning $(echo "$repos_sorted" | jq '. | length') repos on this agent"
fi

final_len=$(echo "$repos_sorted" | jq '. | length')

batchSuffix=""
if [ "$BATCH_TOTAL" -gt 1 ]; then
  batchSuffix="-batch${BATCH_INDEX}"
fi

fileSuffix=""
if [ "${SIZE_FILTER,,}" != "all" ]; then
  fileSuffix="-${SIZE_FILTER,,}${batchSuffix}"
else
  fileSuffix="${batchSuffix}"
fi

if [ "$final_len" -eq 0 ]; then
  echo "No repositories assigned to this agent (Index $BATCH_INDEX). Generating empty report..."
  htmlPath="${reportDir}/secret-scan-report${fileSuffix}.html"
  echo "<html><body><h1>No repositories assigned to this agent.</h1></body></html>" > "$htmlPath"
  
  summaryJson="${reportDir}/secret-scan-summary${fileSuffix}.json"
  echo "[]" > "$summaryJson"
  exit 0
fi

echo "=== Scanning $final_len repos for secrets [$SIZE_FILTER] (ThrottleLimit=$THROTTLE_LIMIT) ==="

# Temporary directory for parallel jobs
tmp_job_dir=$(mktemp -d 2>/dev/null || mktemp -d -t 'secrets-jobs')

process_repo() {
  local repo_json="$1"
  local job_id="$2"
  local adoPat="$3"
  local cloneDir="$4"
  local logDir="$5"
  local tmp_job_dir="$6"

  local proj=$(echo "$repo_json" | jq -r '.Project')
  local name=$(echo "$repo_json" | jq -r '.Name')
  local size_mb=$(echo "$repo_json" | jq -r '.SizeMB')
  local size_bytes=$(echo "$repo_json" | jq -r '.SizeBytes // 0')
  local remote_url=$(echo "$repo_json" | jq -r '.RemoteUrl')

  local repoLabel="[$proj] $name"
  local clonePath="${cloneDir}/${name}-${job_id}.git"
  local reportFile="${logDir}/gitleaks-${name}.json"
  
  # Empty repo check
  if [ "$size_bytes" -eq 0 ]; then
    echo "  CLEAN (Empty) - $repoLabel"
    jq -n \
      --arg proj "$proj" \
      --arg name "$name" \
      --argjson smb "$size_mb" \
      '{Project: $proj, Name: $name, SizeMB: $smb, FindingsCount: 0, Status: "CLEAN"}' > "${tmp_job_dir}/sum_${job_id}.json"
    echo "[]" > "${tmp_job_dir}/find_${job_id}.json"
    return
  fi

  # Clone bare
  local cloneUrl=$(echo "$remote_url" | sed -E 's|://[^@]+@|://|')
  local cloneAuth=$(echo -n "pat:${adoPat}" | base64 | tr -d '\r\n')
  
  export GIT_LFS_SKIP_SMUDGE='1'
  echo "  Cloning $repoLabel - full history ($size_mb MB)"
  
  local clone_success=1
  git -c "http.extraHeader=Authorization: Basic $cloneAuth" -c "lfs.fetchexclude=*" clone --bare --quiet "$cloneUrl" "$clonePath" 2>&1 || clone_success=0

  if [ "$clone_success" -eq 0 ]; then
    echo "  [WARN] Clone failed for ${repoLabel}" >&2
    jq -n \
      --arg proj "$proj" \
      --arg name "$name" \
      --argjson smb "$size_mb" \
      '{Project: $proj, Name: $name, SizeMB: $smb, FindingsCount: -1, Status: "CLONE_FAILED"}' > "${tmp_job_dir}/sum_${job_id}.json"
    echo "[]" > "${tmp_job_dir}/find_${job_id}.json"
    return
  fi

  # Run gitleaks
  local exitCode=0
  gitleaks detect --source "$clonePath" --report-path "$reportFile" --report-format json --no-banner >/dev/null 2>&1 || exitCode=$?

  if [ "$exitCode" -eq 0 ]; then
    echo "  CLEAN - $repoLabel"
    jq -n \
      --arg proj "$proj" \
      --arg name "$name" \
      --argjson smb "$size_mb" \
      '{Project: $proj, Name: $name, SizeMB: $smb, FindingsCount: 0, Status: "CLEAN"}' > "${tmp_job_dir}/sum_${job_id}.json"
    echo "[]" > "${tmp_job_dir}/find_${job_id}.json"
  elif [ "$exitCode" -eq 1 ] && [ -f "$reportFile" ]; then
    local findings_json=$(cat "$reportFile")
    local count=$(echo "$findings_json" | jq '. | length')
    echo "  [WARN] SECRETS FOUND: $count finding(s) in $repoLabel" >&2

    # Parse and enrich findings
    local enriched_findings="[]"
    local idx=0
    while read -r finding; do
      if [ -z "$finding" ]; then continue; fi

      local commit=$(echo "$finding" | jq -r '.Commit // empty')
      local rule_id=$(echo "$finding" | jq -r '.RuleID')
      local secret_val=$(echo "$finding" | jq -r '.Secret // .Match // ""' | xargs)
      local file_path=$(echo "$finding" | jq -r '.File')
      local start_line=$(echo "$finding" | jq -r '.StartLine // 0')
      local author=$(echo "$finding" | jq -r '.Author // "Unknown"')
      local date_val=$(echo "$finding" | jq -r '.Date // "Unknown"')

      local branchName="UNKNOWN"
      if [ -n "$commit" ] && [ "$commit" != "null" ]; then
        local branchOutput=$(git --git-dir="$clonePath" branch --contains "$commit" 2>/dev/null || true)
        if [ -n "$branchOutput" ]; then
          local cleaned_branches
          cleaned_branches=$(echo "$branchOutput" | sed 's/^[ *]*//' | grep -v '^$')
          read -r branchName <<< "$cleaned_branches"
          if [ -z "$branchName" ]; then branchName="UNKNOWN"; fi
        fi
      fi

      local commit_short="N/A"
      if [ -n "$commit" ] && [ "$commit" != "null" ]; then
        commit_short="${commit:0:12}"
      fi

      enriched_findings=$(echo "$enriched_findings" | jq \
        --arg repo "$name" \
        --arg secName "${rule_id^^}" \
        --arg secVal "$secret_val" \
        --arg fPath "$file_path" \
        --argjson lNum "$start_line" \
        --arg bName "$branchName" \
        --arg cHash "$commit_short" \
        --arg rId "$rule_id" \
        --arg aut "$author" \
        --arg dt "$date_val" \
        '. + [{
          Repo: $repo,
          SecretName: $secName,
          SecretValue: $secVal,
          File: $fPath,
          LineNumber: $lNum,
          Branch: $bName,
          CommitHash: $cHash,
          Source: "gitleaks",
          RuleID: $rId,
          Author: $aut,
          Date: $dt
        }]')

    done <<< "$(echo "$findings_json" | jq -c '.[]')"

    jq -n \
      --arg proj "$proj" \
      --arg name "$name" \
      --argjson smb "$size_mb" \
      --argjson cnt "$count" \
      '{Project: $proj, Name: $name, SizeMB: $smb, FindingsCount: $cnt, Status: "SECRETS_FOUND"}' > "${tmp_job_dir}/sum_${job_id}.json"
    
    echo "$enriched_findings" > "${tmp_job_dir}/find_${job_id}.json"
  else
    echo "  [WARN] gitleaks returned exit code $exitCode for $repoLabel" >&2
    jq -n \
      --arg proj "$proj" \
      --arg name "$name" \
      --argjson smb "$size_mb" \
      '{Project: $proj, Name: $name, SizeMB: $smb, FindingsCount: -1, Status: "SCAN_ERROR"}' > "${tmp_job_dir}/sum_${job_id}.json"
    echo "[]" > "${tmp_job_dir}/find_${job_id}.json"
  fi

  # Cleanup clone dir
  rm -rf "$clonePath"
}

# Run in parallel with throttling
repos_list=$(echo "$repos_sorted" | jq -c '.[]')
job_idx=0
running_jobs=0

start_time=$(date +%s)

while read -r repo_json; do
  if [ -z "$repo_json" ]; then continue; fi

  process_repo "$repo_json" "$job_idx" "$adoPat" "$cloneDir" "$logDir" "$tmp_job_dir" &

  job_idx=$((job_idx + 1))
  running_jobs=$((running_jobs + 1))

  if [ "$running_jobs" -ge "$THROTTLE_LIMIT" ]; then
    wait -n
    running_jobs=$((running_jobs - 1))
  fi
done <<< "$repos_list"

wait

end_time=$(date +%s)
elapsed_seconds=$((end_time - start_time))
elapsed_formatted=$(printf "%02d:%02d:%02d" $((elapsed_seconds/3600)) $(( (elapsed_seconds%3600)/60 )) $((elapsed_seconds%60)) )

# Clean up temp clone dir
if [ -d "$cloneDir" ]; then
  rm -rf "$cloneDir"
fi

# Combine summaries and findings
repoSummaryArr="[]"
allFindingsArr="[]"

if [ -d "$tmp_job_dir" ]; then
  repoSummaryArr=$(jq -s '.' "$tmp_job_dir"/sum_*.json 2>/dev/null || echo "[]")
  # Flatten findings arrays
  allFindingsArr=$(jq -s 'add' "$tmp_job_dir"/find_*.json 2>/dev/null || echo "[]")
  rm -rf "$tmp_job_dir"
fi

summaryJson="${reportDir}/secret-scan-summary${fileSuffix}.json"
findingsJson="${reportDir}/secret-scan-findings${fileSuffix}.json"
htmlPath="${reportDir}/secret-scan-report${fileSuffix}.html"

echo "$repoSummaryArr" | jq '.' > "$summaryJson"
echo "$allFindingsArr" | jq '.' > "$findingsJson"

# Generate HTML report
cleanCount=$(echo "$repoSummaryArr" | jq '[.[] | select(.Status == "CLEAN")] | length')
secretsCount=$(echo "$repoSummaryArr" | jq '[.[] | select(.Status == "SECRETS_FOUND")] | length')
errorCount=$(echo "$repoSummaryArr" | jq '[.[] | select(.Status == "SCAN_ERROR")] | length')
failedCount=$(echo "$repoSummaryArr" | jq '[.[] | select(.Status == "CLONE_FAILED")] | length')
totalScanned=$(echo "$repoSummaryArr" | jq '. | length')
totalFindings=$(echo "$allFindingsArr" | jq '. | length')

tableRows=""
sortedSummary=$(echo "$repoSummaryArr" | jq -c '. | sort_by(.Status, .Name) | .[]' 2>/dev/null || true)
while read -r r; do
  if [ -z "$r" ]; then continue; fi
  proj=$(echo "$r" | jq -r '.Project')
  name=$(echo "$r" | jq -r '.Name')
  size_mb=$(echo "$r" | jq -r '.SizeMB')
  cnt=$(echo "$r" | jq -r '.FindingsCount')
  stat=$(echo "$r" | jq -r '.Status')

  statusColor="#333"
  case "$stat" in
    CLEAN) statusColor="#27ae60" ;;
    SECRETS_FOUND) statusColor="#e74c3c" ;;
    SCAN_ERROR) statusColor="#f39c12" ;;
    CLONE_FAILED) statusColor="#95a5a6" ;;
  esac

  escapedProj=$(jq -rn --arg val "$proj" '$val|@html')
  escapedName=$(jq -rn --arg val "$name" '$val|@html')

  tableRows="${tableRows}<tr><td>${escapedProj}</td><td>${escapedName}</td><td>${size_mb}</td><td>${cnt}</td><td style='color:${statusColor};font-weight:bold'>${stat}</td></tr>
"
done <<< "$sortedSummary"

cat <<EOF > "$htmlPath"
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Secret Scan Report [$SIZE_FILTER]</title>
<style>
  body { font-family: 'Segoe UI', sans-serif; margin: 20px; background: #f5f5f5; }
  h1 { color: #2c3e50; } h2 { color: #34495e; }
  .summary { display: flex; gap: 15px; margin: 15px 0; flex-wrap: wrap; }
  .card { padding: 15px 25px; border-radius: 8px; color: #fff; font-size: 1.1em; min-width: 120px; }
  .card .num { font-size: 2em; font-weight: bold; }
  table { border-collapse: collapse; width: 100%; background: #fff; margin-top: 10px; }
  th, td { border: 1px solid #ddd; padding: 8px 12px; text-align: left; }
  th { background: #2c3e50; color: #fff; }
  tr:nth-child(even) { background: #f9f9f9; }
  .elapsed { color: #7f8c8d; font-size: 0.9em; margin-top: 5px; }
</style></head><body>
<h1>Secret Scan Report [$SIZE_FILTER]</h1>
<p class="elapsed">Scanned ${totalScanned} repos in ${elapsed_formatted} | ThrottleLimit=$THROTTLE_LIMIT | Full clone (complete history)</p>
<div class="summary">
  <div class="card" style="background:#27ae60"><div class="num">${cleanCount}</div>Clean</div>
  <div class="card" style="background:#e74c3c"><div class="num">${secretsCount}</div>Secrets Found</div>
  <div class="card" style="background:#f39c12"><div class="num">${errorCount}</div>Errors</div>
  <div class="card" style="background:#95a5a6"><div class="num">${failedCount}</div>Clone Failed</div>
</div>
<h2>Repo Details</h2>
<table><tr><th>Project</th><th>Repo</th><th>Size (MB)</th><th>Findings</th><th>Status</th></tr>
${tableRows}</table>
</body></html>
EOF

echo ""
echo "=== Secret Scan Summary [$SIZE_FILTER] ==="
echo "  Elapsed time        : ${elapsed_formatted}"
echo "  Total repos scanned : ${totalScanned}"
echo "  Clean               : ${cleanCount}"
echo "  Secrets found       : ${secretsCount}"
echo "  Scan errors         : ${errorCount}"
echo "  Clone failed        : ${failedCount}"
echo "  Total findings      : ${totalFindings}"

dirty_repos=$(echo "$repoSummaryArr" | jq -r '.[] | select(.Status == "SECRETS_FOUND") | "\(.Name)\t\(.FindingsCount)"' 2>/dev/null || true)
if [ -n "$dirty_repos" ]; then
  echo ""
  echo "Repos requiring secret scrubbing BEFORE migration:"
  echo "$dirty_repos" | column -t -s $'\t'
  echo "Run 02-prep/scrub-secrets.sh to clean these repos."
fi

echo ""
echo "Reports saved:"
echo "  Summary  : $summaryJson"
echo "  Findings : $findingsJson"
echo "  HTML     : $htmlPath"
