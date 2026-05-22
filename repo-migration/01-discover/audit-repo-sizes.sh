#!/usr/bin/env bash

# SYNOPSIS
#     Clones each repo and runs git-sizer to detect files/trees exceeding GEI limits.

set -euo pipefail

# Resolve script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG_PATH="${SCRIPT_DIR}/../config/repo-migration-config.json"
CONFIG_PATH="${1:-$DEFAULT_CONFIG_PATH}"

# Check config
if [ ! -f "$CONFIG_PATH" ]; then
  echo "Error: Config not found at $CONFIG_PATH." >&2
  exit 1
fi

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

# Verify git-sizer
if ! command -v git-sizer >/dev/null 2>&1; then
  echo "Error: git-sizer not found. Install it: https://github.com/github/git-sizer/releases or run 02-prep/install-tools.sh" >&2
  exit 1
fi

# Load inventory
inventoryPath="${reportDir}/repo-inventory.json"
if [ ! -f "$inventoryPath" ]; then
  echo "Error: repo-inventory.json not found. Run 01-discover/discover-repos.sh first." >&2
  exit 1
fi
repos_json=$(cat "$inventoryPath")

source_pat_raw=$(echo "$config_json" | jq -r '.source.pat // empty')
adoPat=$(resolve_config_value "$source_pat_raw")
if [ -z "$adoPat" ]; then
  echo "Error: Set ADO_PAT environment variable" >&2
  exit 1
fi

adoOrg_raw=$(echo "$config_json" | jq -r '.source.organization // empty')
adoOrg=$(resolve_config_value "$adoOrg_raw")
adoOrg="${adoOrg%/}"

adoProj_raw=$(echo "$config_json" | jq -r '.source.project // empty')
adoProj=$(resolve_config_value "$adoProj_raw")

apiOnlyThresholdMB=1024

repo_count=$(echo "$repos_json" | jq '. | length')
echo "=== Auditing repo sizes for $repo_count repos ==="
echo "  Repos >= ${apiOnlyThresholdMB} MB will use ADO REST API (no clone)"

get_repo_size_via_api() {
  local repo_id="$1"
  local default_branch="$2"
  local repo_name="$3"

  if [ -z "$default_branch" ] || [ "$default_branch" = "null" ]; then
    echo "  [WARN] No default branch - using API size only" >&2
    echo '{"MaxBlobMB": 0, "LargestBlobs": []}'
    return
  fi

  local encoded_branch=$(jq -rn --arg val "$default_branch" '$val|@uri')
  local itemsUrl="${adoOrg}/${adoProj}/_apis/git/repositories/${repo_id}/items?recursionLevel=Full&versionDescriptor.version=${encoded_branch}&api-version=7.1"
  local itemsResp=$(curl -s -f -u ":$adoPat" -H "Accept: application/json" "$itemsUrl" || true)

  if [ -z "$itemsResp" ]; then
    echo "  [WARN] API items call failed for $repo_name" >&2
    echo '{"MaxBlobMB": 0, "LargestBlobs": []}'
    return
  fi

  local jq_filter='
    if .value then
      .value 
      | map(select((.gitObjectType == "blob" or .isFolder == false or (.size != null)) and .size != null and .size > 0))
      | sort_by(.size) | reverse | .[0:10]
      | map({
          SizeMB: ((.size / 1048576 * 100 | round) / 100),
          Hash: .objectId,
          Path: .path
        })
    else
      []
    end
  '
  local top10=$(echo "$itemsResp" | jq "$jq_filter")
  local maxBlobSize=$(echo "$top10" | jq '.[0].SizeMB // 0')

  jq -n --argjson mb "$maxBlobSize" --argjson tb "$top10" '{MaxBlobMB: $mb, LargestBlobs: $tb}'
}

results="[]"
repos_list=$(echo "$repos_json" | jq -c '.[]')

