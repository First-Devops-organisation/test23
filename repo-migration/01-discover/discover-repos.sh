#!/usr/bin/env bash

# SYNOPSIS
#     Discovers all Git repositories in an Azure DevOps project.
#     Outputs repo list with metadata (size, default branch, last commit, LFS usage).

set -euo pipefail

# Resolve script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG_PATH="${SCRIPT_DIR}/../config/repo-migration-config.json"
CONFIG_PATH="${1:-$DEFAULT_CONFIG_PATH}"

# Check config
if [ ! -f "$CONFIG_PATH" ]; then
  echo "Error: Config not found at $CONFIG_PATH. Copy repo-migration-config.json and fill in your values." >&2
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

# Resolve config values
source_org_raw=$(echo "$config_json" | jq -r '.source.organization // empty')
source_proj_raw=$(echo "$config_json" | jq -r '.source.project // empty')
source_pat_raw=$(echo "$config_json" | jq -r '.source.pat // empty')

adoOrg=$(resolve_config_value "$source_org_raw")
adoProj=$(resolve_config_value "$source_proj_raw")
adoPat=$(resolve_config_value "$source_pat_raw")

# Trim trailing slash
adoOrg="${adoOrg%/}"

if [ -z "$adoOrg" ]; then
  echo "Error: Set the ADO_ORG environment variable or update config.source.organization" >&2
  exit 1
fi
if [ -z "$adoProj" ]; then
  echo "Error: Set the ADO_PROJECT environment variable or update config.source.project" >&2
  exit 1
fi
if [ -z "$adoPat" ]; then
  echo "Error: Set the ADO_PAT environment variable or update config.source.pat" >&2
  exit 1
fi

reportDir_raw=$(echo "$config_json" | jq -r '.output.reportDir // "./output/reports"')
reportDir=$(resolve_config_value "$reportDir_raw")
mkdir -p "$reportDir"

# Generate Basic Auth
base64Auth=$(echo -n ":$adoPat" | base64 | tr -d '\r\n')

# Verify PAT connectivity
echo "Verifying PAT connectivity..."
connTest=$(curl -s -f -u ":$adoPat" -H "Accept: application/json" "${adoOrg}/_apis/connectiondata" || true)
if [ -z "$connTest" ]; then
  echo "Error: PAT authentication failed against $adoOrg. Ensure ADO_PAT is valid and not expired." >&2
  exit 1
fi
providerName=$(echo "$connTest" | jq -r '.authenticatedUser.providerDisplayName // "Unknown"')
echo "  Authenticated as: $providerName"

# Fetch all repos
echo "=== Discovering repos in $adoOrg/$adoProj ==="
repoApiUrl="${adoOrg}/${adoProj}/_apis/git/repositories?api-version=7.1"
response=$(curl -s -f -u ":$adoPat" -H "Accept: application/json" "$repoApiUrl" || true)

if [ -z "$response" ]; then
  echo "Error: API call failed for $repoApiUrl - verify ADO_PAT has 'Code (Read)' scope for project '$adoProj'." >&2
  exit 1
fi

# Check if response is not JSON
if ! echo "$response" | jq -e '.' >/dev/null 2>&1; then
  echo "Error: API returned non-JSON response (likely a sign-in page). The PAT is not authorized for $repoApiUrl." >&2
  exit 1
fi

# Verify 'value' key exists
if ! echo "$response" | jq -e '.value' >/dev/null 2>&1; then
  echo "Error: Unexpected API response - no 'value' property. Response keys: $(echo "$response" | jq -r 'keys | join(", ")')" >&2
  exit 1
fi

repoList_length=$(echo "$response" | jq '.value | length')
throttleLimit=10
echo "Enriching $repoList_length repos (parallel, throttle=$throttleLimit)..."

# Temporary directory for parallel jobs
tmp_job_dir=$(mktemp -d 2>/dev/null || mktemp -d -t 'ado-jobs')

