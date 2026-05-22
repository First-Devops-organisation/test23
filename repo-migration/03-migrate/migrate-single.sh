#!/usr/bin/env bash

# SYNOPSIS
#     Migrates a SINGLE repo from ADO to GitHub using GEI (gh ado2gh).
#     Converted from PowerShell to native Linux Bash.

set -euo pipefail

# -- Parse arguments ----------------------------------------------------------
ADOOrg=""
ADOProject=""
ADORepo=""
GHOrg=""
GHRepo=""
ConfigPath=""
OutputDir=""
TargetRepoVisibility="private"
SkipAudit=false
DryRun=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG_PATH="${SCRIPT_DIR}/../config/repo-migration-config.json"
DEFAULT_OUTPUT_DIR="${SCRIPT_DIR}/../output"

while [[ $# -gt 0 ]]; do
  case $1 in
    --ado-org|-ADOOrg) ADOOrg="$2"; shift 2 ;;
    --ado-project|-ADOProject) ADOProject="$2"; shift 2 ;;
    --ado-repo|-ADORepo) ADORepo="$2"; shift 2 ;;
    --github-org|-GHOrg) GHOrg="$2"; shift 2 ;;
    --github-repo|-GHRepo) GHRepo="$2"; shift 2 ;;
    --config-path|-ConfigPath) ConfigPath="$2"; shift 2 ;;
    --output-dir|-OutputDir) OutputDir="$2"; shift 2 ;;
    --target-repo-visibility|-TargetRepoVisibility) TargetRepoVisibility="$2"; shift 2 ;;
    --skip-audit|-SkipAudit) SkipAudit=true; shift ;;
    --dry-run|-DryRun) DryRun=true; shift ;;
    *) echo "Error: Unknown parameter: $1" >&2; exit 1 ;;
  esac
done

# Resolve defaults
ConfigPath="${ConfigPath:-$DEFAULT_CONFIG_PATH}"
OutputDir="${OutputDir:-$DEFAULT_OUTPUT_DIR}"

# Trim whitespace
ADOOrg=$(echo "$ADOOrg" | xargs)
ADOProject=$(echo "$ADOProject" | xargs)
GHOrg=$(echo "$GHOrg" | xargs)
ADORepo=$(echo "$ADORepo" | xargs)
GHRepo=$(echo "$GHRepo" | xargs)
TargetRepoVisibility=$(echo "$TargetRepoVisibility" | xargs)

# -- Fallback: if ADORepo is empty, try to read from config.json ---------------
if [ -z "$ADORepo" ]; then
  echo "  ADORepo parameter is empty - checking config.json..."
  if [ -f "$ConfigPath" ]; then
    cfg_single=$(jq -r '.migration.singleRepo // empty' "$ConfigPath")
    if [ -n "$cfg_single" ]; then
      ADORepo=$(echo "$cfg_single" | xargs)
      echo "  Found default repo in config: $ADORepo"
    fi
  fi
fi

if [ -z "$ADORepo" ]; then
  echo "Error: ADORepo name is required. Provide it as a parameter or set 'migration.singleRepo' in config.json." >&2
  exit 1
fi

if [ -z "$GHRepo" ]; then
  echo "  GHRepo was empty - defaulting to ADORepo: '$ADORepo'"
  GHRepo="$ADORepo"
fi

# Now that we have the final GHRepo name, set the state file path
stateFile="$OutputDir/logs/migration-state-$GHRepo.txt"

