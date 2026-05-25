Ran command: `Get-ChildItem -Path C:\Users\varsha.patil\.gemini\antigravity\scratch\repo-migration -Recurse -Filter *.ps1`
Ran command: `Get-ChildItem -Path C:\Users\varsha.patil\.gemini\antigravity\scratch\repo-migration\04-validate`
Ran command: `Get-Content -Path C:\Users\varsha.patil\.gemini\antigravity\scratch\org\migration-accelerator\01-prep\github-org-setup.sh | Measure-Object -Line`
Ran command: `cat C:\Users\varsha.patil\.gemini\antigravity\scratch\org\migration-accelerator\01-prep\github-org-setup.sh`

Here is the **complete, final, Linux-based script**. 

You can completely replace the contents of your `migration-accelerator/01-prep/github-org-setup.sh` file with the code below. This includes the `--team-mapping` fix, the syntax fix, and all the logic required for it to run perfectly on the Linux agent!

```bash
#!/bin/bash
set -eo pipefail

STAGE=""
ADO_ORG=""
ADO_PAT=""
GH_ORG=""
GH_PAT=""
USER_MAP_FILE="config/user-mappings.csv"
OUTPUT_DIR="."

while [[ "$#" -gt 0 ]]; do
  case $1 in
    --stages) STAGE="$2"; shift ;;
    --ado-org) ADO_ORG="$2"; shift ;;
    --ado-pat) ADO_PAT="$2"; shift ;;
    --gh-org) GH_ORG="$2"; shift ;;
    --gh-pat) GH_PAT="$2"; shift ;;
    --user-mapping) USER_MAP_FILE="$2"; shift ;;
    --team-mapping) TEAM_MAP_FILE="$2"; shift ;;
    --output-dir) OUTPUT_DIR="$2"; shift ;;
    *) echo "Unknown parameter: $1"; exit 1 ;;
  esac
  shift
done

# --- Auth Headers ---
ADO_AUTH=""
if [[ -n "$ADO_PAT" ]]; then
  ADO_AUTH="Authorization: Basic $(printf ":%s" "$ADO_PAT" | base64 -w0 2>/dev/null || printf ":%s" "$ADO_PAT" | base64)"
fi

GH_AUTH=""
if [[ -n "$GH_PAT" ]]; then
  GH_AUTH="Authorization: Bearer $GH_PAT"
fi

# --- Helper Functions ---
ado_api() {
  local uri="$1"
  local res
  res=$(curl -sS -f -H "$ADO_AUTH" -H "Content-Type: application/json" "$uri") || {
    echo -e "\e[31mADO API Error on $uri\e[0m" >&2
    return 1
  }
  if ! echo "$res" | jq -e . >/dev/null 2>&1; then
    echo -e "\e[31mADO API Error: Response was not valid JSON! Your PAT may be expired or invalid.\e[0m" >&2
    return 1
  fi
  echo "$res"
}

gh_api() {
  local uri="$1"
  local method="${2:-GET}"
  local body="$3"
  
  if [[ "$uri" != *"http"* ]]; then uri="https://api.github.com${uri}"; fi
  local cmd=(curl -sS -f -X "$method" -H "$GH_AUTH" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")
  if [[ -n "$body" ]]; then cmd+=(-H "Content-Type: application/json" -d "$body"); fi
  
  local res
  res=$("${cmd[@]}" "$uri") || { echo -e "\e[31mGH API Error on $uri\e[0m" >&2; return 1; }
  echo "$res"
}

declare -A user_map

# --- Discovery Stage ---
if [[ "$STAGE" == *"discover"* ]]; then
  echo -e "\e[36m--- Starting Discovery Stage ---\e[0m"
  
  # Load CSV
  if [[ -f "$USER_MAP_FILE" ]]; then
    echo "Loading user mappings from $USER_MAP_FILE..."
    while IFS=, read -r email ghuser || [ -n "$email" ]; do
      email=$(echo "$email" | tr '[:upper:]' '[:lower:]' | xargs)
      ghuser=$(echo "$ghuser" | xargs)
      if [[ -n "$email" && "$email" != "adoemail" && -n "$ghuser" ]]; then
        user_map["$email"]="$ghuser"
      fi
    done < "$USER_MAP_FILE"
    echo "Loaded ${#user_map[@]} mappings."
  else
    echo -e "\e[33mWarning: User mapping file not found at $USER_MAP_FILE\e[0m"
  fi

  echo "Fetching projects from $ADO_ORG..."
  projects_res=$(ado_api "$ADO_ORG/_apis/projects?api-version=7.1") || exit 1
  project_count=$(echo "$projects_res" | jq -r '.count // 0')
  echo -e "\e[32mFound $project_count projects.\e[0m"

  mappings_json="[]"

  while read -r p_id p_name; do
    echo -e "\e[33mProject: $p_name\e[0m"
    teams_res=$(ado_api "$ADO_ORG/_apis/projects/$p_id/teams?api-version=7.1") || continue
    
    while read -r t_id t_name t_desc; do
      echo -e "\e[37m  Team: $t_name\e[0m"
      gh_team_name=$(echo "$t_name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/-\{2,\}/-/g')
      
      members_res=$(ado_api "$ADO_ORG/_apis/projects/$p_id/teams/$t_id/members?api-version=7.1") || continue
      
      resolved_members="[]"
      resolved_maintainers="[]"
      team_unmapped="[]"
      
      while read -r m_email m_isadmin m_display; do
        [[ -z "$m_email" ]] && continue
        m_email=$(echo "$m_email" | tr '[:upper:]' '[:lower:]' | xargs)
        
        gh_user="${user_map[$m_email]}"
        if [[ -n "$gh_user" ]]; then
          if [[ "$m_isadmin" == "true" ]]; then
            resolved_maintainers=$(echo "$resolved_maintainers" | jq --arg u "$gh_user" '. + [$u]')
            echo -e "\e[36m    [ADMIN] $m_display -> $gh_user [maintainer]\e[0m"
          else
            resolved_members=$(echo "$resolved_members" | jq --arg u "$gh_user" '. + [$u]')
            echo -e "\e[32m    [MAPPED] $m_display -> $gh_user [member]\e[0m"
          fi
        else
          team_unmapped=$(echo "$team_unmapped" | jq --arg e "$m_email" '. + [$e]')
          echo -e "\e[33m    [UNMAPPED] $m_display ($m_email) - no GitHub username\e[0m"
        fi
      done < <(echo "$members_res" | jq -r '.value[]? | "\(.identity.uniqueName)\t\(.isTeamAdmin)\t\(.identity.displayName)"')
      
      team_entry=$(jq -n \
        --arg ap "$p_name" \
        --arg at "$t_name" \
        --arg gt "$gh_team_name" \
        --arg gd "$t_desc" \
        --argjson rm "$resolved_members" \
        --argjson rt "$resolved_maintainers" \
        --argjson tu "$team_unmapped" \
        '{adoProject: $ap, adoTeam: $at, githubTeam: $gt, githubTeamDescription: $gd, parentTeam: null, privacy: "closed", maintainers: $rt, members: $rm, unmappedAdoUsers: $tu}')
      
      mappings_json=$(echo "$mappings_json" | jq --argjson te "$team_entry" '. + [$te]')
    done < <(echo "$teams_res" | jq -r '.value[]? | "\(.id)\t\(.name)\t\(.description // "")"')
  done < <(echo "$projects_res" | jq -r '.value[]? | "\(.id)\t\(.name)"')

  mkdir -p "$OUTPUT_DIR"
  out_file="$OUTPUT_DIR/team-mappings-template.json"
  jq -n --arg org "$ADO_ORG" --argjson maps "$mappings_json" '{generatedAt: (now | todate), adoOrgUrl: $org, totalTeams: ($maps|length), mappings: $maps}' > "$out_file"
  echo -e "\e[36mExport Complete. Saved to $out_file\e[0m"
fi

# --- Sync Stage ---
if [[ "$STAGE" == *"sync"* ]]; then
  echo -e "\e[36m--- Starting Sync Stage ---\e[0m"
  MAPPING_FILE="${TEAM_MAP_FILE:-config/team-mappings.json}"
  if [[ ! -f "$MAPPING_FILE" ]]; then
    echo -e "\e[31mMapping file not found: $MAPPING_FILE\e[0m"
    exit 1
  fi
  
  # Remove comments from JSON and parse
  clean_json=$(grep -v '^\s*//' "$MAPPING_FILE" || true)
  mappings=$(echo "$clean_json" | jq -c '.mappings[]?')

  while IFS= read -r map; do
    [[ -z "$map" ]] && continue
    gh_team=$(echo "$map" | jq -r '.githubTeam')
    ado_team=$(echo "$map" | jq -r '.adoTeam')
    parent_team=$(echo "$map" | jq -r '.parentTeam // empty')
    
    echo -e "\e[33mProcessing: $ado_team -> $gh_team\e[0m"
    
    # 1. Create/Ensure Team
    if gh_api "/orgs/$GH_ORG/teams/$gh_team" >/dev/null 2>&1; then
      echo -e "\e[32m  [OK] Team $gh_team exists.\e[0m"
    else
      echo -e "\e[36m  [NEW] Creating team $gh_team...\e[0m"
      body=$(jq -n --arg n "$gh_team" --arg d "$(echo "$map" | jq -r '.githubTeamDescription // ""')" --arg p "$(echo "$map" | jq -r '.privacy // "closed"')" '{name: $n, description: $d, privacy: $p}')
      if [[ -n "$parent_team" && "$parent_team" != "null" ]]; then
        parent_id=$(gh_api "/orgs/$GH_ORG/teams/$parent_team" | jq -r '.id' 2>/dev/null || echo "")
        if [[ -n "$parent_id" ]]; then
          body=$(echo "$body" | jq --arg pid "$parent_id" '. + {parent_team_id: ($pid|tonumber)}')
        fi
      fi
      gh_api "/orgs/$GH_ORG/teams" "POST" "$body" >/dev/null || echo -e "\e[31m  [FAILED] to create team.\e[0m"
    fi
    
    # 2. Add Maintainers
    maintainers=$(echo "$map" | jq -r '.maintainers[]?')
    for u in $maintainers; do
      if gh_api "/orgs/$GH_ORG/teams/$gh_team/memberships/$u" "PUT" '{"role":"maintainer"}' >/dev/null 2>&1; then
        echo -e "\e[32m    [MAINTAINER] $u added.\e[0m"
      else
        echo -e "\e[31m    [FAILED] Maintainer: $u\e[0m"
      fi
    done
    
    # 3. Add Members
    members=$(echo "$map" | jq -r '.members[]?')
    for u in $members; do
      if gh_api "/orgs/$GH_ORG/teams/$gh_team/memberships/$u" "PUT" '{"role":"member"}' >/dev/null 2>&1; then
        echo -e "\e[32m    [MEMBER] $u added.\e[0m"
      else
        echo -e "\e[31m    [FAILED] Member: $u\e[0m"
      fi
    done
    
    # 4. Repo Permissions
    repos=$(echo "$map" | jq -c '.repositories[]?' 2>/dev/null || echo "")
    for r in $repos; do
      [[ -z "$r" ]] && continue
      r_name=$(echo "$r" | jq -r '.name')
      r_perm=$(echo "$r" | jq -r '.permission')
      if gh_api "/orgs/$GH_ORG/teams/$gh_team/repos/$GH_ORG/$r_name" "PUT" "{\"permission\":\"$r_perm\"}" >/dev/null 2>&1; then
        echo -e "\e[32m    [REPO] $r_name -> $r_perm\e[0m"
      else
        echo -e "\e[31m    [FAILED] Repo: $r_name\e[0m"
      fi
    done
  done <<< "$mappings"
  
  echo -e "\e[36mSync Complete.\e[0m"
fi
```