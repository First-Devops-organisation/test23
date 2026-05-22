#!/usr/bin/env bash
# ==============================================================================
# Multi-Repo GitHub Environment Setup -- Linux/Ubuntu (Bash)
# ==============================================================================
#
# SYNOPSIS:
#   Sets up GitHub deployment environments for multiple repositories from a CSV.
#
# USAGE:
#   # Dry-run first
#   ./setup-env-multi.sh --org "My-Org" --dry-run
#
#   # Execute for real
#   ./setup-env-multi.sh --org "My-Org" --csv ./repos.csv
#
#   # Custom retries and log path
#   ./setup-env-multi.sh --org "My-Org" --csv ./repos.csv --retries 3 --log /tmp/setup.log
#
# PREREQUISITES:
#   - gh CLI installed and authenticated (gh auth login)
#   - jq installed (sudo apt-get install jq)
#   - CSV file with header row (see repos.csv)
#
# ==============================================================================

set -euo pipefail

# ==============================================================================
# DEFAULTS
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_ORG=""
CSV_PATH="${SCRIPT_DIR}/repos.csv"
DRY_RUN=false
MAX_RETRIES=2
LOG_PATH="/tmp/setup-env-multi-$(date +%Y%m%d-%H%M%S).log"

# ==============================================================================
# COLORS
# ==============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ==============================================================================
# COUNTERS FOR SUMMARY
# ==============================================================================
TOTAL=0
SUCCESS_COUNT=0
FAILED_COUNT=0
SKIPPED_COUNT=0
SUMMARY_LINES=()

# ==============================================================================
# USAGE
# ==============================================================================
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Required:
  --org <name>        GitHub organization name

Optional:
  --csv <path>        Path to CSV config file (default: ./repos.csv)
  --dry-run           Validate only, no API calls
  --retries <n>       Max retries for failed API calls (default: 2, max: 5)
  --log <path>        Log file path (default: /tmp/setup-env-multi-<timestamp>.log)
  -h, --help          Show this help message

Examples:
  $(basename "$0") --org "My-Org" --dry-run
  $(basename "$0") --org "My-Org" --csv ./prod-repos.csv --retries 3
EOF
    exit 0
}

# ==============================================================================
# ARGUMENT PARSING
# ==============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --org)       GH_ORG="$2"; shift 2 ;;
        --csv)       CSV_PATH="$2"; shift 2 ;;
        --dry-run)   DRY_RUN=true; shift ;;
        --retries)   MAX_RETRIES="$2"; shift 2 ;;
        --log)       LOG_PATH="$2"; shift 2 ;;
        -h|--help)   usage ;;
        *)           echo "Unknown option: $1"; usage ;;
    esac
done

# Validate required args
if [[ -z "$GH_ORG" ]]; then
    echo -e "${RED}ERROR: --org is required${NC}"
    usage
fi

if [[ "$MAX_RETRIES" -gt 5 ]]; then
    MAX_RETRIES=5
fi

# ==============================================================================
# LOGGING
# ==============================================================================
log() {
    local level="${1}"
    local message="${2}"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local log_entry="[${timestamp}] [${level}] ${message}"

    case "$level" in
        INFO)    echo -e "${CYAN}${log_entry}${NC}" >&2 ;;
        WARN)    echo -e "${YELLOW}${log_entry}${NC}" >&2 ;;
        ERROR)   echo -e "${RED}${log_entry}${NC}" >&2 ;;
        SUCCESS) echo -e "${GREEN}${log_entry}${NC}" >&2 ;;
        DEBUG)   echo -e "${GRAY}${log_entry}${NC}" >&2 ;;
    esac

    echo "${log_entry}" >> "${LOG_PATH}"
}

# ==============================================================================
# GH API WRAPPER WITH RETRY + EXPONENTIAL BACKOFF
# ==============================================================================
invoke_gh_api() {
    local method="$1"
    local endpoint="$2"
    local input_file="${3:-}"

    local attempt
    for attempt in $(seq 1 $((MAX_RETRIES + 1))); do
        local args=("api" "-X" "${method}" "${endpoint}" "--header" "Accept: application/vnd.github+json")
        if [[ -n "$input_file" ]]; then
            args+=("--input" "${input_file}")
        fi

        local result
        if result=$(gh "${args[@]}" 2>&1); then
            echo "${result}"
            return 0
        fi

        # Check for non-retryable errors
        if echo "${result}" | grep -qiE "404|Not Found"; then
            log "ERROR" "Resource not found: ${endpoint}"
            return 1
        fi
        if echo "${result}" | grep -qiE "422|Validation Failed"; then
            log "ERROR" "Validation error on ${endpoint} -- check input payload"
            return 1
        fi

        if [[ "$attempt" -le "$MAX_RETRIES" ]]; then
            local wait_seconds=$((2 ** attempt))
            log "WARN" "Attempt ${attempt} failed for ${method} ${endpoint}. Retrying in ${wait_seconds}s..."
            sleep "${wait_seconds}"
        else
            log "ERROR" "All ${attempt} attempts failed for ${method} ${endpoint}: ${result}"
            return 1
        fi
    done
}