# -- Normalize ADOOrg - strip full URL if user set it as https://dev.azure.com/<org> --
if [[ "$ADOOrg" =~ ^https?://dev\.azure\.com/([^/]+)/?$ ]]; then
  echo "  Normalising ADOOrg: stripping URL prefix -> '${BASH_REMATCH[1]}'"
  ADOOrg="${BASH_REMATCH[1]}"
fi

# -- Normalize GHOrg - strip full URL if user set it as https://github.com/<org> --
if [[ "$GHOrg" =~ ^https?://github\.com/([^/]+)/?$ ]]; then
  echo "  Normalising GHOrg: stripping URL prefix -> '${BASH_REMATCH[1]}'"
  GHOrg="${BASH_REMATCH[1]}"
fi

# -- Validate PATs ------------------------------------------------------------
ghPat="${GH_PAT:-}"
adoPat="${ADO_PAT:-}"
if [ -z "$ghPat" ]; then  echo "Error: Set GH_PAT environment variable" >&2; exit 1; fi
if [ -z "$adoPat" ]; then echo "Error: Set ADO_PAT environment variable" >&2; exit 1; fi

# Set GH_TOKEN once for all gh CLI calls
export GH_TOKEN="$ghPat"

# -- Output directories -------------------------------------------------------
reportDir="$OutputDir/reports"
logDir="$OutputDir/logs"
auditDir="$OutputDir/audit/$GHRepo"
dashDir="$OutputDir/dashboard/$GHRepo"
folderDir="$auditDir/folder-listing"

for d in "$reportDir" "$logDir" "$auditDir" "$dashDir" "$folderDir"; do
  mkdir -p "$d"
done

precheckFile="$logDir/repo-precheck-$GHRepo.txt"

echo "============================================"
echo "  SINGLE REPO MIGRATION"
echo "  ADO:    $ADOOrg / $ADOProject / $ADORepo"
echo "  GitHub: $GHOrg / $GHRepo"
echo "  DryRun: $DryRun"
echo "============================================"

# ============================================================================
# STEP 1 - Authenticate & install ado2gh extension
# ============================================================================
echo ""
echo "[Step 1] Authenticate GitHub CLI..."
echo "  Authenticating via GH_TOKEN environment variable."
gh auth status || true

if ! gh extension list 2>&1 | grep -q 'ado2gh'; then
  echo "  Installing gh-ado2gh extension..."
  gh extension install github/gh-ado2gh || true
else
  echo "  ado2gh extension already installed."
fi
gh extension list

# ============================================================================
# STEP 2 - Pre-check: does the GitHub repo already exist?
# ============================================================================
echo ""
echo "[Step 2] Pre-check repo existence in GitHub..."
repoStatus="NOT_EXISTS"

actualName=$(gh repo view "$GHOrg/$GHRepo" --json name --jq .name 2>/dev/null || echo "")

if [ -n "$actualName" ] && [ "$actualName" = "$GHRepo" ]; then
  echo "  Repo already exists: $GHOrg/$GHRepo"
  repoStatus="ALREADY_EXISTS"
elif [ -n "$actualName" ] && [ "$actualName" != "$GHRepo" ]; then
  echo "  Detected redirect: '$GHRepo' was renamed to '$actualName'."
  echo "  Treating '$GHRepo' as NOT_EXISTS to allow fresh migration."
  repoStatus="NOT_EXISTS"
else
  echo "  Repo does not exist yet (will be migrated): $GHRepo"
  repoStatus="NOT_EXISTS"
fi

echo "$repoStatus" > "$precheckFile"
echo "  Status: $repoStatus"

# ============================================================================
# STEP 3 - Migrate repo via GEI
# ============================================================================
migState="UNKNOWN"
migLogUrl=""

if [ "$repoStatus" = "ALREADY_EXISTS" ]; then
  echo ""
  echo "[Step 3] SKIPPED - repo already exists in GitHub."
  migState="SKIPPED"
  echo "$migState" > "$stateFile"
elif [ "$DryRun" = "true" ]; then
  echo ""
  echo "[Step 3] DRY RUN - GEI command that would run:"
  echo "  gh ado2gh migrate-repo --ado-org \"$ADOOrg\" --ado-team-project \"$ADOProject\" --ado-repo \"$ADORepo\" --github-org \"$GHOrg\" --github-repo \"$GHRepo\" --target-repo-visibility $TargetRepoVisibility"
  migState="DRY_RUN"
  echo "$migState" > "$stateFile"
else
  echo ""
  echo "[Step 3] Migrating repo (with up to 3 retries for network issues)..."
  export ADO_PAT="$adoPat"
  export GH_PAT="$ghPat"
  
  maxAttempts=3
  success=false

  for ((attempt=1; attempt<=maxAttempts; attempt++)); do
    if [ "$attempt" -gt 1 ]; then
      waitTime=$((attempt * 60))
      echo "  Waiting ${waitTime}s before retry attempt $attempt/$maxAttempts..."
      sleep "$waitTime"
    fi

    echo "  State: EXPORTING from ADO (Attempt $attempt)..."
    migState="EXPORTING"
    echo "$migState" > "$stateFile"

    # Run the GEI migration command
    migOutput=$(gh ado2gh migrate-repo \
        --ado-org          "$ADOOrg" \
        --ado-team-project "$ADOProject" \
        --ado-repo         "$ADORepo" \
        --github-org       "$GHOrg" \
        --github-repo      "$GHRepo" \
        --target-repo-visibility "$TargetRepoVisibility" 2>&1)
    exitCode=$?

    echo "$migOutput"

    # Capture log URL from output
    if [[ "$migOutput" =~ Migration\ log\ available\ at\ (https://[^[:space:]]+) ]]; then
      migLogUrl="${BASH_REMATCH[1]}"
      echo "  Log URL captured: $migLogUrl"
    fi

    if [ "$exitCode" -eq 0 ]; then
      echo "  State: COMPLETE"
      migState="COMPLETE"
      echo "$migState" > "$stateFile"
      success=true
      break
    elif echo "$migOutput" | grep -q "already been queued"; then
      echo "  Migration already queued - polling until repo appears..."
      migState="WAITING"
      echo "$migState" > "$stateFile"
      found=false
      for ((w=1; w<=30; w++)); do
        sleep 60
        echo "  Poll $w/30..."
        if gh repo view "$GHOrg/$GHRepo" --json name >/dev/null 2>&1; then
          found=true
          break
        fi
      done
      if [ "$found" = "true" ]; then
        migState="COMPLETE"
        echo "$migState" > "$stateFile"
        echo "  State: COMPLETE (queued migration finished)"
        success=true
      else
        migState="FAILED"
        echo "$migState" > "$stateFile"
        echo "Warning: Migration did not complete within 30 minutes." >&2
      fi
      break
    elif echo "$migOutput" | grep -q -iE "timeout|network|connection reset|429|502"; then
      echo "Warning: Network/Timeout error detected on attempt $attempt." >&2
      if [ "$attempt" -eq "$maxAttempts" ]; then
        migState="FAILED"
        echo "$migState" > "$stateFile"
        echo "Error: Max retries reached. Migration failed due to network issues." >&2
      fi
    else
      migState="FAILED"
      echo "$migState" > "$stateFile"
      if echo "$migOutput" | grep -q -E 'lookup the Organization ID|Failed to lookup'; then
        echo "Warning: Permanent error: Check GH_PAT scopes (repo, read:org)." >&2
      else
        echo "Warning: Permanent error detected (e.g. 401 or 404). No retry will be attempted." >&2
      fi
      break
    fi
  done
fi

# ============================================================================
# STEP 3.5 - Branch Exclusions Cleanup
# ============================================================================
if [ "$migState" = "COMPLETE" ] && [ "$DryRun" != "true" ]; then
  echo ""
  echo "======================================================"
  echo " [Step 3.5] BRANCH EXCLUSIONS CLEANUP"
  echo "======================================================"
  
  if [ -f "$ConfigPath" ]; then
    excludedBranches=$(jq -r '.exclusions.branches[]? // empty' "$ConfigPath" 2>/dev/null || true)
    
    if [ -n "$excludedBranches" ]; then
      mapfile -t branches_arr <<< "$excludedBranches"
      echo "  Found ${#branches_arr[@]} branch(es) to exclude in config."
      for branch in "${branches_arr[@]}"; do
        if [ -z "$branch" ]; then continue; fi
        echo "  --> Target: $branch"
        
        # Check if branch exists
        if gh api "repos/$GHOrg/$GHRepo/branches/$branch" --silent >/dev/null 2>&1; then
          echo "      Found branch on GitHub. Deleting via API..."
          if gh api -X DELETE "repos/$GHOrg/$GHRepo/git/refs/heads/$branch" --silent >/dev/null 2>&1; then
            echo "      [SUCCESS] Deleted branch '$branch'"
          else
            echo "      [FAILED] Could not delete branch."
          fi
        else
          echo "      [SKIP] Branch '$branch' not found in this repository."
        fi
      done
    else
      echo "  No branches listed in 'exclusions.branches'. Nothing to do."
    fi
  else
    echo "Warning: Config file not found at '$ConfigPath'. Cannot process branch exclusions." >&2
  fi
  echo "======================================================"
fi

# ============================================================================
# STEP 4 - Branch-wise post-migration audit
# ============================================================================
if [ "$SkipAudit" = "true" ]; then
  echo ""
  echo "[Step 4] SKIPPED (--skip-audit flag set)."
elif [[ "$migState" =~ ^(FAILED|DRY_RUN|UNKNOWN)$ ]]; then
  echo ""
  echo "[Step 4] SKIPPED - migration state is '$migState', no repo to audit."
else
  echo ""
  echo "[Step 4] Post-migration audit (API-only, no clone)..."

  # Helper for paginated github pages
  get_github_pages() {
    local endpoint="$1"
    local page=1
    local all="[]"
    while true; do
      local sep="?"
      if [[ "$endpoint" == *\?* ]]; then sep="&"; fi
      local batch
      batch=$(gh api "${endpoint}${sep}per_page=100&page=${page}" 2>/dev/null || echo "[]")
      local len
      len=$(echo "$batch" | jq '. | length')
      if [ "$len" -gt 0 ]; then
        all=$(jq -s '.[0] + .[1]' <(echo "$all") <(echo "$batch"))
        if [ "$len" -lt 100 ]; then break; fi
        page=$((page + 1))
      else
        break
      fi
    done
    echo "$all"
  }

  echo "  Fetching repo metadata..."
  repoInfoRaw=$(gh api "repos/$GHOrg/$GHRepo" 2>/dev/null || echo "")
  
  if [ -z "$repoInfoRaw" ]; then
    echo "Warning: Could not fetch repo info via API - skipping audit." >&2
  else
    defaultBranch=$(echo "$repoInfoRaw" | jq -r '.default_branch // empty')
    echo "$defaultBranch" > "$auditDir/gh-default-branch.txt"
    echo "  Default branch: $defaultBranch"

    echo "  Fetching branches..."
    branchObjs=$(get_github_pages "repos/$GHOrg/$GHRepo/branches")
    branchCount=$(echo "$branchObjs" | jq '. | length')
    echo "$branchObjs" | jq -r '.[].name' > "$auditDir/gh-branches.txt"
    echo "  Branches (GitHub): $branchCount"

    echo "  Fetching ADO branches for comparison..."
    adoBranches="[]"
    skip=0
    while true; do
      adoRepoEncoded=$(jq -rn --arg val "$ADORepo" '$val|@uri')
      brResp=$(curl -s -f -u ":$adoPat" -H "Accept: application/json" "https://dev.azure.com/$ADOOrg/$ADOProject/_apis/git/repositories/${adoRepoEncoded}/refs?filter=heads/&\$top=1000&\$skip=${skip}&api-version=7.1" || true)
      if [ -n "$brResp" ] && echo "$brResp" | jq -e '.value' >/dev/null 2>&1; then
        batch_len=$(echo "$brResp" | jq '.value | length')
        if [ "$batch_len" -gt 0 ]; then
          batch_names=$(echo "$brResp" | jq '.value | map(.name | sub("^refs/heads/"; ""))')
          adoBranches=$(jq -s '.[0] + .[1]' <(echo "$adoBranches") <(echo "$batch_names"))
          if [ "$batch_len" -lt 1000 ]; then break; fi
          skip=$((skip + batch_len))
        else
          break
        fi
      else
        echo "Warning: Could not fetch ADO branches - comparison will be skipped." >&2
        break
      fi
    done
    adoBranchCount=$(echo "$adoBranches" | jq '. | length')
    echo "  Branches (ADO): $adoBranchCount"

    ghBranchList=$(echo "$branchObjs" | jq -r '[.[].name]')
    missingInGH=$(jq -n --argjson ado "$adoBranches" --argjson gh "$ghBranchList" '$ado - $gh')
    extraInGH=$(jq -n --argjson ado "$adoBranches" --argjson gh "$ghBranchList" '$gh - $ado')
    missingCount=$(echo "$missingInGH" | jq '. | length')
    extraCount=$(echo "$extraInGH" | jq '. | length')
    echo "  Missing in GitHub: $missingCount  |  Extra in GitHub: $extraCount"
    if [ "$missingCount" -gt 0 ]; then
      echo "$missingInGH" | jq -r '.[]' > "$auditDir/gh-missing-branches.txt"
    fi

    echo "  Fetching tags..."
    tagObjs=$(get_github_pages "repos/$GHOrg/$GHRepo/tags")
    tagCount=$(echo "$tagObjs" | jq '. | length')
    if [ "$tagCount" -gt 0 ]; then
      echo "$tagObjs" | jq -r '.[].name' > "$auditDir/gh-tags.txt"
    else
      echo "" > "$auditDir/gh-tags.txt"
    fi
    echo "  Tags: $tagCount"

    latestHash=$(echo "$branchObjs" | jq -r --arg db "$defaultBranch" '.[] | select(.name == $db) | .commit.sha // "N/A"')
    echo "  Latest hash: $latestHash"

    echo "  Fetching per-branch commit metadata..."
    refMeta="{}"
    mapfile -t b_names < <(echo "$branchObjs" | jq -r '.[].name')
    mapfile -t b_shas < <(echo "$branchObjs" | jq -r '.[].commit.sha')
    for ((i=0; i<${#b_names[@]}; i++)); do
      bName="${b_names[$i]}"
      bSha="${b_shas[$i]}"
      cRaw=$(gh api "repos/$GHOrg/$GHRepo/commits/$bSha" 2>/dev/null || echo "")
      if [ -n "$cRaw" ]; then
        cAuthor=$(echo "$cRaw" | jq -r '.commit.author.name // "N/A"')
        cDateRaw=$(echo "$cRaw" | jq -r '.commit.author.date // "N/A"')
        cDate="N/A"
        if [ "$cDateRaw" != "N/A" ]; then
          cDate="${cDateRaw:0:10}"
        fi
        cMsg=$(echo "$cRaw" | jq -r '.commit.message // "N/A"' | head -n 1)
        shortSha="${bSha:0:12}"
        refMeta=$(jq --arg bn "$bName" --arg sha "$shortSha" --arg auth "$cAuthor" --arg date "$cDate" --arg msg "$cMsg" \
          '. + {($bn): {Hash: $sha, Author: $auth, Date: $date, Msg: $msg}}' <<< "$refMeta")
      fi
    done

    echo "  Fetching commit counts via GraphQL..."
    commitCounts="{}"
    batchSize=50
    for ((i=0; i<${#b_names[@]}; i+=batchSize)); do
      slice=("${b_names[@]:i:batchSize}")
      aliases=""
      idx=0
      for bn in "${slice[@]}"; do
        qualName="refs/heads/$bn"
        aliases="${aliases}  b${idx}: ref(qualifiedName: \"${qualName}\") { target { ... on Commit { history { totalCount } } } }\n"
        idx=$((idx + 1))
      done
      gqlQuery="{ repository(owner: \"$GHOrg\", name: \"$GHRepo\") {\n${aliases}\n} }"
      gqlRaw=$(gh api graphql -f query="$gqlQuery" 2>/dev/null || echo "")
      if [ -n "$gqlRaw" ] && echo "$gqlRaw" | jq -e '.data.repository' >/dev/null 2>&1; then
        idx=0
        for bn in "${slice[@]}"; do
          count=$(echo "$gqlRaw" | jq -r ".data.repository.b${idx}.target.history.totalCount // 0")
          commitCounts=$(jq --arg bn "$bn" --argjson cnt "$count" '. + {($bn): $cnt}' <<< "$commitCounts")
          idx=$((idx + 1))
        done
      fi
    done

    totalCommits=$(echo "$commitCounts" | jq -r --arg db "$defaultBranch" '.[$db] // "N/A"')
    echo "  Total commits (default branch): $totalCommits"

    echo "  Fetching file tree for default branch..."
    csvFolderFile="$auditDir/gh-folder-wise-files.csv"
    csvFolderSummary="$auditDir/gh-folder-summary.csv"
    echo '"Branch","Folder","FileName"' > "$csvFolderFile"
    echo '"Branch","Folder","FileCount"' > "$csvFolderSummary"

    bFileCount=0
    bFolderCount=0
    if [ -n "$latestHash" ] && [ "$latestHash" != "N/A" ]; then
      treeRaw=$(gh api "repos/$GHOrg/$GHRepo/git/trees/${latestHash}?recursive=1" 2>/dev/null || echo "")
      if [ -n "$treeRaw" ] && echo "$treeRaw" | jq -e '.tree' >/dev/null 2>&1; then
        blobEntries=$(echo "$treeRaw" | jq '.tree | map(select(.type == "blob"))')
        bFileCount=$(echo "$blobEntries" | jq '. | length')
        truncated=$(echo "$treeRaw" | jq -r '.truncated // false')
        
        if [ "$truncated" = "true" ]; then
          echo "    WARNING: Tree truncated (100K+ files) - skipping folder enumeration"
          bFolderCount="100K+ (API limit)"
        elif [ "$bFileCount" -gt 50000 ]; then
          echo "    WARNING: $bFileCount files exceeds 50K cap - skipping folder enumeration"
          bFolderCount="55K+ (skipped)"
        else
          folders_json=$(echo "$blobEntries" | jq -r '
            map(
              .path | 
              split("/") | 
              if length > 1 then (.[0:-1] | join("/")) else "(root)" end
            ) | 
            reduce .[] as $item ({}; .[$item] += 1)
          ')
          bFolderCount=$(echo "$folders_json" | jq '. | keys | length')
          
          folderSummaryMd="| Folder | Files |\n|---|---|\n"
          while read -r folder; do
            fc=$(echo "$folders_json" | jq -r --arg f "$folder" '.[$f]')
            folderSummaryMd="${folderSummaryMd}| $folder | $fc |\n"
            echo "\"$defaultBranch\",\"$folder\",\"$fc\"" >> "$csvFolderSummary"
          done < <(echo "$folders_json" | jq -r 'keys[]')
          
          folderSummaryMd="${folderSummaryMd}| **Total** | **$bFileCount** |\n"
          echo -e "$folderSummaryMd" > "$auditDir/gh-folder-summary-default.md"

          safeBranch=$(echo "$defaultBranch" | sed 's/[/\\]/--/g')
          branchFileMd="# Files in branch: $defaultBranch\n\n"
          
          mapfile -t paths < <(echo "$blobEntries" | jq -r '.[].path')
          declare -A grouped_files
          for p in "${paths[@]}"; do
            dir=$(dirname "$p")
            file=$(basename "$p")
            if [ "$dir" = "." ]; then dir="(root)"; fi
            echo "\"$defaultBranch\",\"$dir\",\"$file\"" >> "$csvFolderFile"
            grouped_files["$dir"]+="$file"$'\n'
          done

          for dir in "${!grouped_files[@]}"; do
            branchFileMd="${branchFileMd}## $dir/\n"
            sorted_f=$(echo -n "${grouped_files[$dir]}" | sort)
            while read -r file; do
              if [ -n "$file" ]; then
                branchFileMd="${branchFileMd}- $file\n"
              fi
            done <<< "$sorted_f"
            branchFileMd="${branchFileMd}\n"
          done
          echo -e "$branchFileMd" > "$folderDir/gh-files-$safeBranch.md"
        fi
      fi
    fi

    branchCsvFile="$auditDir/gh-branch-wise-data.csv"
    echo '"Branch","Status","Files","Folders","LatestHash","LatestAuthor","LatestDate","LatestMsg"' > "$branchCsvFile"
    branchStatus="Migrated"
    if [ "$migState" = "SKIPPED" ]; then
      branchStatus="Already Existed"
    fi

    for bn in "${b_names[@]}"; do
      mHash=$(echo "$refMeta" | jq -r --arg bn "$bn" '.[$bn].Hash // "N/A"')
      mAuthor=$(echo "$refMeta" | jq -r --arg bn "$bn" '.[$bn].Author // "N/A"')
      mDate=$(echo "$refMeta" | jq -r --arg bn "$bn" '.[$bn].Date // "N/A"')
      mMsg=$(echo "$refMeta" | jq -r --arg bn "$bn" '.[$bn].Msg // "N/A"')
      
      if [ "$bn" = "$defaultBranch" ]; then
        echo "\"$bn\",\"$branchStatus\",\"$bFileCount\",\"$bFolderCount\",\"$mHash\",\"$mAuthor\",\"$mDate\",\"$mMsg\"" >> "$branchCsvFile"
      else
        echo "\"$bn\",\"$branchStatus\",\"-\",\"-\",\"$mHash\",\"$mAuthor\",\"$mDate\",\"$mMsg\"" >> "$branchCsvFile"
      fi
    done

    mapfile -t missing_arr < <(echo "$missingInGH" | jq -r '.[]')
    for mb in "${missing_arr[@]}"; do
      if [ -n "$mb" ]; then
        echo "\"$mb\",\"Missing\",\"-\",\"-\",\"-\",\"-\",\"-\",\"Not found in GitHub\"" >> "$branchCsvFile"
      fi
    done

    topBranchesCsv="$auditDir/gh-top-branches.csv"
    echo '"Branch","Commits","IsDefault"' > "$topBranchesCsv"
    
    rank_branch() {
      local name="$1"
      if [ "$name" = "$defaultBranch" ]; then echo 0;
      elif [[ "$name" =~ ^(main|master)$ ]]; then echo 1;
      elif [[ "$name" =~ ^(develop|dev)$ ]]; then echo 2;
      elif [[ "$name" =~ ^(release|hotfix) ]]; then echo 3;
      else echo 99; fi
    }

    ranked_branches="[]"
    for bn in "${b_names[@]}"; do
      rank=$(rank_branch "$bn")
      cnt=$(echo "$commitCounts" | jq -r --arg bn "$bn" '.[$bn] // 0')
      isDef="No"
      if [ "$bn" = "$defaultBranch" ]; then isDef="Yes"; fi
      ranked_branches=$(jq --arg bn "$bn" --argjson rk "$rank" --argjson cnt "$cnt" --arg isdef "$isDef" \
        '. + [{Branch: $bn, Rank: $rk, Commits: $cnt, IsDefault: $isdef}]' <<< "$ranked_branches")
    done

    top5=$(echo "$ranked_branches" | jq -c 'sort_by(.Rank, .Branch) | .[0:5][]' 2>/dev/null || echo "")
    if [ -n "$top5" ]; then
      while read -r tb; do
        if [ -n "$tb" ]; then
          tbn=$(echo "$tb" | jq -r '.Branch')
          tbc=$(echo "$tb" | jq -r '.Commits')
          tbDef=$(echo "$tb" | jq -r '.IsDefault')
          echo "\"$tbn\",\"$tbc\",\"$tbDef\"" >> "$topBranchesCsv"
        fi
      done <<< "$top5"
    fi

    echo "  Fetching pull requests..."
    allPRs=$(get_github_pages "repos/$GHOrg/$GHRepo/pulls?state=all")
    totalPRs=$(echo "$allPRs" | jq '. | length')
    totalOpen=$(echo "$allPRs" | jq '[.[] | select(.state == "open")] | length')
    totalMerged=$(echo "$allPRs" | jq '[.[] | select(.merged_at != null)] | length')
    totalClosed=$((totalPRs - totalOpen - totalMerged))

    prHeadMd="| Source Branch (head) | Open | Merged | Closed | Total |\n|---|---|---|---|---|\n"
    prByHead=$(echo "$allPRs" | jq '
      reduce .[] as $pr ({}; 
        local $head = $pr.head.ref;
        .[$head].Open += (if $pr.state == "open" then 1 else 0 end) |
        .[$head].Merged += (if $pr.merged_at != null then 1 else 0 end) |
        .[$head].Closed += (if $pr.state != "open" and $pr.merged_at == null then 1 else 0 end)
      )
    ')
    while read -r head; do
      if [ -n "$head" ]; then
        o=$(echo "$prByHead" | jq -r --arg h "$head" '.[$h].Open // 0')
        m=$(echo "$prByHead" | jq -r --arg h "$head" '.[$h].Merged // 0')
        c=$(echo "$prByHead" | jq -r --arg h "$head" '.[$h].Closed // 0')
        t=$((o + m + c))
        prHeadMd="${prHeadMd}| $head | $o | $m | $c | $t |\n"
      fi
    done < <(echo "$prByHead" | jq -r 'keys[]')
    prHeadMd="${prHeadMd}| **TOTAL** | **$totalOpen** | **$totalMerged** | **$totalClosed** | **$totalPRs** |\n"
    echo -e "$prHeadMd" > "$auditDir/gh-pr-by-source-branch.md"

    prBaseMd="| Target Branch (base) | Open | Merged | Closed | Total |\n|---|---|---|---|---|\n"
    prByBase=$(echo "$allPRs" | jq '
      reduce .[] as $pr ({}; 
        local $base = $pr.base.ref;
        .[$base].Open += (if $pr.state == "open" then 1 else 0 end) |
        .[$base].Merged += (if $pr.merged_at != null then 1 else 0 end) |
        .[$base].Closed += (if $pr.state != "open" and $pr.merged_at == null then 1 else 0 end)
      )
    ')
    while read -r base; do
      if [ -n "$base" ]; then
        o=$(echo "$prByBase" | jq -r --arg b "$base" '.[$b].Open // 0')
        m=$(echo "$prByBase" | jq -r --arg b "$base" '.[$b].Merged // 0')
        c=$(echo "$prByBase" | jq -r --arg b "$base" '.[$b].Closed // 0')
        t=$((o + m + c))
        prBaseMd="${prBaseMd}| $base | $o | $m | $c | $t |\n"
      fi
    done < <(echo "$prByBase" | jq -r 'keys[]')
    echo -e "$prBaseMd" > "$auditDir/gh-pr-by-target-branch.md"

    mdTable="| # | Branch | Status | Files | Latest Commit | Date |\n|---|---|---|---|---|---|\n"
    mdTableRows=$(jq -rn --argjson refMeta "$refMeta" --argjson bNames "$ghBranchList" --argjson missing "$missingInGH" --arg bStatus "$branchStatus" --arg bFiles "$bFileCount" --arg db "$defaultBranch" '
      local $all = ($bNames | map({Branch: ., Status: $bStatus, Files: (if . == $db then $bFiles else "-" end)}) ) + ($missing | map({Branch: ., Status: "Missing", Files: "-"}) );
      $all | sort_by(.Branch) | .[]
    ' | jq -c '.')
    
    idx=1
    while read -r row; do
      if [ -n "$row" ]; then
        b=$(echo "$row" | jq -r '.Branch')
        st=$(echo "$row" | jq -r '.Status')
        fl=$(echo "$row" | jq -r '.Files')
        mHash=$(echo "$refMeta" | jq -r --arg bn "$b" '.[$bn].Hash // "-"')
        mAuthor=$(echo "$refMeta" | jq -r --arg bn "$b" '.[$bn].Author // "-"')
        mDate=$(echo "$refMeta" | jq -r --arg bn "$b" '.[$bn].Date // "-"')
        mMsg=$(echo "$refMeta" | jq -r --arg bn "$b" '.[$bn].Msg // "Not found in GitHub"')
        mdTable="${mdTable}| $idx | $b | $st | $fl | $mAuthor - $mMsg | $mDate |\n"
        idx=$((idx + 1))
      fi
    done <<< "$mdTableRows"
    echo -e "$mdTable" > "$auditDir/gh-branch-wise-table.md"

    echo "$branchCount" > "$auditDir/gh-branch-count.txt"
    echo "$tagCount" > "$auditDir/gh-tag-count.txt"
    echo "$totalCommits" > "$auditDir/gh-commit-count.txt"
    echo "$totalPRs" > "$auditDir/gh-pr-count.txt"
    echo "$totalOpen" > "$auditDir/gh-pr-open.txt"
    echo "$totalMerged" > "$auditDir/gh-pr-merged.txt"
    echo "$totalClosed" > "$auditDir/gh-pr-closed.txt"
    echo "$latestHash" > "$auditDir/gh-latest-hash.txt"

    echo "  Audit complete. PRs: $totalPRs (Open:$totalOpen Merged:$totalMerged Closed:$totalClosed)"
  fi
fi

# ============================================================================
# STEP 5 - Download GEI migration log
# ============================================================================
if [[ "$migState" =~ ^(SKIPPED|DRY_RUN|FAILED)$ ]]; then
  echo ""
  echo "[Step 5] Skipping log download (state: $migState)."
else
  echo ""
  echo "[Step 5] Downloading GEI migration log..."
  migLogFile="$logDir/migration-log-$GHRepo.log"
  success_log=false

  if [ -n "$migLogUrl" ] && [ "$migLogUrl" != "null" ]; then
    echo "  Downloading directly from captured URL (no wait)..."
    if curl -s -f -o "$migLogFile" "$migLogUrl"; then
      success_log=true
      echo "  Log saved (direct download): $migLogFile"
    else
      echo "  Direct download failed."
    fi
  fi

  if [ "$success_log" = "false" ]; then
    backoff=10
    for ((i=1; i<=4; i++)); do
      echo "  Attempt $i/4 (waiting ${backoff}s)..."
      sleep "$backoff"
      if gh ado2gh download-logs --github-org "$GHOrg" --github-repo "$GHRepo" --migration-log-file "$migLogFile" --overwrite >/dev/null 2>&1; then
        success_log=true
        break
      fi
      backoff=$((backoff * 2))
      if [ "$backoff" -gt 60 ]; then backoff=60; fi
    done
  fi

  if [ "$success_log" = "false" ]; then
    echo "Log download failed" > "$migLogFile"
    echo "Warning: Logs unavailable (non-critical - migration data is complete)." >&2
  else
    echo "  Log saved: $migLogFile"
  fi
fi

# ============================================================================
# STEP 6 - Generate HTML dashboard + Markdown summary
# ============================================================================
echo ""
echo "[Step 6] Generating HTML dashboard..."

branchCount=$(cat "$auditDir/gh-branch-count.txt" 2>/dev/null || echo "N/A")
tagCount=$(cat "$auditDir/gh-tag-count.txt" 2>/dev/null || echo "N/A")
commitCount=$(cat "$auditDir/gh-commit-count.txt" 2>/dev/null || echo "N/A")
prCount=$(cat "$auditDir/gh-pr-count.txt" 2>/dev/null || echo "N/A")
prOpen=$(cat "$auditDir/gh-pr-open.txt" 2>/dev/null || echo "N/A")
prMerged=$(cat "$auditDir/gh-pr-merged.txt" 2>/dev/null || echo "N/A")
prClosed=$(cat "$auditDir/gh-pr-closed.txt" 2>/dev/null || echo "N/A")
defaultBranch=$(cat "$auditDir/gh-default-branch.txt" 2>/dev/null || echo "N/A")
migDate=$(date +"%d %b %Y %H:%M")

branchCount="${branchCount:-N/A}"
tagCount="${tagCount:-N/A}"
commitCount="${commitCount:-N/A}"
prCount="${prCount:-N/A}"
prOpen="${prOpen:-N/A}"
prMerged="${prMerged:-N/A}"
prClosed="${prClosed:-N/A}"
defaultBranch="${defaultBranch:-N/A}"

if [ "$migState" = "SKIPPED" ]; then
  migResult="Already Exists"
  statusColor="#f0ad4e"
  statusBg="#fff8e1"
  statusText="Skipped - Repository Already Exists"
  reasonText="Target repository was detected in GitHub prior to migration."
elif [ "$migState" = "DRY_RUN" ]; then
  migResult="Dry Run"
  statusColor="#0969da"
  statusBg="#ddf4ff"
  statusText="Dry Run - No changes made"
  reasonText="Dry run mode: GEI command was printed but not executed."
elif [ "$migState" = "COMPLETE" ]; then
  migResult="Success"
  statusColor="#28a745"
  statusBg="#e6f9ed"
  statusText="Completed - Migration Successful"
  reasonText="Repository migrated successfully from ADO to GitHub."
else
  migResult="Failed"
  statusColor="#dc3545"
  statusBg="#fdecea"
  statusText="Failed - Migration Error"
  reasonText="Check migration logs for error details."
fi

phaseHtml=""
if [ "$migState" = "SKIPPED" ]; then
  phaseHtml+="<tr><td style='font-size:16px;text-align:center;'>[SKIPPED]</td><td><strong>Pre-Check</strong></td><td style='color:#28a745;font-weight:600;'>Completed</td></tr>\n"
  phaseHtml+="<tr><td style='font-size:16px;text-align:center;'>[-]</td><td><strong>Migration</strong></td><td style='color:#f0ad4e;font-weight:600;'>Skipped</td></tr>\n"
  phaseHtml+="<tr><td style='font-size:16px;text-align:center;'>[SKIPPED]</td><td><strong>Audit</strong></td><td style='color:#28a745;font-weight:600;'>Completed</td></tr>\n"
  phaseHtml+="<tr><td style='font-size:16px;text-align:center;'>[SKIPPED]</td><td><strong>Result</strong></td><td style='color:#f0ad4e;font-weight:600;'>Repository Already Exists</td></tr>\n"
elif [ "$migState" = "COMPLETE" ]; then
  phaseHtml+="<tr><td style='font-size:16px;text-align:center;'>[PASS]</td><td><strong>Pre-Check</strong></td><td style='color:#28a745;font-weight:600;'>Completed</td></tr>\n"
  phaseHtml+="<tr><td style='font-size:16px;text-align:center;'>[PASS]</td><td><strong>Migration</strong></td><td style='color:#28a745;font-weight:600;'>Completed</td></tr>\n"
  phaseHtml+="<tr><td style='font-size:16px;text-align:center;'>[PASS]</td><td><strong>Audit</strong></td><td style='color:#28a745;font-weight:600;'>Completed</td></tr>\n"
  phaseHtml+="<tr><td style='font-size:16px;text-align:center;'>[PASS]</td><td><strong>Result</strong></td><td style='color:#28a745;font-weight:600;'>Migration Successful</td></tr>\n"
else
  phaseHtml+="<tr><td style='font-size:16px;text-align:center;'>[PASS]</td><td><strong>Pre-Check</strong></td><td style='color:#28a745;font-weight:600;'>Completed</td></tr>\n"
  phaseHtml+="<tr><td style='font-size:16px;text-align:center;'>[FAIL]</td><td><strong>Migration</strong></td><td style='color:#dc3545;font-weight:600;'>Failed</td></tr>\n"
  phaseHtml+="<tr><td style='font-size:16px;text-align:center;'>[PASS]</td><td><strong>Audit</strong></td><td style='color:#28a745;font-weight:600;'>Completed</td></tr>\n"
  phaseHtml+="<tr><td style='font-size:16px;text-align:center;'>[FAIL]</td><td><strong>Result</strong></td><td style='color:#dc3545;font-weight:600;'>Migration Failed</td></tr>\n"
fi

topBranchHtml=""
if [ -f "$auditDir/gh-top-branches.csv" ]; then
  rank=1
  # Read CSV line by line, skipping header
  while IFS=',' read -r Branch Commits IsDefault || [ -n "$Branch" ]; do
    # Remove quotes
    Branch="${Branch%\"}"
    Branch="${Branch#\"}"
    Commits="${Commits%\"}"
    Commits="${Commits#\"}"
    IsDefault="${IsDefault%\"}"
    IsDefault="${IsDefault#\"}"
    
    if [ "$Branch" = "Branch" ]; then continue; fi
    defLabel=""
    if [ "$IsDefault" = "Yes" ]; then
      defLabel=" <span style='background:#ddf4ff;color:#0969da;padding:2px 8px;border-radius:8px;font-size:11px;font-weight:700;margin-left:6px;'>DEFAULT</span>"
    fi
    topBranchHtml+="<tr><td style='text-align:center;color:#6f42c1;font-weight:700;'>$rank</td><td><code>$Branch</code>$defLabel</td><td style='text-align:right;font-weight:600;font-variant-numeric:tabular-nums;'>$Commits</td></tr>\n"
    rank=$((rank + 1))
  done < "$auditDir/gh-top-branches.csv"
fi
if [ -z "$topBranchHtml" ]; then
  topBranchHtml="<tr><td colspan='3' style='color:#999;text-align:center;'>No data</td></tr>"
fi

allBranchHtml=""
branchCsvFile="$auditDir/gh-branch-wise-data.csv"
if [ -f "$branchCsvFile" ]; then
  idx=1
  # Use simple parsing
  while IFS=',' read -r Branch Status Files Folders LatestHash LatestAuthor LatestDate LatestMsg || [ -n "$Branch" ]; do
    Branch="${Branch%\"}"
    Branch="${Branch#\"}"
    Status="${Status%\"}"
    Status="${Status#\"}"
    
    if [ "$Branch" = "Branch" ]; then continue; fi
    badge=""
    case "$Status" in
      "Missing") badge="<span style='background:#ffebe9;color:#cf222e;padding:4px 12px;border-radius:12px;font-weight:600;font-size:13px;'>[MISSING]</span>" ;;
      "Already Existed") badge="<span style='background:#fff8c5;color:#9a6700;padding:4px 12px;border-radius:12px;font-weight:600;font-size:13px;'>[ALREADY EXISTS]</span>" ;;
      *) badge="<span style='background:#dafbe1;color:#1a7f37;padding:4px 12px;border-radius:12px;font-weight:600;font-size:13px;'>[MIGRATED]</span>" ;;
    esac
    allBranchHtml+="<tr><td style='text-align:center;'>$idx</td><td><code>$Branch</code></td><td style='text-align:center;'>$badge</td></tr>\n"
    idx=$((idx + 1))
  done < "$branchCsvFile"
fi
if [ -z "$allBranchHtml" ]; then
  allBranchHtml="<tr><td colspan='3' style='color:#999;text-align:center;'>No data</td></tr>"
fi

missingCount=0
if [ -f "$auditDir/gh-missing-branches.txt" ]; then
  missingCount=$(grep -c '^' "$auditDir/gh-missing-branches.txt" || echo 0)
fi
totalBranchCount=$((branchCount + missingCount))
if [ "$missingCount" -gt 0 ]; then
  branchSummary="$totalBranchCount - $branchCount in GitHub, $missingCount missing from ADO"
else
  branchSummary="$branchCount"
fi

cat <<EOF > "$dashDir/migration-report-$GHRepo.html"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>Migration Report - $GHRepo</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif; background: #f4f6f9; color: #333; padding: 30px; font-size: 16px; }
  .container { max-width: 960px; margin: 0 auto; }
  .header { background: linear-gradient(135deg, #0d1117 0%, #161b22 100%); color: #fff; padding: 32px 36px; border-radius: 14px; margin-bottom: 24px; }
  .header h1 { font-size: 28px; margin-bottom: 12px; }
  .status-banner { display: inline-block; padding: 10px 22px; border-radius: 8px; font-size: 18px; font-weight: 600; margin-top: 6px; background: $statusBg; color: $statusColor; border: 2px solid $statusColor; }
  .card { background: #fff; border-radius: 12px; padding: 28px 32px; margin-bottom: 20px; box-shadow: 0 2px 8px rgba(0,0,0,.06); }
  .card h2 { font-size: 22px; margin-bottom: 18px; color: #0d1117; border-bottom: 2px solid #e1e4e8; padding-bottom: 10px; }
  table { width: 100%; border-collapse: collapse; font-size: 15px; }
  th { background: #f6f8fa; text-align: left; padding: 12px 16px; font-weight: 600; color: #24292f; border-bottom: 2px solid #d0d7de; }
  td { padding: 11px 16px; border-bottom: 1px solid #eaecef; }
  tr:hover { background: #f6f8fa; }
  .overview-table td:first-child { font-weight: 600; width: 220px; color: #555; font-size: 16px; }
  .overview-table td:last-child { font-size: 16px; }
  code { background: #eff1f3; padding: 3px 8px; border-radius: 5px; font-size: 14px; color: #0d1117; }
  .stat-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 16px; margin-bottom: 8px; }
  .stat-box { background: #f6f8fa; border-radius: 10px; padding: 20px; text-align: center; border: 1px solid #e1e4e8; }
  .stat-box .num { font-size: 32px; font-weight: 700; color: #0d1117; }
  .stat-box .label { font-size: 14px; color: #666; margin-top: 4px; }
  .reason { background: #f0f4f8; border-left: 4px solid $statusColor; padding: 12px 18px; border-radius: 6px; margin-top: 14px; font-size: 15px; color: #555; }
  details { margin-top: 10px; }
  details summary { cursor: pointer; font-weight: 600; font-size: 16px; color: #0969da; padding: 8px 0; }
  details summary:hover { text-decoration: underline; }
  .pr-pills { display: flex; gap: 12px; flex-wrap: wrap; }
  .pr-pill { padding: 8px 18px; border-radius: 20px; font-weight: 600; font-size: 15px; }
  .pr-open { background: #dafbe1; color: #1a7f37; }
  .pr-merged { background: #e8d5f5; color: #8250df; }
  .pr-closed { background: #fdecea; color: #cf222e; }
  .footer { text-align: center; color: #999; font-size: 13px; margin-top: 30px; padding-top: 16px; border-top: 1px solid #e1e4e8; }
</style>
</head>
<body>
<div class="container">
  <div class="header">
    <h1>[MIGRATION] ADO -> GitHub Migration Report</h1>
    <div class="status-banner">$statusText</div>
  </div>
  
  <div class="card">
    <h2>[OVERVIEW] Migration Overview</h2>
    <table class="overview-table">
      <tr><td>Date</td><td>$migDate</td></tr>
      <tr><td>Source (ADO)</td><td><code>$ADOOrg / $ADOProject / $ADORepo</code></td></tr>
      <tr><td>Target (GitHub)</td><td><code>$GHOrg / $GHRepo</code></td></tr>
      <tr><td>Default Branch</td><td><code>$defaultBranch</code></td></tr>
    </table>
  </div>
  
  <div class="card">
    <h2>[STATUS] Pipeline Execution Status</h2>
    <table>
      <thead>
        <tr><th style="width:50px;"></th><th>Phase</th><th>Status</th></tr>
      </thead>
      <tbody>
        $phaseHtml
      </tbody>
    </table>
    <div class="reason"><strong>Info:</strong> $reasonText</div>
  </div>
  
  <div class="card">
    <h2>[METRICS] Repository Snapshot</h2>
    <div class="stat-grid">
      <div class="stat-box"><div class="num">$branchCount</div><div class="label">Branches</div></div>
      <div class="stat-box"><div class="num">$tagCount</div><div class="label">Tags</div></div>
      <div class="stat-box"><div class="num">$commitCount</div><div class="label">Commits</div></div>
      <div class="stat-box"><div class="num">$prCount</div><div class="label">Pull Requests</div></div>
    </div>
    <div class="pr-pills" style="margin-top:14px;">
      <span class="pr-pill pr-open">Open: $prOpen</span>
      <span class="pr-pill pr-merged">Merged: $prMerged</span>
      <span class="pr-pill pr-closed">Closed: $prClosed</span>
    </div>
  </div>
  
  <div class="card">
    <h2>[KEYS] Key Branches</h2>
    <table>
      <thead>
        <tr><th style="text-align:center;">#</th><th>Branch</th><th style="text-align:right;">Commits</th></tr>
      </thead>
      <tbody>
        $topBranchHtml
      </tbody>
    </table>
  </div>
  
  <div class="card">
    <h2>[BRANCHES] All Branches ($branchSummary)</h2>
    <details>
      <summary>Click to expand all branches</summary>
      <table style="margin-top:10px;">
        <thead>
          <tr><th style="text-align:center;">#</th><th>Branch</th><th style="text-align:center;">Status</th></tr>
        </thead>
        <tbody>
          $allBranchHtml
        </tbody>
      </table>
    </details>
  </div>
  
  <div class="card">
    <h2>[ARTIFACTS] Audit &amp; Artifacts</h2>
    <p style="font-size:16px;margin-bottom:10px;">The following compliance files are available in the <strong>MigrationAudit</strong> artifact:</p>
    <ul style="margin-left:24px;font-size:15px;line-height:2;">
      <li>Folder-wise file inventory (<code>gh-folder-wise-files.csv</code>, <code>gh-folder-summary-default.md</code>)</li>
      <li>PR breakdown by source branch (<code>gh-pr-by-source-branch.md</code>)</li>
      <li>PR breakdown by target branch (<code>gh-pr-by-target-branch.md</code>)</li>
      <li>Branch-wise commit table (<code>gh-branch-wise-table.md</code>)</li>
      <li>Validation checks</li>
    </ul>
    <p style="margin-top:12px;font-size:15px;">Recommended for compliance reviews.</p>
  </div>
  
  <div class="footer">Generated $migDate &bull; ADO-to-GitHub Migration Pipeline</div>
</div>
</body>
</html>
EOF

echo "  HTML saved: $dashDir/migration-report-$GHRepo.html"

# Markdown summary (standard ASCII only!)
if [ "$migResult" = "Already Exists" ]; then
  mdStatus="[WARN] Skipped - Repository Already Exists"
elif [ "$migResult" = "Success" ]; then
  mdStatus="[PASS] Completed - Migration Successful"
else
  mdStatus="[FAIL] Failed - Migration Error"
fi

md="# [MIGRATION] ADO -> GitHub Migration Report\n\n"
md+="> Status: $mdStatus\n\n"
md+="| Metric | Value |\n|:---|:---|\n"
md+="| Date | $migDate |\n"
md+="| Source | \`$ADOOrg / $ADOProject / $ADORepo\` |\n"
md+="| Target | \`$GHOrg / $GHRepo\` |\n"
md+="| Branches | $branchCount |\n"
md+="| Commits | $commitCount |\n"
md+="| PRs | $prOpen Open / $prMerged Merged / $prClosed Closed |\n\n"
md+="> Download the **MigrationDashboard** artifact for the full HTML report.\n"

echo -e "$md" > "$reportDir/migration-summary-$GHRepo.md"

echo "============================================"
echo "  MIGRATION COMPLETE: $GHRepo"
echo "  Status:   $migResult"
echo "  Branches: $branchCount | Tags: $tagCount | Commits: $commitCount"
echo "  PRs:      $prCount (Open:$prOpen Merged:$prMerged Closed:$prClosed)"
echo "============================================"
exit 0
