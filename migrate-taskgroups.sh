#!/bin/bash

# ==============================================================================
# Azure DevOps Task Group Discovery & Migration Script
# 
# This script uses GitHub Actions Importer to explicitly discover all Task Groups
# in an ADO project and migrate them into GitHub Actions Composite Actions.
# ==============================================================================

set -e

# ANSI escape codes for coloring
CYAN='\e[36m'
GREEN='\e[32m'
YELLOW='\e[33m'
RED='\e[31m'
NC='\e[0m' # No Color

echo -e "${CYAN}========================================================${NC}"
echo -e "${CYAN} ADO Task Group Discovery & Migration Script${NC}"
echo -e "${CYAN}========================================================${NC}"

# ------------------------------------------------------------------------------
# Configuration Variables - UPDATE THESE BEFORE RUNNING
# ------------------------------------------------------------------------------
ADO_ORG="your-ado-organization"
ADO_PROJECT="your-ado-project"
ADO_PAT="your-ado-pat"

GH_ORG="your-github-organization"
GH_PAT="your-github-pat"

# The target repository in GitHub where you want all the Task Groups to be saved
GH_TARGET_REPO="$GH_ORG/reusable-workflows" 

# GEI requires at least ONE valid pipeline ID to act as an "anchor" to authenticate 
# and pull the project's task groups. Pick ANY valid pipeline ID from your ADO project.
ANCHOR_PIPELINE_ID="123" 

OUTPUT_DIR="./taskgroup-migration-output"

# ------------------------------------------------------------------------------
# 1. Prerequisite Setup
# ------------------------------------------------------------------------------
export GITHUB_ACCESS_TOKEN="$GH_PAT"
export AZURE_DEVOPS_ACCESS_TOKEN="$ADO_PAT"

mkdir -p "$OUTPUT_DIR"

echo -e "\n${YELLOW}Step 1: Ensuring GitHub Actions Importer is up to date...${NC}"
gh actions-importer update

# ------------------------------------------------------------------------------
# 2. DISCOVER: Scan ADO for Task Groups
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Step 2: Discovering Task Groups in ADO Project: $ADO_PROJECT...${NC}"

# Running an audit scans the project and generates a config.yml containing all task groups
gh actions-importer audit azure-devops \
    --output-dir "$OUTPUT_DIR" \
    --azure-devops-organization "$ADO_ORG" \
    --azure-devops-project "$ADO_PROJECT" > /dev/null 2>&1

CONFIG_FILE="$OUTPUT_DIR/config.yml"

if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Error: Failed to discover any Task Groups or generate config.yml.${NC}"
    exit 1
fi

echo -e "${GREEN}Discovery Complete!${NC}"
echo -e "\n${CYAN}The following Task Groups were found and will be migrated:${NC}"
# Parse the config.yml to just show the user the names of the task groups found
grep 'name:' "$CONFIG_FILE" | sed 's/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/  - /'

# ------------------------------------------------------------------------------
# 3. CONFIGURE: Route all Task Groups to the target GitHub Repo
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Step 3: Configuring Task Groups for GitHub Actions format...${NC}"

# We modify the config.yml to ensure every task group is directed to your target GitHub repo
TEMP_CONFIG="$CONFIG_FILE.tmp"
rm -f "$TEMP_CONFIG"

TARGET_URL="https://github.com/$GH_TARGET_REPO"

while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^([[:space:]]*)-[[:space:]]+name:[[:space:]]+([^[:space:]]+) ]]; then
        raw_name="${BASH_REMATCH[2]}"
        # Create a clean folder name for GitHub Actions (lowercase, no spaces)
        folderName=$(echo "$raw_name" | sed -E 's/\.ya?ml$//I' | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]/_/g')
        
        echo "$line" >> "$TEMP_CONFIG"
        echo "      target_url: $TARGET_URL" >> "$TEMP_CONFIG"
        echo "      ref: main" >> "$TEMP_CONFIG"
        echo "      path: .github/actions/$folderName" >> "$TEMP_CONFIG"
    elif [[ "$line" =~ ^[[:space:]]+target_url: ]] || [[ "$line" =~ ^[[:space:]]+ref: ]] || [[ "$line" =~ ^[[:space:]]+path: ]]; then
        # Skip existing routing lines
        continue
    else
        echo "$line" >> "$TEMP_CONFIG"
    fi
done < "$CONFIG_FILE"

mv "$TEMP_CONFIG" "$CONFIG_FILE"

# ------------------------------------------------------------------------------
# 4. MIGRATE: Convert to GitHub Composite Actions and create Pull Requests
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Step 4: Migrating Task Groups to GitHub ($GH_TARGET_REPO)...${NC}"

# We use the 'pipeline' command under the hood, but feed it the config.yml to force 
# it to process the reusable task groups we discovered.
gh actions-importer migrate azure-devops pipeline \
    --output-dir "$OUTPUT_DIR/migrated-files" \
    --azure-devops-organization "$ADO_ORG" \
    --azure-devops-project "$ADO_PROJECT" \
    --pipeline-id "$ANCHOR_PIPELINE_ID" \
    --config-file-path "$CONFIG_FILE" \
    --target-url "$TARGET_URL"

echo -e "\n${GREEN}========================================================${NC}"
echo -e "${GREEN} Task Group Migration Complete!${NC}"
echo -e "${GREEN}========================================================${NC}"
echo -e "Check your GitHub repository ($GH_TARGET_REPO) for the new Pull Requests containing your converted Task Groups (Composite Actions)."