# ==============================================================================
# REVIEWER LOOKUP WITH CACHE
# ==============================================================================
declare -A USER_ID_CACHE

get_github_user_id() {
    local username="$1"

    # Check cache
    if [[ -v USER_ID_CACHE["${username}"] ]]; then
        echo "${USER_ID_CACHE[${username}]}"
        return 0
    fi

    local user_id
    user_id=$(gh api "users/${username}" --jq '.id' 2>/dev/null) || true

    if [[ -n "$user_id" && "$user_id" =~ ^[0-9]+$ ]]; then
        USER_ID_CACHE["${username}"]="${user_id}"
        log "DEBUG" "  Resolved ${username} -> ID ${user_id}"
        echo "${user_id}"
        return 0
    fi

    log "WARN" "  Could not resolve username '${username}' -- skipping"
    return 1
}

# ==============================================================================
# SETUP SINGLE ENVIRONMENT
# ==============================================================================
setup_environment() {
    local org="$1"
    local repo="$2"
    local env_name="$3"
    local branch_name="$4"
    local reviewers_str="$5"
    local wait_timer="$6"

    local repo_slug="${org}/${repo}"
    log "INFO" "--- Setting up '${env_name}' on ${repo_slug} ---"

    # 1. Build reviewer JSON array
    local reviewers_json="[]"
    if [[ -n "$reviewers_str" ]]; then
        local reviewer_array=()
        IFS='|' read -ra USERNAMES <<< "${reviewers_str}"
        for username in "${USERNAMES[@]}"; do
            username="$(echo "${username}" | xargs)"  # trim whitespace
            [[ -z "$username" ]] && continue

            local uid
            if uid=$(get_github_user_id "${username}"); then
                reviewer_array+=("{\"type\":\"User\",\"id\":${uid}}")
            fi
        done

        if [[ ${#reviewer_array[@]} -gt 0 ]]; then
            reviewers_json="[$(IFS=,; echo "${reviewer_array[*]}")]"
        fi
    fi

    # 2. Build environment config JSON
    local env_json
    if [[ "$reviewers_json" != "[]" ]]; then
        env_json=$(cat <<ENDJSON
{
  "wait_timer": ${wait_timer},
  "reviewers": ${reviewers_json},
  "deployment_branch_policy": {
    "protected_branches": false,
    "custom_branch_policies": true
  }
}
ENDJSON
)
    else
        env_json=$(cat <<ENDJSON
{
  "wait_timer": ${wait_timer},
  "deployment_branch_policy": {
    "protected_branches": false,
    "custom_branch_policies": true
  }
}
ENDJSON
)
    fi

    # 3. Write JSON to temp file
    local env_json_file
    env_json_file="$(mktemp /tmp/env-config-${repo}-${env_name}-XXXXXX.json)"
    echo "${env_json}" > "${env_json_file}"
    log "DEBUG" "  Payload: ${env_json}"

    # 4. Create / Update environment
    if [[ "$DRY_RUN" == true ]]; then
        log "INFO" "  [DRY-RUN] Would PUT repos/${repo_slug}/environments/${env_name}"
    else
        if ! invoke_gh_api "PUT" "repos/${repo_slug}/environments/${env_name}" "${env_json_file}" > /dev/null; then
            rm -f "${env_json_file}"
            return 1
        fi
        log "SUCCESS" "  Environment '${env_name}' applied"
    fi

    # 5. Clean existing branch policies (idempotent re-runs)
    if [[ "$DRY_RUN" == false ]]; then
        log "DEBUG" "  Cleaning old branch policies..."
        local policy_ids
        policy_ids=$(gh api "repos/${repo_slug}/environments/${env_name}/deployment-branch-policies" \
            --jq '.branch_policies[].id' 2>/dev/null) || true

        while IFS= read -r policy_id; do
            [[ -z "$policy_id" ]] && continue
            invoke_gh_api "DELETE" "repos/${repo_slug}/environments/${env_name}/deployment-branch-policies/${policy_id}" > /dev/null
            log "DEBUG" "  Deleted old policy ${policy_id}"
        done <<< "${policy_ids}"
    fi

    # 6. Add branch deployment rule
    local branch_json_file
    branch_json_file="$(mktemp /tmp/branch-config-${repo}-${env_name}-XXXXXX.json)"
    echo "{\"name\":\"${branch_name}\"}" > "${branch_json_file}"

    if [[ "$DRY_RUN" == true ]]; then
        log "INFO" "  [DRY-RUN] Would lock branch to '${branch_name}'"
    else
        if ! invoke_gh_api "POST" "repos/${repo_slug}/environments/${env_name}/deployment-branch-policies" "${branch_json_file}" > /dev/null; then
            rm -f "${env_json_file}" "${branch_json_file}"
            return 1
        fi
        log "SUCCESS" "  Branch locked to '${branch_name}'"
    fi

    # 7. Cleanup temp files
    rm -f "${env_json_file}" "${branch_json_file}"
    return 0
}

# ==============================================================================
# MAIN
# ==============================================================================
main() {
    log "INFO" "=========================================="
    log "INFO" "  Multi-Repo Environment Setup (Linux)"
    log "INFO" "=========================================="
    log "INFO" "Org      : ${GH_ORG}"
    log "INFO" "CSV      : ${CSV_PATH}"
    log "INFO" "Log      : ${LOG_PATH}"
    log "INFO" "Dry-Run  : ${DRY_RUN}"
    log "INFO" "Retries  : ${MAX_RETRIES}"
    log "INFO" ""

    # -- Pre-flight checks --
    if ! command -v gh &> /dev/null; then
        log "ERROR" "GitHub CLI (gh) is not installed. Install: https://cli.github.com"
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        log "WARN" "jq is not installed. Some features may not work. Install: sudo apt-get install jq"
    fi

    if ! gh auth status &> /dev/null; then
        log "ERROR" "Not authenticated with gh CLI. Run 'gh auth login' first."
        exit 1
    fi
    log "SUCCESS" "gh CLI authenticated OK"

    if [[ ! -f "$CSV_PATH" ]]; then
        log "ERROR" "CSV file not found: ${CSV_PATH}"
        exit 1
    fi

    # -- Parse CSV --
    # Read non-empty, non-comment lines, skip header
    mapfile -t data_lines < <(grep -v '^\s*#' "${CSV_PATH}" | grep -v '^\s*$' | tail -n +2)

    local total_rows=${#data_lines[@]}
    if [[ "$total_rows" -eq 0 ]]; then
        log "WARN" "CSV file has no data rows."
        exit 0
    fi

    log "INFO" "Found ${total_rows} environment configuration(s) to process."
    log "INFO" ""

    # -- Process each row --
    local row_index=0

    for line in "${data_lines[@]}"; do
        ((row_index++)) || true
        TOTAL=$row_index

        # Parse CSV columns
        IFS=',' read -r repo env_name branch reviewers wait_timer <<< "${line}"

        # Trim whitespace
        repo="$(echo "${repo}" | xargs)"
        env_name="$(echo "${env_name}" | xargs)"
        branch="$(echo "${branch}" | xargs)"
        reviewers="$(echo "${reviewers}" | xargs)"
        wait_timer="$(echo "${wait_timer}" | xargs)"

        # Default wait_timer
        [[ -z "$wait_timer" ]] && wait_timer=0

        # Validate required fields
        if [[ -z "$repo" || -z "$env_name" || -z "$branch" ]]; then
            log "WARN" "Row ${row_index} -- Missing required field(s). Skipping: ${line}"
            ((SKIPPED_COUNT++)) || true
            SUMMARY_LINES+=("$(printf '  %-4s %-25s %-15s %-12s %s' "${row_index}" "${repo:-?}" "${env_name:-?}" "SKIPPED" "Missing required field")")
            continue
        fi

        log "INFO" ""
        log "INFO" "=== Row ${row_index} / ${total_rows}: ${repo} [${env_name}] ==="

        if setup_environment "${GH_ORG}" "${repo}" "${env_name}" "${branch}" "${reviewers}" "${wait_timer}"; then
            local status
            if [[ "$DRY_RUN" == true ]]; then
                status="DRY-RUN OK"
            else
                status="SUCCESS"
            fi
            ((SUCCESS_COUNT++)) || true
            SUMMARY_LINES+=("$(printf '  %-4s %-25s %-15s %-12s' "${row_index}" "${repo}" "${env_name}" "${status}")")
        else
            ((FAILED_COUNT++)) || true
            SUMMARY_LINES+=("$(printf '  %-4s %-25s %-15s %-12s %s' "${row_index}" "${repo}" "${env_name}" "FAILED" "See log for details")")
        fi
    done

    # -- Summary Report --
    log "INFO" ""
    log "INFO" "=========================================="
    log "INFO" "  SUMMARY REPORT"
    log "INFO" "=========================================="
    log "INFO" "Total: ${TOTAL}  |  Success: ${SUCCESS_COUNT}  |  Failed: ${FAILED_COUNT}  |  Skipped: ${SKIPPED_COUNT}"
    log "INFO" ""
    log "INFO" "$(printf '  %-4s %-25s %-15s %-12s %s' 'Row' 'Repo' 'Env' 'Status' 'Error')"
    log "INFO" "  $(printf '%.0s-' {1..70})"

    for summary_line in "${SUMMARY_LINES[@]}"; do
        log "INFO" "${summary_line}"
    done

    log "INFO" ""
    log "INFO" "Full log saved to: ${LOG_PATH}"

    # Exit code
    if [[ "$FAILED_COUNT" -gt 0 ]]; then
        log "WARN" "Completed with ${FAILED_COUNT} failure(s)."
        exit 1
    fi

    log "SUCCESS" "All environments configured successfully!"
    exit 0
}

# Run
main