# Loop through repositories
while read -r repo_json; do
  if [ -z "$repo_json" ]; then continue; fi

  proj=$(echo "$repo_json" | jq -r '.Project')
  name=$(echo "$repo_json" | jq -r '.Name')
  id=$(echo "$repo_json" | jq -r '.Id')
  default_branch=$(echo "$repo_json" | jq -r '.DefaultBranch // empty')
  size_mb=$(echo "$repo_json" | jq -r '.SizeMB')
  size_gb=$(echo "$repo_json" | jq -r '.SizeGB')
  remote_url=$(echo "$repo_json" | jq -r '.RemoteUrl')

  echo ""
  echo "--- [$proj] $name ---"

  maxBlobSize=0
  largestBlobs="[]"
  auditMethod=""

  # Check if size exceeds threshold for API-only path
  is_large=0
  if (( $(awk -v smb="$size_mb" -v thresh="$apiOnlyThresholdMB" 'BEGIN { print (smb >= thresh) }') )); then
    is_large=1
  fi

  if [ "$is_large" -eq 1 ]; then
    auditMethod="API"
    echo "  Using ADO REST API (repo is $size_mb MB - skipping clone)"
    apiResult=$(get_repo_size_via_api "$id" "$default_branch" "$name")
    maxBlobSize=$(echo "$apiResult" | jq -r '.MaxBlobMB')
    largestBlobs=$(echo "$apiResult" | jq '.LargestBlobs')
  else
    auditMethod="Clone"
    clonePath="${cloneDir}/${name}.git"
    
    # Strip credential from RemoteUrl if any
    cloneUrl=$(echo "$remote_url" | sed -E 's|://[^@]+@|://|')
    cloneAuth=$(echo -n "pat:$adoPat" | base64 | tr -d '\r\n')
    
    if [ -d "$clonePath" ]; then
      rm -rf "$clonePath"
    fi

    clone_success=1
    echo "  Cloning $name (bare) to $clonePath..."
    
    # Build clone arguments
    # We do a basic check. If default branch is present, use it.
    if [ -n "$default_branch" ] && [ "$default_branch" != "null" ]; then
      git -c "http.extraHeader=Authorization: Basic $cloneAuth" clone --bare --quiet --single-branch --branch "$default_branch" "$cloneUrl" "$clonePath" 2>&1 || clone_success=0
    else
      git -c "http.extraHeader=Authorization: Basic $cloneAuth" clone --bare --quiet "$cloneUrl" "$clonePath" 2>&1 || clone_success=0
    fi

    if [ "$clone_success" -eq 0 ]; then
      echo "  [WARN] Clone failed for $name - falling back to API" >&2
      apiResult=$(get_repo_size_via_api "$id" "$default_branch" "$name")
      maxBlobSize=$(echo "$apiResult" | jq -r '.MaxBlobMB')
      largestBlobs=$(echo "$apiResult" | jq '.LargestBlobs')
      auditMethod="API-fallback"
    else
      # Run git-sizer and extract blobs inside the bare clone
      (
        cd "$clonePath"
        
        # Run git-sizer
        sizerJson=$(git-sizer --json 2>/dev/null || echo "{}")
        if echo "$sizerJson" | jq -e '.uniqueBlobSize.maxSize' >/dev/null 2>&1; then
          maxSize=$(echo "$sizerJson" | jq '.uniqueBlobSize.maxSize')
          maxBlobSize=$(awk -v size="$maxSize" 'BEGIN { printf "%.2f", size / 1048576 }')
        fi

        # Find largest blobs (temporarily disable pipefail to prevent SIGPIPE/141 from head -n 10)
        set +o pipefail
        top10_list=$(git rev-list --objects --all 2>/dev/null | \
          git cat-file --batch-check='%(objecttype) %(objectsize) %(objectname) %(rest)' 2>/dev/null | \
          awk '/^blob/ {
            path = $0;
            sub(/^blob [0-9]+ [^ ]+ /, "", path);
            sizeMB = sprintf("%.2f", $2 / 1048576);
            print sizeMB "\t" $3 "\t" path;
          }' | \
          sort -k 1 -rn | \
          head -n 10)
        set -o pipefail
          
        largestBlobs=$(echo "$top10_list" | jq -R -s -c '
          split("\n") | map(select(length > 0)) | map(
            split("\t") | {SizeMB: (.[0]|tonumber), Hash: .[1], Path: .[2]}
          )
        ')
        
        # Expose variables to outside block
        echo "MAX_BLOB_SIZE=${maxBlobSize}"
        echo "LARGEST_BLOBS=${largestBlobs}"
      ) > "${clonePath}_output.tmp"
      
      # Read back results
      maxBlobSize=$(grep -E "^MAX_BLOB_SIZE=" "${clonePath}_output.tmp" | cut -d= -f2-)
      largestBlobs=$(grep -E "^LARGEST_BLOBS=" "${clonePath}_output.tmp" | cut -d= -f2-)
      rm -f "${clonePath}_output.tmp"

      # Cleanup clone directory immediately
      rm -rf "$clonePath"
    fi
  fi

  # Evaluate limits
  exceedsGEI="false"
  exceedsPush="false"

  if (( $(awk -v mb="$maxBlobSize" -v gb="$size_gb" 'BEGIN { print (mb > 400.0 || gb > 40.0) }') )); then
    exceedsGEI="true"
  fi
  if (( $(awk -v mb="$maxBlobSize" 'BEGIN { print (mb > 100.0) }') )); then
    exceedsPush="true"
  fi

  status="OK"
  if [ "$exceedsGEI" = "true" ]; then
    status="BLOCKED"
    echo "  [WARN] BLOCKER: Exceeds GEI limits (max blob: ${maxBlobSize} MB, total: ${size_gb} GB)" >&2
  elif [ "$exceedsPush" = "true" ]; then
    status="WARNING"
    echo "  [WARN] WARNING: Has files > 100 MB - will need Git LFS after migration" >&2
  else
    echo "  OK (max blob: ${maxBlobSize} MB) [$auditMethod]"
  fi

  # Append to results
  results=$(echo "$results" | jq \
    --arg proj "$proj" \
    --arg name "$name" \
    --arg stat "$status" \
    --argjson mb "$maxBlobSize" \
    --argjson smb "$size_mb" \
    --argjson sgb "$size_gb" \
    --argjson egei "$exceedsGEI" \
    --argjson epush "$exceedsPush" \
    --argjson top10 "$largestBlobs" \
    --arg method "$auditMethod" \
    '. + [{
      Project: $proj,
      Name: $name,
      Status: $stat,
      MaxBlobMB: $mb,
      TotalSizeMB: $smb,
      TotalSizeGB: $sgb,
      ExceedsGEI: $egei,
      ExceedsPushLimit: $epush,
      Top10Files: $top10,
      AuditMethod: $method
    }]')

