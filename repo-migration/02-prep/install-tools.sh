#!/bin/bash
set -euo pipefail

# SYNOPSIS
#     Installs and validates all tools required for repo migration.
# DESCRIPTION
#     Checks for: git, gh CLI, gh-gei extension, git-sizer, gitleaks, git-filter-repo.
#     Installs missing tools where possible (via apt, gh extension install, pip3).

echo "=== Checking required tools ==="

tools=(
    "git;git --version;sudo apt-get update && sudo apt-get install -y git"
    "gh;gh --version;sudo apt-get update && sudo apt-get install -y gh"
    "gh-gei;gh gei --help;gh extension install github/gh-gei"
    "git-sizer;git-sizer --version;echo 'Download from https://github.com/github/git-sizer/releases'"
    "gitleaks;gitleaks version;echo 'Download from https://github.com/gitleaks/gitleaks/releases'"
    "git-filter-repo;git filter-repo --version;pip3 install git-filter-repo"
)

missing=()

for item in "${tools[@]}"; do
    IFS=";" read -r name cmd install <<< "$item"
    printf "  %s... " "$name"
    if eval "$cmd" >/dev/null 2>&1; then
        version=$(eval "$cmd" 2>&1 | head -n 1)
        echo "OK ($version)"
    else
        echo "MISSING"
        missing+=("$item")
    fi
done

if [ ${#missing[@]} -gt 0 ]; then
    echo ""
    echo "=== Missing tools ==="
    for item in "${missing[@]}"; do
        IFS=";" read -r name cmd install <<< "$item"
        echo "  $name: $install"
    done
    echo ""
    read -r -p "Proceed with automated installs? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        for item in "${missing[@]}"; do
            IFS=";" read -r name cmd install <<< "$item"
            echo ""
            echo "Installing $name..."
            if eval "$install"; then
                echo "  Installed $name"
            else
                echo "  Warning: Failed to install $name. Install manually: $install"
            fi
        done
    fi
else
    echo ""
    echo "All tools installed!"
fi

# Validate GEI auth
echo ""
echo "=== Checking environment variables ==="
envVars=("ADO_PAT" "GH_PAT")
for var in "${envVars[@]}"; do
    val="${!var:-}"
    if [ -z "$val" ]; then
        echo "  $var : NOT SET"
    else
        echo "  $var : Set (${#val} chars)"
    fi
done

echo ""
echo "Done. Ensure all tools are green and env vars are set before proceeding."