process_repo() {
  local repo_json="$1"
  local job_id="$2"
  local adoOrg="$3"
  local adoProj="$4"
  local adoPat="$5"
  local tmp_job_dir="$6"

  local repo_name=$(echo "$repo_json" | jq -r '.name')
  local repo_id=$(echo "$repo_json" | jq -r '.id')
  local default_branch_raw=$(echo "$repo_json" | jq -r '.defaultBranch // empty')
  local default_branch="${default_branch_raw#refs/heads/}"
  local is_disabled=$(echo "$repo_json" | jq -r '.isDisabled // false')
  local size_bytes=$(echo "$repo_json" | jq -r '.size // 0')
  local web_url=$(echo "$repo_json" | jq -r '.webUrl // empty')
  local remote_url=$(echo "$repo_json" | jq -r '.remoteUrl // empty')

  local last_commit_date="null"
  local has_lfs="false"

  # Get last commit on default branch
  if [ -n "$default_branch" ]; then
    local encoded_branch=$(jq -rn --arg val "$default_branch" '$val|@uri')
    local commit_url="${adoOrg}/${adoProj}/_apis/git/repositories/${repo_id}/commits?searchCriteria.\$top=1&searchCriteria.itemVersion.version=${encoded_branch}&api-version=7.1"
    local commit_resp=$(curl -s -f -u ":$adoPat" -H "Accept: application/json" "$commit_url" || true)
    if [ -n "$commit_resp" ]; then
      local commit_date=$(echo "$commit_resp" | jq -r '.value[0].committer.date // empty')
      if [ -n "$commit_date" ]; then
        last_commit_date="$commit_date"
      fi
    else
      echo "  [WARN] Could not fetch last commit for $repo_name" >&2
    fi
  fi

  # Check for .gitattributes LFS markers
  local gitattrs_url="${adoOrg}/${adoProj}/_apis/git/repositories/${repo_id}/items?path=.gitattributes&api-version=7.1"
  local gitattrs_resp=$(curl -s -u ":$adoPat" -H "Accept: application/json" "$gitattrs_url" || true)
  if echo "$gitattrs_resp" | grep -q "filter=lfs"; then
    has_lfs="true"
  fi

  # Size calculations
  local size_mb=$(awk -v size="$size_bytes" 'BEGIN { printf "%.2f", size / 1048576 }')
  local size_gb=$(awk -v size="$size_bytes" 'BEGIN { printf "%.2f", size / 1073741824 }')

  # GEI limit checks
  local exceeds_gei="false"
  if (( $(awk -v gb="$size_gb" 'BEGIN { print (gb > 40.0) }') )); then
    exceeds_gei="true"
  fi

  # Write output JSON to file
  jq -n \
    --arg proj "$adoProj" \
    --arg name "$repo_name" \
    --arg id "$repo_id" \
    --arg db "$default_branch" \
    --argjson sb "$size_bytes" \
    --argjson smb "$size_mb" \
    --argjson sgb "$size_gb" \
    --arg lcd "$last_commit_date" \
    --argjson dis "$is_disabled" \
    --argjson lfs "$has_lfs" \
    --argjson egei "$exceeds_gei" \
    --arg url "$web_url" \
    --arg rurl "$remote_url" \
    '{
      Project: $proj,
      Name: $name,
      Id: $id,
      DefaultBranch: $db,
      SizeBytes: $sb,
      SizeMB: $smb,
      SizeGB: $sgb,
      LastCommitDate: (if $lcd == "null" then null else $lcd end),
      IsDisabled: $dis,
      HasLFS: $lfs,
      ExceedsGEI40GB: $egei,
      Url: $url,
      RemoteUrl: $rurl
    }' > "${tmp_job_dir}/repo_${job_id}.json"
}

# Read repo list
repos_array=$(echo "$response" | jq -c '.value[]')

job_idx=0
running_jobs=0

while read -r repo_json; do
  if [ -z "$repo_json" ]; then continue; fi

  process_repo "$repo_json" "$job_idx" "$adoOrg" "$adoProj" "$adoPat" "$tmp_job_dir" &

  job_idx=$((job_idx + 1))
  running_jobs=$((running_jobs + 1))

  if [ "$running_jobs" -ge "$throttleLimit" ]; then
    wait -n
    running_jobs=$((running_jobs - 1))
  fi
done <<< "$repos_array"

wait

# Read and combine job outputs
enriched_repos="[]"
if [ -d "$tmp_job_dir" ]; then
  enriched_repos=$(jq -s '.' "$tmp_job_dir"/repo_*.json 2>/dev/null || echo "[]")
  rm -rf "$tmp_job_dir"
