#!/usr/bin/env bash

set -euo pipefail

# SYNOPSIS
#     Validates migrated repos - compares ADO source vs GitHub target.
#     Works for both Single repo and Batch.
#     Converted from PowerShell to native Linux Bash.

ADOOrg=""
ADOProject=""
GHOrg=""
GHRepo=""
ADORepo=""
OutputDir=""
ExpectedVisibility="internal"
BatchSummaryJson=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG_PATH="${SCRIPT_DIR}/../config/repo-migration-config.json"
DEFAULT_OUTPUT_DIR="${SCRIPT_DIR}/../output"

while [[ $# -gt 0 ]]; do
  case $1 in
    --ado-org|-ADOOrg) ADOOrg="$2"; shift 2 ;;
    --ado-project|-ADOProject) ADOProject="$2"; shift 2 ;;
    --github-org|-GHOrg) GHOrg="$2"; shift 2 ;;
    --github-repo|-GHRepo) GHRepo="$2"; shift 2 ;;
    --ado-repo|-ADORepo) ADORepo="$2"; shift 2 ;;
    --output-dir|-OutputDir) OutputDir="$2"; shift 2 ;;
    --expected-visibility|-ExpectedVisibility) ExpectedVisibility="$2"; shift 2 ;;
    --batch-summary-json|-BatchSummaryJson) BatchSummaryJson="$2"; shift 2 ;;
    *) echo "Error: Unknown parameter: $1" >&2; exit 1 ;;
  esac
done

OutputDir="${OutputDir:-$DEFAULT_OUTPUT_DIR}"
configPath="${DEFAULT_CONFIG_PATH}"

# Override visibility from config if available
if [ -f "$configPath" ]; then
  cfg_vis=$(jq -r '.migration.targetRepoVisibility // empty' "$configPath" | tr -d '\r')
  if [ -n "$cfg_vis" ]; then
    ExpectedVisibility="$cfg_vis"
  fi
fi
echo "  Expected visibility: $ExpectedVisibility"

# Trim whitespace
ADOOrg=$(echo "$ADOOrg" | xargs || true)
ADOProject=$(echo "$ADOProject" | xargs || true)
GHOrg=$(echo "$GHOrg" | xargs || true)
GHRepo=$(echo "$GHRepo" | xargs || true)
ADORepo=$(echo "$ADORepo" | xargs || true)

