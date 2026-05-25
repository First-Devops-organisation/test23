#!/usr/bin/env bash
###############################################################################
# github-org-setup.sh
# Unified script to manage ADO to GitHub Organization setup, team syncing,
# and user lifecycle (onboarding/offboarding).
###############################################################################
set -eo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
STAGES=""
ADO_ORG_URL=""
ADO_PAT=""
GH_ORG=""
GH_PAT=""
TEAM_MAPPING_FILE="./config/team-mappings.json"
USER_MAPPING_FILE="./config/user-mappings.csv"
OUTPUT_DIR="./output"
REMOVE_FROM_ORG=false

# ── Parse arguments ──────────────────────────────────────────────────────────
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --stages) STAGES="$2"; shift ;;
    --ado-org) ADO_ORG_URL="$2"; shift ;;
    --ado-pat) ADO_PAT="$2"; shift ;;
    --gh-org) GH_ORG="$2"; shift ;;
    --gh-pat) GH_PAT="$2"; shift ;;
    --team-mapping) TEAM_MAPPING_FILE="$2"; shift ;;
    --user-mapping) USER_MAPPING_FILE="$2"; shift ;;
    --output-dir) OUTPUT_DIR="$2"; shift ;;
    --remove-from-org) REMOVE_FROM_ORG=true ;;
    *) echo "Unknown parameter passed: $1"; exit 1 ;;
  esac
  shift
done

# Expand 'full-sync' macro
STAGES="${STAGES//full-sync/create-teams,sync-users,sync-repos}"

# ── Auth & Headers ───────────────────────────────────────────────────────────
ADO_AUTH_HEADER=""
if [[ -n "$ADO_PAT" ]]; then
  ADO_AUTH_HEADER="Authorization: Basic $(printf ":%s" "$ADO_PAT" | base64 -w0 2>/dev/null || printf ":%s" "$ADO_PAT" | base64)"
fi

GH_AUTH_HEADER=""
if [[ -n "$GH_PAT" ]]; then
  GH_AUTH_HEADER="Authorization: Bearer $GH_PAT"
fi

# ── Helpers ──────────────────────────────────────────────────────────────────
ado_api() {
  local uri="$1"
  local api_version="${2:-7.1}"
  if [[ "$uri" == *"?"* ]]; then uri="${uri}&api-version=${api_version}"
  else uri="${uri}?api-version=${api_version}"; fi
  curl -sS --fail-with-body -H "$ADO_AUTH_HEADER" -H "Content-Type: application/json" "$uri" 2>/dev/null || echo ""
}