fi

# Exclusions filter
exclusions_json=$(echo "$config_json" | jq -c '.exclusions.repos // []')
included_repos=$(echo "$enriched_repos" | jq --argjson excl "$exclusions_json" 'map(select(.Name as $n | ($excl | index($n)) == null))')
excluded_repos=$(echo "$enriched_repos" | jq --argjson excl "$exclusions_json" 'map(select(.Name as $n | ($excl | index($n)) != null))')

total_repos_found=$(echo "$enriched_repos" | jq '. | length')
excluded_count=$(echo "$excluded_repos" | jq '. | length')
included_count=$(echo "$included_repos" | jq '. | length')

total_size_mb=$(echo "$included_repos" | jq '[.[] | .SizeMB] | add // 0')
total_size_mb=$(awk -v size="$total_size_mb" 'BEGIN { printf "%.2f", size }')
lfs_count=$(echo "$included_repos" | jq '[.[] | select(.HasLFS == true)] | length')
gei_count=$(echo "$included_repos" | jq '[.[] | select(.ExceedsGEI40GB == true)] | length')
disabled_count=$(echo "$included_repos" | jq '[.[] | select(.IsDisabled == true)] | length')

echo ""
echo "=== Discovery Summary ==="
echo "  Total repos found   : $total_repos_found"
echo "  Excluded by config  : $excluded_count"
echo "  Repos to migrate    : $included_count"
echo "  Total size          : $total_size_mb MB"
echo "  Repos with LFS      : $lfs_count"
echo "  Repos > 40 GB (GEI) : $gei_count"

oversize_repos=$(echo "$included_repos" | jq -r '.[] | select(.ExceedsGEI40GB == true) | "\(.Name)\t\(.SizeGB) GB"' 2>/dev/null || true)
if [ -n "$oversize_repos" ]; then
  echo "[WARN] The following repos exceed GEIs 40 GB limit and need manual migration:"
  echo "$oversize_repos" | column -t -s $'\t'
fi

lfs_repos_list=$(echo "$included_repos" | jq -r '.[] | select(.HasLFS == true) | "\(.Name)\t\(.SizeGB) GB"' 2>/dev/null || true)
if [ -n "$lfs_repos_list" ]; then
  echo "[WARN] The following repos use Git LFS - LFS objects are NOT migrated by GEI:"
  echo "$lfs_repos_list" | column -t -s $'\t'
fi

# Output files
jsonOut="${reportDir}/repo-inventory.json"
csvOut="${reportDir}/repo-inventory.csv"
htmlOut="${reportDir}/repo-inventory.html"

echo "$included_repos" | jq '.' > "$jsonOut"

# Export CSV
echo '"Project","Name","Id","DefaultBranch","SizeBytes","SizeMB","SizeGB","LastCommitDate","IsDisabled","HasLFS","ExceedsGEI40GB","Url","RemoteUrl"' > "$csvOut"
echo "$included_repos" | jq -r '.[] | [
  .Project,
  .Name,
  .Id,
  .DefaultBranch,
  .SizeBytes,
  .SizeMB,
  .SizeGB,
  .LastCommitDate,
  .IsDisabled,
  .HasLFS,
  .ExceedsGEI40GB,
  .Url,
  .RemoteUrl
] | @csv' >> "$csvOut"

# Sort repos for HTML
sorted_repos=$(echo "$included_repos" | jq -c '. | sort_by(.SizeMB) | reverse | .[]' 2>/dev/null || true)