done <<< "$repos_list"

# Final cleanup of temp clone dir
if [ -d "$cloneDir" ]; then
  rm -rf "$cloneDir"
fi

# Write JSON report
jsonOut="${reportDir}/repo-size-audit.json"
echo "$results" | jq '.' > "$jsonOut"

total_count=$(echo "$results" | jq '. | length')
ok_count=$(echo "$results" | jq '[.[] | select(.Status == "OK")] | length')
warn_count=$(echo "$results" | jq '[.[] | select(.Status == "WARNING")] | length')
blocked_count=$(echo "$results" | jq '[.[] | select(.Status == "BLOCKED")] | length')

echo ""
echo "=== Size Audit Summary ==="
echo "  Total repos       : $total_count"
echo "  OK                : $ok_count"
echo "  WARNING (>100MB)  : $warn_count"
echo "  BLOCKED (GEI)     : $blocked_count"

blocked_repos=$(echo "$results" | jq -r '.[] | select(.Status == "BLOCKED") | "\(.Name)\t\(.MaxBlobMB) MB\t\(.TotalSizeGB) GB"' 2>/dev/null || true)
if [ -n "$blocked_repos" ]; then
  echo ""
  echo "BLOCKED repos (must resolve before migration):"
  echo "$blocked_repos" | column -t -s $'\t'
fi

echo ""
echo "Report saved: $jsonOut"
echo "Next step: Run 01-discover/scan-secrets.sh to check for exposed credentials."