# Normalise ADOOrg - strip full URL if passed
if [[ "$ADOOrg" =~ ^https?://dev\.azure\.com/([^/]+)/?$ ]]; then
  echo "  Normalising ADOOrg: stripping URL prefix -> '${BASH_REMATCH[1]}'"
  ADOOrg="${BASH_REMATCH[1]}"
fi

# Validate PATs
adoPat="${ADO_PAT:-}"
ghPat="${GH_PAT:-}"
if [ -z "$adoPat" ]; then echo "Error: Set ADO_PAT environment variable" >&2; exit 1; fi
if [ -z "$ghPat" ]; then  echo "Error: Set GH_PAT environment variable" >&2; exit 1; fi

export GH_TOKEN="$ghPat"

reportDir="$OutputDir/reports"
mkdir -p "$reportDir"

# Build repo list
repoList="[]"

isSingleMode=false
if [ -n "$GHRepo" ] || [ -n "$ADORepo" ]; then
  isSingleMode=true
fi

if [ "$isSingleMode" = "true" ] && [ -z "$GHRepo" ]; then
  echo "  GHRepo parameter is empty - checking config.json..."
  if [ -f "$configPath" ]; then
    cfg_single=$(jq -r '.migration.singleRepo // empty' "$configPath" | tr -d '\r')
    if [ -n "$cfg_single" ]; then
      GHRepo=$(echo "$cfg_single" | xargs)
      echo "  Found default repo in config: $GHRepo"
    fi
  fi
fi

if [ "$isSingleMode" = "true" ] && [ -z "$GHRepo" ] && [ -n "$ADORepo" ]; then
  echo "  GHRepo was still empty - defaulting to ADORepo: '$ADORepo'"
  GHRepo="$ADORepo"
fi

if [ -n "$GHRepo" ]; then
  adoName="${ADORepo:-$GHRepo}"
  stateFile="$OutputDir/logs/migration-state-$GHRepo.txt"
  state="UNKNOWN"
  if [ -f "$stateFile" ]; then
    state=$(cat "$stateFile" | xargs || true)
  fi
  repoList=$(jq -n --arg ado "$adoName" --arg gh "$GHRepo" --arg st "$state" '[{ADORepo: $ado, GHRepo: $gh, State: $st}]')
else
  summaryPath="${BatchSummaryJson:-$reportDir/batch-migration-summary.json}"
  if [ ! -f "$summaryPath" ]; then
    echo "Error: Batch summary not found at: $summaryPath. Specify --github-repo for single-repo validation." >&2
    exit 1
  fi
  repoList=$(cat "$summaryPath")
fi

len_repos=$(echo "$repoList" | jq '. | length')
echo "============================================"
echo "  MIGRATION VALIDATION"
echo "  ADO:   $ADOOrg / $ADOProject"
echo "  GitHub: $GHOrg"
echo "  Repos: $len_repos"
echo "============================================"

# Helper functions for ADO/GitHub APIs
get_ado_branches() {
  local repo_encoded="$1"
  local skip=0
  local all="[]"
  while true; do
    local url="https://dev.azure.com/$ADOOrg/$ADOProject/_apis/git/repositories/${repo_encoded}/refs?filter=heads/&\$top=1000&\$skip=${skip}&api-version=7.1"
    local resp
    resp=$(curl -s -u ":$adoPat" -H "Accept: application/json" "$url" || echo "")
    if [ -n "$resp" ] && echo "$resp" | jq -e '.value' >/dev/null 2>&1; then
      local batch_len
      batch_len=$(echo "$resp" | jq '.value | length')
      if [ "$batch_len" -gt 0 ]; then
        local batch_names
        batch_names=$(echo "$resp" | jq '.value | map(.name | sub("^refs/heads/"; ""))')
        all=$(jq -s '.[0] + .[1]' <(echo "$all") <(echo "$batch_names"))
        if [ "$batch_len" -lt 1000 ]; then break; fi
        skip=$((skip + batch_len))
      else
        break
      fi
    else
      break
    fi
  done
  echo "$all"
}

get_ado_tags() {
  local repo_encoded="$1"
  local skip=0
  local all="[]"
  while true; do
    local url="https://dev.azure.com/$ADOOrg/$ADOProject/_apis/git/repositories/${repo_encoded}/refs?filter=tags/&\$top=1000&\$skip=${skip}&api-version=7.1"
    local resp
    resp=$(curl -s -u ":$adoPat" -H "Accept: application/json" "$url" || echo "")
    if [ -n "$resp" ] && echo "$resp" | jq -e '.value' >/dev/null 2>&1; then
      local batch_len
      batch_len=$(echo "$resp" | jq '.value | length')
      if [ "$batch_len" -gt 0 ]; then
        local batch_names
        batch_names=$(echo "$resp" | jq '.value | map(.name | sub("^refs/tags/"; ""))')
        all=$(jq -s '.[0] + .[1]' <(echo "$all") <(echo "$batch_names"))
        if [ "$batch_len" -lt 1000 ]; then break; fi
        skip=$((skip + batch_len))
      else
        break
      fi
    else
      break
    fi
  done
  echo "$all"
}

get_ado_pr_count() {
  local repo_encoded="$1"
  local total=0
  for status in "completed" "active"; do
    local skip=0
    while true; do
      local url="https://dev.azure.com/$ADOOrg/$ADOProject/_apis/git/repositories/${repo_encoded}/pullrequests?searchCriteria.status=${status}&\$top=1000&\$skip=${skip}&api-version=7.1"
      local resp
      resp=$(curl -s -u ":$adoPat" -H "Accept: application/json" "$url" || echo "")
      if [ -n "$resp" ] && echo "$resp" | jq -e '.value' >/dev/null 2>&1; then
        local batch_len
        batch_len=$(echo "$resp" | jq '.value | length')
        total=$((total + batch_len))
        if [ "$batch_len" -lt 1000 ]; then break; fi
        skip=$((skip + batch_len))
      else
        break
      fi
    done
  done
  echo "$total"
}

get_github_branches() {
  local repo="$1"
  local page=1
  local all="[]"
  while true; do
    local resp
    resp=$(gh api "repos/$GHOrg/$repo/branches?per_page=100&page=${page}" 2>/dev/null || echo "[]")
    local len
    len=$(echo "$resp" | jq '. | length')
    if [ "$len" -gt 0 ]; then
      local names
      names=$(echo "$resp" | jq 'map(.name)')
      all=$(jq -s '.[0] + .[1]' <(echo "$all") <(echo "$names"))
      if [ "$len" -lt 100 ]; then break; fi
      page=$((page + 1))
    else
      break
    fi
  done
  echo "$all"
}

get_github_tags() {
  local repo="$1"
  local page=1
  local all="[]"
  while true; do
    local resp
    resp=$(gh api "repos/$GHOrg/$repo/tags?per_page=100&page=${page}" 2>/dev/null || echo "[]")
    local len
    len=$(echo "$resp" | jq '. | length')
    if [ "$len" -gt 0 ]; then
      local names
      names=$(echo "$resp" | jq 'map(.name)')
      all=$(jq -s '.[0] + .[1]' <(echo "$all") <(echo "$names"))
      if [ "$len" -lt 100 ]; then break; fi
      page=$((page + 1))
    else
      break
    fi
  done
  echo "$all"
}

allResults="[]"
totalPass=0
totalFail=0
totalWarn=0

for ((r_idx=0; r_idx<len_repos; r_idx++)); do
  repo_entry=$(echo "$repoList" | jq ".[$r_idx]")
  adoRepoName=$(echo "$repo_entry" | jq -r ".ADORepo")
  ghRepoName=$(echo "$repo_entry" | jq -r ".GHRepo")
  migState=$(echo "$repo_entry" | jq -r ".State")
  auditDir="$OutputDir/audit/$ghRepoName"

  if [ "$migState" = "SKIPPED" ]; then
    echo ""
    echo "--- Skipping: $adoRepoName -> $ghRepoName --- (migration was SKIPPED - repo already existed)"
    allResults=$(jq --arg ado "$adoRepoName" --arg gh "$ghRepoName" \
      '. + [{ADORepo: $ado, GHRepo: $gh, Status: "SKIPPED", Accuracy: "N/A", PassCount: 0, FailCount: 0, WarnCount: 0, Checks: []}]' <<< "$allResults")
    continue
  fi

  echo ""
  echo "--- Validating: $adoRepoName -> $ghRepoName ---"

  repoChecks="[]"
  repoPassCount=0
  repoFailCount=0
  repoWarnCount=0

  add_check() {
    local name="$1"
    local sourceVal="$2"
    local targetVal="$3"
    local pass="$4"
    local detail="${5:-}"
    
    local checkStatus="FAIL"
    if [ "$pass" = "true" ]; then
      checkStatus="PASS"
      repoPassCount=$((repoPassCount + 1))
      totalPass=$((totalPass + 1))
      echo "    [PASS] $name"
    else
      repoFailCount=$((repoFailCount + 1))
      totalFail=$((totalFail + 1))
      echo "    [FAIL] $name  source=[$sourceVal] target=[$targetVal] $detail"
    fi
    
    repoChecks=$(jq --arg ck "$name" --arg src "$sourceVal" --arg tg "$targetVal" --arg st "$checkStatus" --arg dt "$detail" \
      '. + [{Check: $ck, Source: $src, Target: $tg, Status: $st, Detail: $dt}]' <<< "$repoChecks")
  }

  add_warn() {
    local name="$1"
    local detail="$2"
    
    repoWarnCount=$((repoWarnCount + 1))
    totalWarn=$((totalWarn + 1))
    echo "    [WARN] $name -- $detail"
    
    repoChecks=$(jq --arg ck "$name" --arg src "N/A" --arg tg "N/A" --arg st "WARN" --arg dt "$detail" \
      '. + [{Check: $ck, Source: $src, Target: $tg, Status: $st, Detail: $dt}]' <<< "$repoChecks")
  }

  # 1. Repo Exists on GitHub
  set +e
  ghRepoCheck=$(gh repo view "$GHOrg/$ghRepoName" --json name --jq .name 2>/dev/null)
  exitCode=$?
  set -e
  if [ $exitCode -ne 0 ] || [ -z "$ghRepoCheck" ]; then
    add_check "Repo Exists on GitHub" "expected" "NOT FOUND" "false"
    allResults=$(jq --arg ado "$adoRepoName" --arg gh "$ghRepoName" --argjson pc "$repoPassCount" --argjson fc "$repoFailCount" --argjson wc "$repoWarnCount" --argjson cks "$repoChecks" \
      '. + [{ADORepo: $ado, GHRepo: $gh, Status: "FAIL_NOT_FOUND", Accuracy: 0, PassCount: $pc, FailCount: $fc, WarnCount: $wc, Checks: $cks}]' <<< "$allResults")
    continue
  fi
  add_check "Repo Exists on GitHub" "yes" "yes" "true"

  # Fetch GitHub defaults
  ghDefault=$(gh repo view "$GHOrg/$ghRepoName" --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null || echo "")
  ghVisibility=$(gh repo view "$GHOrg/$ghRepoName" --json visibility --jq .visibility 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "")

  # 2. Fetch ADO data
  adoRepoEncoded=$(jq -rn --arg val "$adoRepoName" '$val|@uri')
  adoRepoUrl="https://dev.azure.com/$ADOOrg/$ADOProject/_apis/git/repositories/$adoRepoEncoded"
  
  adoRepoJson=""
  adoDefault=""
  set +e
  adoRepoJson=$(curl -s -u ":$adoPat" -H "Accept: application/json" "${adoRepoUrl}?api-version=7.1" 2>/dev/null)
  set -e
  if [ -n "$adoRepoJson" ] && echo "$adoRepoJson" | jq -e '.defaultBranch' >/dev/null 2>&1; then
    rawDefault=$(echo "$adoRepoJson" | jq -r '.defaultBranch // empty')
    adoDefault=${rawDefault#refs/heads/}
  else
    add_warn "ADO API Access" "Cannot fetch ADO repo metadata"
  fi

  adoBranches="[]"
  set +e
  adoBranches=$(get_ado_branches "$adoRepoEncoded")
  set -e
  adoBranchCount=$(echo "$adoBranches" | jq '. | length')

  adoPrCount=0
  set +e
  adoPrCount=$(get_ado_pr_count "$adoRepoEncoded")
  set -e

  adoTags="[]"
  set +e
  adoTags=$(get_ado_tags "$adoRepoEncoded")
  set -e
  adoTagCount=$(echo "$adoTags" | jq '. | length')

  # 3. GitHub branches
  ghBranches=$(get_github_branches "$ghRepoName")
  ghBranchCount=$(echo "$ghBranches" | jq '. | length')

  # 4. Branch count
  # Load audit branch count as fallback if ADO branches couldn't be loaded
  if [ "$adoBranchCount" -eq 0 ]; then
    auditBranchCount=$( [ -f "$auditDir/gh-branch-count.txt" ] && cat "$auditDir/gh-branch-count.txt" | xargs || echo "" )
    if [ -n "$auditBranchCount" ] && [ "$auditBranchCount" != "N/A" ]; then
      adoBranchCount="$auditBranchCount"
    fi
  fi

  branchTolerance=0
  if [ "$adoBranchCount" -gt 100 ]; then
    branchTolerance=$(( (adoBranchCount + 99) / 100 ))
  fi
  diff_branch=$(( adoBranchCount - ghBranchCount ))
  if [ "$diff_branch" -lt 0 ]; then
    diff_branch=$(( -diff_branch ))
  fi
  branchMatch="false"
  if [ "$diff_branch" -le "$branchTolerance" ]; then
    branchMatch="true"
  fi

  branchDetail="ADO=$adoBranchCount GH=$ghBranchCount"
  add_check "Branch Count" "$adoBranchCount" "$ghBranchCount" "$branchMatch" "$branchDetail"

  # Show branch list preview in logs
  maxShow=20
  if [ "$adoBranchCount" -gt 0 ]; then
    adoSorted=$(echo "$adoBranches" | jq -r 'sort[]' | head -n $maxShow | tr '\n' ',' | sed 's/,$//')
    adoMore=""
    if [ "$adoBranchCount" -gt "$maxShow" ]; then
      adoMore=" ... and $((adoBranchCount - maxShow)) more"
    fi
    echo "      ADO Branches ($adoBranchCount): $adoSorted$adoMore"
  fi
  if [ "$ghBranchCount" -gt 0 ]; then
    ghSorted=$(echo "$ghBranches" | jq -r 'sort[]' | head -n $maxShow | tr '\n' ',' | sed 's/,$//')
    ghMore=""
    if [ "$ghBranchCount" -gt "$maxShow" ]; then
      ghMore=" ... and $((ghBranchCount - maxShow)) more"
    fi
    echo "      GH  Branches ($ghBranchCount): $ghSorted$ghMore"
  fi

  # 5. Missing branches
  if [ "$adoBranchCount" -gt 0 ]; then
    missing=$(jq -n --argjson ado "$adoBranches" --argjson gh "$ghBranches" '$ado - $gh')
    missingCount=$(echo "$missing" | jq '. | length')
    if [ "$missingCount" -gt 0 ]; then
      mShown=$(echo "$missing" | jq -r '.[]' | head -n 10 | tr '\n' ',' | sed 's/,$//')
      mMore=""
      if [ "$missingCount" -gt 10 ]; then
        mMore=" ... and $((missingCount - 10)) more"
      fi
      add_check "No Missing Branches" "$adoBranchCount" "$missingCount missing" "false" "$mShown$mMore"
    else
      add_check "No Missing Branches" "all present" "all present" "true"
    fi
  fi

  # 6. Default branch
  if [ -z "$ghDefault" ]; then ghDefault="N/A"; fi
  echo "      Default Branch: ADO=[$adoDefault] GH=[$ghDefault]"
  if [ -n "$adoDefault" ]; then
    defMatch="false"
    if [ "$adoDefault" = "$ghDefault" ]; then defMatch="true"; fi
    add_check "Default Branch" "$adoDefault" "$ghDefault" "$defMatch"
  else
    auditDefault=$( [ -f "$auditDir/gh-default-branch.txt" ] && cat "$auditDir/gh-default-branch.txt" | xargs || echo "" )
    if [ -n "$auditDefault" ]; then
      defMatch="false"
      if [ "$auditDefault" = "$ghDefault" ]; then defMatch="true"; fi
      add_check "Default Branch (audit)" "$auditDefault" "$ghDefault" "$defMatch"
    else
      add_warn "Default Branch" "ADO default branch not available for comparison"
    fi
  fi

  # 7. Tag count
  ghTags=$(get_github_tags "$ghRepoName")
  ghTagCount=$(echo "$ghTags" | jq '. | length')
  
  if [ "$adoTagCount" -gt 0 ]; then
    missingTags=$(jq -n --argjson ado "$adoTags" --argjson gh "$ghTags" '$ado - $gh')
    missingTagsCount=$(echo "$missingTags" | jq '. | length')
    tagDetail=""
    if [ "$missingTagsCount" -gt 0 ]; then
      mTagsShown=$(echo "$missingTags" | jq -r '.[]' | head -n 10 | tr '\n' ',' | sed 's/,$//')
      mTagsMore=""
      if [ "$missingTagsCount" -gt 10 ]; then
        mTagsMore=" ... and $((missingTagsCount - 10)) more"
      fi
      tagDetail="$missingTagsCount missing: $mTagsShown$mTagsMore"
    fi
    tagMatch="false"
    if [ "$adoTagCount" -eq "$ghTagCount" ]; then tagMatch="true"; fi
    add_check "Tag Count" "$adoTagCount" "$ghTagCount" "$tagMatch" "$tagDetail"
  else
    auditTagCount=$( [ -f "$auditDir/gh-tag-count.txt" ] && cat "$auditDir/gh-tag-count.txt" | xargs || echo "" )
    if [ -n "$auditTagCount" ] && [ "$auditTagCount" != "N/A" ]; then
      tagMatch="false"
      if [ "$auditTagCount" -eq "$ghTagCount" ]; then tagMatch="true"; fi
      add_check "Tag Count (audit)" "$auditTagCount" "$ghTagCount" "$tagMatch"
    fi
  fi

  # 8. PR count
  ghPrCount=0
  set +e
  prSearchRaw=$(gh api "search/issues?q=repo:$GHOrg/$ghRepoName+type:pr" 2>/dev/null)
  set -e
  if [ -n "$prSearchRaw" ]; then
    ghPrCount=$(echo "$prSearchRaw" | jq '.total_count // 0')
  fi
  
  if [ "$adoPrCount" -gt 0 ]; then
    prDiff=$(( adoPrCount - ghPrCount ))
    if [ "$prDiff" -lt 0 ]; then prDiff=$(( -prDiff )); fi
    prMatch="false"
    if [ "$prDiff" -le 2 ]; then prMatch="true"; fi
    prDetail=""
    if [ "$prDiff" -gt 2 ]; then prDetail="Difference: $prDiff"; fi
    add_check "PR Count (+/-2 tolerance)" "$adoPrCount" "$ghPrCount" "$prMatch" "$prDetail"
  else
    auditPrCount=$( [ -f "$auditDir/gh-pr-count.txt" ] && cat "$auditDir/gh-pr-count.txt" | xargs || echo "" )
    if [ -n "$auditPrCount" ] && [ "$auditPrCount" != "N/A" ]; then
      add_warn "PR Count" "ADO PR count unavailable; GitHub has $ghPrCount (audit: $auditPrCount)"
    fi
  fi

  # 9. Repo visibility
  if [ -z "$ghVisibility" ]; then ghVisibility="unknown"; fi
  adoVisibility="unknown"
  set +e
  projResp=$(curl -s -u ":$adoPat" -H "Accept: application/json" "https://dev.azure.com/$ADOOrg/_apis/projects/${ADOProject}?api-version=7.1" 2>/dev/null)
  set -e
  if [ -n "$projResp" ] && echo "$projResp" | jq -e '.visibility' >/dev/null 2>&1; then
    adoVisibility=$(echo "$projResp" | jq -r '.visibility' | tr '[:upper:]' '[:lower:]')
  fi
  echo "      Visibility   : ADO=$adoVisibility -> GitHub=$ghVisibility (expected=$ExpectedVisibility)"
  visMatch="false"
  if [ "$ghVisibility" = "$ExpectedVisibility" ]; then visMatch="true"; fi
  add_check "Visibility" "$adoVisibility" "$ghVisibility" "$visMatch"

  # 10. Latest commit reachable
  auditHash=$( [ -f "$auditDir/gh-latest-hash.txt" ] && cat "$auditDir/gh-latest-hash.txt" | xargs || echo "" )
  if [ -n "$auditHash" ] && [ "$auditHash" != "N/A" ]; then
    set +e
    commitRaw=$(gh api "repos/$GHOrg/$ghRepoName/git/commits/$auditHash" 2>/dev/null)
    exitCode=$?
    set -e
    if [ $exitCode -eq 0 ] && [ -n "$commitRaw" ]; then
      ghCommitSha=$(echo "$commitRaw" | jq -r '.sha')
      add_check "Latest Commit Reachable" "${auditHash:0:12}" "${ghCommitSha:0:12}" "true"
    else
      add_check "Latest Commit Reachable" "${auditHash:0:12}" "not found" "false" "Commit SHA from audit not found in GitHub"
    fi
  else
    add_warn "Latest Commit Check" "No audit hash available"
  fi

  # 11. Branch protection on default branch
  set +e
  bpRaw=$(gh api "repos/$GHOrg/$ghRepoName/branches/$ghDefault/protection" 2>/dev/null)
  exitCode=$?
  set -e
  if [ $exitCode -eq 0 ] && [ -n "$bpRaw" ]; then
    add_check "Branch Protection" "configured" "configured" "true"
  else
    add_warn "Branch Protection" "No branch protection on default branch '$ghDefault'"
  fi

  # Overall Results
  repoStatus="PASS"
  if [ "$repoFailCount" -gt 0 ]; then
    repoStatus="FAIL"
  fi
  
  accuracy=0
  totalChecks=$(( repoPassCount + repoFailCount ))
  if [ $totalChecks -gt 0 ]; then
    accuracy=$(echo "scale=1; ($repoPassCount * 100) / $totalChecks" | bc -l 2>/dev/null || echo "$(( (repoPassCount * 100) / totalChecks ))")
  fi

  echo "  --- Result: $repoStatus  Accuracy: $accuracy%  ($repoPassCount PASS / $repoFailCount FAIL / $repoWarnCount WARN) ---"

  allResults=$(jq --arg ado "$adoRepoName" --arg gh "$ghRepoName" --arg st "$repoStatus" --argjson acc "$accuracy" \
    --argjson pc "$repoPassCount" --argjson fc "$repoFailCount" --argjson wc "$repoWarnCount" --argjson cks "$repoChecks" \
    '. + [{ADORepo: $ado, GHRepo: $gh, Status: $st, Accuracy: $acc, PassCount: $pc, FailCount: $fc, WarnCount: $wc, Checks: $cks}]' <<< "$allResults")
done

# Write JSON + CSV
jsonPath="$reportDir/validation-results.json"
csvPath="$reportDir/validation-results.csv"

echo "$allResults" | jq . > "$jsonPath"

# Flat CSV
flat_csv="\"ADORepo\",\"GHRepo\",\"RepoStatus\",\"Check\",\"Source\",\"Target\",\"Status\",\"Detail\"\n"
len_results=$(echo "$allResults" | jq '. | length')
for ((idx=0; idx<len_results; idx++)); do
  repo_obj=$(echo "$allResults" | jq ".[$idx]")
  ado=$(echo "$repo_obj" | jq -r ".ADORepo")
  gh=$(echo "$repo_obj" | jq -r ".GHRepo")
  st=$(echo "$repo_obj" | jq -r ".Status")
  
  len_checks=$(echo "$repo_obj" | jq ".Checks | length")
  for ((cidx=0; cidx<len_checks; cidx++)); do
    check_obj=$(echo "$repo_obj" | jq ".Checks[$cidx]")
    ckName=$(echo "$check_obj" | jq -r ".Check")
    ckSrc=$(echo "$check_obj" | jq -r ".Source")
    ckTg=$(echo "$check_obj" | jq -r ".Target")
    ckSt=$(echo "$check_obj" | jq -r ".Status")
    ckDt=$(echo "$check_obj" | jq -r ".Detail")
    
    ckSrc=$(echo "$ckSrc" | sed 's/"/""/g')
    ckTg=$(echo "$ckTg" | sed 's/"/""/g')
    ckDt=$(echo "$ckDt" | sed 's/"/""/g')
    
    flat_csv+="\"$ado\",\"$gh\",\"$st\",\"$ckName\",\"$ckSrc\",\"$ckTg\",\"$ckSt\",\"$ckDt\"\n"
  done
done
echo -ne "$flat_csv" > "$csvPath"

# Generate HTML report
migDate=$(date +"%d %b %Y . %H:%M")
totalRepos=$len_results
passRepos=$(echo "$allResults" | jq '[.[] | select(.Status == "PASS")] | length')
skippedRepos=$(echo "$allResults" | jq '[.[] | select(.Status == "SKIPPED")] | length')
failRepos=$(echo "$allResults" | jq '[.[] | select(.Status != "PASS" and .Status != "SKIPPED")] | length')

overallAccuracy=0
totalPassFail=$(( totalPass + totalFail ))
if [ $totalPassFail -gt 0 ]; then
  overallAccuracy=$(echo "scale=1; ($totalPass * 100) / $totalPassFail" | bc -l 2>/dev/null || echo "$(( (totalPass * 100) / totalPassFail ))")
fi

overallColor="#28a745"
overallBg="#e6f9ed"
overallStatus="[PASS] All repos passed validation"
if [ "$failRepos" -gt 0 ]; then
  overallColor="#dc3545"
  overallBg="#fdecea"
  overallStatus="[FAIL] $failRepos repo(s) failed validation"
fi

accuracyColor="#dc3545"
oa_int=${overallAccuracy%.*}
oa_int=${oa_int:-0}
if [ "$oa_int" -ge 90 ]; then
  accuracyColor="#28a745"
elif [ "$oa_int" -ge 70 ]; then
  accuracyColor="#f0ad4e"
fi

tableRows=""
for ((idx=0; idx<len_results; idx++)); do
  repo_obj=$(echo "$allResults" | jq ".[$idx]")
  ado=$(echo "$repo_obj" | jq -r ".ADORepo")
  gh=$(echo "$repo_obj" | jq -r ".GHRepo")
  st=$(echo "$repo_obj" | jq -r ".Status")
  acc=$(echo "$repo_obj" | jq -r ".Accuracy")
  pc=$(echo "$repo_obj" | jq -r ".PassCount")
  fc=$(echo "$repo_obj" | jq -r ".FailCount")
  
  if [ "$st" = "PASS" ]; then
    badge="<span style='background:#dafbe1;color:#1a7f37;padding:4px 12px;border-radius:12px;font-weight:600;'>[PASS]</span>"
  elif [ "$st" = "SKIPPED" ]; then
    badge="<span style='background:#e8eaed;color:#586069;padding:4px 12px;border-radius:12px;font-weight:600;'>[SKIPPED]</span>"
  else
    badge="<span style='background:#fdecea;color:#cf222e;padding:4px 12px;border-radius:12px;font-weight:600;'>[FAIL]</span>"
  fi
  
  details=""
  len_checks=$(echo "$repo_obj" | jq ".Checks | length")
  for ((cidx=0; cidx<len_checks; cidx++)); do
    check_obj=$(echo "$repo_obj" | jq ".Checks[$cidx]")
    ckName=$(echo "$check_obj" | jq -r ".Check")
    ckSrc=$(echo "$check_obj" | jq -r ".Source")
    ckTg=$(echo "$check_obj" | jq -r ".Target")
    ckSt=$(echo "$check_obj" | jq -r ".Status")
    ckDt=$(echo "$check_obj" | jq -r ".Detail")
    
    if [ "$ckSt" = "PASS" ]; then
      cColor="#28a745"
      cIcon="[PASS]"
    elif [ "$ckSt" = "FAIL" ]; then
      cColor="#dc3545"
      cIcon="[FAIL]"
    else
      cColor="#f0ad4e"
      cIcon="[WARN]"
    fi
    details+="<tr style='font-size:13px;'><td style='padding:6px 12px;color:$cColor;'>$cIcon $ckName</td><td style='padding:6px 12px;'>$ckSrc</td><td style='padding:6px 12px;'>$ckTg</td><td style='padding:6px 12px;color:#666;font-size:12px;'>$ckDt</td></tr>"
  done
  
  repoAccColor="#dc3545"
  acc_int=${acc%.*}
  acc_int=${acc_int:-0}
  if [ "$acc_int" -ge 90 ]; then
    repoAccColor="#28a745"
  elif [ "$acc_int" -ge 70 ]; then
    repoAccColor="#f0ad4e"
  fi
  
  tableRows+="
  <tr>
    <td><code>$ado</code></td>
    <td><code>$gh</code></td>
    <td>$badge</td>
    <td style='text-align:center;font-weight:700;color:$repoAccColor;font-size:16px;'>$acc%</td>
    <td style='text-align:center;color:#28a745;font-weight:600;'>$pc</td>
    <td style='text-align:center;color:#dc3545;font-weight:600;'>$fc</td>
  </tr>
  <tr><td colspan='6' style='padding:0;'>
    <details style='margin:0 8px 8px;'><summary style='cursor:pointer;font-size:13px;color:#0969da;padding:6px;'>View check details</summary>
      <table style='width:100%;font-size:13px;margin-top:4px;'>
        <thead><tr style='background:#f6f8fa;'><th style='padding:6px 12px;'>Check</th><th style='padding:6px 12px;'>Source</th><th style='padding:6px 12px;'>Target</th><th style='padding:6px 12px;'>Notes</th></tr></thead>
        <tbody>$details</tbody>
      </table>
    </details>
  </td></tr>"
done

html_content="<!DOCTYPE html>
<html lang='en'>
<head>
<meta charset='UTF-8'>
<title>Validation Report</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif; background: #f4f6f9; color: #333; padding: 30px; }
  .container { max-width: 1100px; margin: 0 auto; }
  .header { background: linear-gradient(135deg, #0d1117, #161b22); color: #fff; padding: 32px; border-radius: 14px; margin-bottom: 24px; }
  .header h1 { font-size: 26px; margin-bottom: 10px; }
  .status-banner { display: inline-block; padding: 10px 22px; border-radius: 8px; font-size: 17px; font-weight: 600; background: $overallBg; color: $overallColor; border: 2px solid $overallColor; }
  .card { background: #fff; border-radius: 12px; padding: 24px; margin-bottom: 20px; box-shadow: 0 2px 8px rgba(0,0,0,.06); }
  .card h2 { font-size: 20px; margin-bottom: 16px; border-bottom: 2px solid #e1e4e8; padding-bottom: 8px; }
  .stat-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(130px, 1fr)); gap: 14px; margin-bottom: 16px; }
  .stat-box { background: #f6f8fa; border-radius: 10px; padding: 18px; text-align: center; border: 1px solid #e1e4e8; }
  .stat-box .num { font-size: 28px; font-weight: 700; color: #0d1117; }
  .stat-box .label { font-size: 13px; color: #666; margin-top: 4px; }
  table { width: 100%; border-collapse: collapse; }
  th { background: #f6f8fa; padding: 11px 14px; font-weight: 600; border-bottom: 2px solid #d0d7de; text-align: left; }
  td { padding: 10px 14px; border-bottom: 1px solid #eaecef; }
  tr:hover { background: #fafafa; }
  code { background: #eff1f3; padding: 2px 7px; border-radius: 4px; font-size: 13px; }
  .footer { text-align: center; color: #999; font-size: 13px; margin-top: 24px; padding-top: 14px; border-top: 1px solid #e1e4e8; }
</style>
</head>
<body>
<div class='container'>
  <div class='header'>
    <h1>[VALIDATION] Migration Validation Report</h1>
    <div class='status-banner'>$overallStatus</div>
    <div class='status-banner' style='margin-left:16px;background:#fff;color:$accuracyColor;border-color:$accuracyColor;font-size:20px;'>[ACCURACY] $overallAccuracy% Accuracy</div>
  </div>
  <div class='card'>
    <h2>[SUMMARY] Overview</h2>
    <div class='stat-grid'>
      <div class='stat-box' style='border:2px solid $accuracyColor;'><div class='num' style='color:$accuracyColor;font-size:32px;'>$overallAccuracy%</div><div class='label'>[ACCURACY] Migration Accuracy</div></div>
      <div class='stat-box'><div class='num'>$totalRepos</div><div class='label'>Total Repos</div></div>
      <div class='stat-box'><div class='num' style='color:#28a745;'>$passRepos</div><div class='label'>[PASS] Passed</div></div>
      <div class='stat-box'><div class='num' style='color:#6a737d;'>$skippedRepos</div><div class='label'>[SKIPPED] Skipped</div></div>
      <div class='stat-box'><div class='num' style='color:#dc3545;'>$failRepos</div><div class='label'>[FAIL] Failed</div></div>
      <div class='stat-box'><div class='num'>$totalPass</div><div class='label'>Checks Passed</div></div>
      <div class='stat-box'><div class='num' style='color:#dc3545;'>$totalFail</div><div class='label'>Checks Failed</div></div>
    </div>
  </div>
  <div class='card'>
    <h2>[RESULTS] Repo-by-Repo Results</h2>
    <table>
      <thead>
        <tr>
          <th>ADO Repo</th>
          <th>GitHub Repo</th>
          <th>Status</th>
          <th style='text-align:center;'>Accuracy</th>
          <th style='text-align:center;'>Pass</th>
          <th style='text-align:center;'>Fail</th>
        </tr>
      </thead>
      <tbody>
        $tableRows
      </tbody>
    </table>
  </div>
  <div class='footer'>Generated $migDate &bull; ADO-to-GitHub Migration Validation</div>
</div>
</body>
</html>"

htmlPath="$reportDir/validation-report.html"
echo -n "$html_content" > "$htmlPath"

# Markdown summary
md_summary="# Migration Validation Report\n\n"
md_summary+="> Generated: $migDate\n\n"
md_summary+="| Metric | Value |\n|:---|---:|\n"
md_summary+="| Total repos validated | $totalRepos |\n"
md_summary+="| [ACCURACY] Migration Accuracy | **$overallAccuracy%** |\n"
md_summary+="| [PASS] PASS | $passRepos |\n"
md_summary+="| [SKIPPED] SKIPPED | $skippedRepos |\n"
md_summary+="| [FAIL] FAIL | $failRepos |\n\n"

if [ "$failRepos" -gt 0 ]; then
  md_summary+="## Failed Repos\n\n"
  for ((idx=0; idx<len_results; idx++)); do
    repo_obj=$(echo "$allResults" | jq ".[$idx]")
    ado=$(echo "$repo_obj" | jq -r ".ADORepo")
    gh=$(echo "$repo_obj" | jq -r ".GHRepo")
    st=$(echo "$repo_obj" | jq -r ".Status")
    
    if [ "$st" != "PASS" ] && [ "$st" != "SKIPPED" ]; then
      md_summary+="### \`$gh\`\n\n"
      len_checks=$(echo "$repo_obj" | jq ".Checks | length")
      for ((cidx=0; cidx<len_checks; cidx++)); do
        check_obj=$(echo "$repo_obj" | jq ".Checks[$cidx]")
        ckName=$(echo "$check_obj" | jq -r ".Check")
        ckSrc=$(echo "$check_obj" | jq -r ".Source")
        ckTg=$(echo "$check_obj" | jq -r ".Target")
        ckSt=$(echo "$check_obj" | jq -r ".Status")
        ckDt=$(echo "$check_obj" | jq -r ".Detail")
        
        if [ "$ckSt" = "FAIL" ]; then
          md_summary+="- [FAIL] **$ckName** -- Source: \`$ckSrc\` Target: \`$ckTg\` $ckDt\n"
        fi
      done
      md_summary+="\n"
    fi
  done
fi

mdPath="$reportDir/validation-summary.md"
echo -e "$md_summary" > "$mdPath"

# Console summary
echo ""
if [ "$failRepos" -eq 0 ]; then
  echo "============================================"
  echo "  VALIDATION SUMMARY [PASS]"
else
  echo "============================================"
  echo "  VALIDATION SUMMARY [FAIL]"
fi
echo "  Total repos : $totalRepos"
echo "  Accuracy    : $overallAccuracy%"
echo "  PASS        : $passRepos"
echo "  SKIPPED     : $skippedRepos"
echo "  FAIL        : $failRepos"
echo "============================================"
echo ""
echo "  JSON    : $jsonPath"
echo "  CSV     : $csvPath"
echo "  HTML    : $htmlPath"
echo "  Summary : $mdPath"

if [ "$failRepos" -gt 0 ]; then
  echo ""
  echo "Failed repos:"
  for ((idx=0; idx<len_results; idx++)); do
    repo_obj=$(echo "$allResults" | jq ".[$idx]")
    gh=$(echo "$repo_obj" | jq -r ".GHRepo")
    st=$(echo "$repo_obj" | jq -r ".Status")
    if [ "$st" != "PASS" ] && [ "$st" != "SKIPPED" ]; then
      echo "  - $gh"
    fi
  done
fi

exit 0