tableRows=""
rowIndex=0
while read -r r; do
  if [ -z "$r" ]; then continue; fi
  rowIndex=$((rowIndex + 1))

  name=$(echo "$r" | jq -r '.Name')
  defaultBranch=$(echo "$r" | jq -r '.DefaultBranch // ""')
  sizeMB=$(echo "$r" | jq -r '.SizeMB')
  sizeGB=$(echo "$r" | jq -r '.SizeGB')
  lastCommitDate=$(echo "$r" | jq -r '.LastCommitDate // "N/A"')
  hasLFS=$(echo "$r" | jq -r '.HasLFS')
  exceedsGEI=$(echo "$r" | jq -r '.ExceedsGEI40GB')
  url=$(echo "$r" | jq -r '.Url')

  sizeClass="ok"
  if [ "$exceedsGEI" = "true" ]; then
    sizeClass="blocked"
  else
    integer_mb=$(echo "$sizeMB" | cut -d. -f1)
    if [ "${integer_mb:-0}" -gt 1024 ]; then
      sizeClass="warning"
    fi
  fi

  lfsIcon="[NO]"
  if [ "$hasLFS" = "true" ]; then
    lfsIcon="[YES]"
  fi

  geiIcon="<span class='badge ok'>OK</span>"
  if [ "$exceedsGEI" = "true" ]; then
    geiIcon="<span class='badge blocked'>BLOCKED</span>"
  fi

  lastCommit="N/A"
  if [ "$lastCommitDate" != "N/A" ] && [ -n "$lastCommitDate" ] && [ "$lastCommitDate" != "null" ]; then
    lastCommit="${lastCommitDate:0:10}"
  fi

  escapedName=$(jq -rn --arg val "$name" '$val|@html')
  escapedUrl=$(jq -rn --arg val "$url" '$val|@html')
  escapedBranch=$(jq -rn --arg val "$defaultBranch" '$val|@html')

  repoLink="$escapedName"
  if [ -n "$url" ] && [ "$url" != "null" ]; then
    repoLink="<a href='$escapedUrl' target='_blank'>$escapedName</a>"
  fi

  tableRows="${tableRows}    <tr class='${sizeClass}'>
      <td>${rowIndex}</td>
      <td>${repoLink}</td>
      <td>${escapedBranch}</td>
      <td class='num'>${sizeMB}</td>
      <td class='num'>${sizeGB}</td>
      <td>${lastCommit}</td>
      <td class='center'>${lfsIcon}</td>
      <td class='center'>${geiIcon}</td>
    </tr>
"
done <<< "$sorted_repos"

totalSizeGB=$(awk -v size="$total_size_mb" 'BEGIN { printf "%.2f", size / 1024 }')
timestamp=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

escapedAdoOrg=$(jq -rn --arg val "$adoOrg" '$val|@html')
escapedAdoProj=$(jq -rn --arg val "$adoProj" '$val|@html')

lfsCardClass="card"
if [ "$lfs_count" -gt 0 ]; then lfsCardClass="card warn"; fi

geiCardClass="card"
if [ "$gei_count" -gt 0 ]; then geiCardClass="card error"; fi

disabledCardClass="card"
if [ "$disabled_count" -gt 0 ]; then disabledCardClass="card warn"; fi

