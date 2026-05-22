#!/bin/bash
set -euo pipefail

# SYNOPSIS
#     Scrubs secrets from Git history using git-filter-repo for repos flagged by scan-secrets.sh.
# DESCRIPTION
#     For each repo with findings in secret-scan-findings.json:
#       - Clones the repo (full)
#       - Runs git-filter-repo to exclude file paths containing secrets
#       - Force-pushes cleaned history back to ADO
#       - Generates credential rotation checklist

configPath="config/repo-migration-config.json"
dryRun=false

# Simple argument parsing
for arg in "$@"; do
    if [[ "$arg" == "--dry-run" || "$arg" == "-DryRun" || "$arg" == "DryRun" ]]; then
        dryRun=true
    elif [[ "$arg" == *"repo-migration-config.json"* ]]; then
        configPath="$arg"
    fi
done

if [ ! -f "$configPath" ]; then
    # try relative to script parent directory
    scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    configPath="$scriptDir/../config/repo-migration-config.json"
    if [ ! -f "$configPath" ]; then
        echo "Error: Config not found at $configPath." >&2
        exit 1
    fi
fi

reportDir=$(jq -r '.output.reportDir' "$configPath")
logDir=$(jq -r '.output.logDir' "$configPath")
cloneDir=$(jq -r '.migration.cloneTempDir' "$configPath")

mkdir -p "$reportDir" "$logDir" "$cloneDir"

findingsPath="$reportDir/secret-scan-findings.json"
if [ ! -f "$findingsPath" ]; then
    echo "Error: secret-scan-findings.json not found. Run 01-discover/scan-secrets.sh first." >&2
    exit 1
fi

findingsCount=$(jq '. | length' "$findingsPath")
if [ "$findingsCount" -eq 0 ]; then
    echo "No secrets found - nothing to scrub."
    exit 0
fi

inventoryPath="$reportDir/repo-inventory.json"
if [ ! -f "$inventoryPath" ]; then
    echo "Error: repo-inventory.json not found." >&2
    exit 1
fi

adoPat="${ADO_PAT:-}"
if [ -z "$adoPat" ]; then
    adoPat=$(jq -r '.source.pat' "$configPath")
    if [[ "$adoPat" == *'$('* || -z "$adoPat" ]]; then
        echo "Error: Set ADO_PAT environment variable" >&2
        exit 1
    fi
fi

# Get list of unique repos with findings
repos=$(jq -r '.[].Repo' "$findingsPath" | sort -u)

echo "=== Secret Scrubbing (${findingsCount} findings, DryRun=$dryRun) ==="

checklistPath="$reportDir/credential-rotation-checklist.csv"
echo "Repo,RuleID,File,Action" > "$checklistPath"

for repoName in $repos; do
    # Get findings for this repo
    repoFindings=$(jq -c --arg repo "$repoName" '.[] | select(.Repo == $repo)' "$findingsPath")
    repoFindingsCount=$(echo "$repoFindings" | grep -c "^{" || true)

    echo ""
    echo "--- $repoName ($repoFindingsCount findings) ---"

    if [ "$dryRun" = true ]; then
        echo "  [DRY RUN] Would scrub $repoFindingsCount secrets from $repoName"
        while read -r finding; do
            if [ -z "$finding" ]; then continue; fi
            ruleId=$(echo "$finding" | jq -r '.RuleID')
            file=$(echo "$finding" | jq -r '.File')
            line=$(echo "$finding" | jq -r '.LineNumber')
            echo "    - $ruleId in $file:$line"
            echo "$repoName,$ruleId,$file,ROTATE_CREDENTIAL" >> "$checklistPath"
        done <<< "$repoFindings"
        continue
    fi

    # Full clone
    repoClonePath="$cloneDir/$repoName"
    rm -rf "$repoClonePath"

    remoteUrl=$(jq -r --arg repo "$repoName" '.[] | select(.Name == $repo) | .RemoteUrl' "$inventoryPath")
    # Clean remoteUrl and inject ADO_PAT
    cloneUrl=$(echo "$remoteUrl" | sed -E "s|://([^@]+@)?|://$adoPat@|")

    echo "  Cloning repository..."
    git clone --quiet "$cloneUrl" "$repoClonePath"

    # Build unique list of files containing secrets
    uniqueFiles=$(echo "$repoFindings" | jq -r '.File' | sort -u)

    # Use git-filter-repo
    pushd "$repoClonePath" >/dev/null
    
    filterCmd=("git" "filter-repo" "--invert-paths" "--force")
    while read -r file; do
        if [ -n "$file" ]; then
            filterCmd+=("--path" "$file")
        fi
    done <<< "$uniqueFiles"

    echo "  Removing files from history..."
    if "${filterCmd[@]}"; then
        # Force push back to ADO
        echo "  Force-pushing cleaned history to ADO..."
        git remote add origin "$cloneUrl" 2>/dev/null || git remote set-url origin "$cloneUrl"
        git push --force --all origin --quiet
        git push --force --tags origin --quiet
        echo "  DONE - history rewritten for $repoName"
    else
        echo "  Warning: Failed to scrub $repoName"
    fi

    popd >/dev/null

    while read -r finding; do
        if [ -z "$finding" ]; then continue; fi
        ruleId=$(echo "$finding" | jq -r '.RuleID')
        file=$(echo "$finding" | jq -r '.File')
        echo "$repoName,$ruleId,$file,ROTATE_CREDENTIAL" >> "$checklistPath"
    done <<< "$repoFindings"
done

# Cleanup clone dir
rm -rf "$cloneDir"/* 2>/dev/null || true

echo ""
echo "=== Scrub Summary ==="
echo "  Credentials to rotate: $(tail -n +2 "$checklistPath" | grep -c "." || true)"
echo "  CRITICAL: Rotate ALL credentials listed in: $checklistPath"
echo "  All developers must re-clone affected repos after history rewrite."