gh_api() {
  local uri="$1"
  local method="${2:-GET}"
  local body="$3"
  
  if [[ "$uri" != *"http"* ]]; then
    uri="https://api.github.com${uri}"
  fi

  local cmd=(curl -sS --fail-with-body -X "$method" -H "$GH_AUTH_HEADER" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")
  if [[ -n "$body" ]]; then
    cmd+=(-H "Content-Type: application/json" -d "$body")
  fi
  
  "${cmd[@]}" "$uri" 2>/dev/null || echo ""
}

gh_api_fail_fast() {
  local res
  res=$(gh_api "$@")
  if [[ -z "$res" || "$res" == *"\"message\""* && "$res" != *"\"id\""* ]]; then
    # We might want to be more careful parsing errors, but for now simple check
    echo "$res"
    return 1
  fi
  echo "$res"
}

jq_val() {
  local json="$1" path="$2" fallback="${3:-}"
  local val
  val=$(echo "$json" | jq -r "$path" 2>/dev/null) || val=""
  [[ -z "$val" || "$val" == "null" ]] && val="$fallback"
  printf '%s' "$val"
}

# ── Stages ───────────────────────────────────────────────────────────────────

# 1. Validate Org
run_validate() {
  echo -e "\e[36m=== GitHub Org Setup Validation: $GH_ORG ===\e[0m"
  
  echo -e "\n\e[33m1. Verifying organization...\e[0m"
  local org_res
  org_res=$(gh_api "/orgs/$GH_ORG")
  if [[ -z "$org_res" || $(jq_val "$org_res" '.message') == "Not Found" ]]; then
    echo -e "\e[31mCannot access org '$GH_ORG'. Verify the org exists and your PAT has admin:org scope.\e[0m"
    exit 1
  fi
  echo -e "\e[32m   Org: $(jq_val "$org_res" '.login') — Plan: $(jq_val "$org_res" '.plan.name')\e[0m"
  
  echo -e "\n\e[33m2. Checking PAT scopes...\e[0m"
  local scopes
  scopes=$(curl -sI -H "$GH_AUTH_HEADER" "https://api.github.com/user" | grep -i "x-oauth-scopes:" | sed 's/.*: //')
  echo -e "\e[90m   PAT scopes: $scopes\e[0m"
  
  for s in "repo" "admin:org" "workflow"; do
    if [[ "$scopes" == *"$s"* ]]; then
      echo -e "\e[32m   [OK] $s\e[0m"
    else
      echo -e "\e[31m   [MISSING] $s — required for migration\e[0m"
    fi
  done
  
  echo -e "\n\e[36mOrg setup validation complete.\e[0m"
}

# 2. Discover ADO Teams
run_discover() {
  echo -e "\e[36m=== Discovery: Exporting ADO Teams ===\e[0m"
  mkdir -p "$OUTPUT_DIR"
  local template_out="${OUTPUT_DIR}/team-mappings-template.json"
  
  # Load User Mappings
  declare -A USER_MAP
  if [[ -f "$USER_MAPPING_FILE" ]]; then
    echo -e "\e[36mLoading user mappings from $USER_MAPPING_FILE...\e[0m"
    # Skip header, read CSV mapping adoEmail -> ghUser
    while IFS=, read -r adoEmail adoName adoUser ghUser ghEmail notes; do
      [[ "$adoEmail" == "ADOEmail" ]] && continue
      [[ -z "$adoEmail" || -z "$ghUser" ]] && continue
      # Trim and lowercase email
      adoEmail=$(echo "$adoEmail" | tr '[:upper:]' '[:lower:]' | xargs)
      ghUser=$(echo "$ghUser" | xargs)
      USER_MAP["$adoEmail"]="$ghUser"
    done < "$USER_MAPPING_FILE"
    echo -e "\e[32mLoaded ${#USER_MAP[@]} user mappings.\e[0m"
  else
    echo -e "\e[33mUser mapping file not found at $USER_MAPPING_FILE. Members won't be resolved.\e[0m"
  fi

  echo -e "\n\e[36mFetching projects from $ADO_ORG_URL...\e[0m"
  local projects_res
  projects_res=$(ado_api "$ADO_ORG_URL/_apis/projects")
  local proj_count
  proj_count=$(jq_val "$projects_res" '.count' 0)
  echo -e "\e[32mFound $proj_count projects.\e[0m"
  
  local MAPPINGS_JSON="[]"
  
  for proj_id in $(echo "$projects_res" | jq -r '.value[]?.id'); do
    local proj_name
    proj_name=$(echo "$projects_res" | jq -r ".value[] | select(.id==\"$proj_id\") | .name")
    echo -e "\n\e[33mProject: $proj_name\e[0m"
    
    local teams_res
    teams_res=$(ado_api "$ADO_ORG_URL/_apis/projects/$proj_id/teams")
    for team_id in $(echo "$teams_res" | jq -r '.value[]?.id'); do
      local team_name
      team_name=$(echo "$teams_res" | jq -r ".value[] | select(.id==\"$team_id\") | .name")
      local team_desc
      team_desc=$(echo "$teams_res" | jq -r ".value[] | select(.id==\"$team_id\") | (.description // \"\")")
      echo -e "\e[90m  Team: $team_name\e[0m"
      
      local gh_team_name
      gh_team_name=$(echo "$team_name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/-\{2,\}/-/g')
      
      local members_res
      members_res=$(ado_api "$ADO_ORG_URL/_apis/projects/$proj_id/teams/$team_id/members")
      
      local maintainers_json="[]"
      local members_json="[]"
      
      for member_id in $(echo "$members_res" | jq -r '.value[]?.identity.id'); do
        local member_obj
        member_obj=$(echo "$members_res" | jq -c ".value[] | select(.identity.id==\"$member_id\")")
        local ado_email
        ado_email=$(jq_val "$member_obj" '.identity.uniqueName' | tr '[:upper:]' '[:lower:]' | xargs)
        local is_admin
        is_admin=$(jq_val "$member_obj" '.isTeamAdmin')
        
        local gh_user="${USER_MAP[$ado_email]:-}"
        if [[ -n "$gh_user" ]]; then
          if [[ "$is_admin" == "true" ]]; then
            maintainers_json=$(echo "$maintainers_json" | jq ". + [\"$gh_user\"]")
          else
            members_json=$(echo "$members_json" | jq ". + [\"$gh_user\"]")
          fi
        fi
      done
      
      local mapping_obj
      mapping_obj=$(jq -n \
        --arg adoProj "$proj_name" \
        --arg adoTeam "$team_name" \
        --arg ghTeam "$gh_team_name" \
        --arg ghDesc "$team_desc" \
        --argjson maintainers "$maintainers_json" \
        --argjson members "$members_json" \
        '{
          adoProject: $adoProj,
          adoTeam: $adoTeam,
          githubTeam: $ghTeam,
          githubTeamDescription: $ghDesc,
          parentTeam: null,
          privacy: "closed",
          maintainers: $maintainers,
          members: $members,
          repositories: []
        }')
      
      MAPPINGS_JSON=$(echo "$MAPPINGS_JSON" | jq ". + [$mapping_obj]")
    done
  done
  
  jq -n --argjson m "$MAPPINGS_JSON" '{ mappings: $m, defaultVisibility: "closed" }' > "$template_out"
  echo -e "\n\e[36mExport Complete. Saved to $template_out\e[0m"
}

# 3. Create Teams
run_create_teams() {
  echo -e "\e[36m=== Creating GitHub Teams ===\e[0m"
  if [[ ! -f "$TEAM_MAPPING_FILE" ]]; then echo "Config $TEAM_MAPPING_FILE not found!"; exit 1; fi
  
  # Strip comments from JSON
  local clean_json
  clean_json=$(sed -e 's/^\s*\/\/.*//' "$TEAM_MAPPING_FILE")
  
  local mappings
  mappings=$(echo "$clean_json" | jq -c '.mappings[]')
  
  while read -r map; do
    local gh_team
    gh_team=$(jq_val "$map" '.githubTeam')
    local gh_desc
    gh_desc=$(jq_val "$map" '.githubTeamDescription')
    local privacy
    privacy=$(jq_val "$map" '.privacy' 'closed')
    local parent
    parent=$(jq_val "$map" '.parentTeam')
    
    echo -e "\e[33mProcessing: $gh_team\e[0m"
    
    local team_res
    team_res=$(gh_api "/orgs/$GH_ORG/teams/$gh_team")
    if [[ -n "$team_res" && $(jq_val "$team_res" '.name') != "" ]]; then
      echo -e "\e[32m  [OK] Team exists.\e[0m"
      
      # Check parent
      if [[ -n "$parent" && "$parent" != "null" ]]; then
        local parent_res
        parent_res=$(gh_api "/orgs/$GH_ORG/teams/$parent")
        if [[ -z "$parent_res" || $(jq_val "$parent_res" '.id') == "" ]]; then
          echo -e "\e[33m    Creating missing parent '$parent'...\e[0m"
          parent_res=$(gh_api "/orgs/$GH_ORG/teams" "POST" "{\"name\":\"$parent\",\"privacy\":\"closed\"}")
        fi
        local parent_id
        parent_id=$(jq_val "$parent_res" '.id')
        gh_api "/orgs/$GH_ORG/teams/$gh_team" "PATCH" "{\"parent_team_id\":$parent_id}" >/dev/null
        echo -e "\e[32m  [UPDATED] Linked to parent '$parent'\e[0m"
      fi
    else
      echo -e "\e[36m  [NEW] Creating team...\e[0m"
      local create_body="{\"name\":\"$gh_team\",\"description\":\"$gh_desc\",\"privacy\":\"$privacy\"}"
      
      if [[ -n "$parent" && "$parent" != "null" ]]; then
        local parent_res
        parent_res=$(gh_api "/orgs/$GH_ORG/teams/$parent")
        if [[ -z "$parent_res" || $(jq_val "$parent_res" '.id') == "" ]]; then
          parent_res=$(gh_api "/orgs/$GH_ORG/teams" "POST" "{\"name\":\"$parent\",\"privacy\":\"closed\"}")
        fi
        local parent_id
        parent_id=$(jq_val "$parent_res" '.id')
        create_body=$(echo "$create_body" | jq ". + {\"parent_team_id\":$parent_id}")
      fi
      
      gh_api "/orgs/$GH_ORG/teams" "POST" "$create_body" >/dev/null
      echo -e "\e[32m  [CREATED] Team '$gh_team'\e[0m"
    fi
  done <<< "$mappings"
}

# 4. Sync Users
run_sync_users() {
  echo -e "\e[36m=== Syncing Users to Teams ===\e[0m"
  if [[ ! -f "$TEAM_MAPPING_FILE" ]]; then echo "Config $TEAM_MAPPING_FILE not found!"; exit 1; fi
  
  local clean_json
  clean_json=$(sed -e 's/^\s*\/\/.*//' "$TEAM_MAPPING_FILE")
  
  # Build whitelist
  local whitelist
  whitelist=$(echo "$clean_json" | jq -r '.mappings[] | (.maintainers[]?, .members[]?)' | grep -v '^$' | sort -u)
  echo -e "\e[36mConfig Whitelist contains $(echo "$whitelist" | wc -w) users.\e[0m"
  
  local mappings
  mappings=$(echo "$clean_json" | jq -c '.mappings[]')
  
  while read -r map; do
    local gh_team
    gh_team=$(jq_val "$map" '.githubTeam')
    echo -e "\e[33mProcessing: $gh_team\e[0m"
    
    # Add Maintainers
    for user in $(echo "$map" | jq -r '.maintainers[]?' | grep -v '^$'); do
      if echo "$whitelist" | grep -qix "$user"; then
        gh_api "/orgs/$GH_ORG/teams/$gh_team/memberships/$user" "PUT" '{"role":"maintainer"}' >/dev/null
        echo -e "\e[32m  [MAINTAINER] $user\e[0m"
      else
        echo -e "\e[31m  [BLOCKED] $user not in whitelist\e[0m"
      fi
    done
    
    # Add Members
    for user in $(echo "$map" | jq -r '.members[]?' | grep -v '^$'); do
      if echo "$whitelist" | grep -qix "$user"; then
        gh_api "/orgs/$GH_ORG/teams/$gh_team/memberships/$user" "PUT" '{"role":"member"}' >/dev/null
        echo -e "\e[32m  [MEMBER] $user\e[0m"
      else
        echo -e "\e[31m  [BLOCKED] $user not in whitelist\e[0m"
      fi
    done
  done <<< "$mappings"
}

# 5. Sync Repos
run_sync_repos() {
  echo -e "\e[36m=== Syncing Repo Permissions ===\e[0m"
  if [[ ! -f "$TEAM_MAPPING_FILE" ]]; then echo "Config $TEAM_MAPPING_FILE not found!"; exit 1; fi
  
  local clean_json
  clean_json=$(sed -e 's/^\s*\/\/.*//' "$TEAM_MAPPING_FILE")
  
  local mappings
  mappings=$(echo "$clean_json" | jq -c '.mappings[]')
  
  while read -r map; do
    local gh_team
    gh_team=$(jq_val "$map" '.githubTeam')
    echo -e "\e[33mProcessing: $gh_team\e[0m"
    
    local repos
    repos=$(echo "$map" | jq -c '.repositories[]?')
    while read -r repo; do
      [[ -z "$repo" || "$repo" == "null" ]] && continue
      local r_name
      r_name=$(jq_val "$repo" '.name')
      local r_perm
      r_perm=$(jq_val "$repo" '.permission')
      
      gh_api "/orgs/$GH_ORG/teams/$gh_team/repos/$GH_ORG/$r_name" "PUT" "{\"permission\":\"$r_perm\"}" >/dev/null
      echo -e "\e[32m  [REPO] $r_name -> $r_perm\e[0m"
    done <<< "$repos"
  done <<< "$mappings"
}

# 6. Offboard Users (Reconcile removals)
run_offboard() {
  echo -e "\e[36m=== Offboarding Users ===\e[0m"
  if [[ ! -f "$TEAM_MAPPING_FILE" ]]; then echo "Config $TEAM_MAPPING_FILE not found!"; exit 1; fi
  
  local clean_json
  clean_json=$(sed -e 's/^\s*\/\/.*//' "$TEAM_MAPPING_FILE")
  
  local mappings
  mappings=$(echo "$clean_json" | jq -c '.mappings[]')
  
  local to_remove_from_org=()
  
  while read -r map; do
    local gh_team
    gh_team=$(jq_val "$map" '.githubTeam')
    echo -e "\n\e[33mReconciling Team: $gh_team\e[0m"
    
    local config_users
    config_users=$(echo "$map" | jq -r '(.maintainers[]?, .members[]?)' | tr '[:upper:]' '[:lower:]' | sort -u)
    
    local current_members_res
    current_members_res=$(gh_api "/orgs/$GH_ORG/teams/$gh_team/members")
    local current_users
    current_users=$(echo "$current_members_res" | jq -r '.[].login' 2>/dev/null | tr '[:upper:]' '[:lower:]' | sort -u)
    
    for u in $current_users; do
      if ! echo "$config_users" | grep -qix "$u"; then
        echo -e "\e[31m  [REMOVING] $u from team $gh_team (Not in config)\e[0m"
        gh_api "/orgs/$GH_ORG/teams/$gh_team/memberships/$u" "DELETE" >/dev/null
        to_remove_from_org+=("$u")
      else
        echo -e "\e[90m  [KEEPING] $u\e[0m"
      fi
    done
  done <<< "$mappings"
  
  if [[ "$REMOVE_FROM_ORG" == "true" && ${#to_remove_from_org[@]} -gt 0 ]]; then
    echo -e "\n\e[36mRemoving unmapped users from entire Organization...\e[0m"
    # Deduplicate
    mapfile -t to_remove_from_org < <(printf "%s\n" "${to_remove_from_org[@]}" | sort -u)
    
    # We should only remove them from the org if they aren't in ANY team's config!
    local all_config_users
    all_config_users=$(echo "$clean_json" | jq -r '.mappings[] | (.maintainers[]?, .members[]?)' | tr '[:upper:]' '[:lower:]' | sort -u)
    
    for u in "${to_remove_from_org[@]}"; do
      if ! echo "$all_config_users" | grep -qix "$u"; then
        echo -e "\e[31m  [REMOVING ORG-WIDE] $u\e[0m"
        gh_api "/orgs/$GH_ORG/members/$u" "DELETE" >/dev/null
      else
        echo -e "\e[90m  [SKIP ORG REMOVAL] $u is still in other teams' configs.\e[0m"
      fi
    done
  fi
}

# 7. Onboard Users (Ensure config users exist in teams)
run_onboard() {
  echo -e "\e[36m=== Onboarding Users ===\e[0m"
  # onboarding is functionally very similar to sync-users, as PUT /memberships is idempotent.
  # We just call run_sync_users.
  run_sync_users
}

# ── Main ─────────────────────────────────────────────────────────────────────
IFS=',' read -ra STAGE_ARRAY <<< "$STAGES"
for stage in "${STAGE_ARRAY[@]}"; do
  stage=$(echo "$stage" | xargs)
  case $stage in
    validate) run_validate ;;
    discover) run_discover ;;
    create-teams) run_create_teams ;;
    sync-users) run_sync_users ;;
    sync-repos) run_sync_repos ;;
    offboard) run_offboard ;;
    onboard) run_onboard ;;
    *) echo -e "\e[33mSkipping unknown stage: $stage\e[0m" ;;
  esac
done