cat <<EOF > "$htmlOut"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>ADO Repository Discovery Report</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { font-family: 'Segoe UI', Tahoma, sans-serif; background: #f0f2f5; color: #24292f; padding: 20px; }
  .container { max-width: 1400px; margin: 0 auto; }
  h1 { font-size: 1.8rem; margin-bottom: 5px; color: #0078d4; }
  .subtitle { color: #586069; margin-bottom: 20px; font-size: 0.9rem; }
  .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); gap: 15px; margin-bottom: 25px; }
  .card { background: #fff; border-radius: 8px; padding: 18px; box-shadow: 0 1px 3px rgba(0,0,0,0.12); text-align: center; }
  .card .value { font-size: 2rem; font-weight: 700; color: #0078d4; }
  .card .label { font-size: 0.85rem; color: #586069; margin-top: 4px; }
  .card.warn .value { color: #d29922; }
  .card.error .value { color: #cf222e; }
  table { width: 100%; border-collapse: collapse; background: #fff; border-radius: 8px; overflow: hidden; box-shadow: 0 1px 3px rgba(0,0,0,0.12); }
  th { background: #0078d4; color: #fff; padding: 12px 10px; text-align: left; font-size: 0.85rem; position: sticky; top: 0; cursor: pointer; user-select: none; }
  th:hover { background: #106ebe; }
  td { padding: 10px; border-bottom: 1px solid #e1e4e8; font-size: 0.85rem; }
  tr:hover { background: #f6f8fa; }
  tr.blocked { background: #fff0f0; }
  tr.warning { background: #fff8e1; }
  .num { text-align: right; font-variant-numeric: tabular-nums; }
  .center { text-align: center; }
  .badge { padding: 2px 8px; border-radius: 12px; font-size: 0.75rem; font-weight: 600; }
  .badge.ok { background: #dafbe1; color: #1a7f37; }
  .badge.blocked { background: #ffebe9; color: #cf222e; }
  .search-box { margin-bottom: 15px; }
  .search-box input { width: 100%; max-width: 400px; padding: 10px 14px; border: 1px solid #d0d7de; border-radius: 6px; font-size: 0.9rem; }
  .search-box input:focus { outline: none; border-color: #0078d4; box-shadow: 0 0 0 3px rgba(0,120,212,0.15); }
  a { color: #0078d4; text-decoration: none; }
  a:hover { text-decoration: underline; }
  .footer { margin-top: 15px; color: #586069; font-size: 0.8rem; text-align: center; }
</style>
</head>
<body>
<div class="container">
  <h1>[Discovery] ADO Repository Discovery Report</h1>
  <p class="subtitle">${escapedAdoOrg} / ${escapedAdoProj} - Generated: ${timestamp}</p>
  <div class="cards">
    <div class="card"><div class="value">${included_count}</div><div class="label">Repos to Migrate</div></div>
    <div class="card"><div class="value">${excluded_count}</div><div class="label">Excluded</div></div>
    <div class="card"><div class="value">${totalSizeGB} GB</div><div class="label">Total Size</div></div>
    <div class="${lfsCardClass}"><div class="value">${lfs_count}</div><div class="label">Repos with LFS</div></div>
    <div class="${geiCardClass}"><div class="value">${gei_count}</div><div class="label">Exceed GEI 40 GB</div></div>
    <div class="${disabledCardClass}"><div class="value">${disabled_count}</div><div class="label">Disabled</div></div>
  </div>
  <div class="search-box">
    <input type="text" id="searchInput" placeholder="Search repos..." onkeyup="filterTable()">
  </div>
  <table id="repoTable">
    <thead>
      <tr>
        <th onclick="sortTable(0)">#</th>
        <th onclick="sortTable(1)">Repository</th>
        <th onclick="sortTable(2)">Default Branch</th>
        <th onclick="sortTable(3)">Size (MB)</th>
        <th onclick="sortTable(4)">Size (GB)</th>
        <th onclick="sortTable(5)">Last Commit</th>
        <th onclick="sortTable(6)">LFS</th>
        <th onclick="sortTable(7)">GEI Status</th>
      </tr>
    </thead>
    <tbody>
${tableRows}    </tbody>
  </table>
  <p class="footer">Total repos found: ${total_repos_found} | Included: ${included_count} | Excluded: ${excluded_count}</p>
</div>
<script>
function filterTable() {
  var input = document.getElementById('searchInput').value.toLowerCase();
  var rows = document.querySelectorAll('#repoTable tbody tr');
  for (var i = 0; i < rows.length; i++) {
    rows[i].style.display = rows[i].textContent.toLowerCase().indexOf(input) > -1 ? '' : 'none';
  }
}
var sortDir = {};
function sortTable(col) {
  var tbody = document.getElementById('repoTable').querySelector('tbody');
  var rows = Array.prototype.slice.call(tbody.querySelectorAll('tr'));
  var dir = sortDir[col] = !sortDir[col];
  rows.sort(function(a, b) {
    var aVal = a.cells[col].textContent.trim();
    var bVal = b.cells[col].textContent.trim();
    var aNum = parseFloat(aVal), bNum = parseFloat(bVal);
    if (!isNaN(aNum) && !isNaN(bNum)) return dir ? aNum - bNum : bNum - aNum;
    return dir ? aVal.localeCompare(bVal) : bVal.localeCompare(aVal);
  });
  for (var i = 0; i < rows.length; i++) { tbody.appendChild(rows[i]); }
}
</script>
</body>
</html>
EOF

echo ""
echo "Reports saved:"
echo "  JSON : $jsonOut"
echo "  CSV  : $csvOut"
echo "  HTML : $htmlOut"
echo ""
echo "Next step: Run 01-discover/audit-repo-sizes.sh for detailed per-file size analysis."
